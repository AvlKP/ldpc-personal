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

  output logic [3:0][ZC_WIDTH-1:0] permutation_o, // will be -1 when col is unavailable
  output logic [3:0] gf2_en_o, // alternative to above's indicator
  output logic [COL_WIDTH-1:0] col_curr_o, // current column index being prrocessed
  output logic rg_changed_o // flags that a row group change has occured
);

typedef enum logic { 
  INIT = 1'b0, // 1 cycle delay for colval_addr to be initialized
  VALID = 1'b1
 } state_t;

state_t state_q, next_state;

// I/O stuff
typedef struct packed {
  logic [COL_WIDTH-1:0] col_curr;
  logic [3:0] gf2_en;
  logic [3:0][ZC_WIDTH-1:0] permutation;
} ldpc_packet_t;

logic inner_ready, inner_valid;
logic bg_q, bg_n;
logic [ROW_WIDTH-1:0] row_q, row_n;

assign bg_n = (start_i & state_q == INIT)? base_graph_i : bg_q;
assign row_n = (start_i & state_q == INIT)? row_i : row_q;

always_ff @(posedge clk_i or negedge arst_ni) begin : input_lock
  if (!arst_ni) begin
    bg_q <= 0;
    row_q <= '0;
  end else if (start_i & state_q == INIT) begin
    bg_q <= base_graph_i;
    row_q <= row_i;
  end
end

logic rg_changed_n, rg_changed_q;
logic [COL_WIDTH-1:0] col_curr_n, col_curr_q;
logic [3:0] gf2_en_q;
logic [3:0][ZC_WIDTH-1:0] permutation;

ldpc_packet_t ldpc_packet_i, ldpc_packet_o; 
assign ldpc_packet_i = '{
  col_curr: col_curr_q,
  gf2_en: gf2_en_q,
  permutation: permutation
};

