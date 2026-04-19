import ldpc_pkg::*;

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
// ! NEED MECHANISM TO ACCESS DIFFERENT DATA BATCHES

  // input logic start_i, // move new data to R2 (request new information bit group)
  // output logic done_o, // data in R2 ready to be consumed



// extra +1 for leading first pointer
localparam int unsigned BRAM_SIZE = INPUT_BITS_MAX/DATA_WIDTH;
localparam int unsigned POINTER_WIDTH = $clog2(BRAM_SIZE);
logic [POINTER_WIDTH-1:0] first_pointer;
logic [POINTER_WIDTH-1:0] second_pointer;

logic handshake;
logic initial_cyc; // handle initial edge case

assign handshake = s_axis_tready & s_axis_tvalid;
always_comb begin
  s_axis_tready = (second_pointer >= input_bits_i)? 1 : 0;
end

// ! driver must assure that the input bits in register is correct
// else this fails
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    initial_cyc <= 1;

    first_pointer <= '0;
    second_pointer <= '0;
  end
  else begin
    if (start_i) initial_cyc <= 0;

    if (initial_cyc) begin
      // second bram lags by 1 clock
      if (handshake) first_pointer <= first_pointer + 1;
      if (s_axis_tready) second_pointer <= first_pointer;
    end else begin
      // second bram in sync with first
      if (handshake) first_pointer <= first_pointer + 1;
      if (s_axis_tready) second_pointer <= second_pointer + 1;
    end

    if (start_i) begin
      first_pointer <= '0;
      second_pointer <= '0;
    end
  end
end

// first BRAM: 32in-32out
logic [DATA_WIDTH-1:0] data_1to2;
sdp_bram #(
  .WORD_WIDTH(DATA_WIDTH),
  .SIZE      (BRAM_SIZE)
 ) sdp_bram (
  .clk_i  (clk_i),
  .ena_i  (1),
  .enb_i  (1),
  .wea_i  (handshake),
  .addra_i(first_pointer),
  .addrb_i(second_pointer),
  .dia_i  (s_axis_tdata),
  .dob_o  (data_1to2)
);

// second BRAMs (3): 32-in-128out
logic [127:0] data_2toout;
asym_rgw_sdp_bram #(
  .WORDA_WIDTH(DATA_WIDTH),
  .WORDB_WIDTH(128), // 128 > 96
  .SIZEA      (BRAM_SIZE)
) asym_rgw_sdp_bram (
  .clk_i  (clk_i),
  .ena_i  (1),
  .wea_i  (s_axis_tready),
  .enb_i  (1),
  .addra_i(second_pointer),
  .addrb_i(addrb_i), // output control
  .dia_i  (data_1to2),
  .dob_i  (data_2toout) // to output datapaths
);

// TODO: OUTPUT CONTROL AND DATAPATH

// control: zc + kb -> 2nd bram base address
// prod[13:0] = zc * (kb - 1)
// prod[13:7] -> BRAM read address
// prod[6:0] -> shifter control
  
logic [1:0] out_sel; // select data_batch size according to zc
assign out_sel[0] = (lifting_size_i <= ZC_MAX >> 1)? 0 : 1; // zc <= 192
assign out_sel[1] = (lifting_size_i <= ZC_MAX >> 2)? 0 : 1; // zc <= 96

logic [ZC_WIDTH + KB_WIDTH - 1:0] zc_kb_prod;
// dont know how to parameterize these ones
logic [6:0] base_pointer;
logic [6:0] offset_shift;

always_comb begin
  integer unsigned i;
  case (out_sel)
    2'b00: begin // 2 <= zc <= 96 (let driver handle zc minimum)

    end
    2'b01: begin // 96 < zc <= 192
    
    end
    2'b10: begin // err

    end
    2'b11: begin // 192 < zc <= 384
    
    end 
  endcase
end

endmodule