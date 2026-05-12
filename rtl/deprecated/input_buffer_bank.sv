module input_buffer_bank #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned BANK_SIZE = 32,
  parameter int unsigned BANK_NUM = 12
) (
  input logic clk_i,

  // write port
  input logic [DATA_WIDTH-1:0] din_i,
  input logic [$clog2(BANK_SIZE)-1:0] waddr_i,
  input logic [$clog2(BANK_NUM)-1:0] bank_i,
  input logic we_i,

  // read port
  input logic [$clog2(BANK_SIZE)-1:0] raddr_i,
  output logic [BANK_NUM-1:0][DATA_WIDTH-1:0] dout_o
);

generate
  genvar i;
  for (i = 0; i < BANK_NUM; i++) begin
    logic we;
    assign we = (i == bank_i) & we_i;

    lutram #(
      .WORD_WIDTH(DATA_WIDTH),
      .SIZE      (BANK_SIZE),
      .NUM_RPORTS(1),
      .MEM_INIT  (),
      .MERGE_ADDR(0)
     ) lutram (
      .clk_i  (clk_i),
      .we     (we),
      .waddr_i(waddr_i),
      .din_i  (din_i),
      .raddr_i(raddr_i),
      .dout_o (dout_o[i])
    );
  end
endgenerate
  
endmodule