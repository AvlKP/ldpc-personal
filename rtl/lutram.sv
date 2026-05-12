module lutram #(
  parameter int unsigned WORD_WIDTH = 8,
  parameter int unsigned SIZE = 32,
  parameter int unsigned NUM_RPORTS = 1,
  parameter string MEM_INIT = "mem/example.mem",
  parameter logic MERGE_ADDR = 0, // use write address as read too
  
  localparam int unsigned INUM_RPORTS = (MERGE_ADDR)? NUM_RPORTS-1 : NUM_RPORTS,
  localparam int unsigned ADDR_WIDTH = $clog2(SIZE)
) (
  input logic clk_i,
  input logic we,

  // write port
  input logic [ADDR_WIDTH-1:0] waddr_i,
  input logic [WORD_WIDTH-1:0] din_i,

  // read port
  input logic [INUM_RPORTS-1:0][ADDR_WIDTH-1:0] raddr_i,
  output logic [NUM_RPORTS-1:0][WORD_WIDTH-1:0] dout_o
);
  
(* ram_style = "distributed" *) logic [WORD_WIDTH-1:0] ram [0:SIZE-1];

initial begin
  $readmemh(MEM_INIT, ram);
end

always_ff @(posedge clk_i) begin
  if (we) ram[waddr_i] <= din_i;
end

generate
  genvar i;
  if (MERGE_ADDR) begin
    assign dout_o[0] = ram[waddr_i];
    for (i = 0; i < INUM_RPORTS; i++)
      assign dout_o[i+1] = ram[raddr_i[i]];

  end else begin
    for (i = 0; i < INUM_RPORTS; i++)
      assign dout_o[i] = ram[raddr_i[i]];
  end
endgenerate

endmodule
