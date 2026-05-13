`timescale 1ns / 1ps

module codeword_generator #(
    parameter int ZC_MAX     = 384,
    parameter int ADDR_WIDTH = 5   // 5 bits supports up to 32 depth (32 * 1536 = 49,152 bits)
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // Top-Level Configuration
    input  logic [15:0]                 expected_cw_bits_i, // Total bits expected for this codeword
    input  logic [8:0]                  zc_i,               // Current lifting size (Zc)

    // LDPC Core Interfaces
    // Information bits (1 group per cycle = max 384 bits)
    input  logic [ZC_MAX-1:0]           info_group_i,
    input  logic                        info_valid_i,

    // Core parity bits (max 4 groups = max 1536 bits)
    input  logic [3:0][ZC_MAX-1:0]      parity_core_i,
    input  logic                        parity_core_valid_i,

    // Additional parity bits (max 4 groups = max 1536 bits)
    input  logic [3:0][ZC_MAX-1:0]      parity_additional_i,
    input  logic                        parity_additional_valid_i,

    // Parity Group Selector (2'b00: 1 group, 2'b01: 2 groups, 2'b11: 4 groups)
    input  logic [1:0]                  parity_groups_i,

    // Flow Control
    input  logic                        outbuff_full_i,
    output logic                        core_stall_o,
    
    // Output Buffer Interface (LUTRAM Write Port & DMA Controls)
    output logic [(ZC_MAX << 2)-1:0]    outbuff_data_o,
    output logic [ADDR_WIDTH-1:0]       outbuff_addr_o,
    output logic                        outbuff_wr_en_o,
    output logic                        cw_done_o,          // Pulses on final write
    output logic [10:0]                 total_words_o       // Passed to buffer for AXI TLAST
);

    // Internal Registers
    logic [ADDR_WIDTH-1:0] current_addr;
    logic [15:0]           written_bits_cnt;
    logic [15:0]           incoming_bits;

    // -------------------------------------------------------------------------
    // 1. Bit Tracking & Write Logic (Combinational)
    // -------------------------------------------------------------------------
    always_comb begin
        // Default assignments guarantee zero-padding
        outbuff_data_o  = '0; 
        outbuff_wr_en_o = 1'b0;
        incoming_bits   = '0;

        if (!outbuff_full_i) begin
            if (info_valid_i) begin
                outbuff_data_o[ZC_MAX-1:0] = info_group_i;
                outbuff_wr_en_o            = 1'b1;
                incoming_bits              = {7'd0, zc_i};
            end 
            else if (parity_core_valid_i) begin
                outbuff_wr_en_o = 1'b1;
                case (parity_groups_i)
                    2'b00: begin 
                        outbuff_data_o[ZC_MAX-1:0]     = parity_core_i[0];
                        incoming_bits                  = {7'd0, zc_i};
                    end
                    2'b01: begin 
                        outbuff_data_o[(ZC_MAX*2)-1:0] = {parity_core_i[1], parity_core_i[0]};
                        incoming_bits                  = {6'd0, zc_i, 1'b0}; // zc_i * 2
                    end
                    2'b11: begin 
                        outbuff_data_o[(ZC_MAX*4)-1:0] = {parity_core_i[3], parity_core_i[2], parity_core_i[1], parity_core_i[0]};
                        incoming_bits                  = {5'd0, zc_i, 2'b00}; // zc_i * 4
                    end
                    default: begin 
                        outbuff_data_o[ZC_MAX-1:0]     = parity_core_i[0];
                        incoming_bits                  = {7'd0, zc_i};
                    end
                endcase
            end 
            else if (parity_additional_valid_i) begin
                outbuff_wr_en_o = 1'b1;
                case (parity_groups_i)
                    2'b00: begin 
                        outbuff_data_o[ZC_MAX-1:0]     = parity_additional_i[0];
                        incoming_bits                  = {7'd0, zc_i};
                    end
                    2'b01: begin 
                        outbuff_data_o[(ZC_MAX*2)-1:0] = {parity_additional_i[1], parity_additional_i[0]};
                        incoming_bits                  = {6'd0, zc_i, 1'b0}; // zc_i * 2
                    end
                    2'b11: begin 
                        outbuff_data_o[(ZC_MAX*4)-1:0] = {parity_additional_i[3], parity_additional_i[2], parity_additional_i[1], parity_additional_i[0]};
                        incoming_bits                  = {5'd0, zc_i, 2'b00}; // zc_i * 4
                    end
                    default: begin 
                        outbuff_data_o[ZC_MAX-1:0]     = parity_additional_i[0];
                        incoming_bits                  = {7'd0, zc_i};
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Control Flags & Total Words Calculation
    // -------------------------------------------------------------------------
    // Pulse cw_done_o synchronously on the cycle the final chunk is written
    assign cw_done_o = outbuff_wr_en_o && ((written_bits_cnt + incoming_bits) >= expected_cw_bits_i);

    // Calculate total 32-bit AXI Stream Words: (Total Bits + 31) / 32
    assign total_words_o = (expected_cw_bits_i + 16'd31) >> 5;

    // Core must stall if a valid output is pending but the buffer is locked
    assign core_stall_o  = outbuff_full_i && (info_valid_i || parity_core_valid_i || parity_additional_valid_i);

    // -------------------------------------------------------------------------
    // 3. Address Generation & Accumulator (Sequential)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_addr     <= '0;
            written_bits_cnt <= '0;
        end else begin
            if (cw_done_o) begin
                // Reset pointers automatically for the next codeword frame
                current_addr     <= '0;
                written_bits_cnt <= '0;
            end else if (outbuff_wr_en_o) begin
                current_addr     <= current_addr + 1'b1;
                written_bits_cnt <= written_bits_cnt + incoming_bits;
            end
        end
    end

    // Continuous Assignments
    assign outbuff_addr_o = current_addr;

endmodule