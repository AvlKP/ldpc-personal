import ldpc_pkg::*;

module codeword_generator #(
    parameter int ZC_MAX     = 384,
    parameter int ADDR_WIDTH = 7
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Top-Level Configuration
    input  logic [15:0]                 expected_cw_bits_i,
    input  logic [8:0]                  zc_i,

    // LDPC Core Interfaces
    // Information bits (1 group per cycle = max 384 bits)
    input  logic [ZC_MAX-1:0]           info_group_i,
    input  logic                        info_valid_i,
    input  logic [KB_WIDTH-1:0]         kb_max_i,
    input  logic [$clog2(BG1_COL_N)-1:0] curr_col_i,

    // Core parity bits (Single 384-bit datapath partitioned into chunks)
    input  logic [ZC_MAX-1:0]           parity_core_i,
    input  logic                        parity_core_valid_i,

    // Additional parity bits (Single 384-bit datapath partitioned into chunks)
    input  logic [ZC_MAX-1:0]           parity_additional_i,
    input  logic                        parity_additional_valid_i,

    // Parity Group Selector (ZC_SMALL: 4 groups, ZC_MEDIUM: 2 groups, ZC_LARGE: 1 group)
    input  zc_group_t                   parity_groups_i,

    // Flow Control
    input  logic                        outbuff_full_i,
    output logic                        core_stall_o,
    
    // Output Buffer Interface
    output logic [ZC_MAX-1:0]    outbuff_data_o,
    output logic [ADDR_WIDTH-1:0]       outbuff_addr_o,
    output logic                        outbuff_wr_en_o,
    output logic                        cw_done_o,
    output logic [10:0]                 total_words_o
);

    localparam int unsigned COL_WIDTH = $clog2(BG1_COL_N);
    localparam int OUT_WIDTH          = ZC_MAX; // 384 bits

    // Internal Registers & Signals
    logic [ADDR_WIDTH-1:0]  current_addr;
    logic [15:0]            total_processed_bits;
    logic [COL_WIDTH-1:0]   kb_max_ext;
    logic                   info_group_pending;
    logic [BG1_COL_N-1:0]   info_group_seen_q;

    // Bit Extraction Signals
    logic [ZC_MAX-1:0]      active_parity;
    logic [OUT_WIDTH-1:0]   ext_data;
    logic [15:0]            ext_len;
    logic                   ext_valid;
    logic                   info_group_accepted;

    // Dynamic Packer Registers
    logic [(OUT_WIDTH*2)-1:0] pack_reg;
    logic [11:0]              pack_cnt; 
    
    typedef enum logic {
        ST_ACCUMULATE,
        ST_FLUSH
    } state_t;
    state_t state;

    assign kb_max_ext = COL_WIDTH'(kb_max_i);
    assign info_group_pending = info_valid_i 
                              && (curr_col_i <= kb_max_ext) 
                              && !info_group_seen_q[curr_col_i];

    // -------------------------------------------------------------------------
    // 1. Padding Removal & Chunk Packing (Combinational)
    // -------------------------------------------------------------------------
    // active_parity is only used for the multi-chunk parity_core path now;
    // parity_additional arrives one row at a time from the reorder buffer.
    assign active_parity = parity_core_i;

    always_comb begin
        ext_data            = '0;
        ext_len             = '0;
        ext_valid           = 1'b0;
        info_group_accepted = 1'b0;

        if (state == ST_ACCUMULATE && !outbuff_full_i) begin
            if (info_group_pending) begin
                // info_group_i is already MSB-packed: valid Z bits in [ZC_MAX-1:ZC_MAX-Z].
                ext_data[ZC_MAX-1:0] = info_group_i;
                ext_len              = {7'd0, zc_i};
                ext_valid            = 1'b1;
                info_group_accepted  = 1'b1;
            end
            else if (parity_core_valid_i) begin
                ext_valid = 1'b1;
                case (parity_groups_i)
                    ZC_SMALL: begin
                        // 4 chunks of 96, each MSB-packed within its 96-bit slot.
                        // Lift each chunk to the top of a 384-bit value, then
                        // OR them together so the 4*Z valid bits are compacted
                        // into ext_data[ZC_MAX-1 : ZC_MAX-4*Z].
                        logic [ZC_MAX-1:0] g0, g1, g2, g3;
                        g3 = {active_parity[383:288], 288'b0};
                        g2 = {active_parity[287:192], 288'b0};
                        g1 = {active_parity[191:96],  288'b0};
                        g0 = {active_parity[95:0],    288'b0};
                        ext_data[ZC_MAX-1:0] = g3 | (g2 >> zc_i) | (g1 >> (2*zc_i)) | (g0 >> (3*zc_i));
                        ext_len              = {5'd0, zc_i, 2'b00}; // zc_i * 4
                    end

                    ZC_MEDIUM: begin
                        // 2 chunks of 192, each MSB-packed within its 192-bit slot.
                        logic [ZC_MAX-1:0] g0, g1;
                        g1 = {active_parity[383:192], 192'b0};
                        g0 = {active_parity[191:0],   192'b0};
                        ext_data[ZC_MAX-1:0] = g1 | (g0 >> zc_i);
                        ext_len              = {6'd0, zc_i, 1'b0}; // zc_i * 2
                    end

                    ZC_LARGE: begin
                        // Single 384-bit MSB-packed word, pass through.
                        ext_data[ZC_MAX-1:0] = active_parity;
                        ext_len              = {7'd0, zc_i};
                    end

                    default: begin
                        ext_data[ZC_MAX-1:0] = active_parity;
                        ext_len              = {7'd0, zc_i};
                    end
                endcase
            end
            else if (parity_additional_valid_i) begin
                // Single row from the reorder buffer: Z bits MSB-packed in
                // [ZC_MAX-1:ZC_MAX-Z], regardless of zc_group.
                ext_data[ZC_MAX-1:0] = parity_additional_i;
                ext_len              = {7'd0, zc_i};
                ext_valid            = 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Dynamic Continuous Packer FSM (Sequential)
    // -------------------------------------------------------------------------
    logic [(OUT_WIDTH*2)-1:0] next_pack_reg;
    logic [12:0]              next_pack_cnt; 
    logic                     is_last_input;

    assign is_last_input = ext_valid && ((total_processed_bits + ext_len) >= expected_cw_bits_i);
    assign core_stall_o  = outbuff_full_i || (state == ST_FLUSH);
    assign total_words_o = (expected_cw_bits_i + 16'd31) >> 5;

    // 1-cycle delayed curr_col_i, used when marking info_group_seen_q.
    logic [COL_WIDTH-1:0] curr_col_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) curr_col_q <= '0;
        else        curr_col_q <= curr_col_i;
    end

    always_comb begin
        next_pack_cnt = pack_cnt + ext_len;
        // pack_reg accumulates from the top (MSB). Place ext_data MSB-aligned in
        // the 768-bit working value, then right-shift it to sit just below the
        // bits already accumulated.
        next_pack_reg = pack_reg | ({ext_data, {OUT_WIDTH{1'b0}}} >> pack_cnt);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_ACCUMULATE;
            current_addr         <= '0;
            total_processed_bits <= '0;
            info_group_seen_q    <= '0;
            pack_reg             <= '0;
            pack_cnt             <= '0;
            outbuff_wr_en_o      <= 1'b0;
            outbuff_addr_o       <= '0;
            outbuff_data_o       <= '0;
            cw_done_o            <= 1'b0;
        end else begin
            outbuff_wr_en_o <= 1'b0;
            cw_done_o       <= 1'b0;

            case (state)
                ST_ACCUMULATE: begin
                    if (ext_valid) begin
                        total_processed_bits <= total_processed_bits + ext_len;
                        if (info_group_accepted) info_group_seen_q[curr_col_q] <= 1'b1;

                        if (next_pack_cnt >= OUT_WIDTH) begin
                            outbuff_wr_en_o <= 1'b1;
                            outbuff_addr_o  <= current_addr;
                            // Top 384 bits are full — emit them MSB-first.
                            outbuff_data_o  <= next_pack_reg[(OUT_WIDTH*2)-1 -: OUT_WIDTH];

                            // Shift the leftover bits back to the top of pack_reg.
                            pack_reg        <= next_pack_reg << OUT_WIDTH;
                            pack_cnt        <= next_pack_cnt - OUT_WIDTH;
                            current_addr    <= current_addr + 1'b1;

                            if (is_last_input) begin
                                if ((next_pack_cnt - OUT_WIDTH) > 0) begin
                                    state <= ST_FLUSH;
                                end else begin
                                    cw_done_o            <= 1'b1;
                                    current_addr         <= '0;
                                    total_processed_bits <= '0;
                                    info_group_seen_q    <= '0;
                                    pack_reg             <= '0;
                                    pack_cnt             <= '0;
                                end
                            end
                        end else begin
                            pack_reg <= next_pack_reg;
                            pack_cnt <= next_pack_cnt;

                            if (is_last_input) begin
                                state <= ST_FLUSH;
                            end
                        end
                    end
                end

                ST_FLUSH: begin
                    outbuff_wr_en_o      <= 1'b1;
                    outbuff_addr_o       <= current_addr;
                    // Final partial word: valid bits live at the top of pack_reg.
                    outbuff_data_o       <= pack_reg[(OUT_WIDTH*2)-1 -: OUT_WIDTH];
                    cw_done_o            <= 1'b1;
                    
                    state                <= ST_ACCUMULATE;
                    current_addr         <= '0;
                    total_processed_bits <= '0;
                    info_group_seen_q    <= '0;
                    pack_reg             <= '0;
                    pack_cnt             <= '0;
                end
            endcase
        end
    end

endmodule