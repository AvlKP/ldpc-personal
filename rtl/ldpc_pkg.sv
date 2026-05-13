package ldpc_pkg;
  parameter int unsigned DATA_WIDTH = 32;  // ARM A9 CPU
  parameter int unsigned STRB_WIDTH = DATA_WIDTH / 8;  // strobe selects the bytes from a word

  // consult the register map
  parameter int unsigned REG_WIDTH = 32;
  parameter int unsigned REG_COUNT = 4;
  parameter int unsigned REG_NUM_BYTES = REG_WIDTH * REG_COUNT / 8;
  parameter int unsigned ADDR_WIDTH = $clog2(REG_NUM_BYTES);

  parameter int unsigned BG1_ROW_N = 46;
  parameter int unsigned BG2_ROW_N = 42;
  parameter int unsigned BG1_COL_N = 68;
  parameter int unsigned BG2_COL_N = 52;

  parameter int unsigned CSR_SIZE = 415;
  parameter int unsigned ZC_MAX = 384;
  parameter int unsigned ZC_WIDTH = $clog2(ZC_MAX + 1);
  parameter int unsigned INPUT_BITS_MAX = 8448;  // BG1 maximum
  parameter int unsigned OUTPUT_BITS_MAX = 26112;
  parameter int unsigned KB_BG1 = 22;
  parameter int unsigned KB_BG2 = 10;
  parameter int unsigned KB_WIDTH = $clog2(KB_BG1 + 1);
  parameter int unsigned RG_BG1 = 12;
  parameter int unsigned RG_BG2 = 11;

  parameter int unsigned NUM_CS = 4;
  parameter int unsigned BG1_H = 46;
  parameter int unsigned BG1_W = 68;
  parameter int unsigned BG1_WEFF = 26;
  parameter int unsigned BG2_H = 42;
  parameter int unsigned BG2_W = 52;
  parameter int unsigned BG2_WEFF = 14;

  typedef enum logic [1:0] {
    CASE_A = 2'b00,
    CASE_B = 2'b01,
    CASE_C = 2'b10
  } cases_e;

  typedef enum logic [1:0] {
      B_IN = 2'b00,
      PC_IN = 2'b01,
      PA_IN = 2'b10
  } cwgen_mode_e;
endpackage
