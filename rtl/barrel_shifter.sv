module barrel_shifter #(
    parameter int unsigned ZC_PER_CS = 96,
    parameter int unsigned SHIFT_W = $clog2(ZC_PER_CS + 1) 
)(
    input  logic [ZC_PER_CS-1:0] data_in,
    input  logic [SHIFT_W-1:0]   zc_in,
    input  logic [SHIFT_W-1:0]   shift_amt,
    input  logic                 direction,
    output logic [ZC_PER_CS-1:0] data_out
);

// Intermediate signals declared at module scope for waveform visibility
logic [ZC_PER_CS-1:0] data_mask;
logic [ZC_PER_CS-1:0] masked_data_in;
logic [ZC_PER_CS-1:0] rotated_val;

always_comb begin
    // Default assignments strictly prevent latch inference
    data_mask      = '0;
    masked_data_in = '0;
    rotated_val    = '0;
    data_out       = '0;

    if (shift_amt != '1) begin
        // Use explicit width replication for the all-ones mask
        data_mask = {ZC_PER_CS{1'b1}} << (SHIFT_W'(ZC_PER_CS) - $unsigned(zc_in));
        
        masked_data_in = data_in & data_mask;

        if (!direction) begin 
            // Left circular shift (rotate)
            rotated_val = (masked_data_in << shift_amt) | 
                            (masked_data_in >> ($unsigned(zc_in) - shift_amt));
        end else begin 
            // Right circular shift (rotate)
            rotated_val = (masked_data_in >> shift_amt) | 
                            (masked_data_in << ($unsigned(zc_in) - shift_amt));
        end

        data_out = rotated_val & data_mask;
    end
end

endmodule