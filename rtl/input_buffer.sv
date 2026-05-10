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

// TODO: formalize FSMs, restructure module for better synth

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

logic [POINTER_WIDTH-1:0] ramw_pointer;
logic ramw_swap;

logic ramr_swap;
// logic [CHUNK_WIDTH-1:0] ramr_pointer_inner [0:1];
logic [1:0][CHUNK_BITS-1:0] ramr_data_inner;
logic [CHUNK_WIDTH-1:0] ramr_pointer;
logic [CHUNK_BITS-1:0] ramr_data;

// assign ramr_pointer = ramr_pointer_inner[ramr_swap];
assign ramr_data = ramr_data_inner[ramr_swap];

// AXIS
logic axis_handshake;
assign axis_handshake = s_axis_tready & s_axis_tvalid;

// Write signals
logic [POINTER_WIDTH-1:0] write_threshold;
logic write_idle, write_idle_past;
// let there be 1 clock delay between ram transition, meh
// assign s_axis_tready = (write_counter >= write_threshold)? 1 : 0;
assign s_axis_tready = (ramw_pointer >= write_threshold)? 0 : 1;

always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) write_idle_past <= '0;
  else write_idle_past <= write_idle;
end

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
    for (j = 0; j < 2; j++) begin
      ram_full[j] <= '0;
      ram_zc[j] <= '0;
    end
    ramw_pointer <= '0;

    ramw_swap <= 0;
    ramr_swap <= 0;
  end else begin
    // TODO: Check this for writing to the same signal
    // might change to per-ram basis
    int unsigned j;
    for (j = 0; j < 2; j++) begin
      if (ramr_swap == j & ldpc_done_i) begin
        ramw_pointer <= '0;
        ram_zc[j] <= '0;
        ram_full[j] <= 0;
        ramr_swap <= ~ramr_swap;          
      end else if (ramw_swap == j) begin
        if (write_idle & axis_handshake) ram_zc[j] <= lifting_size_i;
        if (write_idle & ~write_idle_past) ramw_pointer <= '0;
        else if (axis_handshake) ramw_pointer <= ramw_pointer + 1;
        if (~write_idle & ~s_axis_tready) ram_full[j] <= 1;
        if (ram_full[j] & ~ram_full[~j]) ramw_swap <= ~ramw_swap;
      end
    end
  end
end

genvar i;
generate
  for (i=0;i<2;i++) begin : ram_gen
    logic ena_w, ena_r;
    assign ena_w = i == ramw_swap;
    assign ena_r = i == ramr_swap;
    asym_rgw_sdp_bram #(
      .WORDA_WIDTH(DATA_WIDTH),
      .WORDB_WIDTH(128), // 128 is least power of 2 to be > 96
      .SIZEA      (BRAM_SIZE)
    ) asym_rgw_sdp_bram (
      .clk_i  (clk_i),
      // .ena_i  (1),
      .ena_i  (ena_w),
      .wea_i  (s_axis_tready),
      // .enb_i  (1),
      .enb_i  (ena_r),
      .addra_i(ramw_pointer),
      // .addrb_i(ramr_pointer_inner[i]), // output control
      .addrb_i(ramr_pointer), // output control
      .dia_i  (s_axis_tdata),
      .dob_o  (ramr_data_inner[i]) // to output datapaths
    );
  end
endgenerate

// OUTPUT CONTROL AND DATAPATH
// control: zc + kb -> 2nd bram base address
// prod[13:0] = zc * (kb - 1)
// prod[13:7] -> BRAM read address
// prod[6:0] -> shifter control

// 2 <= Zc <= 96 -> 1*128
// 96 < Zc <= 192 -> 2*128
// 192 < Zc <= 384 -> 4*128
// read delay counter is lagging by 1 clk
logic [2:0] read_counter, read_delay_counter;
logic read_idle;
logic [(1 << ZC_WIDTH)-1:0] read_buffer;

logic read_handshake;
assign read_handshake = ldpc_ready_i & ldpc_valid_o;

logic [1:0] out_sel; // select data_batch size according to zc
assign out_sel[1] = (ram_zc[ramr_swap] <= ZC_MAX >> 1)? 0 : 1; // zc <= 192
assign out_sel[0] = (ram_zc[ramr_swap] <= ZC_MAX >> 2)? 0 : 1; // zc <= 96

