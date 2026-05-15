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
  input logic [ZC_WIDTH-1:0] lifting_size_i,
  input logic [ROW_WIDTH-1:0] row_i, // current row, converted to row group of 4

  output logic [3:0][ZC_WIDTH-1:0] permutation_o, // will be -1 when col is unavailable
  output logic [3:0] gf2_en_o, // alternative to above's indicator
  output logic [3:0] parity_core_col_o,
  output logic [COL_WIDTH-1:0] col_curr_o, // current column index being processed
  output logic rowgrp_changed_o // flags that a row group change has occured
);

typedef enum logic { 
  INIT = 1'b0, // 1 cycle delay for colval_addr to be initialized
  VALID = 1'b1
 } state_t;

state_t state_q, next_state;

// I/O stuff
typedef struct packed {
  logic [COL_WIDTH-1:0] col_curr;
  logic [3:0] parity_core_col;
  logic [3:0] gf2_en;
  logic [3:0][ZC_WIDTH-1:0] permutation;
} ldpc_packet_t;

logic inner_ready, inner_valid;
logic [ROW_WIDTH-1:0] row_q, row_n;

assign row_n = (start_i & state_q == INIT)? row_i : row_q;
always_ff @(posedge clk_i or negedge arst_ni) begin : input_lock
  if (!arst_ni) begin
    row_q <= '0;
  end else if (start_i & state_q == INIT) begin
    row_q <= row_i;
  end
end

logic rowgrp_changed_n, rowgrp_changed_q;
logic [COL_WIDTH-1:0] col_curr_n, col_curr_q;
logic [3:0] parity_core_col_q;
logic [3:0] gf2_en_q;
logic [3:0][ZC_WIDTH-1:0] permutation;

ldpc_packet_t ldpc_packet_i, ldpc_packet_o; 
assign ldpc_packet_i = '{
  col_curr: col_curr_q,
  parity_core_col: parity_core_col_q,
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
assign parity_core_col_o = ldpc_packet_o.parity_core_col;
assign gf2_en_o = ldpc_packet_o.gf2_en;
assign permutation_o = ldpc_packet_o.permutation;

assign rowgrp_changed_o = rowgrp_changed_q;

// FSM
logic ldpc_handshake;

// mainly for readability
assign inner_valid = (state_q == VALID)? 1 : 0;
assign ldpc_handshake = inner_ready & inner_valid;

always_ff @(posedge clk_i or negedge arst_ni) begin : state_ff
  if (!arst_ni) 
    state_q <= INIT;
  else if (!(state_q == VALID & ~ldpc_handshake)) 
    // only transition when there's no backpressure
    state_q <= next_state;
end

logic [3:0] row_changed;
always_comb begin
  unique case (state_q)
    INIT:    next_state = start_i ? VALID : INIT;
    VALID:   next_state = (ldpc_handshake & rowgrp_changed_n) ? INIT : VALID;
    default: next_state = INIT; // Safe state recovery
  endcase
end

// Constants
localparam int unsigned RPW_SIZE = $ceil(RP_SIZE/4.0);
localparam int unsigned RPW_WIDTH = $clog2(RPW_SIZE+1);
logic [KB_WIDTH-1:0] kb_max;
logic [RPW_WIDTH-1:0] rowgrp_max;

assign kb_max = (base_graph_i)? KB_WIDTH'(KB_BG2-1) : KB_WIDTH'(KB_BG1-1);
assign rowgrp_max = (base_graph_i)? RPW_WIDTH'(RG_BG2+RG_BG1-1) : RPW_WIDTH'(RG_BG1-1);

// Row Pointer ROM
logic [3:0][BASEP_WIDTH-1:0] rowpnt_n, rowpnt_limit_q;
logic [RPW_WIDTH-1:0] rowgrp, rowgrp_base;

assign rowgrp_base = 
  (base_graph_i)? RPW_WIDTH'(RG_BG1) + RPW_WIDTH'(row_n >> 2)
        : RPW_WIDTH'(row_n >> 2);
assign rowgrp = rowgrp_base + RPW_WIDTH'(state_q);

always_ff @(posedge clk_i or negedge arst_ni) begin : rp_ff
  if (!arst_ni) begin
    rowpnt_limit_q <= '1;
  end
  else begin
    unique case (state_q)
      INIT : begin
        rowpnt_limit_q[2:0] <= rowpnt_n[3:1];
        rowpnt_limit_q[3] <= '1;
      end 
      VALID : begin
        rowpnt_limit_q[3] <= rowpnt_n[0];
        rowpnt_limit_q[2:0] <= rowpnt_limit_q[2:0];
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
  .addr_i({rowgrp}),
  .dout_o({>>{rowpnt_n}})
);

// Column Indices ROM
localparam int unsigned CSR_WIDTH = $clog2(CSR_SIZE);
logic [3:0][CSR_WIDTH-1:0] colval_addr_q, colval_addr_n; 
logic [3:0][COL_WIDTH-1:0] col_idx;

