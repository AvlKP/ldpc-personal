import ldpc_pkg::*;

module output_buffer #(
    parameter int unsigned DATA_WIDTH = 32,
    localparam int unsigned COL_WIDTH = $clog2(BG1_COL_N)
) (
    input logic clk_i,                                     // Global clock source
    input logic arst_ni,                                   // Active-low asynchronous reset

    input logic base_graph_i,                              // 0: BG1, 1: BG2 configuration selection flag
    input zc_group_t zc_group_i,                           // Pre-calculated lifting size group configuration enum
    input logic [ZC_WIDTH-1:0] lifting_size_i,             // Active valid target lifting size Z

    // Codeword Generator Module Interface
    input  logic                 codeword_valid_i,         // Memory bank ready notification flag
    output logic                 codeword_done_o,          // Codeword readout complete acknowledgement strobe
    output logic [COL_WIDTH-1:0] r_addr_o,                 // Row index lookup address driven to generator
    input  logic [ZC_MAX-1:0]     r_data_i,                 // Recombined 384-bit wide row data return from generator

    // Downstream Master AXI Stream Interface
    output logic [DATA_WIDTH-1:0] m_axis_tdata,            // AXI Stream data payload channel
    output logic                  m_axis_tvalid,           // AXI Stream data valid handshake validation
    input  logic                  m_axis_tready,           // Downstream consumer backpressure signal
    output logic                  m_axis_tlast             // End-of-frame packet delimiter strobe
);

    // Encapsulate AXI Stream Channels into a packed structure for generic instantiation
    typedef struct packed {
        logic [DATA_WIDTH-1:0] tdata;
        logic                  tlast;
    } axis_packet_t;

    // FSM State Encoding
    typedef enum logic [2:0] { 
        IDLE     = 3'b000,
        FETCH    = 3'b001,
        WAIT_RAM = 3'b010,
        STREAM   = 3'b011,
        FLUSH    = 3'b100
    } state_t;

    // Control and Datapath Register Chains
    state_t                  state_q, state_n;
    logic [COL_WIDTH-1:0]    col_idx_q, col_idx_n;
    logic [COL_WIDTH-1:0]    r_addr_q, r_addr_n;
    
    localparam int unsigned  ACCUM_LEN = 2 * DATA_WIDTH;
    localparam int unsigned  ACCUM_WIDTH = $clog2(ACCUM_LEN);
    logic [ACCUM_LEN-1:0]    accum_q, accum_n;
    logic [ACCUM_WIDTH-1:0]  accum_cnt_q, accum_cnt_n;

    logic [ZC_MAX-1:0]       shifter_q, shifter_n;
    logic [ZC_WIDTH-1:0]     shifter_cnt_q, shifter_cnt_n;
    logic                    codeword_done_n;

    // Internal Skid Buffer Interconnect Lines
    logic                    internal_valid;
    logic                    internal_ready;
    logic [DATA_WIDTH-1:0]   internal_data;
    logic                    internal_last;

    // Boundary Evaluation Status Flags
    logic                    axis_handshake;
    logic                    col_depleted;
    logic                    flush_complete;
    logic [COL_WIDTH-1:0]    col_max;
    logic [COL_WIDTH-1:0]    sys_limit;
    logic [1:0]              slot_idx;
    logic [8:0]              total_bits_left;
    logic                    ram_word_exhausted;
    logic [ZC_MAX-1:0]       current_column_chunk;
    logic [ZC_WIDTH-1:0]     effective_shifter_cnt;

    assign axis_handshake = internal_valid & internal_ready;
    assign r_addr_o       = r_addr_q;
    assign col_max        = (base_graph_i) ? BG2_COL_N : BG1_COL_N;
    assign sys_limit      = (base_graph_i) ? COL_WIDTH'(10) : COL_WIDTH'(22);
    
    assign col_depleted   = (shifter_cnt_n == '0);
    assign flush_complete = (accum_cnt_n == '0);
    assign effective_shifter_cnt = (shifter_cnt_q == '0) ? lifting_size_i : shifter_cnt_q;

    //--------------------------------------------------------------------------
    // Concern 1: Subblock Column Chunk Demultiplexing Logic (Explicitly Configured)
    //--------------------------------------------------------------------------
    always_comb begin
        // Calculate Phase-Aware Slot Index within the BRAM word
        if (col_idx_q < sys_limit) begin
            slot_idx = col_idx_q[1:0];
        end else if (col_idx_q < sys_limit + 4) begin
            slot_idx = 2'(col_idx_q - sys_limit);
        end else begin
            slot_idx = 2'(col_idx_q - sys_limit - 4);
        end

        // Secure defensive defaults to guarantee zero latch generation
        current_column_chunk = r_data_i;
        ram_word_exhausted   = (r_addr_n != r_addr_q);

        unique case (zc_group_i)
            ZC_SMALL: begin
                unique case (slot_idx)
                    2'b00: current_column_chunk = ZC_MAX'(r_data_i[95:0]);
                    2'b01: current_column_chunk = ZC_MAX'(r_data_i[191:96]);
                    2'b10: current_column_chunk = ZC_MAX'(r_data_i[287:192]);
                    2'b11: current_column_chunk = ZC_MAX'(r_data_i[383:288]);
                endcase
            end
            
            ZC_MEDIUM: begin
                if (slot_idx[0] == 1'b0) begin
                    current_column_chunk = ZC_MAX'(r_data_i[191:0]);
                end else begin
                    current_column_chunk = ZC_MAX'(r_data_i[383:192]);
                end
            end
            
            ZC_LARGE: begin
                current_column_chunk = r_data_i;
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // Concern 2: Gearbox Datapath Shifting Engine
    //--------------------------------------------------------------------------
    always_comb begin
        logic [ACCUM_WIDTH-1:0] take_bits;
        logic [DATA_WIDTH-1:0]  slice;

        accum_n       = accum_q;
        accum_cnt_n   = accum_cnt_q;
        shifter_n     = shifter_q;
        shifter_cnt_n = shifter_cnt_q;
        take_bits     = '0;
        slice         = '0;

        if (axis_handshake) begin
            accum_n = accum_n >> DATA_WIDTH;
            if (accum_cnt_n >= ACCUM_WIDTH'(DATA_WIDTH)) begin
                accum_cnt_n = accum_cnt_n - ACCUM_WIDTH'(DATA_WIDTH);
            end else begin
                accum_cnt_n = '0;
            end
        end

        if (state_q == IDLE) begin
            accum_n       = '0;
            accum_cnt_n   = '0;
            shifter_cnt_n = '0;
        end else if (state_q == STREAM) begin
            // Extract lookahead chunk from active row wires if the local register tracker is empty
            if (shifter_cnt_n == '0) begin
                shifter_n     = current_column_chunk;
                shifter_cnt_n = lifting_size_i;
            end

            // Localized extraction loop and variable bit masking
            if (accum_cnt_n < ACCUM_WIDTH'(DATA_WIDTH) && shifter_cnt_n > '0) begin
                take_bits = (shifter_cnt_n >= ZC_WIDTH'(DATA_WIDTH)) ? 
                             ACCUM_WIDTH'(DATA_WIDTH) : shifter_cnt_n[ACCUM_WIDTH-1:0];
                slice     = shifter_n[DATA_WIDTH-1:0];
                
                if (take_bits < ACCUM_WIDTH'(DATA_WIDTH)) begin
                    slice = slice & ((DATA_WIDTH'(1) << take_bits) - DATA_WIDTH'(1));
                end
                
                accum_n       = accum_n | (ACCUM_LEN'(slice) << accum_cnt_n);
                accum_cnt_n   = accum_cnt_n + take_bits;
                shifter_n     = shifter_n >> DATA_WIDTH;
                shifter_cnt_n = shifter_cnt_n - ZC_WIDTH'(take_bits);
            end
        end
    end

    //--------------------------------------------------------------------------
    // Concern 3: FSM Control Phase Controller
    //--------------------------------------------------------------------------
    always_comb begin
        state_n         = state_q;
        codeword_done_n = 1'b0;

        case (state_q)
            IDLE:     if (codeword_valid_i) state_n = FETCH;
            FETCH:    state_n = WAIT_RAM;
            WAIT_RAM: state_n = STREAM;
            STREAM:   if (col_depleted) begin
                          if (col_idx_q == col_max - 1) begin
                              state_n = FLUSH;
                          end else if (ram_word_exhausted) begin
                              state_n = WAIT_RAM; // Trigger 1-cycle latency wait state for new row
                          end else begin
                              state_n = STREAM;   // Stay in STREAM to consume next packed column chunk
                          end
                      end
            FLUSH:    if (flush_complete) begin
                          codeword_done_n = 1'b1;
                          state_n         = IDLE;
                      end
            default:  state_n = IDLE;
        endcase
    end

    //--------------------------------------------------------------------------
    // Concern 4: Sequential Addressing Matrix Generation Logic
    //--------------------------------------------------------------------------
    function automatic [COL_WIDTH-1:0] get_r_addr(
        input logic [COL_WIDTH-1:0] c,
        input logic                 bg,
        input zc_group_t            g
    );
        logic [COL_WIDTH-1:0] limit;
        logic [COL_WIDTH-1:0] cp_base;
        logic [COL_WIDTH-1:0] ap_base;
        logic [COL_WIDTH-1:0] addr;
        
        limit = bg ? COL_WIDTH'(10) : COL_WIDTH'(22);
        
        unique case (g)
            ZC_SMALL: begin
                cp_base = bg ? COL_WIDTH'(3) : COL_WIDTH'(6);
                ap_base = cp_base + COL_WIDTH'(1);
            end
            ZC_MEDIUM: begin
                cp_base = bg ? COL_WIDTH'(5) : COL_WIDTH'(11);
                ap_base = cp_base + COL_WIDTH'(2);
            end
            ZC_LARGE: begin
                cp_base = bg ? COL_WIDTH'(10) : COL_WIDTH'(22);
                ap_base = cp_base + COL_WIDTH'(4);
            end
            default: begin
                cp_base = COL_WIDTH'(6);
                ap_base = COL_WIDTH'(7);
            end
        endcase

        if (c < limit) begin
            unique case (g)
                ZC_SMALL:  addr = c >> 2;
                ZC_MEDIUM: addr = c >> 1;
                ZC_LARGE:  addr = c;
                default:   addr = c >> 2;
            endcase
        end else if (c < limit + COL_WIDTH'(4)) begin
            logic [COL_WIDTH-1:0] rel_c;
            rel_c = c - limit;
            unique case (g)
                ZC_SMALL:  addr = cp_base + (rel_c >> 2);
                ZC_MEDIUM: addr = cp_base + (rel_c >> 1);
                ZC_LARGE:  addr = cp_base + rel_c;
                default:   addr = cp_base + (rel_c >> 2);
            endcase
        end else begin
            logic [COL_WIDTH-1:0] rel_c;
            rel_c = c - limit - COL_WIDTH'(4);
            unique case (g)
                ZC_SMALL:  addr = ap_base + (rel_c >> 2);
                ZC_MEDIUM: addr = ap_base + (rel_c >> 1);
                ZC_LARGE:  addr = ap_base + rel_c;
                default:   addr = ap_base + (rel_c >> 2);
            endcase
        end
        return addr;
    endfunction

    always_comb begin
        col_idx_n = col_idx_q;
        r_addr_n  = r_addr_q;
        
        case (state_q)
            IDLE: if (codeword_valid_i) begin
                col_idx_n = '0;
                r_addr_n  = '0;
            end
            STREAM: if (col_depleted && col_idx_q != col_max - 1) begin
                col_idx_n = col_idx_q + 1;
                r_addr_n  = get_r_addr(col_idx_n, base_graph_i, zc_group_i);
            end
            default: ;
        endcase
    end

    //--------------------------------------------------------------------------
    // Concern 5: Total Bit Tracking & Outbound AXI Stream Mapping
    //--------------------------------------------------------------------------
    always_comb begin
        if (state_q == FLUSH) begin
            total_bits_left = {3'b0, accum_cnt_q};
        end else if (state_q == STREAM && col_idx_q == col_max - 1) begin
            total_bits_left = {3'b0, accum_cnt_q} + effective_shifter_cnt;
        end else begin
            total_bits_left = 9'h1FF; // 511 acts as safe out-of-bounds flag
        end
    end

    always_comb begin
        internal_data  = accum_q[DATA_WIDTH-1:0];
        internal_valid = 1'b0;
        internal_last  = 1'b0;
        
        case (state_q)
            STREAM: begin
                internal_valid = (accum_cnt_q >= ACCUM_WIDTH'(DATA_WIDTH));
                internal_last  = (total_bits_left <= DATA_WIDTH);
            end
            FLUSH: begin
                internal_valid = (accum_cnt_q > '0);
                internal_last  = (total_bits_left <= DATA_WIDTH);
            end 
            default: ;
        endcase
    end

    //--------------------------------------------------------------------------
    // Concern 6: Clean Clock-Edge Register Synchronous Layer
    //--------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge arst_ni) begin
        if (!arst_ni) begin
            state_q         <= IDLE;
            col_idx_q       <= '0;
            r_addr_q        <= '0;
            accum_q         <= '0;
            accum_cnt_q     <= '0;
            shifter_q       <= '0;
            shifter_cnt_q   <= '0;
            codeword_done_o <= 1'b0;
        end else begin
            state_q         <= state_n;
            col_idx_q       <= col_idx_n;
            r_addr_q        <= r_addr_n;
            accum_q         <= accum_n;
            accum_cnt_q     <= accum_cnt_n;
            shifter_q       <= shifter_n;
            shifter_cnt_q   <= shifter_cnt_n;
            codeword_done_o <= codeword_done_n;
        end
    end

    // Physical Interfacing Struct Configurations
    axis_packet_t internal_payload;
    axis_packet_t external_payload;

    assign internal_payload.tdata = internal_data;
    assign internal_payload.tlast = internal_last;

    assign m_axis_tdata = external_payload.tdata;
    assign m_axis_tlast = external_payload.tlast;

    // Timing Path Isolation Deployment via Output Register Skid Buffer
    spill_register #(
        .T     (axis_packet_t),
        .Bypass(0)
    ) u_spill_register (
        .clk_i  (clk_i),
        .rst_ni (arst_ni),
        .valid_i(internal_valid),
        .ready_o(internal_ready),
        .data_i (internal_payload),
        .valid_o(m_axis_tvalid),
        .ready_i(m_axis_tready),
        .data_o (external_payload)
    );

endmodule