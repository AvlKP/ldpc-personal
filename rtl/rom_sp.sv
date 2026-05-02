module rom_sp #(
  parameter int unsigned WORD_WIDTH = 9,
  parameter int unsigned SIZE = 16,
  parameter string MEM_INIT = "mem/example.mem",
  localparam int unsigned ADDR_WIDTH = $clog2(SIZE)
) (
  input logic clk_i,
  input logic en_i,
  input logic [ADDR_WIDTH-1:0] addr_i,
  output logic [WORD_WIDTH-1:0] dout_o
);
  
(* rom_style = "block" *) logic [WORD_WIDTH-1:0] rom [0:SIZE-1];

initial begin
  $readmemh(MEM_INIT, rom);
end

always @(posedge clk_i) begin
  if (en_i) dout_o <= rom[addr_i];
end
endmodule