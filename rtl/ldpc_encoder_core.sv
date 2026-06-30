import ldpc_pkg::*;

module ldpc_encoder_core #(
  // Top-level parameters mirroring the sub-modules
  parameter int ZC_PER_CS = 96,
  parameter int NUM_CS = 4
) (
  input logic clk_i,
  input logic arst_ni,

  // from config reg to input buffer to core
  // will not change for a processing cycle
  input logic base_graph_i,
  input logic [15:0] input_bits_i,
  input logic [15:0] output_bits_i,
  input logic [ZC_WIDTH-1:0] lifting_size_i, 

  output logic idle_o,

  output logic inbuff_clear_o,
  input logic inbuff_valid_i,
  output logic [KB_WIDTH-1:0] info_group_sel_o,
  input logic [ZC_MAX-1:0] info_group_i,

  output logic codeword_valid_o,
  input logic [COL_WIDTH-1:0] r_addr_i,
  output logic [ZC_MAX-1:0] r_data_o,
  input logic codeword_done_i,

  output logic [ZC_WIDTH-1:0] lifting_size_o,
  // Plain 2-bit vector (zc_group_t encoding) so the Verilog top level can
  // route it to the output buffer without SV enum typing at the boundary.
  output logic [1:0] zc_group_o,
  output logic base_graph_o
);

localparam int unsigned IDX_WIDTH = $clog2(NUM_CS);

// Frame configuration, registered. Updated only while the core is IDLE so it
// tracks the (AXIL-stable) config wires up to the moment a frame starts, then
// stays frozen for the whole codeword. Every internal user reads the _q view.
// The register is loaded in IDLE; the LOAD state below gives it (and the CSR
// decoder fed by it) a settling cycle before CALC_LAMBDA.
logic                base_graph_q;
logic [ZC_WIDTH-1:0] lifting_size_q;

// Input Transform
zc_group_t zc_group; // Zc parallelism case selector
always_comb begin
  if (lifting_size_q > (ZC_MAX >> 1)) zc_group = ZC_LARGE;        // zc > 192
  else if (lifting_size_q > (ZC_MAX >> 2)) zc_group = ZC_MEDIUM;  // zc > 96
  else zc_group = ZC_SMALL;
end

logic [3:0][(ZC_MAX >> 2)-1:0] data_segment;
always_comb begin
    case (zc_group)
    // info_group_i is LSB-packed (active bits in [Zc-1:0]).  The barrel shifter
    // masks the BOTTOM zc_in bits of each 96-bit sub-lane, so no alignment
    // shift is needed: the natural LSB packing passes through the DBP forward
    // interleave and lands in [z_per_d-1:0] of every sub-lane automatically.
    ZC_SMALL: for (int unsigned j = 0; j < 4; j++)
            data_segment[j] = info_group_i[0 +: (ZC_MAX >> 2)];
    ZC_MEDIUM: for (int unsigned j = 0; j < 2; j++)
            {data_segment[j*2+1], data_segment[j*2]} = info_group_i[0 +: (ZC_MAX >> 1)];
    ZC_LARGE: {data_segment} = info_group_i;
    default: {data_segment} = '0;
    endcase
end
  
logic cw_ready;
logic cw_last_col;

// Which row within the rowgrp is being processed; drives merge_select_lambda,
// cpb_en, and the top_level_shifter q-lane selection. Declared early so it is
// visible at the top_level_shifter instantiation above its assigning always_ff.
logic [1:0] merge_d_cycle;

// Row counters
// initial 4 row counter for CALC_LAMBDA
logic [ROW_WIDTH-1:0] row_cnt_q, row_cnt_n;
logic [ROW_WIDTH-1:0] row_limit;
// logic [KB_WIDTH-1:0] kb_max;
logic rowgrp_changed_q, rowgrp_changed_qdly; // row group change signal
logic csr_valid_q, csr_valid_qdly;
logic csr_start;
// logic stall_en;

// assign kb_max = base_graph_q ? KB_WIDTH'(KB_BG2-1) : KB_WIDTH'(KB_BG1-1);
assign row_limit = (base_graph_q)?
    ROW_WIDTH'(BG2_ROW_N) : ROW_WIDTH'(BG1_ROW_N);

