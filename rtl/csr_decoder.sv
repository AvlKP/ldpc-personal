// TODO:
// 1. Check row_change edge to col_idx_addr sync [x] -> handle via start_i
// 2. Check gf2_en sync [x] -> no need, already good
// 3. Check input buffer and permutation_o sync [x] -> handle via backpressure
// 4. Locking mechanism for row_i and base_graph_i [ ] (i think not really needed)

import ldpc_pkg::*;

module csr_decoder #(
  localparam int unsigned ROW_WIDTH = $clog2(BG1_ROW_N),
  localparam int unsigned COL_WIDTH = $clog2(BG1_COL_N),
  // + 2 for each BG row pointer format first entry (0)
  localparam int unsigned RP_SIZE = BG1_ROW_N + BG2_ROW_N + 2,
  localparam int unsigned BASEP_WIDTH = 9
) (
  input logic clk_i,
  input logic arst_ni,

  input logic ldpc_ready_i, // backpressure from other module
  output logic ldpc_valid_o, // output is ready to be consumed
  input logic start_i, // control the initialization

  input logic base_graph_i,
  input logic [ROW_WIDTH-1:0] row_i, // current row, converted to row group of 4

  output logic [ZC_WIDTH-1:0] permutation_o [0:3], // will be -1 when col is unavailable
  output logic [3:0] gf2_en_o, // alternative to above's indicator
  // TODO: just use kb <= 22 to check if data is info or core parity [x]
  output logic [COL_WIDTH-1:0] col_curr_o, // current column index being prrocessed
  output logic row_change_o // flags that a row change has occured
);

// FSM
typedef enum { 
  INIT, // 1 cycle delay for colval_addr to be initialized
  VALID
 } state_t;

state_t state_q, next_state;
logic row_change;
logic ldpc_handshake;

always_ff @(posedge clk_i or negedge arst_ni) begin : state_ff
  if (!arst_ni) state_q <= INIT;
  else begin
    if (state_q == VALID & ~ldpc_handshake) 
      state_q <= state_q; // backpressure
    else
      state_q <= next_state;
  end
end

// mainly for readability
assign ldpc_handshake = ldpc_ready_i & ldpc_valid_o;
assign ldpc_valid_o = (state_q == VALID)? 1 : 0;

always_comb begin
  next_state = state_q;

  case (state_q)
    INIT: begin
      if (start_i) next_state = VALID; // 1 clock delay
      else next_state = INIT; // hold init if core is not starting the process yet
    end
    VALID: begin
      // handle backpressure and row change
      if (ldpc_handshake & row_change) next_state = INIT; 
    end
  endcase
end

// Row Pointer ROM
logic [4*BASEP_WIDTH-1:0] row_pointer;
logic [($clog2(RP_SIZE/4))-1:0] row_group;

