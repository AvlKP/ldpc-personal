import ldpc_pkg::*;

// INPUT BUFFER
// takes an AXI Stream input of code block that is to be processed by LDPC core
// takes several configuration signals from control registers
// can take the next code block to be processed before current one is done
// outputs a 384-bit data that is cleared on handshake
// output can be:
// - 1 384-bit vector
// - 2 192-bit vectors
// - 4 96-bit vectors
// multiple vector output contain the same data
// output vectors might contain extra data that is not part of the Zc-bit info group

module input_buffer #(
  // recalculate as needed
  localparam int unsigned DATA_WIDTH = 32,
  localparam int unsigned BANK_SIZE = 32,
  localparam int unsigned BANK_NUM = 12
) (
  input logic clk_i,
  input logic arst_ni,

  // AXI Stream
  input  logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  logic s_axis_tvalid,
  output logic s_axis_tready,

  output logic ldpc_valid_o, // data batch output is valid
  input logic ldpc_ready_i, // the ldpc core is ready to accept a data batch
  // the input vector has been processed
  // change to the other RAM after asserted
  input logic ldpc_done_i,

  // store in inner register local to each RAM
  // change upon first AXIS handshake after counter >= input_bits_i
  input logic [ZC_WIDTH-1:0] lifting_size_i,
  // store in inner register
  // change upon first AXIS handshake after counter >= input_bits_i
  input logic [15:0] input_bits_i, 

  // store in inner register
  // change upon LDPC inner handshake
  input logic [KB_WIDTH-1:0] info_group_i,
  output logic [ZC_MAX-1:0] data_batch_o
);

// RAM signals
localparam int unsigned ADDR_WIDTH = $clog2(BANK_SIZE);
localparam int unsigned BANK_WIDTH = $clog2(BANK_NUM);

logic [1:0] ram_full_q;
logic [ZC_WIDTH-1:0] ram_zc_q [0:1];

logic ramw_swap_q;
logic [ADDR_WIDTH-1:0] ramw_addr_q;
logic [BANK_WIDTH-1:0] ramw_bank_q;
logic [DATA_WIDTH-1:0] ramw_data;
assign ramw_data = s_axis_tdata;

logic ramr_swap_q;
logic [ADDR_WIDTH-1:0] ramr_addr_q, ramr_addr_n;
logic [BANK_NUM-1:0][DATA_WIDTH-1:0] ramr_data_n [0:1];

// R/W signals
localparam int unsigned COUNTER_WIDTH = $clog2(INPUT_BITS_MAX/DATA_WIDTH);

logic [COUNTER_WIDTH-1:0] w_limit_q, w_cnt_q;
logic w_idle_q, w_idle_qdly;

// AXI Stream signals
logic axis_handshake;
assign axis_handshake = s_axis_tready & s_axis_tvalid;
assign s_axis_tready = (w_cnt_q < w_limit_q);

// RAM R/W logic
always_ff @(posedge clk_i or negedge arst_ni) begin : write_init
  if (!arst_ni) begin
    w_limit_q <= '1;
    w_idle_q <= 1;
    w_idle_qdly <= 1;
  end else begin
    if (w_idle_q & axis_handshake) begin
      w_limit_q <= COUNTER_WIDTH'(input_bits_i >> $clog2(DATA_WIDTH));
      w_idle_q <= 0;
    end else if (~w_idle_q & ~s_axis_tready) begin
      w_limit_q <= '1;
      w_idle_q <= 1;
    end

    w_idle_qdly <= w_idle_q;
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : ram_control
  if (!arst_ni) begin
    ram_full_q <= 2'b00;
    ram_zc_q[0] <= '0;
    ram_zc_q[1] <= '0;

    ramw_swap_q <= 0;
    ramr_swap_q <= 0;
  end else begin
    for (int unsigned i = 0; i < 2; i++) begin
      if (ramr_swap_q == i) begin
        // TODO: assume done is idle core, do edge check instead of level
        if (ldpc_done_i) ram_zc_q[i] <= '0;
        else if (w_idle_q & axis_handshake) ram_zc_q[i] <= lifting_size_i;

        if (ldpc_done_i) ram_full_q[i] <= 0;
        else if (~w_idle_q & ~s_axis_tready) ram_full_q[i] <= 1; 
      end
    end

    if (ldpc_done_i) ramr_swap_q <= ~ramr_swap_q;
    if (^ram_full_q) ramw_swap_q <= ~ramw_swap_q;
  end
end

logic bank_full;
assign bank_full = (ramw_bank_q + (1 << 2)) >= (1 << 4);
always_ff @(posedge clk_i or negedge arst_ni) begin : ram_counter
  if (!arst_ni) begin
    ramw_addr_q <= '0;
    ramw_bank_q <= '0;
    w_cnt_q <= '0;
  end else begin
    if (w_idle_q & ~w_idle_qdly) begin
      ramw_addr_q <= '0;
      ramw_bank_q <= '0;
      w_cnt_q <= '0;
    end
    else if (axis_handshake) begin
      w_cnt_q <= w_cnt_q + 1;

      if (bank_full) begin
        ramw_bank_q <= '0;
        ramw_addr_q <= ramw_addr_q + 1;
      end else
        ramw_bank_q <= ramw_bank_q + 1;
    end
  end
end

// LDPC Core interface
// TODO: latch during transaction
assign ramr_addr_n = info_group_i;

// RAM instances
generate
  genvar i;
  for (i = 0; i < 2; i++) begin : ram_gen
    logic we;
    assign we = i == ramw_swap_q;

    input_buffer_bank #(
      .DATA_WIDTH(DATA_WIDTH),
      .BANK_SIZE (BANK_SIZE),
      .BANK_NUM  (BANK_NUM)
     ) input_buffer_bank (
      .clk_i  (clk_i),
      .din_i  (ramw_data),
      .waddr_i(ramw_addr_q),
      .bank_i (ramw_bank_q),
      .we_i   (we),
      .raddr_i(ramr_addr_n),
      .dout_o (ramr_data_n[i])
    );
  end
endgenerate

logic [1:0] out_sel; // select data_batch size according to zc
assign out_sel[1] = (ram_zc_q[ramr_swap_q] <= ZC_MAX >> 1)? 0 : 1; // zc <= 192
assign out_sel[0] = (ram_zc_q[ramr_swap_q] <= ZC_MAX >> 2)? 0 : 1; // zc <= 96

always_ff @(posedge clk_i or negedge arst_ni) begin : out_reg
  if (!arst_ni) begin 
    ldpc_valid_o <= 0;
    data_batch_o <= '0;
  end 
  else if (ldpc_ready_i) begin
    ldpc_valid_o <= 1;

    case (out_sel)
      2'b00: begin
        for (int unsigned j = 0; j < 4; j++) begin
          data_batch_o[(ZC_MAX >> 2)*j +: (ZC_MAX >> 2)] 
            <= {ramr_data_n[ramr_swap_q]}[0 +: (ZC_MAX >> 2)];
        end
      end
      2'b01: begin
        for (int unsigned j = 0; j < 2; j++) begin
          data_batch_o[(ZC_MAX >> 1)*j +: (ZC_MAX >> 1)] 
            <= {ramr_data_n[ramr_swap_q]}[0 +: (ZC_MAX >> 1)];
        end
      end
      2'b11: data_batch_o <= {ramr_data_n[ramr_swap_q]};
      default: data_batch_o <= '1;
    endcase
  end 
  // else if (transaction done and no further transaction) invalidate
end
endmodule
