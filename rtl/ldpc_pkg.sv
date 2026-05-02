package ldpc_pkg;
  parameter int unsigned DATA_WIDTH = 32; // ARM A9 CPU
  parameter int unsigned STRB_WIDTH = DATA_WIDTH / 8; // strobe selects the bytes from a word

  // consult the register map
  parameter int unsigned REG_WIDTH = 32;
  parameter int unsigned REG_COUNT = 4;
  parameter int unsigned REG_NUM_BYTES = REG_WIDTH * REG_COUNT / 8;
  parameter int unsigned ADDR_WIDTH = $clog2(REG_NUM_BYTES);

  parameter int unsigned BG1_ROW_N = 46;
  parameter int unsigned BG2_ROW_N = 42;
  parameter int unsigned BG1_COL_N = 68;
  parameter int unsigned BG2_COL_N = 52;
  parameter int unsigned BG1_CSR_COL_N = 316;
  parameter int unsigned BG2_CSR_COL_N = 197;

  parameter int unsigned ZC_MAX = 384;
  parameter int unsigned ZC_WIDTH = $clog2(ZC_MAX + 1);
  parameter int unsigned INPUT_BITS_MAX = 8448; // BG1 maximum
  parameter int unsigned OUTPUT_BITS_MAX = 26112;
  parameter int unsigned KB_MAX = 22;
  parameter int unsigned KB_WIDTH = $clog2(KB_MAX + 1);
endpackage