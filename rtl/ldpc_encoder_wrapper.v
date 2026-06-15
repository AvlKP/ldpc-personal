`timescale 1ns / 1ps

module ldpc_encoder_wrapper #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4
) (
    // Clock and Reset
    input  wire                                aclk,
    input  wire                                aresetn,

    // AXI-Lite Slave Interface
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]     s_axi_awaddr,
    input  wire [2 : 0]                        s_axi_awprot,
    input  wire                                s_axi_awvalid,
    output wire                                s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] s_axi_wstrb,
    input  wire                                s_axi_wvalid,
    output wire                                s_axi_wready,
    output wire [1 : 0]                        s_axi_bresp,
    output wire                                s_axi_bvalid,
    input  wire                                s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]     s_axi_araddr,
    input  wire [2 : 0]                        s_axi_arprot,
    input  wire                                s_axi_arvalid,
    output wire                                s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]     s_axi_rdata,
    output wire [1 : 0]                        s_axi_rresp,
    output wire                                s_axi_rvalid,
    input  wire                                s_axi_rready,

    // AXI-Stream Slave Interface
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]     s_axis_tdata,
    input  wire                                s_axis_tvalid,
    output wire                                s_axis_tready,

    // AXI-Stream Master Interface
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]     m_axis_tdata,
    output wire                                m_axis_tvalid,
    input  wire                                m_axis_tready,
    output wire                                m_axis_tlast
);

    // Instantiate the underlying SystemVerilog module.
    // The SV module's port widths are determined by ldpc_pkg::DATA_WIDTH (32)
    // and ldpc_pkg::ADDR_WIDTH (4).
    
    ldpc_encoder u_ldpc_encoder (
        .clk_i          (aclk),
        .arst_ni        (aresetn),

        // AXI-Lite Interface
        .s_axil_awaddr  (s_axi_awaddr),
        .s_axil_awvalid (s_axi_awvalid),
        .s_axil_awready (s_axi_awready),
        .s_axil_wdata   (s_axi_wdata),
        .s_axil_wstrb   (s_axi_wstrb),
        .s_axil_wvalid  (s_axi_wvalid),
        .s_axil_wready  (s_axi_wready),
        .s_axil_bresp   (s_axi_bresp),
        .s_axil_bvalid  (s_axi_bvalid),
        .s_axil_bready  (s_axi_bready),
        .s_axil_araddr  (s_axi_araddr),
        .s_axil_arvalid (s_axi_arvalid),
        .s_axil_arready (s_axi_arready),
        .s_axil_rdata   (s_axi_rdata),
        .s_axil_rresp   (s_axi_rresp),
        .s_axil_rvalid  (s_axi_rvalid),
        .s_axil_rready  (s_axi_rready),

        // AXI-Stream Slave Interface
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),

        // AXI-Stream Master Interface
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast)
    );

endmodule
