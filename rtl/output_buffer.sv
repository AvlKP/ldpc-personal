import ldpc_pkg::*;

// Drains the codeword generator's banked column store into a dense LSB-first
// 32-bit AXI-Stream.
//
// Generator contract (see codeword_generator.sv / codeword_generator_tb.py):
// read address == codeword column index. Each address holds exactly ONE
// column: its Zc bits span the banks flagged in bank_valid_i in increasing
// bank order, 96 bits per bank, padding above Zc ("data with padding, bit
// mask to remove"). Reads have one cycle of latency; r_data_i / bank_valid_i
// are aligned. lifting_size_i / base_graph_i are the generator's read-side
// config and stay stable for the whole readout.
//
// Per fetched column the drain takes <=32-bit slices from the lowest
// still-valid bank (reverse priority encoder), thermometer-masks the final
// partial slice, barrel-shifts it by the output register's fill level and
// ORs it into a 64-bit append register whose low word is the AXIS beat.
// Valid banks left over after the column's Zc bits are consumed are
// discarded: the core's final half row-group duplicates row labels into the
// upper lanes, which land in higher banks at the same address.
module output_buffer #(
    parameter int unsigned DATA_WIDTH = 32,
    localparam int unsigned COL_WIDTH = $clog2(BG1_COL_N)
) (
    input logic clk_i,                                     // Global clock source
    input logic arst_ni,                                   // Active-low asynchronous reset

    input logic base_graph_i,                              // 0: BG1, 1: BG2 configuration selection flag
    input logic [ZC_WIDTH-1:0] lifting_size_i,             // Active valid target lifting size Z

    // Codeword Generator Module Interface
    input  logic                 codeword_valid_i,         // Memory bank ready notification flag
    output logic                 codeword_done_o,          // Codeword readout complete acknowledgement strobe
    output logic [COL_WIDTH-1:0] r_addr_o,                 // Column lookup address driven to generator
    input  logic [ZC_MAX-1:0]    r_data_i,                 // Recombined 384-bit wide column data return from generator
    input  logic [3:0]           bank_valid_i,             // Which 96-bit banks of r_data_i hold this column

    // Downstream Master AXI Stream Interface
    output logic [DATA_WIDTH-1:0] m_axis_tdata,            // AXI Stream data payload channel
    output logic                  m_axis_tvalid,           // AXI Stream data valid handshake validation
    input  logic                  m_axis_tready,           // Downstream consumer backpressure signal
    output logic                  m_axis_tlast             // End-of-frame packet delimiter strobe
);

    localparam int unsigned LANE_W     = ZC_MAX >> 2;         // 96-bit bank width
    localparam int unsigned LANE_STEPS = LANE_W / DATA_WIDTH; // 3 slices per full bank
    localparam int unsigned OUT_LEN    = 2 * DATA_WIDTH;      // 64-bit append register
    localparam int unsigned FILL_W     = $clog2(OUT_LEN + 1); // fill counts 0..64

    // FSM State Encoding
    typedef enum logic [2:0] {
        IDLE    = 3'b000,
        FETCH   = 3'b001,  // column address presented, generator registers the read
        CAPTURE = 3'b010,  // r_data_i / bank_valid_i valid: load the bank registers
        DRAIN   = 3'b011,  // one <=32-bit slice per cycle into the append register
        FLUSH   = 3'b100   // all columns consumed: emit the trailing partial words
    } state_t;

    state_t state_q, state_n;

    // Column sequencing (address == column index)
    logic [COL_WIDTH-1:0] col_cnt_q, col_cnt_n;
    logic                 col_last;

    // Bank registers: the fetched column, drained lowest-valid-bank first
    typedef logic [3:0][LANE_W-1:0] bank_arr_t;
    bank_arr_t              bank_q, bank_n;
    logic [3:0]             bank_valid_q, bank_valid_n;
    logic [1:0]             bank_sel;
    logic [1:0]             bank_step_q, bank_step_n; // slices taken from the selected bank

    // Remaining bits of the current column (loaded with the lifting size)
    logic [ZC_WIDTH-1:0] col_rem_q, col_rem_n;

    // Output append register ("OR append" + 64-bit output reg of the design)
    logic [OUT_LEN-1:0] out_q, out_n;
    logic [FILL_W-1:0]  fill_q, fill_n;

    logic codeword_done_n;

    assign col_last = (col_cnt_q == (base_graph_i ? COL_WIDTH'(BG2_COL_N - 1)
                                                  : COL_WIDTH'(BG1_COL_N - 1)));
    assign r_addr_o = col_cnt_q;

    // The append register doubles as the AXIS holding stage: while 32+ bits
    // are pending, appends land at bit fill_q >= 32, so tdata's low word
    // stays stable under a stalled tvalid as AXIS requires.
    logic handshake;
    assign m_axis_tdata  = out_q[DATA_WIDTH-1:0];
    assign m_axis_tvalid = (state_q != IDLE)
                         & ((fill_q >= FILL_W'(DATA_WIDTH))
                            | ((state_q == FLUSH) & (fill_q != '0)));
    assign m_axis_tlast  = (state_q == FLUSH) & (fill_q <= FILL_W'(DATA_WIDTH));
    assign handshake     = m_axis_tvalid & m_axis_tready;

    // Reverse priority encoder: the lowest still-valid bank holds the
    // column's next 96-bit span (banks fill LSB-first).
    always_comb begin
        casez (bank_valid_q)
            4'b???1: bank_sel = 2'd0;
            4'b??10: bank_sel = 2'd1;
            4'b?100: bank_sel = 2'd2;
            4'b1000: bank_sel = 2'd3;
            default: bank_sel = 2'd0;
        endcase
    end

    logic [OUT_LEN-1:0] eff_out;   // append register view after this cycle's pop
    logic [FILL_W-1:0]  eff_fill;
    logic [5:0]         take;      // bits consumed this slice: 32, or the final partial
    logic [DATA_WIDTH-1:0] slice;
    logic               can_append;

    always_comb begin
        state_n         = state_q;
        col_cnt_n       = col_cnt_q;
        bank_n          = bank_q;
        bank_valid_n    = bank_valid_q;
        bank_step_n     = bank_step_q;
        col_rem_n       = col_rem_q;
        codeword_done_n = 1'b0;

        // Emission side: pop the low word on a handshake
        eff_out  = out_q;
        eff_fill = fill_q;
        if (handshake) begin
            eff_out  = out_q >> DATA_WIDTH;
            eff_fill = (fill_q >= FILL_W'(DATA_WIDTH)) ? fill_q - FILL_W'(DATA_WIDTH) : '0;
        end
        out_n  = eff_out;
        fill_n = eff_fill;

        // Append side: slice of the selected bank, thermometer mask on the
        // column's final partial slice so bank padding never leaks through
        take  = (col_rem_q >= ZC_WIDTH'(DATA_WIDTH)) ? 6'(DATA_WIDTH) : col_rem_q[5:0];
        slice = bank_q[bank_sel][DATA_WIDTH-1:0];
        if (take < 6'(DATA_WIDTH))
            slice = slice & ~({DATA_WIDTH{1'b1}} << take[4:0]);
        can_append = ({2'b0, eff_fill} + {3'b0, take}) <= 9'(OUT_LEN);

        case (state_q)
            IDLE: begin
                col_cnt_n   = '0;
                out_n       = '0;
                fill_n      = '0;
                col_rem_n   = '0;
                bank_step_n = '0;
                // ~codeword_done_o: the generator swaps its read bank one
                // cycle after the done pulse, so codeword_valid_i still
                // reflects the frame just released during that cycle.
                if (codeword_valid_i & ~codeword_done_o) state_n = FETCH;
            end
            FETCH: state_n = CAPTURE; // generator read latency cycle
            CAPTURE: begin
                bank_n       = bank_arr_t'(r_data_i);
                bank_valid_n = bank_valid_i;
                col_rem_n    = lifting_size_i;
                bank_step_n  = '0;
                state_n      = DRAIN;
            end
            DRAIN: begin
                if (can_append) begin
                    out_n            = eff_out | (OUT_LEN'(slice) << eff_fill[5:0]);
                    fill_n           = eff_fill + FILL_W'(take);
                    col_rem_n        = col_rem_q - ZC_WIDTH'(take);
                    bank_n[bank_sel] = bank_q[bank_sel] >> DATA_WIDTH;
                    if (col_rem_n == '0) begin
                        col_cnt_n = col_cnt_q + 1'b1;
                        state_n   = col_last ? FLUSH : FETCH;
                    end else if (bank_step_q == 2'(LANE_STEPS - 1)) begin
                        bank_valid_n[bank_sel] = 1'b0; // bank consumed, encoder moves on
                        bank_step_n            = '0;
                    end else begin
                        bank_step_n = bank_step_q + 2'd1;
                    end
                end
            end
            FLUSH: begin
                if (handshake & m_axis_tlast) begin
                    codeword_done_n = 1'b1;
                    state_n         = IDLE;
                end
            end
            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) begin
            state_q         <= IDLE;
            col_cnt_q       <= '0;
            bank_q          <= '0;
            bank_valid_q    <= '0;
            bank_step_q     <= '0;
            col_rem_q       <= '0;
            out_q           <= '0;
            fill_q          <= '0;
            codeword_done_o <= 1'b0;
        end else begin
            state_q         <= state_n;
            col_cnt_q       <= col_cnt_n;
            bank_q          <= bank_n;
            bank_valid_q    <= bank_valid_n;
            bank_step_q     <= bank_step_n;
            col_rem_q       <= col_rem_n;
            out_q           <= out_n;
            fill_q          <= fill_n;
            codeword_done_o <= codeword_done_n;
        end
    end

`ifndef SYNTHESIS
    // Generator-contract violations that would otherwise stall the drain
    always_ff @(posedge clk_i) begin
        if (arst_ni && (state_q == CAPTURE) && (bank_valid_i == '0))
            $error("output_buffer: no valid bank at column %0d", col_cnt_q);
        if (arst_ni && (state_q == DRAIN) && (bank_valid_q == '0) && (col_rem_q != '0))
            $error("output_buffer: banks exhausted with %0d bits left in column %0d",
                   col_rem_q, col_cnt_q);
    end
`endif

endmodule
