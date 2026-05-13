`timescale 1ns / 1ps

module output_buffer #(
    parameter int ZC_MAX     = 384,
    parameter int ADDR_WIDTH = 5   // 5 bits supports up to 32 depth (32 * 1536 = 49,152 bits)
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Interface from codeword_generator
    input  logic [(ZC_MAX << 2)-1:0]    wr_data_i,
    input  logic [ADDR_WIDTH-1:0]       wr_addr_i,
    input  logic                        wr_en_i,
    
    // Control Interface
    input  logic                        cw_done_i,       // Triggers the stream-out process
    input  logic [10:0]                 total_words_i,   // Total 32-bit words to stream out for this codeword
    output logic                        outbuff_full_o,
    
    // AXI-Stream Interface
    output logic [31:0]                 m_axis_tdata,
    output logic                        m_axis_tlast,
    output logic                        m_axis_tvalid,
    input  logic                        m_axis_tready
);

    localparam int ROW_WIDTH = ZC_MAX << 2; // 1536 bits
    localparam int WORDS_PER_ROW = ROW_WIDTH / 32; // 48 words
    localparam int MUX_IDX_WIDTH = $clog2(WORDS_PER_ROW);

    // -------------------------------------------------------------------------
    // Custom AXI Payload Typedef for Spill Register
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic        tlast;
        logic [31:0] tdata;
    } axis_payload_t;

    // -------------------------------------------------------------------------
    // Distributed RAM (LUTRAM) Inference
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *) logic [ROW_WIDTH-1:0] mem [(1<<ADDR_WIDTH)-1:0];

    // Synchronous Write
    always_ff @(posedge clk) begin
        if (wr_en_i) begin
            mem[wr_addr_i] <= wr_data_i;
        end
    end

    // -------------------------------------------------------------------------
    // Internal Readout State Machine
    // -------------------------------------------------------------------------
    typedef enum logic {
        IDLE,
        STREAMING
    } state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0]  rd_addr;
    logic [MUX_IDX_WIDTH:0] word_idx; 
    logic [10:0]            words_streamed;
    
    logic [ROW_WIDTH-1:0]   current_row;
    
    axis_payload_t          internal_payload;
    logic                   internal_tvalid;
    logic                   internal_tready; 

    // Asynchronous Read from LUTRAM
    assign current_row = mem[rd_addr];

    // Combinational Payload Generation
    assign internal_payload.tdata = current_row[word_idx * 32 +: 32];
    
    // TLAST is asserted when the currently evaluated word is the final word of the stream
    assign internal_payload.tlast = (words_streamed + 1'b1 == total_words_i);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            rd_addr         <= '0;
            word_idx        <= '0;
            words_streamed  <= '0;
            outbuff_full_o  <= 1'b0;
            internal_tvalid <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    rd_addr         <= '0;
                    word_idx        <= '0;
                    words_streamed  <= '0;
                    internal_tvalid <= 1'b0;
                    outbuff_full_o  <= 1'b0;

                    if (cw_done_i) begin
                        state           <= STREAMING;
                        outbuff_full_o  <= 1'b1; 
                        internal_tvalid <= 1'b1; 
                    end
                end

                STREAMING: begin
                    // Advance only if the downstream spill register accepts the data
                    if (internal_tready && internal_tvalid) begin
                        words_streamed <= words_streamed + 1'b1;

                        if (words_streamed + 1'b1 == total_words_i) begin
                            state           <= IDLE;
                            internal_tvalid <= 1'b0;
                            outbuff_full_o  <= 1'b0;
                        end 
                        else begin
                            internal_tvalid <= 1'b1; 
                            
                            // Advance chunk/row pointers
                            if (word_idx + 1'b1 == WORDS_PER_ROW) begin
                                word_idx <= '0;
                                rd_addr  <= rd_addr + 1'b1;
                            end else begin
                                word_idx <= word_idx + 1'b1;
                            end
                        end
                    end
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // AXI-Stream Spill Register (Skid Buffer)
    // -------------------------------------------------------------------------
    axis_payload_t m_axis_payload;

    spill_register #(
        .T      (axis_payload_t),
        .Bypass (1'b0)
    ) axis_skid_buffer (
        .clk_i   (clk),
        .rst_ni  (rst_n),
        .valid_i (internal_tvalid),
        .ready_o (internal_tready),
        .data_i  (internal_payload),
        .valid_o (m_axis_tvalid),
        .ready_i (m_axis_tready),
        .data_o  (m_axis_payload)
    );

    // Unpack the payload at the top-level boundary
    assign m_axis_tdata = m_axis_payload.tdata;
    assign m_axis_tlast = m_axis_payload.tlast;

endmodule