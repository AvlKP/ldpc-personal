import ldpc_pkg::*;

// TODO: instantiate ROMs outside of decoder's scope
module csr_decoder #(
  localparam int unsigned BG_ROW_WIDTH = $clog2(BG1_ROW_N),
  localparam int unsigned BG_COL_WIDTH = $clog2(BG1_COL_N)
) (
  input logic clk_i,
  input logic arst_ni,

  input logic base_graph_i,
  input logic [ZC_WIDTH-1:0] lifting_size_i,
  input logic [BG_ROW_WIDTH-1:0] row_i,
  input logic [BG_COL_WIDTH-1:0] col_i,
  output logic [ZC_WIDTH-1:0] permutation_o [0:3]
);

// NOTE: optimized for PYNQ Z1 BRAM's 9n port width

// Decode row and BG to row pointer ROM address
localparam int unsigned RP_ROM_SIZE = BG1_ROW_N + BG2_ROW_N + 4; // +2 for rp, +2 for rounding to nearest 4n
localparam int unsigned RP_ROM_WIDTH = $clog2(RP_ROM_SIZE);
logic [8:0] rp_out;
logic [RP_ROM_WIDTH-1:0] rp_addr, rp_offset;
assign rp_addr = rp_offset + RP_ROM_WIDTH'(row_i);

always_comb begin
  case (base_graph_i)
    1'b0 : rp_offset = '0;
    1'b1 : rp_offset = BG1_ROW_N + 2; 
  endcase
end

rom_sp #(
  .WORD_WIDTH(9),
  .SIZE      (RP_ROM_SIZE), 
  .MEM_INIT  ("mem/rp_rom.mem")
) rp_rom (
  .clk_i (clk_i),
  .en_i  (1),
  .addr_i(rp_addr),
  .dout_o(rp_out)
);

// Decode BG and row pointer to col ROM address
localparam int unsigned COL_ROM_SIZE = BG1_CSR_COL_N + BG2_CSR_COL_N;
localparam int unsigned COL_ROM_WIDTH = $clog2(COL_ROM_SIZE);
logic [5:0] col_out;
logic [COL_ROM_WIDTH-1:0] col_addr, col_offset;
assign col_addr = rp_out

rom_sp #(
  .WORD_WIDTH(6), // will implicitly expands to 9 (3 unsused bits)
  .SIZE      (COL_ROM_SIZE),
  .MEM_INIT  ("mem/col_rom.mem")
) col_rom (
  .clk_i (clk_i),
  .en_i  (1),
  .addr_i(addr_i),
  .dout_o(dout_o)
);

// Decode BG, Zc and col to value ROM address


endmodule