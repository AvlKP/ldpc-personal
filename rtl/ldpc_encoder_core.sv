import ldpc_pkg::*;

module ldpc_encoder_core #(
  // Top-level parameters mirroring the sub-modules
  parameter int ZC_PER_CS = 96,
  parameter int NUM_CS = 4,
  parameter int OUTPUT_BITS_MAX = 26112
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
  output logic outbuff_addr_o,
  output logic [(ZC_MAX << 2)-1:0] outbuff_data_o
);

// Input Transform
logic [1:0] zc_group; // Zc parallelism case selector
assign zc_group[1] = (lifting_size_i > ZC_MAX >> 1); // zc > 192
assign zc_group[0] = (lifting_size_i > ZC_MAX >> 2); // zc > 96

logic [3:0][(ZC_MAX >> 2)-1:0] data_segment;
always_comb begin
    case (zc_group)
    2'b00: for (int unsigned j = 0; j < 4; j++)
            data_segment[j] = info_group_i[0 +: (ZC_MAX >> 2)];            
    2'b01: for (int unsigned j = 0; j < 2; j++)
            {data_segment[j*2+1], data_segment[j*2]} = info_group_i[0 +: (ZC_MAX >> 1)];
    2'b11: {data_segment} <= info_group_i;
    default: {data_segment} <= '0;
    endcase  
end
  
// Row counters
localparam int unsigned ROW_WIDTH = $clog2(BG1_ROW_N);
// initial 4 row counter for CALC_LAMBDA
logic [ROW_WIDTH-1:0] row_cnt_q, row_cnt_n;
logic [ROW_WIDTH-1:0] row_limit;
logic rg_changed_q; // row group change signal

assign row_limit = (base_graph_i)? 
    ROW_WIDTH'(BG2_ROW_N) : ROW_WIDTH'(BG1_ROW_N);

always_comb begin
  case (zc_group)
    2'b00: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 0);
    2'b01: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 1);
    2'b11: row_cnt_n <= row_cnt_q + ROW_WIDTH'(1'b1 << 2);
    default: row_cnt_n <= row_cnt_q;
  endcase  
end

always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) row_cnt_q <= '0;
    else if (rg_changed_q) row_cnt_q <= row_cnt_n;   
end

// FSM
typedef enum logic [1:0] { 
  IDLE,
  CALC_LAMBDA,
  CALC_PC,
  CALC_PA
} state_t;

state_t state_q, state_n;

always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    state_q <= IDLE;
  end else begin
    state_q <= state_n;
  end
end

always_comb begin
  unique case (state_q)
    IDLE:
      // TODO: only change after permutation and input bit is synced after delay
      if (inbuff_valid_i & ~outbuff_full_i)
          state_n <= CALC_LAMBDA; // start
      else state_n <= IDLE;
    CALC_LAMBDA:
      if (row_cnt_n >= ROW_WIDTH'(1'b1 << 2))
          state_n <= CALC_PC;
      else state_n <= CALC_LAMBDA;
    CALC_PC: state_n <= CALC_PA;
    CALC_PA:
      // csr decoder will assert rg_changed_q at +1 cycle after last permutation
      // last pa will be available by then
      if (row_cnt_n >= row_limit & rg_changed_q) 
        state_n <= IDLE;
      else state_n <= CALC_PA;
    default: state_n <= CALC_PA;
    endcase
end

// Modules

// need to delay output by 1 clock to sync with input bits arrival
csr_decoder csr_decoder (
  .clk_i         (clk_i),
  .arst_ni       (arst_ni),
  .ldpc_ready_i  (ldpc_ready_i),
  .ldpc_valid_o  (ldpc_valid_o),
  .start_i       (start_i),
  .base_graph_i  (base_graph_i),
  .lifting_size_i(lifting_size_i),
  .row_i         (row_cnt_q),
  .permutation_o (permutation_o),
  .gf2_en_o      (gf2_en_o),
  .col_curr_o    (col_curr_o),
  .rg_changed_o  (rg_changed_q)
);

top_level_shifter #(
  .ZC_PER_CS(ZC_PER_CS /* default 96 */),
  .NUM_CS   (NUM_CS /* default 4 */)
 ) top_level_shifter (
  .data_in ({>>{data_segment}}),
  .z       (),
  .p       (p),
  .data_out(data_out),
  .d       (d)
);


endmodule