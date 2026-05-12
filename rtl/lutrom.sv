module lutrom #(
    parameter int unsigned WORD_WIDTH = 9,
    parameter int unsigned SIZE = 16,
    parameter int unsigned NUM_PORTS = 4,
    parameter string MEM_INIT = "",
    localparam int unsigned ADDR_WIDTH = $clog2(SIZE)
) (
    input  logic [NUM_PORTS-1:0][ADDR_WIDTH-1:0] addr_i,
    output logic [NUM_PORTS-1:0][WORD_WIDTH-1:0] dout_o
);

  (* rom_style = "distributed" *) logic [WORD_WIDTH-1:0] rom [0:SIZE-1];

  initial begin
    if (MEM_INIT != "") $readmemh(MEM_INIT, rom);
    else begin
      for (integer unsigned i = 0; i < SIZE; i++) begin
        rom[i] = '0;
      end
    end
  end

  always_comb begin
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      dout_o[i] = rom[addr_i[i]];
    end
  end

endmodule
