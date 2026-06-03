import ldpc_pkg::*;

module group_reordering #(
    parameter int ZC_PER_CS = 96, 
    parameter int NUM_CS = 4
)(
    input  logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_in,
    input  zc_group_t                     d,       // [00 = 1, 01 = 2, 11 = 4]
    
    input  logic [NUM_CS-1:0][1:0]                    p_mod_d, // [0, 1, 2, 3]
    output logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_out,
    output logic [NUM_CS-1:0]             use_q_plus // ADDED: outputs 1 if mux_sel[i] > i
);

    localparam int MUX_SEL_WIDTH = $clog2(NUM_CS);    
    logic [MUX_SEL_WIDTH-1:0] mux_sel [NUM_CS];

    always_comb begin
        // Default assignments
        for (int i = 0; i < NUM_CS; i++) begin
            mux_sel[i] = MUX_SEL_WIDTH'(i);
        end
        
        unique case (d)
            ZC_SMALL: begin
                // Handled by default assignments
            end
            ZC_MEDIUM: begin
                // Each 192-bit row occupies a lane PAIR {2j, 2j+1}; the two
                // pairs are independent rows. Rotate by p_mod (0/1) WITHIN each
                // pair only -- rotating across all four lanes (the old
                // (i - p_mod*2) form) cross-mixed the two rows.
                for (int i = 0; i < NUM_CS; i++) begin
                    mux_sel[i] = MUX_SEL_WIDTH'((i & (NUM_CS - 2)) | ((i + int'(p_mod_d[i])) & 1));
                end
            end
            ZC_LARGE: begin
                // All four lanes form one row: rotate by p_mod across the group.
                // Source lane is (i + p_mod) so the lane whose source wraps past
                // the top takes the q+1 shift (see use_q_plus below).
                for (int i = 0; i < NUM_CS; i++) begin
                    mux_sel[i] = MUX_SEL_WIDTH'((i + int'(p_mod_d[i])) & (NUM_CS - 1));
                end
            end
            default: begin
                // Handled by default assignments
            end
        endcase
    end

    always_comb begin : output_mux
        for (int i = 0; i < NUM_CS; i++) begin
            data_out[i]   = data_in[mux_sel[i]];
            // The lane whose source index wrapped past the top of its group
            // takes the q+1 shift. With source = (i + p_mod), a wrap makes the
            // selected source index LESS than i, so test mux_sel[i] < i.
            // (The previous '>' selected q+1 on the wrong lane.)
            use_q_plus[i] = (int'(mux_sel[i]) < i);
        end
    end

endmodule