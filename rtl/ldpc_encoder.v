// 5G NR LDPC encoder, top level.
//
// Written in Verilog-2001 so Vivado IP Integrator can reference the module
// directly ("Add Module" requires a Verilog/VHDL top; the submodules below
// it may stay SystemVerilog). Designed to pair with Xilinx AXI DMA in a
// PYNQ-style block design:
//
//   AXI DMA MM2S  -> s_axis  (code block in, 32-bit words, LSB-first bits)
//   m_axis        -> AXI DMA S2MM (codeword out; TLAST closes the transfer,
//                    TKEEP is held all-ones)
//   PS M_AXI_GP   -> s_axil  (frame configuration CSRs)
//
// Register map (32-bit registers, byte addresses):
//   0x0  STATUS  (RO)  bit0 = ready for input (s_axis_tready)
//                      bit1 = core busy (encoding in progress)
//   0x4  CONFIG  (RW)  bit0 = base graph (0: BG1, 1: BG2)
//                      bits[9:1] = lifting size Zc
//   0x8  IN_BITS (RW)  bits[15:0] = code block length (KB*Zc bits)
//   0xC  OUT_BITS(RW)  bits[15:0] = codeword length (NB*Zc bits)
//
// A frame's configuration is latched by the input buffer on the first AXIS
// beat of that frame, so the CSRs may be retargeted for the next frame while
// the current one is still streaming in/out.
module ldpc_encoder #(
  parameter AXIL_ADDR_WIDTH = 4,
  // Fixed at 32 (matches the input/output buffer gearboxes and the classic
  // AXI DMA configuration); exposed for interface clarity only.
  parameter AXIS_DATA_WIDTH = 32
)(
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_i CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axil:s_axis:m_axis, ASSOCIATED_RESET arst_ni" *)
  input  wire                        clk_i,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 arst_ni RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                        arst_ni,

  // AXI4-Lite slave (configuration/status CSRs)
  input  wire [AXIL_ADDR_WIDTH-1:0]  s_axil_awaddr,
  input  wire                        s_axil_awvalid,
  output wire                        s_axil_awready,
  input  wire [31:0]                 s_axil_wdata,
  input  wire [3:0]                  s_axil_wstrb,
  input  wire                        s_axil_wvalid,
  output wire                        s_axil_wready,
  output wire [1:0]                  s_axil_bresp,
  output reg                         s_axil_bvalid,
  input  wire                        s_axil_bready,
  input  wire [AXIL_ADDR_WIDTH-1:0]  s_axil_araddr,
  input  wire                        s_axil_arvalid,
  output wire                        s_axil_arready,
  output reg  [31:0]                 s_axil_rdata,
  output wire [1:0]                  s_axil_rresp,
  output reg                         s_axil_rvalid,
  input  wire                        s_axil_rready,

  // AXI4-Stream slave (code block in, e.g. from AXI DMA MM2S). TKEEP/TLAST
  // are accepted for interface compatibility; framing comes from IN_BITS.
  input  wire [AXIS_DATA_WIDTH-1:0]   s_axis_tdata,
  input  wire [AXIS_DATA_WIDTH/8-1:0] s_axis_tkeep,
  input  wire                         s_axis_tlast,
  input  wire                         s_axis_tvalid,
  output wire                         s_axis_tready,

  // AXI4-Stream master (codeword out, e.g. to AXI DMA S2MM)
  output wire [AXIS_DATA_WIDTH-1:0]   m_axis_tdata,
  output wire [AXIS_DATA_WIDTH/8-1:0] m_axis_tkeep,
  output wire                         m_axis_tvalid,
  input  wire                         m_axis_tready,
  output wire                         m_axis_tlast
);

  // Mirrors of ldpc_pkg widths (this file cannot import an SV package)
  localparam ZC_WIDTH  = 9;    // $clog2(384 + 1)
  localparam COL_WIDTH = 7;    // $clog2(68)
  localparam KB_WIDTH  = 5;    // $clog2(22 + 1)
  localparam ZC_MAX    = 384;

  // ==========================================================
  // AXI4-Lite CSRs
  // ==========================================================
  // Single-outstanding slave: AW and W are accepted together (waiting for
  // both before asserting ready is AXI-compliant) and B is held until BREADY.
  reg [31:0] cfg_reg;
  reg [31:0] in_bits_reg;
  reg [31:0] out_bits_reg;

  wire wr_fire = s_axil_awvalid & s_axil_wvalid & ~s_axil_bvalid;

  assign s_axil_awready = wr_fire;
  assign s_axil_wready  = wr_fire;
  assign s_axil_bresp   = 2'b00; // OKAY
  assign s_axil_rresp   = 2'b00; // OKAY

  integer b;
  always @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
      cfg_reg       <= 32'd0;
      in_bits_reg   <= 32'd0;
      out_bits_reg  <= 32'd0;
      s_axil_bvalid <= 1'b0;
    end else begin
      if (wr_fire) begin
        s_axil_bvalid <= 1'b1;
        for (b = 0; b < 4; b = b + 1) begin
          if (s_axil_wstrb[b]) begin
            case (s_axil_awaddr[3:2])
              2'd1: cfg_reg[8*b +: 8]      <= s_axil_wdata[8*b +: 8];
              2'd2: in_bits_reg[8*b +: 8]  <= s_axil_wdata[8*b +: 8];
              2'd3: out_bits_reg[8*b +: 8] <= s_axil_wdata[8*b +: 8];
              default: ; // 0x0 STATUS is read-only
            endcase
          end
        end
      end else if (s_axil_bvalid & s_axil_bready) begin
        s_axil_bvalid <= 1'b0;
      end
    end
  end

  wire core_idle;
  wire [31:0] status_reg = {30'd0, ~core_idle, s_axis_tready};

  assign s_axil_arready = ~s_axil_rvalid;
  always @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= 32'd0;
    end else if (s_axil_arvalid & s_axil_arready) begin
      s_axil_rvalid <= 1'b1;
      case (s_axil_araddr[3:2])
        2'd0:    s_axil_rdata <= status_reg;
        2'd1:    s_axil_rdata <= cfg_reg;
        2'd2:    s_axil_rdata <= in_bits_reg;
        default: s_axil_rdata <= out_bits_reg;
      endcase
    end else if (s_axil_rvalid & s_axil_rready) begin
      s_axil_rvalid <= 1'b0;
    end
  end

  wire                ldpc_base_graph   = cfg_reg[0];
  wire [ZC_WIDTH-1:0] ldpc_lifting_size = cfg_reg[9:1];
  wire [15:0]         ldpc_input_bits   = in_bits_reg[15:0];
  wire [15:0]         ldpc_output_bits  = out_bits_reg[15:0];

  // ==========================================================
  // Datapath: input buffer -> encoder core -> output buffer
  // ==========================================================
  wire [ZC_WIDTH-1:0] core_lifting_size;
  wire [15:0]         core_input_bits;
  wire [15:0]         core_output_bits;
  wire                core_base_graph;
  wire                core_clear, core_valid;
  wire [KB_WIDTH-1:0] core_kb;
  wire [ZC_MAX-1:0]   core_data_in;

  wire [ZC_WIDTH-1:0] outbuff_lifting_size;
  wire                outbuff_base_graph;
  wire [1:0]          outbuff_zc_group;

  wire                cw_valid;
  wire [COL_WIDTH-1:0] cw_r_addr;
  wire [ZC_MAX-1:0]   cw_r_data;
  wire                outbuff_done;

  input_buffer input_buffer (
    .clk_i           (clk_i),
    .arst_ni         (arst_ni),
    .s_axis_tdata    (s_axis_tdata),
    .s_axis_tvalid   (s_axis_tvalid),
    .s_axis_tready   (s_axis_tready),
    .ldpc_clear_i    (core_clear),
    .ldpc_valid_o    (core_valid),
    .lifting_size_i  (ldpc_lifting_size),
    .input_bits_i    (ldpc_input_bits),
    .output_bits_i   (ldpc_output_bits),
    .base_graph_i    (ldpc_base_graph),
    .lifting_size_o  (core_lifting_size),
    .input_bits_o    (core_input_bits),
    .output_bits_o   (core_output_bits),
    .base_graph_o    (core_base_graph),
    .info_group_sel_i(core_kb),
    .info_group_o    (core_data_in)
  );

  ldpc_encoder_core #(
    .ZC_PER_CS(96),
    .NUM_CS   (4)
  ) ldpc_encoder_core (
    .clk_i           (clk_i),
    .arst_ni         (arst_ni),
    .base_graph_i    (core_base_graph),
    .input_bits_i    (core_input_bits),
    .output_bits_i   (core_output_bits),
    .lifting_size_i  (core_lifting_size),
    .idle_o          (core_idle),
    .inbuff_clear_o  (core_clear),
    .inbuff_valid_i  (core_valid),
    .info_group_sel_o(core_kb),
    .info_group_i    (core_data_in),
    .codeword_valid_o(cw_valid),
    .r_addr_i        (cw_r_addr),
    .r_data_o        (cw_r_data),
    .codeword_done_i (outbuff_done),
    .lifting_size_o  (outbuff_lifting_size),
    .zc_group_o      (outbuff_zc_group),
    .base_graph_o    (outbuff_base_graph)
  );

  output_buffer #(
    .DATA_WIDTH(AXIS_DATA_WIDTH)
  ) output_buffer (
    .clk_i           (clk_i),
    .arst_ni         (arst_ni),
    .base_graph_i    (outbuff_base_graph),
    .lifting_size_i  (outbuff_lifting_size),
    .zc_group_i      (outbuff_zc_group),
    .codeword_valid_i(cw_valid),
    .codeword_done_o (outbuff_done),
    .r_addr_o        (cw_r_addr),
    .r_data_i        (cw_r_data),
    .m_axis_tdata    (m_axis_tdata),
    .m_axis_tvalid   (m_axis_tvalid),
    .m_axis_tready   (m_axis_tready),
    .m_axis_tlast    (m_axis_tlast)
  );

  // S2MM DMA expects TKEEP; every byte of every beat is meaningful (the last
  // beat is zero-padded up to the word boundary, like the MM2S input).
  assign m_axis_tkeep = {AXIS_DATA_WIDTH/8{1'b1}};

  // Sideband inputs accepted only for AXIS interface completeness
  wire unused_axis_sideband = &{1'b1, s_axis_tkeep, s_axis_tlast};

endmodule
