import ldpc_pkg::*;

// Double-banked codeword assembly RAM between the encoder core and the
// output buffer.
//
// Bank layout (per half, addressed by "bank row", 4 sub-banks of 96b):
//   ZC_SMALL  (Zc<=96) : 4 columns per row, column c at sub-bank c%4
//   ZC_MEDIUM (Zc<=192): 2 columns per row, column c at sub-bank pair c%2
//   ZC_LARGE  (Zc<=384): 1 column per row across all 4 sub-banks
// Segments: info rows [0 .. ceil(KB/pf)-1], core parity rows starting at
// cp_base = ceil(KB/pf), additional parity at ap_base = cp_base + 4/pf.
// Partial boundary rows leave padding sub-banks that are never read back
// (the output buffer's address generator skips them with the same bases).
//
// Write sources (mutually exclusive by core FSM construction):
//   - info: one column per strobe, addressed by info_col_i. The folded modes
//     revisit columns across row-group passes; rewrites carry identical data.
//   - core parity: one strobe per CALC_PC cycle, cycle n -> bank row
//     cp_base + n (the per-cycle column packing is done in the core).
//   - additional parity: one strobe per finished row-group pass, up to 4 rows
//     landing on ARBITRARY bank rows/sub-banks (the CSR row schedule is out
//     of order), so the event is staged and drained one row per cycle.
//     Row-group passes always span more cycles than the rows they complete,
//     so a drain never collides with the next event.
module codeword_generator (
    input logic clk_i,
    input logic arst_ni,

    // Upstream Encoder Core Interface (strobes aligned to the core's qdly
    // stage; config inputs are the core's frame-stable registered copies)
    input logic [ZC_WIDTH-1:0] lifting_size_i,
    input zc_group_t zc_group_i,
    input logic base_graph_i,

    input logic info_valid_i,
    input logic [COL_WIDTH-1:0] info_col_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] info_data_i,

    input logic core_parity_valid_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] core_parity_data_i,

    // Lane k carries (a 96b sub-lane of) base-graph row add_parity_idx_i[k];
    // add_parity_mask_i flags the lanes holding real rows (the final partial
    // row-group of ZC_SMALL pads with stale duplicate labels).
    input logic add_parity_valid_i,
    input logic [3:0][COL_WIDTH-1:0] add_parity_idx_i,
    input logic [3:0] add_parity_mask_i,
    input logic [3:0][(ZC_MAX >> 2)-1:0] add_parity_data_i,

    // High on the FINAL add_parity strobe of a frame: swap write banks.
    input logic input_last_subblock_i,
    output logic upstream_ready_o,

    // Inter-Module Interface to Output Buffer (read data registered, 1 cycle)
    output logic codeword_valid_o,
    input logic [COL_WIDTH-1:0] r_addr_i,
    output logic [ZC_MAX-1:0] r_data_o,
    input logic codeword_done_i,

    output logic [ZC_WIDTH-1:0] lifting_size_o,
    output zc_group_t zc_group_o,
    output logic base_graph_o
);

    localparam int unsigned LANE_W = ZC_MAX >> 2; // 96

    // 4 Horizontally Separated Memory Sub-Banks (Depth: 256, Width: 96)
    (* ram_style = "block" *) logic [LANE_W-1:0] ram [0:3][0:255];

    logic       w_swap_q, r_swap_q;
    logic [1:0] bank_full_q;

    // Configuration double buffering registers
    logic [1:0]               base_graph_q;
    logic [1:0][ZC_WIDTH-1:0] lifting_size_q;
    zc_group_t [1:0]          zc_group_q;

    // Segment base rows for the CURRENT frame's group/base-graph config
    logic [COL_WIDTH-1:0] core_parity_base_row;
    logic [COL_WIDTH-1:0] add_parity_base_row;
    always_comb begin
        case (zc_group_i)
            ZC_SMALL: begin
                core_parity_base_row = base_graph_i ? 7'd3  : 7'd6;  // ceil(KB/4)
                add_parity_base_row  = core_parity_base_row + 7'd1;
            end
            ZC_MEDIUM: begin
                core_parity_base_row = base_graph_i ? 7'd5  : 7'd11; // ceil(KB/2)
                add_parity_base_row  = core_parity_base_row + 7'd2;
            end
            ZC_LARGE: begin
                core_parity_base_row = base_graph_i ? 7'd10 : 7'd22; // KB
                add_parity_base_row  = core_parity_base_row + 7'd4;
            end
            default: begin
                core_parity_base_row = 7'd6;
                add_parity_base_row  = 7'd7;
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // Additional-parity staging & one-row-per-cycle drain
    //--------------------------------------------------------------------------
    // The hand-off pulse is edge-detected: after the final group of a frame
    // the core's rowgrp_changed_qdly (and thus add_parity_valid_i) stays high
    // through IDLE while the accumulators have already been cleared, so only
    // the first cycle carries the real data.
    logic pa_valid_d;
    logic pa_event;
    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) pa_valid_d <= 1'b0;
        else          pa_valid_d <= add_parity_valid_i;
    end
    assign pa_event = add_parity_valid_i & ~pa_valid_d;

    logic                      pa_busy_q;
    logic [1:0]                pa_ptr_q;       // row-of-event being written
    logic [3:0][LANE_W-1:0]    pa_data_q;
    logic [3:0][COL_WIDTH-1:0] pa_idx_q;
    logic [3:0]                pa_mask_q;
    logic                      pa_swap_q;      // bank half of the staged event
    logic                      pa_last_q;      // event closes the frame
    zc_group_t                 pa_grp_q;
    logic [COL_WIDTH-1:0]      pa_ap_base_q;

    // Rows carried per event (minus one): SMALL row-groups complete 4 rows,
    // MEDIUM passes 2, LARGE passes 1.
    logic [1:0] pa_rows_max;
    always_comb begin
        case (pa_grp_q)
            ZC_SMALL:  pa_rows_max = 2'd3;
            ZC_MEDIUM: pa_rows_max = 2'd1;
            ZC_LARGE:  pa_rows_max = 2'd0;
            default:   pa_rows_max = 2'd0;
        endcase
    end

    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) begin
            pa_busy_q    <= 1'b0;
            pa_ptr_q     <= '0;
            pa_data_q    <= '0;
            pa_idx_q     <= '0;
            pa_mask_q    <= '0;
            pa_swap_q    <= 1'b0;
            pa_last_q    <= 1'b0;
            pa_grp_q     <= ZC_SMALL;
            pa_ap_base_q <= '0;
        end else if (pa_event & ~pa_busy_q) begin
            pa_busy_q    <= 1'b1;
            pa_ptr_q     <= '0;
            pa_data_q    <= add_parity_data_i;
            pa_idx_q     <= add_parity_idx_i;
            pa_mask_q    <= add_parity_mask_i;
            pa_swap_q    <= w_swap_q;
            pa_last_q    <= input_last_subblock_i;
            pa_grp_q     <= zc_group_i;
            pa_ap_base_q <= add_parity_base_row;
        end else if (pa_busy_q) begin
            if (pa_ptr_q == pa_rows_max) begin
                pa_busy_q <= 1'b0;
                pa_last_q <= 1'b0;
            end else begin
                pa_ptr_q <= pa_ptr_q + 2'd1;
            end
        end
    end

    // Drain decode: which sub-banks / bank row / data the staged row hits.
    logic [3:0]             pa_w_en;
    logic [COL_WIDTH-1:0]   pa_rel;
    logic [COL_WIDTH-1:0]   pa_addr;
    logic [3:0][LANE_W-1:0] pa_wdata;
    logic                   pa_row_real;

    always_comb begin
        pa_w_en     = '0;
        pa_wdata    = pa_data_q;
        pa_rel      = '0;
        pa_addr     = '0;
        pa_row_real = 1'b0;

        case (pa_grp_q)
            ZC_SMALL: begin
                // Row pa_ptr: 96b on lane pa_ptr -> sub-bank rel%4.
                pa_rel      = pa_idx_q[pa_ptr_q] - 7'd4;
                pa_addr     = pa_ap_base_q + (pa_rel >> 2);
                pa_row_real = pa_mask_q[pa_ptr_q];
                for (int unsigned i = 0; i < 4; i++)
                    pa_wdata[i] = pa_data_q[pa_ptr_q];
                pa_w_en     = 4'b0001 << pa_rel[1:0];
            end
            ZC_MEDIUM: begin
                // Row pa_ptr[0]: 192b on lanes {2p,2p+1} -> sub-bank pair rel%2.
                pa_rel      = pa_idx_q[{pa_ptr_q[0], 1'b0}] - 7'd4;
                pa_addr     = pa_ap_base_q + (pa_rel >> 1);
                pa_row_real = pa_mask_q[{pa_ptr_q[0], 1'b0}];
                pa_wdata[0] = pa_data_q[{pa_ptr_q[0], 1'b0}];
                pa_wdata[1] = pa_data_q[{pa_ptr_q[0], 1'b1}];
                pa_wdata[2] = pa_data_q[{pa_ptr_q[0], 1'b0}];
                pa_wdata[3] = pa_data_q[{pa_ptr_q[0], 1'b1}];
                pa_w_en     = pa_rel[0] ? 4'b1100 : 4'b0011;
            end
            ZC_LARGE: begin
                // Single row: full 384b across all sub-banks.
                pa_rel      = pa_idx_q[0] - 7'd4;
                pa_addr     = pa_ap_base_q + pa_rel;
                pa_row_real = pa_mask_q[0];
                pa_wdata    = pa_data_q;
                pa_w_en     = 4'b1111;
            end
            default: ;
        endcase

        if (!pa_busy_q || !pa_row_real) pa_w_en = '0;
    end

    //--------------------------------------------------------------------------
    // Core-parity write sequencing: one bank row per valid cycle from cp_base
    //--------------------------------------------------------------------------
    logic [1:0] pc_cnt_q;
    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni)                                    pc_cnt_q <= '0;
        else if (core_parity_valid_i & upstream_ready_o) pc_cnt_q <= pc_cnt_q + 2'd1;
        else                                             pc_cnt_q <= '0;
    end

    //--------------------------------------------------------------------------
    // Write port mux (PA drain has priority; it never overlaps info/PC writes
    // because PA events only occur in CALC_PA/IDLE and the next frame is held
    // off by upstream_ready_o until the drain finishes)
    //--------------------------------------------------------------------------
    logic [3:0]               w_en;
    logic [3:0][COL_WIDTH:0]  w_addr;       // {bank half, bank row}
    logic [3:0][LANE_W-1:0]   w_data_mux;

    always_comb begin
        w_en       = '0;
        w_data_mux = info_data_i;
        for (int unsigned i = 0; i < 4; i++) begin
            w_addr[i] = {w_swap_q, 7'd0};
        end

        if (pa_busy_q) begin
            w_en       = pa_w_en;
            w_data_mux = pa_wdata;
            for (int unsigned i = 0; i < 4; i++) begin
                w_addr[i] = {pa_swap_q, pa_addr};
            end
        end else if (info_valid_i & upstream_ready_o) begin
            w_data_mux = info_data_i;
            case (zc_group_i)
                ZC_SMALL: begin
                    w_en = 4'b0001 << info_col_i[1:0];
                    for (int unsigned i = 0; i < 4; i++)
                        w_addr[i] = {w_swap_q, info_col_i >> 2};
                end
                ZC_MEDIUM: begin
                    w_en = info_col_i[0] ? 4'b1100 : 4'b0011;
                    for (int unsigned i = 0; i < 4; i++)
                        w_addr[i] = {w_swap_q, info_col_i >> 1};
                end
                ZC_LARGE: begin
                    w_en = 4'b1111;
                    for (int unsigned i = 0; i < 4; i++)
                        w_addr[i] = {w_swap_q, info_col_i};
                end
                default: ;
            endcase
        end else if (core_parity_valid_i & upstream_ready_o) begin
            w_data_mux = core_parity_data_i;
            w_en       = 4'b1111;
            for (int unsigned i = 0; i < 4; i++)
                w_addr[i] = {w_swap_q, core_parity_base_row + 7'(pc_cnt_q)};
        end
    end

    always_ff @(posedge clk_i) begin
        for (int unsigned i = 0; i < 4; i++) begin
            if (w_en[i]) begin
                ram[i][w_addr[i]] <= w_data_mux[i];
            end
        end
    end

    //--------------------------------------------------------------------------
    // Read port (registered, 1-cycle latency; output buffer waits one cycle)
    //--------------------------------------------------------------------------
    logic [COL_WIDTH:0] r_addr;
    assign r_addr = {r_swap_q, r_addr_i};

    always_ff @(posedge clk_i) begin
        for (int unsigned i = 0; i < 4; i++) begin
            r_data_o[i*LANE_W +: LANE_W] <= ram[i][r_addr];
        end
    end

    //--------------------------------------------------------------------------
    // Bank swap & full/empty interlock
    //--------------------------------------------------------------------------
    // The write half swaps immediately on the frame's final PA event so the
    // next frame's writes route to the fresh half while the staged rows still
    // drain into the old one (their jobs carry pa_swap_q). The bank is only
    // flagged readable once that final drain completes.
    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) begin
            r_swap_q       <= 1'b0;
            w_swap_q       <= 1'b0;
            bank_full_q    <= 2'b00;
            base_graph_q   <= '0;
            lifting_size_q <= '0;
            zc_group_q     <= {ZC_SMALL, ZC_SMALL};
        end else begin
            if (pa_event & input_last_subblock_i) begin
                w_swap_q                 <= ~w_swap_q;
                base_graph_q[w_swap_q]   <= base_graph_i;
                lifting_size_q[w_swap_q] <= lifting_size_i;
                zc_group_q[w_swap_q]     <= zc_group_i;
            end

            if (pa_busy_q & pa_last_q & (pa_ptr_q == pa_rows_max))
                bank_full_q[pa_swap_q] <= 1'b1;

            if (codeword_done_i) begin
                r_swap_q              <= ~r_swap_q;
                bank_full_q[r_swap_q] <= 1'b0;
            end
        end
    end

    // Ready blocks the core from STARTING a frame (gates IDLE->LOAD) while
    // the target bank is still being read out or a final drain is in flight;
    // it never deasserts against a running frame's own writes.
    assign upstream_ready_o = ~bank_full_q[w_swap_q] & ~pa_busy_q;
    // ~codeword_done_i: bank_full/r_swap update one cycle after the done
    // pulse; mask the dying cycle so the consumer never sees the released
    // bank as still valid.
    assign codeword_valid_o = bank_full_q[r_swap_q] & ~codeword_done_i;

    assign lifting_size_o = lifting_size_q[r_swap_q];
    assign base_graph_o   = base_graph_q[r_swap_q];
    assign zc_group_o     = zc_group_q[r_swap_q];

endmodule
