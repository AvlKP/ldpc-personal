import ldpc_pkg::*;

// goofy ahh parameters
module input_buffer #(
  parameter int unsigned DATA_WIDTH = 32'd32
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

localparam int unsigned BRAM_SIZE = INPUT_BITS_MAX/DATA_WIDTH;
localparam int unsigned POINTER_WIDTH = $clog2(BRAM_SIZE);
localparam int unsigned CHUNK_BITS = 128;
localparam int unsigned CHUNK_WIDTH = $clog2(CHUNK_BITS);

// RAM signals
logic ram_full [0:1];
logic [ZC_WIDTH-1:0] ram_zc [0:1];

logic [POINTER_WIDTH-1:0] ramw_pointer [0:1];
logic ramw_swap;

logic ramr_swap;
logic [CHUNK_WIDTH-1:0] ramr_pointer_inner [0:1];
logic [CHUNK_BITS-1:0] ramr_data_inner [0:1];
logic [CHUNK_WIDTH-1:0] ramr_pointer;
logic [CHUNK_BITS-1:0] ramr_data;

assign ramr_pointer = ramr_data_inner[ramr_swap];
assign ramr_data = ramr_data_inner[ramr_swap];

// AXIS
logic axis_handshake;
assign axis_handshake = s_axis_tready & s_axis_tvalid;

// Write signals
logic [POINTER_WIDTH-1:0] write_counter;
logic [POINTER_WIDTH-1:0] write_threshold;
logic write_idle;
assign write_counter = (ramw_swap)? ramw_pointer[1] : ramw_pointer[0];
// let there be 1 clock delay between ram transition, meh
assign s_axis_tready = (write_counter >= write_threshold)? 1 : 0;

always_ff @(posedge clk_i or negedge arst_ni) begin : write_init
  if (!arst_ni) begin
    write_threshold <= '1; // set to cap before input is received
    write_idle <= 1;
  end else begin
    if (write_idle & axis_handshake) begin
      write_threshold <= 9'(input_bits_i >> $clog2(DATA_WIDTH));
      write_idle <= 0;
    end else if (~write_idle & ~s_axis_tready) begin
      write_threshold <= '1;
      write_idle <= 1;
    end
  end 
end

always_ff @(posedge clk_i or negedge arst_ni) begin : ram_control
  if (!arst_ni) begin
    int unsigned j;
    for (j=0;j<2;j++) begin
      ramw_pointer[j] <= '0;
      ram_full[j] <= '0;
      ram_zc[j] <= '0;
    end

    ramw_swap <= 0;
    ramr_swap <= 0;
  end else begin
    // TODO: Check this for writing to the same signal
    // might change to per-ram basis
    if (write_idle & axis_handshake) ram_zc[ramw_swap] <= lifting_size_i;
    if (axis_handshake) ramw_pointer[ramw_swap] <= ramw_pointer[ramw_swap] + 1;
    if (~write_idle & ~s_axis_tready) ram_full[ramw_swap] <= 1;
    if (ram_full[ramw_swap] & ~ram_full[~ramw_swap]) ramw_swap <= ~ramw_swap;

    if (ldpc_done_i) begin
      ram_zc[ramr_swap] <= '0;
      ramw_pointer[ramr_swap] <= '0;
      ram_full[ramr_swap] <= 0;
      ramr_swap <= ~ramr_swap;
    end else begin
      
    end
  end
end

genvar i;
generate
  for (i=0;i<2;i++) begin : ram_gen
    asym_rgw_sdp_bram #(
      .WORDA_WIDTH(DATA_WIDTH),
      .WORDB_WIDTH(128), // 128 is least power of 2 to be > 96
      .SIZEA      (BRAM_SIZE)
    ) asym_rgw_sdp_bram (
      .clk_i  (clk_i),
      .ena_i  (1),
      .wea_i  (s_axis_tready),
      .enb_i  (1),
      .addra_i(ramw_pointer[i]),
      .addrb_i(ramr_pointer_inner[i]), // output control
      .dia_i  (s_axis_tdata),
      .dob_i  (ramr_data_inner[i]) // to output datapaths
    );
  end
endgenerate

// TODO: OUTPUT CONTROL AND DATAPATH
// control: zc + kb -> 2nd bram base address
// prod[13:0] = zc * (kb - 1)
// prod[13:7] -> BRAM read address
// prod[6:0] -> shifter control

logic read_idle;
logic [KB_WIDTH-1:0] read_kb;

// 2 <= Zc <= 96 -> 1*128
// 96 < Zc <= 192 -> 2*128
// 192 < Zc <= 384 -> 4*128
logic [2:0] read_counter;

logic read_handshake;
assign read_handshake = ldpc_ready_i & ldpc_valid_o;

always_ff @(posedge clk_i or negedge arst_ni) begin : read_init
  if (!arst_ni) begin
    read_kb <= '0;
    read_idle <= 1;
  end else begin
    if (read_idle & ldpc_ready_i) begin
      read_idle <= 0;
      read_kb <= info_group_i;
    end else if (~read_idle & ldpc_valid_o) begin
      read_idle <= 1;
      read_kb <= '0;
    end
  end
end

logic [1:0] out_sel; // select data_batch size according to zc
assign out_sel[0] = (ram_zc[ramr_swap] <= ZC_MAX >> 1)? 0 : 1; // zc <= 192
assign out_sel[1] = (ram_zc[ramr_swap] <= ZC_MAX >> 2)? 0 : 1; // zc <= 96

logic [2:0] read_thres;
always_comb begin
  case (out_sel)
    2'b00: read_thres = 3'b001; // 2 <= zc <= 96 (let driver handle zc minimum)
    2'b01: read_thres = 3'b010; // 96 < zc <= 192
    2'b10: read_thres = 3'b000; // err
    2'b11: read_thres = 3'b100; // 192 < zc <= 384
  endcase
end

logic read_fetch_done;
assign read_fetch_done = read_counter >= read_thres;
always_ff @(posedge clk_i or negedge arst_ni) begin : read_count
  if (!arst_ni) begin
    read_counter <= '0;
  end else begin
    if (~read_idle) begin
      if (ldpc_valid_o) read_counter <= '0;
      else if (~read_fetch_done) read_counter <= read_counter + 1;
    end
  end
end

// goofy paramsss
logic [ZC_WIDTH + KB_WIDTH - 1:0] zc_kb_prod;
logic [(ZC_WIDTH + KB_WIDTH - CHUNK_WIDTH)-1:0] base_pointer;
logic [CHUNK_WIDTH - 1:0] offset_shift;
logic mult_en;

always_ff @(posedge clk_i) begin : zc_kb_mult
  if (mult_en) zc_kb_prod <= ram_zc[ramr_swap] * (read_kb - 1);
end
endmodule