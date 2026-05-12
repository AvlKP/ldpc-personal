module rom_dp #(
  parameter int unsigned WORD_WIDTH = 9,
  parameter int unsigned SIZE = 16,
  parameter string MEM_INIT = "",
  localparam int unsigned ADDR_WIDTH = $clog2(SIZE)
) (
  input logic clk_i,
  
  // Port A
  input logic en_a_i,
  input logic [ADDR_WIDTH-1:0] addra_i,
  output logic [WORD_WIDTH-1:0] douta_o,
  
  // Port B
  input logic en_b_i,
  input logic [ADDR_WIDTH-1:0] addrb_i,
  output logic [WORD_WIDTH-1:0] doutb_o
);
  
  (* rom_style = "block" *) logic [WORD_WIDTH-1:0] rom [0:SIZE-1];

  initial begin
    if (MEM_INIT != "") $readmemh(MEM_INIT, rom);
    else begin
      for (integer unsigned i = 0; i < SIZE; i++) begin
        rom[i] = '0;
      end
    end
  end

  always @(posedge clk_i) begin
    if (en_a_i) douta_o <= rom[addra_i];
    if (en_b_i) doutb_o <= rom[addrb_i];
  end
  
endmodule
