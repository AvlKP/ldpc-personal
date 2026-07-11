import ldpc_pkg::*;

// cocotb harness: codeword_generator write side in, AXI-Stream out.
// Wires the generator's read port (r_addr / r_data / bank_valid / valid /
// done / read-side config) to the output_buffer exactly like
// ldpc_encoder_core + ldpc_encoder do.
module outbuff_integration (
    input logic clk_i,
    input logic arst_ni,

    // codeword_generator write-side (driven by the cocotb core-like driver)
    input logic [ZC_WIDTH-1:0] lifting_size_i,
    input logic [1:0] zc_group_i,
    input logic base_graph_i,

    input logic info_valid_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] info_data_i,

    input logic core_parity_valid_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] core_parity_data_i,

    input logic add_parity_valid_i,
    input logic [3:0][COL_WIDTH-1:0] add_parity_idx_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] add_parity_data_i,

    input logic last_block_i,
    input logic init_i,
    output logic ready_o,

    // output_buffer AXI-Stream master
    output logic [31:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast
);

    logic cw_valid, cw_done;
    logic [COL_WIDTH-1:0] r_addr;
    logic [ZC_MAX-1:0] r_data;
    logic [3:0] bank_valid;
    logic [ZC_WIDTH-1:0] ob_lifting_size;
    logic ob_base_graph;

    codeword_generator u_codeword_generator (
        .clk_i              (clk_i),
        .arst_ni            (arst_ni),
        .lifting_size_i     (lifting_size_i),
        .zc_group_i         (zc_group_t'(zc_group_i)),
        .base_graph_i       (base_graph_i),
        .info_valid_i       (info_valid_i),
        .info_data_i        (info_data_i),
        .core_parity_valid_i(core_parity_valid_i),
        .core_parity_data_i (core_parity_data_i),
        .add_parity_valid_i (add_parity_valid_i),
        .add_parity_idx_i   (add_parity_idx_i),
        .add_parity_data_i  (add_parity_data_i),
        .last_block_i       (last_block_i),
        .init_i             (init_i),
        .ready_o            (ready_o),
        .r_addr_i           (r_addr),
        .r_data_o           (r_data),
        .bank_valid_o       (bank_valid),
        .codeword_valid_o   (cw_valid),
        .codeword_done_i    (cw_done),
        .lifting_size_o     (ob_lifting_size),
        .zc_group_o         (/* unused: output_buffer no longer needs the group */),
        .base_graph_o       (ob_base_graph)
    );

    output_buffer #(
        .DATA_WIDTH(32)
    ) u_output_buffer (
        .clk_i           (clk_i),
        .arst_ni         (arst_ni),
        .base_graph_i    (ob_base_graph),
        .lifting_size_i  (ob_lifting_size),
        .codeword_valid_i(cw_valid),
        .codeword_done_o (cw_done),
        .r_addr_o        (r_addr),
        .r_data_i        (r_data),
        .bank_valid_i    (bank_valid),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .m_axis_tlast    (m_axis_tlast)
    );

endmodule