always_comb begin : rp_addressing
  case (base_graph_i)
    1'b0 : row_group = 5'(row_i >> 2);
    1'b1 : row_group = 5'(1 + ((row_i + 6'(BG1_ROW_N)) >> 2));
  endcase
end

rom_lutram #(
  .WORD_WIDTH(4*BASEP_WIDTH),
  .SIZE      ($ceil(RP_SIZE/4.0)),
  .NUM_PORTS (1),
  .MEM_INIT  ("mem/row_ptr.mem")
) rp_rom (
  .addr_i('{row_group}),
  .dout_o('{row_pointer})
);

// Column Indices ROM
localparam int unsigned CSR_WIDTH = $clog2(CSR_SIZE);
logic [CSR_WIDTH-1:0] colval_addr_q [0:3]; 
logic [CSR_WIDTH-1:0] colval_addr [0:3]; 
logic [COL_WIDTH-1:0] col_idx [0:3];
logic [COL_WIDTH-1:0] col_idx_ctl [0:3];
logic [COL_WIDTH-1:0] col_curr;

logic [3:0] col_en;
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    // enable when it is current col or a core parity bit
    col_en[i] = (col_curr == col_idx[i] | col_idx[i] > 7'(KB_MAX-1));
  end
end

// TODO: optimize power by using previous value instead of fetching data at RP's addr [x]
always_ff @(posedge clk_i or negedge arst_ni) begin : colval_addressing
for (int unsigned i = 0; i < 4; i++) begin
  if (!arst_ni) begin
    colval_addr_q[i] <= '0;
  end else begin
    if (state_q == VALID & ~ldpc_handshake) colval_addr_q[i] <= colval_addr_q[i]; // backpressure
    else if (state_q == INIT) begin
      // take data from bypass to increment correctly after init
      // TODO: change this, integrate to col_en
      if (col_en[i]) colval_addr_q[i] <= colval_addr[i] + 1;
      else colval_addr_q[i] <= colval_addr[i];
    end
    else begin
      if (col_en[i]) colval_addr_q[i] <= colval_addr_q[i] + 1;
      else colval_addr_q[i] <= colval_addr_q[i];      
    end
  end
end
end

// bypass colval_addr_q reg for the 1 cycle during INIT
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    case (state_q)
      INIT : colval_addr[i] = row_pointer[i*BASEP_WIDTH +: BASEP_WIDTH];
      VALID: colval_addr[i] = colval_addr_q[i];
      default: colval_addr[i] = colval_addr_q[i];
    endcase
  end
end

rom_lutram #(
  .WORD_WIDTH(COL_WIDTH),
  .SIZE      (CSR_SIZE),
  .NUM_PORTS (4),
  .MEM_INIT  ("mem/col_indices.mem")
) col_idx_rom (
  .addr_i(colval_addr),
  .dout_o(col_idx)
);

// handle non-zero col_idx during INIT
assign col_idx_ctl = (state_q == INIT & ~start_i)? {'0, '0, '0, '0} : col_idx;

csr_col_ctl #(
  .COL_WIDTH(COL_WIDTH)
 ) csr_col_ctl (
  .clk_i       (clk_i),
  .arst_ni     (arst_ni),
  .col_idx_i   (col_idx_ctl),
  .col_curr_o  (col_curr),
  .row_change_o(row_change)
);

// Values ROM
generate
  genvar rom_i;
  for (rom_i = 0; rom_i < 2; rom_i++) begin : val_rom_gen
    logic [CSR_WIDTH-1:0] val_addr [0:1];
    logic [ZC_WIDTH-1:0] val [0:1];
    assign val_addr = colval_addr[rom_i*2 +: 2];

    rom_dp #(
      .WORD_WIDTH(BASEP_WIDTH),
      .SIZE      (CSR_SIZE),
      .MEM_INIT  ("mem/values.mem")
    ) val_rom (
      .clk_i  (clk_i),
      .en_a_i (1),
      .addra_i(val_addr[0]),
      .douta_o(val[0]),
      .en_b_i (1),
      .addrb_i(val_addr[1]),
      .doutb_o(val[1])
    );

    // assign -1 if (row, col) is invalid (!= col_curr)
    // can also use gf2_en to handle this like Dawam's idea
    assign permutation_o[rom_i*2] = (gf2_en_o[rom_i*2])? val[0] : '1;
    assign permutation_o[rom_i*2+1] = (gf2_en_o[rom_i*2+1])? val[1] : '1;
  end
endgenerate

// output registers
always_ff @(posedge clk_i or negedge arst_ni) begin : output_ff
  if (!arst_ni) begin
    col_curr_o <= '0;
    gf2_en_o <= '0; 
  end else begin
    if (state_q == VALID & ~ldpc_handshake) begin
      // backpressure
      col_curr_o <= col_curr_o;
      gf2_en_o <= gf2_en_o;
    end else begin
      col_curr_o <= col_curr;
      gf2_en_o <= col_en;
    end
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : row_change_ff
  if (!arst_ni) begin
    row_change_o <= 0;
  end else begin
    if (state_q == INIT & ~start_i) begin
      row_change_o <= row_change_o;
    end else begin
      row_change_o <= row_change;
    end
  end
end
endmodule