// cw_last_col is registered below (after the FSM): it must pulse exactly on
// the final additional-parity hand-off cycle, i.e. one cycle after the last
// row-group's rowgrp_changed edge. It cannot be derived combinationally from
// rowgrp_changed_qdly because row_cnt_q has already been reset by then.

// FSM
typedef enum logic [2:0] {
  IDLE,
  LOAD,        // 1 settling cycle: config registered, CSR decoder kicked off
  CALC_LAMBDA,
  CALC_PC,
  CALC_PA
} state_t;

state_t state_q, state_n;
logic [1:0] pc_state_cnt_q;

// High from the 2nd LOAD cycle onward: the config has had one cycle in LOAD to
// settle onto lifting_size_i/base_graph_i, so it's safe to latch it and start
// the CSR decoder. (The new frame's config arrives ~1 cycle into LOAD, after
// the IDLE->LOAD edge, so capturing on that edge sampled the OLD value.)
logic cfg_settled;
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni)             cfg_settled <= 1'b0;
  else if (state_q == LOAD) cfg_settled <= 1'b1;
  else                      cfg_settled <= 1'b0;
end

// Capture frame config ONCE, at the instant we commit to a new frame
// (IDLE -> LOAD). The register must NOT track the config wires during IDLE:
// the codeword generator may still be draining the previous frame's core
// parity, which core_parity_bit_calculator derives combinationally from
// base_graph/z, so a mid-IDLE config change would corrupt that read-out.
// Held stable through LOAD and all CALC states; LOAD gives the freshly
// captured value a settling cycle before CALC_LAMBDA.
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    base_graph_q   <= '0;
    lifting_size_q <= '0;
  end else if (state_q == LOAD) begin
    // Latch config DURING LOAD (not on the IDLE->LOAD edge): the new frame's
    // config has settled onto the wires by then. Still never changes during
    // IDLE, so the codeword generator's previous-frame drain is undisturbed.
    base_graph_q   <= base_graph_i;
    lifting_size_q <= lifting_size_i;
  end
end

// TODO: check if this needs guarding when certain states
always_comb begin
  case (zc_group)
    ZC_SMALL: row_cnt_n = row_cnt_q + ROW_WIDTH'(1'b1 << 2);
    ZC_MEDIUM: row_cnt_n = row_cnt_q + ROW_WIDTH'(1'b1 << 1);
    ZC_LARGE: row_cnt_n = row_cnt_q + ROW_WIDTH'(1'b1 << 0);
    default: row_cnt_n = row_cnt_q;
  endcase  
end

always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    row_cnt_q <= '0;
    inbuff_clear_o <= 0;
  end
  else if (state_q == IDLE) begin
    row_cnt_q <= row_cnt_q;
    inbuff_clear_o <= 0;
  end
  else if (rowgrp_changed_q & ~rowgrp_changed_qdly) begin
    if (row_cnt_n >= row_limit) begin
      // transition to IDLE after processing is finished
      row_cnt_q <= '0;
      inbuff_clear_o = 1;
    end else begin
      row_cnt_q <= row_cnt_n;
      inbuff_clear_o <= 0;
    end
  end    
end

// TODO: optimize this (new state?)
logic csr_start_init, csr_start_calc;

// Kick the CSR decoder off in LOAD, once base_graph_q / lifting_size_q have
// been registered. (Previously this fired in IDLE off the raw config wires.)
assign csr_start_init = (state_q == LOAD) & cfg_settled;
assign csr_start_calc = (state_q != IDLE) & (state_q != LOAD)
                      & (rowgrp_changed_qdly & (row_cnt_q < row_limit));
assign csr_start = csr_start_init | csr_start_calc;

// initial start for CSR, not core
assign idle_o = (state_q == IDLE);

// some guy said it's best not to use state_n
// so ...
logic pc_to_pc, lambda_to_pc;

logic [ROW_WIDTH-1:0] lambda_to_pc_thresh;
always_comb begin
  case (zc_group)
    ZC_SMALL:  lambda_to_pc_thresh = ROW_WIDTH'(0);
    ZC_MEDIUM: lambda_to_pc_thresh = ROW_WIDTH'(2);
    ZC_LARGE:  lambda_to_pc_thresh = ROW_WIDTH'(3);
    default:   lambda_to_pc_thresh = ROW_WIDTH'(0);
  endcase