logic [1:0] read_thres;
always_comb begin
  case (out_sel)
    2'b00: read_thres = 2'b01; // 2 <= zc <= 96 (let driver handle zc minimum)
    2'b01: read_thres = 2'b10; // 96 < zc <= 192
    2'b11: read_thres = 2'b11; // 192 < zc <= 384
    default: read_thres = 2'b00;
  endcase
end

// goofy paramsss
localparam int unsigned ZC_KB_WIDTH = ZC_WIDTH + KB_WIDTH;
localparam int unsigned BASEP_WIDTH = ZC_KB_WIDTH - CHUNK_WIDTH;
logic [ZC_KB_WIDTH - 1:0] zc_kb_prod;
logic [BASEP_WIDTH - 1:0] base_pointer;
logic [CHUNK_WIDTH - 1:0] offset_shift;

assign base_pointer = zc_kb_prod[ZC_KB_WIDTH-1:CHUNK_WIDTH] + BASEP_WIDTH'(read_counter);
assign offset_shift = zc_kb_prod[CHUNK_WIDTH-1:0];

// configure the bram read
// TODO: check combi path length
assign ramr_pointer = base_pointer; 

always_ff @(posedge clk_i or negedge arst_ni) begin : read_init
  if (!arst_ni) begin
    read_idle <= 1;
    zc_kb_prod <= '0;
  end else begin
    if (read_idle & ldpc_ready_i) begin
      read_idle <= 0;
      zc_kb_prod <= (info_group_i - 1) * ram_zc[ramr_swap];
    end else if (~read_idle & read_handshake) begin
      read_idle <= 1;
      zc_kb_prod <= '0;
    end
  end
end

logic read_fetch_done, read_shift_done, read_fetch_comp;
assign read_fetch_comp = read_counter > read_thres;
always_ff @(posedge clk_i or negedge arst_ni) begin : read_count
  if (!arst_ni) begin
    read_fetch_done <= 0;
    read_counter <= '0;
    read_delay_counter <= '0;
  end else begin
    if (~read_idle) begin
      if (read_handshake) begin
        read_counter <= '0;
        read_delay_counter <= '0;
        read_fetch_done <= 0;
      end 
      else if (~read_fetch_comp) begin
        read_counter <= read_counter + 1;
        read_delay_counter <= read_counter;
      end 
      else begin
        read_fetch_done <= 1;
        read_delay_counter <= read_counter;
      end 
    end

  end
end

// NOTE: might need to pipeline shifting to 2 stages if combi too long
// TODO: check combi path length
always_ff @(posedge clk_i or negedge arst_ni) begin : read_buff
  if (!arst_ni) begin
    read_buffer <= '0;
    read_shift_done <= 0;
  end else begin
    if (~read_idle) begin
      if (read_handshake) begin
        read_shift_done <= 0;
        read_buffer <= '0;
      end
      // shifting for actual data
      else if (~read_fetch_done) read_buffer[ZC_WIDTH'(read_delay_counter) << CHUNK_WIDTH +: CHUNK_BITS] <= ramr_data;
      else if (read_fetch_done & ~ldpc_valid_o) begin
        read_buffer <= read_buffer >> offset_shift;
        read_shift_done <= 1;
      end
    end
  end
end

always_ff @(posedge clk_i or negedge arst_ni) begin : read_out
  if (!arst_ni) begin
    data_batch_o <= '0;
    ldpc_valid_o <= 0;
  end else begin
    if (read_handshake) begin
      data_batch_o <= '0;
      ldpc_valid_o <= 0;
    end else if (read_shift_done & ~ldpc_valid_o) begin
      case (out_sel)
        2'b00 : begin
          int unsigned j;
          for (j = 0; j < 4; j++) begin
            data_batch_o[(ZC_MAX >> 2)*j +: (ZC_MAX >> 2)] <= read_buffer[0 +: (ZC_MAX >> 2)];
          end
        end 
        2'b01 : begin
          int unsigned j;
          for (j = 0; j < 2; j++) begin
            data_batch_o[(ZC_MAX >> 1)*j +: (ZC_MAX >> 1)] <= read_buffer[0 +: (ZC_MAX >> 1)];
          end
        end
        2'b11 : begin
          data_batch_o <= read_buffer[ZC_MAX-1:0];
        end
        default: begin
          data_batch_o <= '1;
        end
      endcase

      ldpc_valid_o <= 1;
    end
  end
end
endmodule