logic [3:0] row_en;
logic [3:0] is_parity_core_col;
logic [3:0] is_valid_info_col;
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    is_parity_core_col[i] = (col_idx[i] > kb_max & ~row_changed[i]);
    is_valid_info_col[i] = (col_idx[i] <= kb_max & col_curr_n == col_idx[i]); 

    row_en[i] = is_parity_core_col[i] | is_valid_info_col[i];
  end

  // ignore out of bounds value when reaching memory ends
  if (rowgrp_base >= rowgrp_max) row_en[3:2] = 2'b00;
end

always_ff @(posedge clk_i or negedge arst_ni) begin : colval_addressing
  if (!arst_ni) begin
    colval_addr_q <= '0;
  end else if (!(state_q == VALID & ~ldpc_handshake)) begin
    for (int unsigned i = 0; i < 4; i++) begin
      if (state_q == INIT) begin
        // take data from bypass to increment correctly after init
        colval_addr_q[i] <= (row_en[i])? colval_addr_n[i] + 1
                                      : colval_addr_n[i];
      end
      else begin
        colval_addr_q[i] <= (row_en[i])? colval_addr_q[i] + 1
                              : colval_addr_q[i];
      end
    end
  end
end

// bypass colval_addr_q reg for the 1 cycle during INIT
always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    case (state_q)
      INIT : colval_addr_n[i] = rowpnt_n[i];
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
    row_changed[i] = colval_addr_n[i] == rowpnt_limit_q[i];

    // append row change to skew comparison
    cidx_comp[i] = {row_changed[i], col_idx[i]};
  end
end
assign rowgrp_changed_n = &row_changed;

// Get current column
always_comb begin
  cidx_temp[0] = (cidx_comp[0] <= cidx_comp[1])? cidx_comp[0] : cidx_comp[1];
  cidx_temp[1] = (rowgrp_base >= rowgrp_max) ? '1 :
                ((cidx_comp[2] <= cidx_comp[3])? cidx_comp[2] : cidx_comp[3]);

  col_curr_n = (cidx_temp[0] <= cidx_temp[1])?
    cidx_temp[0][COL_WIDTH-1:0] : cidx_temp[1][COL_WIDTH-1:0];
end

// select which values ROM to read from
logic [2:0] rom_sel;
logic       sel_valid;

zc_decoder zc_decoder (
  .clk_i      (clk_i),
  .arst_ni    (arst_ni),
  .zc_i       (lifting_size_i),
  .zc_valid_i (1'b1),
  .i_ls_o     (rom_sel),
  .sel_valid_o(sel_valid)
);

// Values ROM
generate
  genvar rom_i, set_idx;
  for (rom_i = 0; rom_i < 2; rom_i++) begin : val_rom_gen
    logic [1:0][CSR_WIDTH-1:0]        val_addr;
    logic [1:0][ZC_WIDTH-1:0]         val, val_held_q, val_muxed;
    logic [7:0][1:0][ZC_WIDTH-1:0]    val_all_sets;
    logic                             val_is_held;
    logic [7:0]                       rom_en_decoded;

    assign val_addr = colval_addr_n[rom_i*2 +: 2];
    always_comb begin
      // PLACEHOLDER
      // TODO: Add pipelining and actual wait for this to be stable
      if (state_q == INIT) rom_en_decoded = '1;
      else begin
        rom_en_decoded = 8'h00;
        rom_en_decoded[rom_sel] = 1'b1;
      end
    end

    for (set_idx = 0; set_idx < 8; set_idx++) begin : set_rom_gen
      rom_dp #(
        .WORD_WIDTH(BASEP_WIDTH),
        .SIZE      (CSR_SIZE),
        .MEM_INIT  ((set_idx == 0) ? "mem/values_0.mem" : 
                    (set_idx == 1) ? "mem/values_1.mem" :
                    (set_idx == 2) ? "mem/values_2.mem" :
                    (set_idx == 3) ? "mem/values_3.mem" :
                    (set_idx == 4) ? "mem/values_4.mem" :
                    (set_idx == 5) ? "mem/values_5.mem" :
                    (set_idx == 6) ? "mem/values_6.mem" : "mem/values_7.mem")
      ) val_rom (
        .clk_i  (clk_i),
        .en_a_i (rom_en_decoded[set_idx]),
        .addra_i(val_addr[0]),
        .douta_o(val_all_sets[set_idx][0]),
        .en_b_i (rom_en_decoded[set_idx]),
        .addrb_i(val_addr[1]),
        .doutb_o(val_all_sets[set_idx][1])
      );
    end

    assign val[0] = val_all_sets[rom_sel][0];
    assign val[1] = val_all_sets[rom_sel][1];

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
    parity_core_col_q <= '0;
  end else if (!(state_q == VALID & ~ldpc_handshake)) begin
    col_curr_q <= col_curr_n;
    gf2_en_q <= row_en;
    parity_core_col_q <= is_parity_core_col;
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : row_change_ff
  if (!arst_ni) begin
    rowgrp_changed_q <= 0;
  end else begin
    if (state_q == INIT & ~start_i) begin
      rowgrp_changed_q <= rowgrp_changed_q;
    end else if (state_q == VALID) begin
      rowgrp_changed_q <= rowgrp_changed_n & ldpc_handshake;
    end else begin
      rowgrp_changed_q <= 0; 
    end
  end
end
endmodule