end
assign lambda_to_pc = row_cnt_q > lambda_to_pc_thresh;
assign pc_to_pc = pc_state_cnt_q < 2'(zc_group);

always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    state_q <= IDLE;
    pc_state_cnt_q <= '0;
  end else begin
    state_q <= state_n;

    if ((state_q == CALC_PC) & pc_to_pc)
      pc_state_cnt_q <= pc_state_cnt_q + 1;
    else pc_state_cnt_q <= 2'b00;
  end
end

always_comb begin
  unique case (state_q)
    IDLE:
      // Commit to the frame and register config; CSR start happens in LOAD.
      if (inbuff_valid_i & ~inbuff_clear_o & cw_ready)
          state_n = LOAD;
      else state_n = IDLE;
    LOAD:
      // Stay until config has settled (cfg_settled) AND the CSR decoder, which
      // is started only after that, has produced its first valid output.
      if (csr_valid_q & cfg_settled)
          state_n = CALC_LAMBDA;
      else state_n = LOAD;
    CALC_LAMBDA:
      if (lambda_to_pc)
          state_n = CALC_PC;
      else state_n = CALC_LAMBDA;
    CALC_PC: 
      if (pc_to_pc)
        state_n = CALC_PC;
      else state_n = CALC_PA;
    CALC_PA:
      // csr decoder will assert rowgrp_changed_q at +1 cycle after last permutation
      // last pa will be available by then
      if (row_cnt_n >= row_limit & (rowgrp_changed_q & ~rowgrp_changed_qdly))
        state_n = IDLE;
      else state_n = CALC_PA;
    default: state_n = CALC_PA;
    endcase
end

// Frame-done strobe for the codeword generator. The condition below is true
// exactly on the final row-group's rowgrp_changed rising edge (the same one
// that sends the FSM to IDLE); registering it lands the pulse on the next
// cycle, which is precisely when parity_additional_valid flags the final PA
// batch. The generator uses it to close and swap its write bank.
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) cw_last_col <= 1'b0;
  else          cw_last_col <= (rowgrp_changed_q & ~rowgrp_changed_qdly)
                             & (row_cnt_n >= row_limit)
                             & (state_q == CALC_PA);
end

// -----------
// MODULES
// -----------

// need to delay output by 1 clock to sync with input bits arrival
logic [3:0][ZC_WIDTH-1:0] permutation_q, p_norm_qdly;
logic [3:0][ZC_WIDTH-1:0] p_norm_q;  // (permutation_q % z) pre-register, Cut #2
logic [3:0][COL_WIDTH-1:0] col_idx_q, col_idx_qdly;
logic [COL_WIDTH-1:0] col_curr_q, col_curr_qdly;
logic [3:0] gf2_en_q, gf2_en_qdly;
logic [NUM_CS-1:0] cs_pc_sel_q, cs_pc_sel_qdly;
logic [3:0][ROW_WIDTH-1:0] actual_row_q;
logic [3:0][ROW_WIDTH-1:0] actual_row_qdly;
logic csr_ready;

assign csr_ready = ~rowgrp_changed_q;
assign info_group_sel_o = KB_WIDTH'(col_curr_q);

always_ff @(posedge clk_i or negedge arst_ni) begin : csr_delay
  if (!arst_ni) begin
    p_norm_qdly <= '0;
    gf2_en_qdly <= '0;
    csr_valid_qdly <= 0;
    rowgrp_changed_qdly <= 0;
    cs_pc_sel_qdly <= '0;
    actual_row_qdly <= '0;
    col_curr_qdly <= '0;
  end else begin
    if (csr_valid_q) begin
      p_norm_qdly <= p_norm_q;
      gf2_en_qdly <= gf2_en_q;
      cs_pc_sel_qdly <= cs_pc_sel_q;
      actual_row_qdly <= actual_row_q;
      col_idx_qdly <= col_idx_q;
      col_curr_qdly <= col_curr_q;
    end else gf2_en_qdly <= '0;

    csr_valid_qdly <= csr_valid_q;
    rowgrp_changed_qdly <= rowgrp_changed_q;
  end 
