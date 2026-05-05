// a for write (wider)
// b for read (lesser)

module asym_rgw_sdp_bram #(
  parameter int unsigned WORDA_WIDTH = 8,
  parameter int unsigned WORDB_WIDTH = 16,
  parameter int unsigned SIZEA = 128,
  localparam int unsigned RATIO_RW = WORDB_WIDTH / WORDA_WIDTH,
  localparam int unsigned ADDRA_WIDTH = $clog2(SIZEA),
  localparam int unsigned ADDRB_WIDTH = $clog2(SIZEA / RATIO_RW)
) (
  input logic clk_i,
  input logic ena_i,
  input logic wea_i,
  input logic enb_i,
  input logic [ADDRA_WIDTH-1:0] addra_i,
  input logic [ADDRB_WIDTH-1:0] addrb_i,
  input logic [WORDA_WIDTH-1:0] dia_i,
  output logic [WORDB_WIDTH-1:0] dob_o
);

logic [WORDA_WIDTH-1:0] ram [0:SIZEA-1];
logic [WORDB_WIDTH-1:0] readb;

always_ff @(posedge clk_i) begin
  if (ena_i) begin
    if (wea_i) ram[addra_i] <= dia_i;
  end
end

localparam int unsigned LSB_WIDTH = $clog2(RATIO_RW);
always_ff @(posedge clk_i) begin
  if (enb_i) begin
    integer unsigned i;
    logic [LSB_WIDTH-1:0] lsb_addr;
    for (i = 0; i < RATIO_RW; i = i+1) begin
      lsb_addr = LSB_WIDTH'(i);
      readb[(i+1)*WORDA_WIDTH-1 -: WORDA_WIDTH] <= 
        ram[{addrb_i, lsb_addr}];
    end
  end
end
assign dob_o = readb;

// asymmetric BRAM only supports x * 2^n word size on the wider side
initial begin
  assert (RATIO_RW != 1) 
  else   $fatal(1, "RAM is symmetric.");

  assert (RATIO_RW > 0 && (RATIO_RW & (RATIO_RW - 1)) == 0) 
  else   $fatal(2, "The read port must be bigger by a power of 2.");
end

endmodule