fall_through_register #(
  .T(ldpc_packet_t)
) ldpc_io_reg (
  .clk_i     (clk_i),
  .rst_ni    (arst_ni),
  .clr_i     (1'b0),
  .testmode_i(),
  .valid_i   (inner_valid),
  .ready_o   (inner_ready),
  .data_i    (ldpc_packet_i),
  .valid_o   (ldpc_valid_o),
  .ready_i   (ldpc_ready_i),
  .data_o    (ldpc_packet_o)
);

assign col_curr_o = ldpc_packet_o.col_curr;
assign gf2_en_o = ldpc_packet_o.gf2_en;
assign permutation_o = ldpc_packet_o.permutation;

assign rg_changed_o = rg_changed_q;

// FSM
logic ldpc_handshake;

// mainly for readability
assign inner_valid = (state_q == VALID)? 1 : 0;
assign ldpc_handshake = inner_ready & inner_valid;

always_ff @(posedge clk_i or negedge arst_ni) begin : state_ff
  if (!arst_ni) state_q <= INIT;
  else begin
    if (state_q == VALID & ~ldpc_handshake) 
      state_q <= state_q; // backpressure
    else
      state_q <= next_state;
  end
end

logic [3:0] row_changed;
always_comb begin
  case (state_q)
    INIT: begin
      if (start_i) next_state = VALID; // 1 clock delay
      else next_state = INIT; // hold init if core is not starting the process yet
    end
    VALID: begin
      // handle backpressure and row change
      if (ldpc_handshake & rg_changed_n) next_state = INIT; 
      else next_state = state_q;
    end
    default: next_state = state_q;
  endcase
end

// Constants
localparam int unsigned RPW_SIZE = $ceil(RP_SIZE/4.0);
localparam int unsigned RPW_WIDTH = $clog2(RPW_SIZE+1);
logic [KB_WIDTH-1:0] kb_max;
logic [RPW_WIDTH-1:0] rg_max;

assign kb_max = (bg_n)? KB_WIDTH'(KB_BG2) : KB_WIDTH'(KB_BG1);
assign rg_max = (bg_n)? RPW_WIDTH'(RG_BG2+RG_BG1) : RPW_WIDTH'(RG_BG1);

// Row Pointer ROM
logic [3:0][BASEP_WIDTH-1:0] rp_wire, rp_limit_q;
logic [RPW_WIDTH-1:0] rg, rg_base;

assign rg_base = 
  (bg_n)? RPW_WIDTH'(RG_BG1) + RPW_WIDTH'(row_n >> 2)
        : RPW_WIDTH'(row_n >> 2);
assign rg = rg_base + RPW_WIDTH'(state_q);

always_ff @(posedge clk_i or negedge arst_ni) begin : rp_ff
  if (!arst_ni) rp_limit_q <= '1;
  else begin
    case (state_q)
      INIT : begin
        rp_limit_q[2:0] <= rp_wire[3:1];
        rp_limit_q[3] <= '1;
      end 
      VALID : begin
        rp_limit_q[3] <= rp_wire[0];
        rp_limit_q[2:0] <= rp_limit_q[2:0];
      end 
    endcase
  end
end

lutrom #(
  .WORD_WIDTH(4*BASEP_WIDTH),
  .SIZE      (RPW_SIZE+1),
  .NUM_PORTS (1),
  .MEM_INIT  ("mem/row_ptr.mem")
) rp_rom (
  .addr_i('{rg}),
  .dout_o('{{rp_wire}})
);

// Column Indices ROM
localparam int unsigned CSR_WIDTH = $clog2(CSR_SIZE);
logic [3:0][CSR_WIDTH-1:0] colval_addr_q, colval_addr_n; 
logic [3:0][COL_WIDTH-1:0] col_idx;

logic [3:0] row_en;
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    // enable when it is current col or a core parity bit
    row_en[i] = ((col_idx[i] <= 7'(kb_max-1) & col_curr_n == col_idx[i]) 
              | (col_idx[i] > 7'(kb_max-1) & ~row_changed[i]));
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : colval_addressing
for (int unsigned i = 0; i < 4; i++) begin
  if (!arst_ni) begin
    colval_addr_q[i] <= '0;
  end else begin
    if (state_q == VALID & ~ldpc_handshake) colval_addr_q[i] <= colval_addr_q[i]; // backpressure
    else if (state_q == INIT) begin
      // take data from bypass to increment correctly after init
      if (row_en[i]) colval_addr_q[i] <= colval_addr_n[i] + 1;
      else colval_addr_q[i] <= colval_addr_n[i];
    end
    else begin
      if (row_en[i]) colval_addr_q[i] <= colval_addr_q[i] + 1;
      else colval_addr_q[i] <= colval_addr_q[i];      
    end
  end
end
end

// bypass colval_addr_q reg for the 1 cycle during INIT
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    case (state_q)
      INIT : colval_addr_n[i] = rp_wire[i];
      VALID: colval_addr_n[i] = colval_addr_q[i];
      default: colval_addr_n[i] = colval_addr_q[i];
    endcase
  end
end

lutrom #(
  .WORD_WIDTH(COL_WIDTH),
  .SIZE      (CSR_SIZE),
  .NUM_PORTS (4),
  .MEM_INIT  ("mem/col_indices.mem")
) col_idx_rom (
  .addr_i(colval_addr_n),
  .dout_o(col_idx)
);

// Column check and row change check
logic [1:0][COL_WIDTH:0] cidx_temp;
logic [3:0][COL_WIDTH:0] cidx_comp;

always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    // row change check
    row_changed[i] = colval_addr_n[i] == rp_limit_q[i];

    // append row change to skew comparison
    cidx_comp[i] = {row_changed[i], col_idx[i]};
  end
end
assign rg_changed_n = &row_changed;

// Get current column
always_comb begin
  // compare row 1 and 2
  if (cidx_comp[0] <= cidx_comp[1]) cidx_temp[0] = cidx_comp[0];
  else cidx_temp[0] = cidx_comp[1];

  // compare row 3 and 4
  if (rg_base >= rg_max - 1) cidx_temp[1] = '1; // guard for last row
  else if (cidx_comp[2] <= cidx_comp[3]) cidx_temp[1] = cidx_comp[2];
  else cidx_temp[1] = cidx_comp[3];  

  // get minimum of all 4 rows
  if (cidx_temp[0] <= cidx_temp[1]) col_curr_n = cidx_temp[0][COL_WIDTH-1:0];
  else col_curr_n = cidx_temp[1][COL_WIDTH-1:0];
end

// Values ROM
generate
  genvar rom_i;
  for (rom_i = 0; rom_i < 2; rom_i++) begin : val_rom_gen
    logic [1:0][CSR_WIDTH-1:0] val_addr;
    logic [1:0][ZC_WIDTH-1:0] val, val_held_q, val_muxed;
    logic val_is_held;

    assign val_addr = colval_addr_n[rom_i*2 +: 2];

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

    // skid buffer ready delay handling
    // NOTE: due to 1 clock delay, even if address changed
    // output will still be same for a clock, so this works
    always_ff @(posedge clk_i or negedge arst_ni) begin
      if (!arst_ni) begin
        val_is_held <= 0;
        val_held_q <= '0;
      end else begin
        if (state_q == VALID) begin
          if (~ldpc_handshake & ~val_is_held) begin
            val_held_q <= val;
            val_is_held <= 1;
          end else if (ldpc_handshake) begin
            val_is_held <= 0;
          end
        end else begin
          val_is_held <= 0;
        end
      end
    end

    // mux BRAM last output and current output
    assign val_muxed[0] = val_is_held ? val_held_q[0] : val[0];
    assign val_muxed[1] = val_is_held ? val_held_q[1] : val[1];

    // assign -1 if (row, col) is invalid (!= col_curr)
    // can also use gf2_en to handle this like Dawam's idea
    assign permutation[rom_i*2] = (gf2_en_q[rom_i*2])? val_muxed[0] : '1;
    assign permutation[rom_i*2+1] = (gf2_en_q[rom_i*2+1])? val_muxed[1] : '1;
  end
endgenerate

// output registers
always_ff @(posedge clk_i or negedge arst_ni) begin : output_ff
  if (!arst_ni) begin
    col_curr_q <= '0;
    gf2_en_q <= '0; 
  end else begin
    if (state_q == VALID & ~ldpc_handshake) begin
      // backpressure
      col_curr_q <= col_curr_q;
      gf2_en_q <= gf2_en_q;
    end else begin
      col_curr_q <= col_curr_n;
      gf2_en_q <= row_en;
    end
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : row_change_ff
  if (!arst_ni) begin
    rg_changed_q <= 0;
  end else begin
    if (state_q == INIT & ~start_i) begin
      rg_changed_q <= rg_changed_q;
    end else if (state_q == VALID) begin
      rg_changed_q <= rg_changed_n & ldpc_handshake;
    end else begin
      rg_changed_q <= 0; 
    end
  end
end
endmodule
