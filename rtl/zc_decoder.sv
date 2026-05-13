`timescale 1ns / 1ps

module lifting_size_decoder (
    input  logic        clk_i,
    input  logic        arst_ni,
    input  logic [10:0] zc_i,       // Max Z = 1920 (requires 11 bits)
    input  logic        zc_valid,   // Upstream valid signal
    output logic [2:0]  rom_sel,    // Output index i_LS for ROM selection
    output logic        sel_valid   // Valid flag for downstream read enable
);

logic [2:0] next_rom_sel;
logic       next_valid;

always_comb begin
    next_valid   = 1'b1;
    next_rom_sel = 3'd0;
    
    unique case (zc_i)
        // i_LS = 0 (base_Z = 2)
        11'd2, 11'd4, 11'd8, 11'd16, 11'd32, 11'd64, 11'd128, 11'd256: 
            next_rom_sel = 3'd0;
        
        // i_LS = 1 (base_Z = 3)
        11'd3, 11'd6, 11'd12, 11'd24, 11'd48, 11'd96, 11'd192, 11'd384: 
            next_rom_sel = 3'd1;
        
        // i_LS = 2 (base_Z = 5)
        11'd5, 11'd10, 11'd20, 11'd40, 11'd80, 11'd160, 11'd320, 11'd640: 
            next_rom_sel = 3'd2;
        
        // i_LS = 3 (base_Z = 7)
        11'd7, 11'd14, 11'd28, 11'd56, 11'd112, 11'd224, 11'd448, 11'd896: 
            next_rom_sel = 3'd3;
        
        // i_LS = 4 (base_Z = 9)
        11'd9, 11'd18, 11'd36, 11'd72, 11'd144, 11'd288, 11'd576, 11'd1152: 
            next_rom_sel = 3'd4;
        
        // i_LS = 5 (base_Z = 11)
        11'd11, 11'd22, 11'd44, 11'd88, 11'd176, 11'd352, 11'd704, 11'd1408: 
            next_rom_sel = 3'd5;
        
        // i_LS = 6 (base_Z = 13)
        11'd13, 11'd26, 11'd52, 11'd104, 11'd208, 11'd416, 11'd832, 11'd1664: 
            next_rom_sel = 3'd6;
        
        // i_LS = 7 (base_Z = 15)
        11'd15, 11'd30, 11'd60, 11'd120, 11'd240, 11'd480, 11'd960, 11'd1920: 
            next_rom_sel = 3'd7;
        
        default: begin
            next_rom_sel = 3'd0;
            next_valid   = 1'b0;
        end
    endcase
    
    // Gate logic with upstream valid to avoid propagating garbage ROM indexes
    if (!zc_valid) begin
        next_rom_sel = 3'd0;
        next_valid   = 1'b0;
    end
end

always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
        rom_sel   <= 3'd0;
        sel_valid <= 1'b0;
    end else begin
        rom_sel   <= next_rom_sel;
        sel_valid <= next_valid;
    end
end

endmodule