end

logic [ROW_WIDTH-1:0] row_cnt_csr;

assign row_cnt_csr = row_cnt_q;

csr_decoder csr_decoder (
  .clk_i         (clk_i),
  .arst_ni       (arst_ni),
  .ldpc_ready_i  (csr_ready),
  .ldpc_valid_o  (csr_valid_q),
  .start_i       (csr_start),
  .base_graph_i  (base_graph_q),
  .lifting_size_i(lifting_size_q),
  .row_i         (row_cnt_csr),
  .permutation_o (permutation_q),
  .gf2_en_o      (gf2_en_q),
  .actual_row_o  (actual_row_q),
  .col_idx_o     (col_idx_q),
  .col_curr_o    (col_curr_q),
  .parity_core_col_o (cs_pc_sel_q),
  .rowgrp_changed_o  (rowgrp_changed_q)
);

// Cut #2: pre-compute per-lane (permutation_q % z) one cycle early so the
// runtime divider is registered into the csr_delay stage (p_norm_qdly) and off
// the shifter datapath. Depends only on permutation_q and the frame-constant z
// (not merge_d_cycle/d), so parameter_calculation consumes it via PRE_MOD=1 and
// only does the cheap lane-select. '1 is the null marker; guard z==0 (idle).
always_comb begin
  for (int i = 0; i < 4; i++) begin
    p_norm_q[i] = (permutation_q[i] != '1)
                ? ((lifting_size_q != '0) ? (permutation_q[i] % lifting_size_q)
                                          : '0)
                : permutation_q[i];
  end
end

logic [3:0][(ZC_MAX >> 2)-1:0] cs_data_in, cs_data_out;

top_level_shifter #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */),
  .PRE_MOD  (1'b1)  /* Cut #2: p arrives pre-modulo'd (p_norm_qdly) */
 ) top_level_shifter (
  .data_in      ({>>{cs_data_in}}),
  .z            (lifting_size_q),
  .p            (p_norm_qdly),
  .merge_d_cycle(merge_d_cycle),
  .data_out     ({>>{cs_data_out}}),
  .d            (zc_group)
);

// note: data_out stored in internal registers
logic [3:0][(ZC_MAX >> 2)-1:0] row_sum;
logic [3:0] cpb_en;
logic gf2_clear, gf2_clear_q;

assign gf2_clear = rowgrp_changed_qdly;

always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) gf2_clear_q <= 0;
  else          gf2_clear_q <= gf2_clear;
end

// For the folded modes each cyclic-shifter lane is a SUB-LANE of a logical
// row, but gf2_en_qdly is a per-base-graph-row enable. The accumulate enable
// must reference the SAME row that supplied each lane's permutation in
// parameter_calculation (its src mapping); otherwise only the lane where
// src(i)==i accumulates a consistent (row,column) stream and the rest pick up
// the wrong columns. Remap to match:
//   ZC_SMALL : lane i  = row i                 -> en[i]
//   ZC_MEDIUM: pair k  = row 2*(d_cycle-1)+k    -> en[2*(d_cycle-1)+k]
//   ZC_LARGE : all     = row merge_d_cycle      -> en[merge_d_cycle] (broadcast)
logic [3:0] gf2_en_eff;
logic [1:0] med_base;
assign med_base = (merge_d_cycle - 2'd1) << 1;   // 0 (d_cycle=1) or 2 (d_cycle=2)
always_comb begin
  case (zc_group)
    ZC_MEDIUM: begin
      gf2_en_eff[0] = gf2_en_qdly[med_base];
      gf2_en_eff[1] = gf2_en_qdly[med_base];
      gf2_en_eff[2] = gf2_en_qdly[med_base + 2'd1];
      gf2_en_eff[3] = gf2_en_qdly[med_base + 2'd1];
    end
    ZC_LARGE:  gf2_en_eff = {4{gf2_en_qdly[merge_d_cycle]}};
    ZC_SMALL:  gf2_en_eff = gf2_en_qdly;   // lane i = row i
    default:   gf2_en_eff = gf2_en_qdly;
  endcase
end

gf2_sum #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) gf2_sum (
  .clk     (clk_i),
  .rst_n   (arst_ni),
  .clr     (gf2_clear),
  .en      (gf2_en_eff),
  .data_in ({>>{cs_data_out}}),
  .data_out({row_sum})
);

logic [3:0][ZC_MAX-1:0] lambda;

logic [IDX_WIDTH-1:0] merge_row_idx;
assign merge_row_idx = IDX_WIDTH'(row_cnt_q);

// Pass phase for the folded modes. merge_row_idx (row_cnt mod 4) walks each
// row-group's passes high-position-first (MEDIUM: 2,1; LARGE: 3,2,1,0).
// The FINAL row-group of both base graphs is half-height (ROW_N % 4 == 2):
// only the LOW positions {0,1} hold real rows (the CSR duplicates the row
// LABELS into {2,3} but their column ranges are empty), so the natural phase
// would spend the tail pass(es) on the empty positions {3,2} and the last two
// parity rows would never accumulate. Clamp the phase to the passes actually
// remaining; for full groups the clamp never binds.
logic [ROW_WIDTH-1:0] rows_left;
assign rows_left = row_limit - row_cnt_q;

// TODO: make sequential based on calc_pc state counter
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni || state_q == IDLE) merge_d_cycle <= '0;
  else case (zc_group)
    ZC_SMALL:  merge_d_cycle <= '0;
    ZC_MEDIUM: begin
      automatic logic [1:0] nat_m;
      automatic logic [ROW_WIDTH-1:0] pairs_left;
      nat_m      = IDX_WIDTH'((unsigned'(NUM_CS) >> 1) - (32'(merge_row_idx) >> 1));
      pairs_left = rows_left >> 1;
      merge_d_cycle <= (ROW_WIDTH'(nat_m) <= pairs_left)
                       ? nat_m : IDX_WIDTH'(pairs_left);
    end
    ZC_LARGE: begin
      automatic logic [1:0] nat_l;
      automatic logic [ROW_WIDTH-1:0] rows_left_m1;
      nat_l        = IDX_WIDTH'(unsigned'(NUM_CS) - 32'(merge_row_idx) - 32'd1);
      rows_left_m1 = rows_left - 1'b1;
      merge_d_cycle <= (ROW_WIDTH'(nat_l) <= rows_left_m1)
                       ? nat_l : IDX_WIDTH'(rows_left_m1);
    end
    default:   merge_d_cycle <= '0;
  endcase
end

merge_select_lambda #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) merge_select_lambda (
  .zc_group (zc_group),
  .d_cycle (merge_d_cycle),
  .data_in (row_sum),
  .data_out(lambda)
);

logic [3:0][ZC_MAX-1:0] parity_core;
logic [3:0][(ZC_MAX >> 2)-1:0] parity_additional;

assign parity_additional = row_sum;

// cpb_en fires once per row completion (gf2_clear) during CALC_LAMBDA.
// merge_d_cycle indicates which row was just processed:
//   ZC_SMALL  : 4 rows in one event   -> 1111.
//   ZC_MEDIUM : d_cycle=2 (1st event) -> 1100,
//               d_cycle=1 (2nd event) -> 0011.
//   ZC_LARGE  : d_cycle=0 -> 1000, =3 -> 0100, =2 -> 0010, =1 -> 0001
//               (2-bit subtract wraps so d_cycle=0 shifts by 3).
always_comb begin
  cpb_en = '0;

  if ((state_q == CALC_LAMBDA) & gf2_clear & ~gf2_clear_q)
    case (zc_group)
      ZC_SMALL:  cpb_en = 4'b1111;
      ZC_MEDIUM: cpb_en = 4'b0011 << ((merge_d_cycle - 2'd1) << 1);
      ZC_LARGE:  cpb_en = 4'b0001 << (merge_d_cycle);
      default:   cpb_en = '0;
    endcase
end

core_parity_bit_calculator #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) core_parity_bit_calculator (
  .clk       (clk_i),
  .rst_n     (arst_ni),
  .en        (cpb_en),
  .base_graph(base_graph_q),
  .z         (lifting_size_q),
  .data_in   (lambda),
  .data_out  (parity_core)
);

