import ldpc_pkg::*;

// TODO:
// 1. output buffer should be written according to zc_group, not once per row group no matter zc_group
// 2. transition from IDLE to LAMBDA should not happen before input buffer clears the data

module ldpc_encoder_core #(
  // Top-level parameters mirroring the sub-modules
  parameter int ZC_PER_CS = 96,
  parameter int NUM_CS = 4,

  localparam int unsigned ROW_WIDTH = $clog2(BG1_ROW_N),
  localparam int unsigned COL_WIDTH = $clog2(BG1_COL_N)

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

  input logic outbuff_full_i,
  output logic [4:0] outbuff_addr_o,
  output logic outbuff_wr_en_o,
  output logic [(ZC_MAX << 2)-1:0] outbuff_data_o,
  output logic cw_done_o, // Pulses on final write
  output logic [10:0] total_words_o // Passed to buffer for AXI TLAST
);

localparam int unsigned IDX_WIDTH = $clog2(NUM_CS);

// Input Transform
zc_group_t zc_group; // Zc parallelism case selector
always_comb begin
  if (lifting_size_i > (ZC_MAX >> 1)) zc_group = ZC_LARGE;        // zc > 192
  else if (lifting_size_i > (ZC_MAX >> 2)) zc_group = ZC_MEDIUM;  // zc > 96
  else zc_group = ZC_SMALL;
end

logic [3:0][(ZC_MAX >> 2)-1:0] data_segment;
always_comb begin
    case (zc_group)
    ZC_SMALL: for (int unsigned j = 0; j < 4; j++)
            data_segment[j] = info_group_i[0 +: (ZC_MAX >> 2)];            
    ZC_MEDIUM: for (int unsigned j = 0; j < 2; j++)
            {data_segment[j*2+1], data_segment[j*2]} = info_group_i[0 +: (ZC_MAX >> 1)];
    ZC_LARGE: {data_segment} <= info_group_i;
    default: {data_segment} <= '0;
    endcase  
end
  
// Row counters
// initial 4 row counter for CALC_LAMBDA
logic [ROW_WIDTH-1:0] row_cnt_q, row_cnt_n;
logic [ROW_WIDTH-1:0] row_limit;
logic [KB_WIDTH-1:0] kb_max;
logic rowgrp_changed_q, rowgrp_changed_qdly; // row group change signal
logic csr_valid_q, csr_valid_qdly;
logic csr_start;
logic stall_en;

assign kb_max = base_graph_i ? KB_WIDTH'(KB_BG2-1) : KB_WIDTH'(KB_BG1-1);
assign row_limit = (base_graph_i)? 
    ROW_WIDTH'(BG2_ROW_N) : ROW_WIDTH'(BG1_ROW_N);

// FSM
typedef enum logic [1:0] { 
  IDLE,
  CALC_LAMBDA,
  CALC_PC,
  CALC_PA
} state_t;

state_t state_q, state_n;
logic [1:0] pc_state_cnt_q;

// TODO: check if this needs guarding when certain states
always_comb begin
  case (zc_group)
    ZC_SMALL: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 0);
    ZC_MEDIUM: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 1);
    ZC_LARGE: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 2);
    default: row_cnt_n <= row_cnt_q;
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
  else if (rowgrp_changed_q) begin
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
// assign csr_start = ((rowgrp_changed_q & row_cnt_n < row_limit) 
//                 | ((state_q == IDLE) & inbuff_valid_i))
//                 & ~inbuff_clear_o;
logic csr_start_init, csr_start_calc;

assign csr_start_init = (state_q == IDLE) 
                      & (inbuff_valid_i & ~inbuff_clear_o);
assign csr_start_calc = (state_q != IDLE)
                      & (rowgrp_changed_q & (row_cnt_n < row_limit));
assign csr_start = csr_start_init | csr_start_calc;

// initial start for CSR, not core
assign idle_o = (state_q == IDLE);

// some guy said it's best not to use state_n
// so ...
logic pc_to_pc, lambda_to_pc;

assign lambda_to_pc = row_cnt_n >= ROW_WIDTH'(3'd4);
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
      if (inbuff_valid_i & ~inbuff_clear_o 
        & ~outbuff_full_i & csr_valid_q)
          state_n <= CALC_LAMBDA; // start
      else state_n <= IDLE;
    CALC_LAMBDA:
      if (lambda_to_pc)
          state_n <= CALC_PC;
      else state_n <= CALC_LAMBDA;
    CALC_PC: 
      if (pc_to_pc)
        state_n <= CALC_PC;
      else state_n <= CALC_PA;
    CALC_PA:
      // csr decoder will assert rowgrp_changed_q at +1 cycle after last permutation
      // last pa will be available by then
      if (row_cnt_n >= row_limit & rowgrp_changed_q) 
        state_n <= IDLE;
      else state_n <= CALC_PA;
    default: state_n <= CALC_PA;
    endcase
end

// -----------
// MODULES
// -----------

// need to delay output by 1 clock to sync with input bits arrival
logic [3:0][ZC_WIDTH-1:0] permutation_q, permutation_qdly;
logic [COL_WIDTH-1:0] col_curr_q;
logic [3:0] gf2_en_q, gf2_en_qdly;
logic [NUM_CS-1:0] cs_pc_sel_q, cs_pc_sel_qdly;
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
  end else begin
    if (csr_valid_q) begin
      permutation_qdly <= permutation_q;
      gf2_en_qdly <= gf2_en_q;
      cs_pc_sel_qdly <= cs_pc_sel_q;
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
  .base_graph_i  (base_graph_i),
  .lifting_size_i(lifting_size_i),
  .row_i         (row_cnt_csr),
  .permutation_o (permutation_q),
  .gf2_en_o      (gf2_en_q),
  .col_curr_o    (col_curr_q),
  .parity_core_col_o (cs_pc_sel_q),
  .rowgrp_changed_o  (rowgrp_changed_q)
);

