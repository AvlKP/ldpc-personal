`timescale 1ns / 1ps

module set_index_decoder (
    input  logic       clk,
    input  logic       rst_n,      // Active-low asynchronous reset
    input  logic [8:0] z_val,      // Max Z = 384 (requires 9 bits)
    input  logic       z_valid,    // Upstream valid signal
    output logic [2:0] i_ls,       // Set index (iLS) output
    output logic       sel_valid   // Valid flag for downstream logic
);

  // -------------------------------------------------------------------------
  // Combinational Decode Logic
  // -------------------------------------------------------------------------
  logic [2:0] next_i_ls;
  logic       next_valid;

  always_comb begin
    // Default assignments to prevent latch inference
    next_valid = 1'b1;
    next_i_ls  = 3'd0;
    
    // The unique case statement builds a flat, parallel multiplexer tree.
    // For sparse, static 3GPP LDPC tables, this maps efficiently to 6-input 
    // LUTs, avoiding the deep logic cones of dynamic shifters.
    unique case (z_val)
      // iLS = 0 (base_Z = 2)
      9'd2, 9'd4, 9'd8, 9'd16, 9'd32, 9'd64, 9'd128, 9'd256: 
          next_i_ls = 3'd0;
      
      // iLS = 1 (base_Z = 3)
      9'd3, 9'd6, 9'd12, 9'd24, 9'd48, 9'd96, 9'd192, 9'd384: 
          next_i_ls = 3'd1;
      
      // iLS = 2 (base_Z = 5)
      9'd5, 9'd10, 9'd20, 9'd40, 9'd80, 9'd160, 9'd320: 
          next_i_ls = 3'd2;
      
      // iLS = 3 (base_Z = 7)
      9'd7, 9'd14, 9'd28, 9'd56, 9'd112, 9'd224: 
          next_i_ls = 3'd3;
      
      // iLS = 4 (base_Z = 9)
      9'd9, 9'd18, 9'd36, 9'd72, 9'd144, 9'd288: 
          next_i_ls = 3'd4;
      
      // iLS = 5 (base_Z = 11)
      9'd11, 9'd22, 9'd44, 9'd88, 9'd176, 9'd352: 
          next_i_ls = 3'd5;
      
      // iLS = 6 (base_Z = 13)
      9'd13, 9'd26, 9'd52, 9'd104, 9'd208: 
          next_i_ls = 3'd6;
      
      // iLS = 7 (base_Z = 15)
      9'd15, 9'd30, 9'd60, 9'd120, 9'd240: 
          next_i_ls = 3'd7;
      
      default: begin
          next_i_ls  = 3'd0;
          next_valid = 1'b0; // Flag unsupported Z values
      end
    endcase
    
    // Mask with upstream valid to ensure isolation of garbage data
    if (!z_valid) begin
        next_i_ls  = 3'd0;
        next_valid = 1'b0;
    end
end

// -------------------------------------------------------------------------
// Sequential Output Register
// -------------------------------------------------------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i_ls      <= 3'd0;
        sel_valid <= 1'b0;
    end else begin
        i_ls      <= next_i_ls;
        sel_valid <= next_valid;
    end
  end

endmodule