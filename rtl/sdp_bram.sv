// a for write
// b for read
// {9, 18, 36, 72}-bit native ports for xc7z020

module sdp_bram #(
  parameter int unsigned WORD_WIDTH = 32,
  parameter int unsigned SIZE = 1,
  localparam int unsigned ADDR_WIDTH = $clog2(SIZE)
) (
  input logic clk_i,
  input logic ena_i,
  input logic enb_i,
  input logic wea_i,
  input logic [ADDR_WIDTH-1:0] addra_i,
  input logic [ADDR_WIDTH-1:0] addrb_i,
  input logic [WORD_WIDTH-1:0] dia_i,
  output logic [WORD_WIDTH-1:0] dob_o
);
  
logic [WORD_WIDTH-1:0] ram [0:ADDR_WIDTH-1];

always_ff @(posedge clk_i) begin
  if (ena_i) begin
    if (wea_i) ram[addra_i] <= dia_i;
  end
end

always_ff @(posedge clk_i) begin
  if (enb_i) dob_o <= ram[addrb_i];
end

endmodule