logic [3:0][(ZC_MAX >> 2)-1:0] cs_data_in, cs_data_out;

// TODO: check why cs_data_out is zeroed out at some places
top_level_shifter #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) top_level_shifter (
  .data_in ({>>{cs_data_in}}),
  .z       (lifting_size_i),
  .p       (permutation_qdly),
  .data_out({>>{cs_data_out}}),
  .d       (zc_group)
);

// note: data_out stored in internal registers
logic [3:0][(ZC_MAX >> 2)-1:0] row_sum;
logic [3:0] cpb_en;
logic gf2_clear;

assign gf2_clear = rowgrp_changed_qdly;

gf2_sum #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) gf2_sum (
  .clk     (clk_i),
  .rst_n   (arst_ni),
  .clr     (gf2_clear),
  .en      (gf2_en_qdly),
  .data_in ({>>{cs_data_out}}),
  .data_out({row_sum})
);

logic [3:0][ZC_MAX-1:0] lambda;
logic [1:0] merge_d_cycle;

logic [IDX_WIDTH-1:0] merge_row_idx;
assign merge_row_idx = IDX_WIDTH'(row_cnt_q);

always_comb begin
  case (zc_group)
    // make unused case calculate the same thing for res efficiency
    ZC_SMALL: merge_d_cycle = '0;
    ZC_MEDIUM: merge_d_cycle = IDX_WIDTH'((NUM_CS >> 1) - (merge_row_idx >> 1));
    ZC_LARGE: merge_d_cycle = IDX_WIDTH'(NUM_CS - merge_row_idx);
    default: merge_d_cycle = '0;
  endcase
end

merge_select_lambda #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) merge_select_lambda (
  .d       (zc_group),
  .d_cycle (merge_d_cycle),
  .data_in (row_sum),
  .data_out(lambda)
);

logic [3:0][ZC_MAX-1:0] parity_core;

always_comb begin
  cpb_en = '0;

  if (((state_q == CALC_LAMBDA) & lambda_to_pc)
      | ((state_q == CALC_PC) & pc_to_pc))
    case (zc_group)
      ZC_SMALL: cpb_en = '1; 
      ZC_MEDIUM: cpb_en = 4'b0011 << (merge_d_cycle << 1);
      ZC_LARGE: cpb_en = 4'b0001 << (merge_d_cycle);
      default: cpb_en = '0;
    endcase  
end

core_parity_bit_calculator #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) core_parity_bit_calculator (
  .clk       (clk_i),
  .rst_n     (arst_ni),
  .en        (cpb_en),
  .base_graph(base_graph_i),
  .z         (lifting_size_i),
  .data_in   (lambda),
  .data_out  (parity_core)
);

logic [3:0][(ZC_MAX >> 2)-1:0] parity_core_arranged;
logic [IDX_WIDTH-1:0] parity_core_sel;
logic [$clog2(NUM_CS+1)-1:0] parity_core_sel_cnt;

always_comb begin
  parity_core_sel_cnt = '0;
  for (int unsigned i = 0; i < NUM_CS; i++) 
    if (cs_pc_sel_qdly[i]) parity_core_sel_cnt = parity_core_sel_cnt + 1'b1;

  if (parity_core_sel_cnt >= NUM_CS) parity_core_sel = IDX_WIDTH'(NUM_CS-1);
  else parity_core_sel = IDX_WIDTH'(parity_core_sel_cnt);
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
  for (int unsigned i = 0; i < NUM_CS; i++) begin
    if (cs_pc_sel_qdly[i]) 
      cs_data_in[NUM_CS-1-i] = parity_core_arranged[i];
    else 
      cs_data_in[NUM_CS-1-i] = data_segment[NUM_CS-1-i];
  end
end

logic parity_core_valid_q, parity_additional_valid_q;
logic [3:0][ZC_MAX-1:0] parity_additional;
logic info_valid;

assign parity_additional = lambda;
assign info_valid = (state_q == CALC_LAMBDA);
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    parity_core_valid_q <= 0;
    parity_additional_valid_q <= 0;
  end else begin
    parity_core_valid_q <= (state_q == CALC_PC) & rowgrp_changed_qdly;
    parity_additional_valid_q <= (state_q == CALC_PA) & rowgrp_changed_qdly;
  end
end

codeword_generator #(
  .ZC_MAX    (ZC_MAX /* default 384 */),
  .ADDR_WIDTH(5 /* default 5 */)
 ) codeword_generator (
  .clk                      (clk_i),
  .rst_n                    (arst_ni),
  .expected_cw_bits_i       (output_bits_i),
  .zc_i                     (lifting_size_i),
  .info_group_i             (info_group_i),
  .info_valid_i             (info_valid),
  .kb_max_i                 (kb_max),
  .curr_col_i               (col_curr_q),
  .parity_core_i            (parity_core),
  .parity_core_valid_i      (parity_core_valid_q),
  .parity_additional_i      (parity_additional),
  .parity_additional_valid_i(parity_additional_valid_q),
  .parity_groups_i          (zc_group),
  .outbuff_full_i           (outbuff_full_i),
  .core_stall_o             (stall_en),
  .outbuff_data_o           (outbuff_data_o),
  .outbuff_addr_o           (outbuff_addr_o),
  .outbuff_wr_en_o          (outbuff_wr_en_o),
  .cw_done_o                (cw_done_o),
  .total_words_o            (total_words_o)
);

endmodule