logic [3:0][(ZC_MAX >> 2)-1:0] parity_core_arranged;
logic [3:0][IDX_WIDTH-1:0] parity_core_sel;

// Which core-parity column is being fed back this cycle: c_idx = col_curr - KB.
// col_curr_qdly aligns with cs_pc_sel_qdly / p_norm_qdly (the column the
// shifter is processing). Only meaningful when cs_pc_sel_qdly != 0.
logic [COL_WIDTH-1:0] kb_cols;
logic [3:0][1:0]      pc_col_idx;
assign kb_cols    = base_graph_q ? COL_WIDTH'(KB_BG2) : COL_WIDTH'(KB_BG1);

always_comb begin
  for (int i = 0; i < 4; i++) begin
    pc_col_idx[i] = 2'(col_idx_qdly[i] - kb_cols);
  end
end

// Map the core-parity column index to the parity_core lane that holds its p_c.
// core_parity_bit_calculator stores p_c1=parity_core[3], p_c2=[0], p_c3=[1],
// p_c4=[2]; column KB+c feeds p_c(c+1), so c=0->3, 1->0, 2->1, 3->2.
always_comb begin
  for (int i = 0; i < 4; i++) begin
    case (pc_col_idx[i])
      2'd0:    parity_core_sel[i] = IDX_WIDTH'(3); // p_c1
      2'd1:    parity_core_sel[i] = IDX_WIDTH'(0); // p_c2
      2'd2:    parity_core_sel[i] = IDX_WIDTH'(1); // p_c3
      default: parity_core_sel[i] = IDX_WIDTH'(2); // p_c4 (c_idx==3)
    endcase
  end
