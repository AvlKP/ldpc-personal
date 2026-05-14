`include "axi/typedef.svh"

import ldpc_pkg::*;

// assume input is already CRC-added code block
// it respects the maximum size that can be encoded at a time
module ldpc_encoder (
  // common signals
  input  logic         clk_i,
  input  logic         arst_ni,

  // AXI-Lite (CPU controls CSRs)
  input  logic [ADDR_WIDTH-1:0]  s_axil_awaddr,
  input  logic         s_axil_awvalid,
  output logic         s_axil_awready,
  input  logic [DATA_WIDTH-1:0]  s_axil_wdata,
  input  logic [STRB_WIDTH-1:0]   s_axil_wstrb,
  input  logic         s_axil_wvalid,
  output logic         s_axil_wready,
  output logic [1:0]   s_axil_bresp,
  output logic         s_axil_bvalid,
  input  logic         s_axil_bready,
  input  logic [ADDR_WIDTH-1:0]  s_axil_araddr,
  input  logic         s_axil_arvalid,
  output logic         s_axil_arready,
  output logic [DATA_WIDTH-1:0]  s_axil_rdata,
  output logic [1:0]   s_axil_rresp,
  output logic         s_axil_rvalid,
  input  logic         s_axil_rready,

  // AXI-Stream Slave (DMA controls mem to periph)
  input  logic [DATA_WIDTH-1:0]  s_axis_tdata,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,

  // AXI-Stream Master (DMA controls periph to mem)
  output logic [DATA_WIDTH-1:0]  m_axis_tdata,
  output logic         m_axis_tvalid,
  input  logic         m_axis_tready,
  output logic         m_axis_tlast
);

// ==== AXI LITE Register Interface ====
// define the types and structs for axi lite
typedef logic [ADDR_WIDTH-1:0] addr_t;
typedef logic [DATA_WIDTH-1:0] data_t;
typedef logic [STRB_WIDTH-1:0] strb_t;
`AXI_LITE_TYPEDEF_ALL(axil, addr_t, data_t, strb_t)

axil_req_t axil_req;
axil_resp_t axil_resp;

// assign the ports to the structs
assign axil_req.aw_valid = s_axil_awvalid;
assign axil_req.aw.addr = s_axil_awaddr;
assign axil_req.aw.prot = 3'b000;
assign axil_req.w_valid = s_axil_wvalid;
assign axil_req.w.data = s_axil_wdata;
assign axil_req.w.strb = s_axil_wstrb;
assign axil_req.b_ready = s_axil_bready;
assign axil_req.ar_valid = s_axil_arvalid;
assign axil_req.ar.addr = s_axil_araddr;
assign axil_req.ar.prot = 3'b000;
assign axil_req.r_ready = s_axil_rready;

assign s_axil_awready = axil_resp.aw_ready;
assign s_axil_arready = axil_resp.ar_ready;
assign s_axil_wready = axil_resp.w_ready;
assign s_axil_bvalid = axil_resp.b_valid;
assign s_axil_bresp = axil_resp.b.resp;
assign s_axil_rvalid = axil_resp.r_valid;
assign s_axil_rdata = axil_resp.r.data;
assign s_axil_rresp = axil_resp.r.resp;

localparam logic [REG_NUM_BYTES-1:0] REG_RO = {
  4'b0000,
  4'b0000,
  4'b0000,
  4'b1111
};

// still unused for now
logic [REG_NUM_BYTES-1:0] wr_active;
logic [REG_NUM_BYTES-1:0] rd_active;
logic [REG_NUM_BYTES-1:0][7:0] reg_d;
logic [REG_NUM_BYTES-1:0] reg_load;

assign reg_d = {REG_NUM_BYTES{8'b0}};
assign reg_load = {REG_NUM_BYTES{1'b0}};

// routing from axil reg to local signals
logic [REG_NUM_BYTES-1:0][7:0] reg_q;

// register level
logic [DATA_WIDTH-1:0] status_reg;
logic [DATA_WIDTH-1:0] config_reg;
logic [DATA_WIDTH-1:0] input_bits_reg;
logic [DATA_WIDTH-1:0] output_bits_reg;

assign status_reg = DATA_WIDTH'(reg_q[3:0]);
assign config_reg = DATA_WIDTH'(reg_q[7:4]);
assign input_bits_reg = DATA_WIDTH'(reg_q[11:8]);
assign output_bits_reg = DATA_WIDTH'(reg_q[15:12]);

// signal level
// logic ldpc_ready;
// logic ldpc_busy;
// logic ldpc_done;
logic ldpc_base_graph;
logic [ZC_WIDTH-1:0] ldpc_lifting_size;
logic [15:0] ldpc_input_bits;
logic [15:0] ldpc_output_bits;

// assign ldpc_ready = status_reg[0];
// assign ldpc_busy = status_reg[1];
// assign ldpc_done = status_reg[2];
assign ldpc_base_graph = config_reg[0];
assign ldpc_lifting_size = config_reg[9:1];
assign ldpc_input_bits = input_bits_reg[15:0];
assign ldpc_output_bits = output_bits_reg[15:0];

axi_lite_regs #(
  .RegNumBytes(REG_NUM_BYTES),
  .AxiAddrWidth(ADDR_WIDTH),
  .AxiDataWidth(DATA_WIDTH),
  .AxiReadOnly(REG_RO),
  .req_lite_t(axil_req_t),
  .resp_lite_t(axil_resp_t)
) ldpc_regs (
  .clk_i(clk_i),
  .rst_ni(arst_ni),
  .axi_req_i(axil_req),
  .axi_resp_o(axil_resp),
  .wr_active_o(wr_active),
  .rd_active_o(rd_active), 
  .reg_d_i(reg_d),
  .reg_load_i(reg_load),
  .reg_q_o(reg_q)
);

logic [ZC_WIDTH-1:0] core_lifting_size;
logic [15:0] core_input_bits;
logic [15:0] core_output_bits;
logic core_base_graph;
logic core_clear, core_valid;
logic [KB_WIDTH-1:0] core_kb;
logic [ZC_MAX-1:0] core_data_in;
logic core_done;
logic core_idle;
logic [10:0] core_word_cnt;

logic outbuff_full;
logic outbuff_wr_en;
logic [4:0] outbuff_addr;
logic [(ZC_MAX << 2)-1:0] outbuff_data;

// ==== AXI Stream input ====
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

// ==== AXI Stream output ====
output_buffer #(
  .ZC_MAX    (ZC_MAX /* default 384 */),
  .ADDR_WIDTH(5 /* default 5 */)
 ) output_buffer (
  .clk           (clk_i),
  .rst_n         (arst_ni),
  .wr_data_i     (outbuff_data),
  .wr_addr_i     (outbuff_addr),
  .wr_en_i       (outbuff_wr_en),
  .cw_done_i     (core_done),
  .total_words_i (core_word_cnt),
  .outbuff_full_o(outbuff_full),
  .m_axis_tdata  (m_axis_tdata),
  .m_axis_tlast  (m_axis_tlast),
  .m_axis_tvalid (m_axis_tvalid),
  .m_axis_tready (m_axis_tready)
);

// ==== LDPC Core ====
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
  .outbuff_full_i  (outbuff_full),
  .outbuff_addr_o  (outbuff_addr),
  .outbuff_wr_en_o (outbuff_wr_en),
  .outbuff_data_o  (outbuff_data),
  .cw_done_o       (core_done),
  .total_words_o   (core_word_cnt)
);

endmodule