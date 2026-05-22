import ldpc_pkg::*;

module codeword_generator (
    input logic clk_i,
    input logic arst_ni,

    // Upstream Encoder Core Interface
    input logic [ZC_WIDTH-1:0] lifting_size_i,
    input zc_group_t zc_group_i,
    input logic base_graph_i,

    input logic info_valid_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] info_data_i,

    input logic core_parity_valid_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] core_parity_data_i,

    input logic add_parity_valid_i,
    input logic [3:0][COL_WIDTH-1:0] add_parity_idx_i, 
    input logic [3:0][(ZC_MAX >> 2)-1:0] add_parity_data_i,

    input logic input_last_subblock_i,
    output logic upstream_ready_o,

    // Inter-Module Interface to Output Buffer
    output logic codeword_valid_o,
    input logic [COL_WIDTH-1:0] r_addr_i,
    output logic [ZC_MAX-1:0] r_data_o,
    input logic codeword_done_i,

    output logic [ZC_WIDTH-1:0] lifting_size_o,
    output zc_group_t zc_group_o,
    output logic base_graph_o
);

    // 4 Horizontally Separated Memory Sub-Banks (Depth: 256, Width: 96)
    (* ram_style = "block" *) logic [(ZC_MAX >> 2)-1:0] ram [0:3][0:255];

    // Control and Interlock Boundary Tracking Registers
    logic       w_swap_q, r_swap_q;
    logic [1:0] bank_full_q;
    logic [COL_WIDTH-1:0] w_seq_addr_q, w_seq_addr_n;

    // Structural Addressing and Muxing Vectors
    logic [3:0][COL_WIDTH:0] w_addr;
    logic [3:0][(ZC_MAX >> 2)-1:0] w_data_mux;
    logic [3:0] w_en;                                      // Independent write enables per sub-bank
    logic       input_stroke;

    // Configuration double buffering registers
    logic [1:0] base_graph_q;
    logic [1:0][ZC_WIDTH-1:0] lifting_size_q;
    zc_group_t [1:0] zc_group_q;

    // Phase Boundary Alignment Evaluation Wires
    logic [COL_WIDTH-1:0] core_parity_base_row;
    logic [COL_WIDTH-1:0] add_parity_base_row;
    logic [2:0] packing_factor;
    logic [COL_WIDTH-1:0] core_parity_start_idx;
    logic [COL_WIDTH-1:0] active_w_seq_addr;
    logic [3:0][COL_WIDTH-1:0] rel_idx;

    assign input_stroke     = (info_valid_i | core_parity_valid_i | add_parity_valid_i) & upstream_ready_o;
    assign upstream_ready_o = (w_swap_q == 1'b0) ? !bank_full_q[0] : !bank_full_q[1];
    assign codeword_valid_o = (r_swap_q == 1'b0) ? bank_full_q[0] : bank_full_q[1];

    //--------------------------------------------------------------------------
    // Offsets & Phase Base Row and Stride Calculations
    //--------------------------------------------------------------------------
    always_comb begin
        unique case (zc_group_i)
            ZC_SMALL: begin
                core_parity_base_row = base_graph_i ? 7'd3 : 7'd6;   // ceil(10/4)=3, ceil(22/4)=6
                add_parity_base_row  = core_parity_base_row + 7'd1; // Core parity takes exactly 1 row
                packing_factor       = 3'd4;
            end
            ZC_MEDIUM: begin
                core_parity_base_row = base_graph_i ? 7'd5 : 7'd11;  // ceil(10/2)=5, ceil(22/2)=11
                add_parity_base_row  = core_parity_base_row + 7'd2; // Core parity takes exactly 2 rows
                packing_factor       = 3'd2;
            end
            ZC_LARGE: begin
                core_parity_base_row = base_graph_i ? 7'd10 : 7'd22; // 10/1=10, 22/1=22
                add_parity_base_row  = core_parity_base_row + 7'd4; // Core parity takes exactly 4 rows
                packing_factor       = 3'd1;
            end
            default: begin
                core_parity_base_row = 7'd6;
                add_parity_base_row  = 7'd7;
                packing_factor       = 3'd4;
            end
        endcase
        
        // Calculate the absolute starting index to force a row alignment jump
        core_parity_start_idx = core_parity_base_row * packing_factor;
        
        // Intercept unaligned transitions instantly during the current write cycle
        active_w_seq_addr = (core_parity_valid_i && (w_seq_addr_q < core_parity_start_idx)) ? 
                            core_parity_start_idx : w_seq_addr_q;
    end

    //--------------------------------------------------------------------------
    // Sequential Ingestion Address Pointer Evolution
    //--------------------------------------------------------------------------
    always_comb begin
        w_seq_addr_n = w_seq_addr_q;
        if (upstream_ready_o) begin
            if (info_valid_i) begin
                if (input_last_subblock_i) w_seq_addr_n = '0;
                else                       w_seq_addr_n = w_seq_addr_q + COL_WIDTH'(1);
            end else if (core_parity_valid_i) begin
                // Force step-pointer forward past the padding gap if entering unaligned
                if (w_seq_addr_q < core_parity_start_idx) begin
                    w_seq_addr_n = core_parity_start_idx + COL_WIDTH'(packing_factor);
                end else if (input_last_subblock_i) begin
                    w_seq_addr_n = '0;
                end else begin
                    w_seq_addr_n = w_seq_addr_q + COL_WIDTH'(packing_factor);
                end
            end else if (add_parity_valid_i & input_last_subblock_i) begin
                w_seq_addr_n = '0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // Address Steering Matrix & Sub-Bank Write Enable Decoding
    //--------------------------------------------------------------------------
    always_comb begin
        w_en       = '0;
        w_data_mux = core_parity_data_i;
        for (int unsigned i = 0; i < 4; i++) begin
            w_addr[i]  = {w_swap_q, active_w_seq_addr}; 
            rel_idx[i] = add_parity_idx_i[i] - COL_WIDTH'(4);
        end

        // Phase A: Systematic/Info Ingestion (Arrives 1-by-1)
        if (info_valid_i) begin
            w_data_mux = info_data_i;
            unique case (zc_group_i)
                ZC_SMALL: begin
                    w_en[active_w_seq_addr[1:0]] = upstream_ready_o;
                    for (int unsigned i = 0; i < 4; i++) begin
                        w_addr[i] = {w_swap_q, 2'b00, active_w_seq_addr[COL_WIDTH-1:2]};
                    end
                end
                ZC_MEDIUM: begin
                    if (active_w_seq_addr[0] == 1'b0) w_en[1:0] = {2{upstream_ready_o}};
                    else                              w_en[3:2] = {2{upstream_ready_o}};
                    for (int unsigned i = 0; i < 4; i++) begin
                        w_addr[i] = {w_swap_q, 1'b0, active_w_seq_addr[COL_WIDTH-1:1]};
                    end
                end
                ZC_LARGE: begin
                    w_en = {4{upstream_ready_o}};
                    for (int unsigned i = 0; i < 4; i++) begin
                        w_addr[i] = {w_swap_q, active_w_seq_addr};
                    end
                end
            endcase

        // Phase B: Core Parity Ingestion (Row Aligned, Groups of 4/2/1)
        end else if (core_parity_valid_i) begin
            w_data_mux = core_parity_data_i;
            w_en       = {4{upstream_ready_o}};
            unique case (zc_group_i)
                ZC_SMALL:  for (int unsigned i = 0; i < 4; i++) w_addr[i] = {w_swap_q, 2'b00, active_w_seq_addr[COL_WIDTH-1:2]};
                ZC_MEDIUM: for (int unsigned i = 0; i < 4; i++) w_addr[i] = {w_swap_q, 1'b0,  active_w_seq_addr[COL_WIDTH-1:1]};
                ZC_LARGE:  for (int unsigned i = 0; i < 4; i++) w_addr[i] = {w_swap_q,        active_w_seq_addr};
            endcase

        // Phase C: Additional Parity Ingestion (Out-of-order, appended past Parity blocks)
        end else if (add_parity_valid_i) begin
            w_data_mux = add_parity_data_i;
            w_en       = {4{upstream_ready_o}};
            
            unique case (zc_group_i)
                ZC_SMALL: begin
                    for (int unsigned i = 0; i < 4; i++) begin
                        w_addr[i] = {w_swap_q, add_parity_base_row + (rel_idx[i] >> 2)};
                    end
                end
                ZC_MEDIUM: begin
                    w_addr[0] = {w_swap_q, add_parity_base_row + (rel_idx[0] >> 1)};
                    w_addr[1] = {w_swap_q, add_parity_base_row + (rel_idx[0] >> 1)};
                    w_addr[2] = {w_swap_q, add_parity_base_row + (rel_idx[1] >> 1)};
                    w_addr[3] = {w_swap_q, add_parity_base_row + (rel_idx[1] >> 1)};
                end
                ZC_LARGE: begin
                    for (int unsigned i = 0; i < 4; i++) begin
                        w_addr[i] = {w_swap_q, add_parity_base_row + rel_idx[0]};
                    end
                end
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Sub-Bank Physical Hardware Memory Writing
    //--------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        for (int unsigned i = 0; i < 4; i++) begin
            if (w_en[i]) begin
                ram[i][w_addr[i]] <= w_data_mux[i];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read Port Structural Mapping
    //--------------------------------------------------------------------------
    logic [COL_WIDTH:0] r_addr;
    assign r_addr = {r_swap_q, r_addr_i};

    always_ff @(posedge clk_i) begin
        for (int unsigned i = 0; i < 4; i++) begin
            r_data_o[i*(ZC_MAX >> 2) +: (ZC_MAX >> 2)] <= ram[i][r_addr];
        end
    end

    //--------------------------------------------------------------------------
    // Control Boundaries and Swap State Machinery
    //--------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) begin
            r_swap_q       <= 1'b0;
            w_swap_q       <= 1'b0;
            bank_full_q    <= 2'b00;
            w_seq_addr_q   <= '0;
            base_graph_q   <= '0;
            lifting_size_q <= '0;
            zc_group_q     <= '0;
        end else begin
            w_seq_addr_q <= w_seq_addr_n;

            if (input_stroke & input_last_subblock_i) begin
                w_swap_q              <= ~w_swap_q;
                bank_full_q[w_swap_q] <= 1'b1;

                base_graph_q[w_swap_q]   <= base_graph_i;
                lifting_size_q[w_swap_q] <= lifting_size_i;
                zc_group_q[w_swap_q]     <= zc_group_i;
            end

            if (codeword_done_i) begin
                r_swap_q              <= ~r_swap_q;
                bank_full_q[r_swap_q] <= 1'b0;

                base_graph_q[r_swap_q]   <= '0;
                lifting_size_q[r_swap_q] <= '0;
                zc_group_q[r_swap_q]     <= ZC_SMALL;
            end
        end
    end

    assign lifting_size_o = lifting_size_q[r_swap_q];
    assign base_graph_o   = base_graph_q[r_swap_q];
    assign zc_group_o     = zc_group_q[r_swap_q];

endmodule