end

// parity_core_sel is PER-ROW-POSITION (indexed like col_idx_qdly), but
// pc_rearrange consumes a PER-LANE selection: it reads [0] for lane pair
// {0,1} and [2] for pair {2,3} in MEDIUM, and [0] for all lanes in LARGE.
// Remap positions onto lanes exactly like cs_pc_sel_eff / gf2_en_eff, so each
// fold-group gets the p_c of the row it is actually processing this cycle.
logic [3:0][IDX_WIDTH-1:0] parity_core_sel_eff;
always_comb begin
  case (zc_group)
    ZC_MEDIUM: begin
      parity_core_sel_eff[0] = parity_core_sel[med_base];
      parity_core_sel_eff[1] = parity_core_sel[med_base];
      parity_core_sel_eff[2] = parity_core_sel[med_base + 2'd1];
      parity_core_sel_eff[3] = parity_core_sel[med_base + 2'd1];
    end
    ZC_LARGE: begin
      parity_core_sel_eff[0] = parity_core_sel[merge_d_cycle];
      parity_core_sel_eff[1] = parity_core_sel[merge_d_cycle];
      parity_core_sel_eff[2] = parity_core_sel[merge_d_cycle];
      parity_core_sel_eff[3] = parity_core_sel[merge_d_cycle];
    end
    ZC_SMALL:  parity_core_sel_eff = parity_core_sel;
    default:   parity_core_sel_eff = parity_core_sel;
  endcase
end

pc_rearrange #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) pc_rearrange (
  .pc_sel(parity_core_sel_eff),
  .d     (zc_group),
  .pc_in (parity_core),
  .pc_out(parity_core_arranged)
);

// cs_pc_sel_qdly is a PER-ROW-POSITION D/E selector straight from the CSR
// (same indexing as gf2_en_q). In the folded modes each logical row is spread
// over several cyclic-shifter lanes, so every lane of a fold-group must share
// that row's selection -- otherwise one sub-lane picks data_segment while its
// partner picks parity_core_arranged, corrupting the reassembled vector. Remap
// exactly like gf2_en_eff:
//   ZC_SMALL : lane i  = row i
//   ZC_MEDIUM: pair k  = row 2*(d_cycle-1)+k    (med_base / med_base+1)
//   ZC_LARGE : all     = row merge_d_cycle      (broadcast)
logic [3:0] cs_pc_sel_eff;
always_comb begin
  case (zc_group)
    ZC_MEDIUM: begin
      cs_pc_sel_eff[0] = cs_pc_sel_qdly[med_base];
      cs_pc_sel_eff[1] = cs_pc_sel_qdly[med_base];
      cs_pc_sel_eff[2] = cs_pc_sel_qdly[med_base + 2'd1];
      cs_pc_sel_eff[3] = cs_pc_sel_qdly[med_base + 2'd1];
    end
    ZC_LARGE:  cs_pc_sel_eff = {4{cs_pc_sel_qdly[merge_d_cycle]}};
    ZC_SMALL:  cs_pc_sel_eff = cs_pc_sel_qdly;   // lane i = row i
    default:   cs_pc_sel_eff = cs_pc_sel_qdly;
  endcase
end

always_comb begin
  for (int k = 0; k < NUM_CS; k++) begin
    if (cs_pc_sel_eff[k])
      cs_data_in[k] = parity_core_arranged[k];
    else
      cs_data_in[k] = data_segment[k];
  end
end

logic [3:0][(ZC_MAX >> 2)-1:0] parity_core_packed;
logic parity_core_valid, parity_additional_valid;
logic info_valid;

// Pack the core parity for the codeword generator, one CALC_PC cycle at a
// time. The generator writes lane k of cycle n at bank row (cp_base + n),
// sub-bank k, i.e. codeword column KB + n*cols_per_cycle + slot. parity_core
// lane mapping (core_parity_bit_calculator): p_c1=[3], p_c2=[0], p_c3=[1],
// p_c4=[2]; column KB+c carries p_c(c+1). All values are LSB-packed.
// pc_state_cnt_q counts the CALC_PC cycles 0..(1/2/4)-1.
always_comb begin
  case (zc_group)
    // One cycle: lanes 0..3 = columns KB..KB+3 = p_c1..p_c4.
    ZC_SMALL: begin
      parity_core_packed[0] = parity_core[3][(ZC_MAX >> 2)-1:0]; // p_c1
      parity_core_packed[1] = parity_core[0][(ZC_MAX >> 2)-1:0]; // p_c2
      parity_core_packed[2] = parity_core[1][(ZC_MAX >> 2)-1:0]; // p_c3
      parity_core_packed[3] = parity_core[2][(ZC_MAX >> 2)-1:0]; // p_c4
    end
    // Two cycles of two columns: {KB,KB+1} = {p_c1,p_c2}, then {p_c3,p_c4}.
    // Lane pair {0,1} = even column (lower half), {2,3} = odd column.
    ZC_MEDIUM: begin
      {parity_core_packed[1], parity_core_packed[0]} =
        (pc_state_cnt_q[0] == 1'b0) ? parity_core[3][(ZC_MAX >> 1)-1:0]   // p_c1
                                    : parity_core[1][(ZC_MAX >> 1)-1:0];  // p_c3
      {parity_core_packed[3], parity_core_packed[2]} =
        (pc_state_cnt_q[0] == 1'b0) ? parity_core[0][(ZC_MAX >> 1)-1:0]   // p_c2
                                    : parity_core[2][(ZC_MAX >> 1)-1:0];  // p_c4
    end
    // Four cycles of one column: cycle n = p_c(n+1) = parity_core[n-1 mod 4];
    // lane k holds bits [96k +: 96] of the Zc-bit value.
    ZC_LARGE: {parity_core_packed[3], parity_core_packed[2],
               parity_core_packed[1], parity_core_packed[0]} =
                 parity_core[pc_state_cnt_q - 2'd1];
    default: parity_core_packed = '0;
  endcase
end

// Systematic-data hand-off to the codeword generator: one strobe per CSR
// info-column consumption, aligned to the qdly stage where data_segment is
// valid (info_group_i lags info_group_sel_o/col_curr_q by one cycle). The
// column index travels alongside (col_curr_qdly) so the generator can address
// the write by the column itself -- columns repeat across the folded modes'
// row-group passes, and rewriting the same column with the same data is
// harmless. E-column cycles (col >= KB) are parity feedback, not info.
// LOAD is included because the very FIRST CSR entry (column 0) is consumed
// while the FSM is still in LOAD: the LOAD->CALC_LAMBDA transition registers
// one cycle after csr_valid_q rises. The CSR cannot present anything else
// during LOAD (it is restarted there), so the gate stays exact.
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) info_valid <= 1'b0;
  else          info_valid <= ((state_q == CALC_LAMBDA) | (state_q == LOAD))
                            & csr_valid_q & (col_curr_q < kb_cols);
end
assign parity_core_valid = (state_q == CALC_PC);
// The FSM leaves CALC_PA->IDLE on the rising edge of rowgrp_changed_q, but the
// PA for that final row-group only becomes valid one cycle later, when
// rowgrp_changed_qdly pulses -- by then state_q is already IDLE. Include IDLE
// so the last batch (e.g. the 2-row remainder when the BG height isn't a
// multiple of 4) is still flagged. rowgrp_changed_qdly is 0 during steady
// IDLE, so this only fires on that one trailing cycle.
assign parity_additional_valid = ((state_q == CALC_PA) | (state_q == IDLE)) & rowgrp_changed_qdly;

// Per-LANE row index for the additional-parity hand-off. actual_row_qdly is
// per-ROW-POSITION (CSR indexing); the generator needs the row each physical
// lane is a sub-lane of this pass. Same fold remap as gf2_en_eff.
logic [3:0][COL_WIDTH-1:0] parity_additional_idx;
always_comb begin
  case (zc_group)
    ZC_MEDIUM: begin
      parity_additional_idx[0] = COL_WIDTH'(actual_row_qdly[med_base]);
      parity_additional_idx[1] = COL_WIDTH'(actual_row_qdly[med_base]);
      parity_additional_idx[2] = COL_WIDTH'(actual_row_qdly[med_base + 2'd1]);
      parity_additional_idx[3] = COL_WIDTH'(actual_row_qdly[med_base + 2'd1]);
    end
    ZC_LARGE: begin
      for (int unsigned i = 0; i < 4; i++)
        parity_additional_idx[i] = COL_WIDTH'(actual_row_qdly[merge_d_cycle]);
    end
    default: begin // ZC_SMALL: lane i = row position i
      for (int unsigned i = 0; i < 4; i++)
        parity_additional_idx[i] = COL_WIDTH'(actual_row_qdly[i]);
    end
  endcase
end

// Which lanes of a PA hand-off carry REAL rows. Only ZC_SMALL's final
// (partial) row-group has stale duplicate row labels in the upper positions
// (BG height % 4 != 0); writing those lanes would clobber real rows with the
// zeroed accumulators. The folded modes never select the empty positions
// (merge_d_cycle clamp), so their mask is always full. Sampled on the rowgrp
// edge, while rows_left still reflects the group just finished, so it is
// stable during the hand-off cycle that follows.
logic [3:0] pa_lane_mask_q;
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) pa_lane_mask_q <= 4'hF;
  else if (rowgrp_changed_q & ~rowgrp_changed_qdly) begin
    if ((zc_group == ZC_SMALL) && (rows_left < ROW_WIDTH'(3'd4)))
      case (rows_left[1:0])
        2'd1:    pa_lane_mask_q <= 4'b0001;
        2'd2:    pa_lane_mask_q <= 4'b0011;
        2'd3:    pa_lane_mask_q <= 4'b0111;
        default: pa_lane_mask_q <= 4'hF;
      endcase
    else pa_lane_mask_q <= 4'hF;
  end
end

codeword_generator codeword_generator (
  .clk_i                (clk_i),
  .arst_ni              (arst_ni),
  .zc_group_i           (zc_group),
  .info_valid_i         (info_valid),
  .info_col_i           (col_curr_qdly),
  .info_data_i          (data_segment),
  .core_parity_valid_i  (parity_core_valid),
  .core_parity_data_i   (parity_core_packed),
  .add_parity_valid_i   (parity_additional_valid),
  .add_parity_idx_i     (parity_additional_idx),
  .add_parity_mask_i    (pa_lane_mask_q),
  .add_parity_data_i    (parity_additional),
  .base_graph_i         (base_graph_q),
  .lifting_size_i       (lifting_size_q),
  .input_last_subblock_i(cw_last_col),
  .upstream_ready_o     (cw_ready),
  .codeword_valid_o     (codeword_valid_o),
  .r_addr_i             (r_addr_i),
  .r_data_o             (r_data_o),
  .codeword_done_i      (codeword_done_i),
  .base_graph_o         (base_graph_o),
  .lifting_size_o       (lifting_size_o),
  .zc_group_o           (zc_group_o)
);
endmodule