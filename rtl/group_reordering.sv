module group_reordering #(
    parameter int ZC_PER_CS = 96, 
    parameter int NUM_CS = 4
)(
    input  logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_in,
    input  logic [1:0]                    d,       // [00 = 1, 01 = 2, 11 = 4]
    
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
            2'b00: begin
                // Handled by default assignments
            end
            2'b01: begin
                for (int i = 0; i < NUM_CS; i++) begin
                    mux_sel[i] = MUX_SEL_WIDTH'((i - (p_mod_d[i] * 2)) & (NUM_CS - 1));
                end
            end
            2'b11: begin
                for (int i = 0; i < NUM_CS; i++) begin
                    mux_sel[i] = MUX_SEL_WIDTH'((i - p_mod_d[i]) & (NUM_CS - 1));
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
            use_q_plus[i] = (mux_sel[i] > MUX_SEL_WIDTH'(i)); // Evaluates to 1 when true, 0 when false
        end
    end

endmodule