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
  output zc_group_t zc_group_o,
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
    // info_group_i is LSB-packed (active bits in [Zc-1:0]), but the cyclic
    // shifter masks the TOP zc_in bits ([95:96-Zc]) of each 96-bit lane. For
    // ZC_SMALL (no fold) MSB-align each lane by Zc so the active bits land in
    // the masked region; otherwise the shift result is 0 for Zc < 96.
    ZC_SMALL: for (int unsigned j = 0; j < 4; j++)
            data_segment[j] = info_group_i[0 +: (ZC_MAX >> 2)] << ((ZC_MAX >> 2) - lifting_size_q);
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

assign cw_last_col = (row_cnt_n >= row_limit) & rowgrp_changed_qdly;

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

// -----------
// MODULES
// -----------

// need to delay output by 1 clock to sync with input bits arrival
logic [3:0][ZC_WIDTH-1:0] permutation_q, permutation_qdly;
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
    permutation_qdly <= '0;
    gf2_en_qdly <= '0;
    csr_valid_qdly <= 0;
    rowgrp_changed_qdly <= 0;
    cs_pc_sel_qdly <= '0;
    actual_row_qdly <= '0;
    col_curr_qdly <= '0;
  end else begin
    if (csr_valid_q) begin
      permutation_qdly <= permutation_q;
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

logic [3:0][(ZC_MAX >> 2)-1:0] cs_data_in, cs_data_out;

top_level_shifter #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) top_level_shifter (
  .data_in      ({>>{cs_data_in}}),
  .z            (lifting_size_q),
  .p            (permutation_qdly),
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

// TODO: make sequential based on calc_pc state counter
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni || state_q == IDLE) merge_d_cycle <= '0;
  else case (zc_group)
    ZC_SMALL:  merge_d_cycle <= '0;
    ZC_MEDIUM: merge_d_cycle <= IDX_WIDTH'((NUM_CS >> 1) - (merge_row_idx >> 1));
    ZC_LARGE:  merge_d_cycle <= IDX_WIDTH'(NUM_CS - merge_row_idx - 1);
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
// col_curr_qdly aligns with cs_pc_sel_qdly / permutation_qdly (the column the
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

pc_rearrange #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) pc_rearrange (
  .pc_sel(parity_core_sel),
  .d     (zc_group),
  .pc_in (parity_core),
  .pc_out(parity_core_arranged)
);

always_comb begin
  for (int k = 0; k < NUM_CS; k++) begin
    if (cs_pc_sel_qdly[k])
      cs_data_in[k] = parity_core_arranged[k];
    else
      cs_data_in[k] = data_segment[k];
  end
end

logic [3:0][(ZC_MAX >> 2)-1:0] parity_core_packed;
logic parity_core_valid, parity_additional_valid;
logic info_valid;

always_comb begin
  case (zc_group)
    ZC_SMALL: begin
      for (int unsigned i = 0; i < 4; i++) begin
        parity_core_packed[3-i] = parity_core[i][ZC_MAX-1 -: (ZC_MAX >> 2)];
      end
    end
    
    ZC_MEDIUM: begin
      for (int unsigned i = 0; i < 2; i++) begin
        {parity_core_packed[3 - 2*i], 
         parity_core_packed[2 - 2*i]} = 
          parity_core[merge_row_idx + i][ZC_MAX-1 -: (ZC_MAX >> 1)];
      end
    end 
    ZC_LARGE: {parity_core_packed[0], parity_core_packed[1], parity_core_packed[2], parity_core_packed[3]} = parity_core[merge_row_idx];
    default: parity_core_packed = '0;
  endcase
end

assign info_valid = (state_q == CALC_LAMBDA);
assign parity_core_valid = (state_q == CALC_PC);
assign parity_additional_valid = (state_q == CALC_PA) & rowgrp_changed_qdly;

logic [3:0][ROW_WIDTH:0] parity_additional_idx;
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    parity_additional_idx[i] = {1'b0, actual_row_qdly[i]};
  end
end

assign cw_ready = 1; // TODO remove this if cwgen is done
codeword_generator codeword_generator (
  .clk_i                (clk_i),
  .arst_ni              (arst_ni),
  .zc_group_i           (zc_group),
  .info_valid_i         (info_valid),
  .info_data_i          (data_segment),
  .core_parity_valid_i  (parity_core_valid),
  .core_parity_data_i   (parity_core_packed),
  .add_parity_valid_i   (parity_additional_valid),
  .add_parity_idx_i     (parity_additional_idx),
  .add_parity_data_i    (parity_additional),
  .base_graph_i         (base_graph_q),
  .lifting_size_i       (lifting_size_q),
  .input_last_subblock_i(cw_last_col),
  // .upstream_ready_o     (cw_ready),
  .codeword_valid_o     (codeword_valid_o),
  .r_addr_i             (r_addr_i),
  .r_data_o             (r_data_o),
  .codeword_done_i      (codeword_done_i),
  .base_graph_o         (base_graph_o),
  .lifting_size_o       (lifting_size_o),
  .zc_group_o           (zc_group_o)
);
endmodule