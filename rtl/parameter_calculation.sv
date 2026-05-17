import ldpc_pkg::*;

module parameter_calculation #(
    parameter int ZC_PER_CS = 96, 
    parameter int NUM_CS = 4
)(
    input  logic [8:0] z,
    input  logic [NUM_CS-1:0][8:0] p,
    input  zc_group_t d,
    output logic [NUM_CS-1:0][1:0] p_mod_d,
    output logic [6:0] z_per_d,
    output logic [NUM_CS-1:0][6:0] q,
    output logic [NUM_CS-1:0][6:0] q_plus
);

  always_comb begin
    // Default assignments strictly prevent latch inference
    q       = '0;
    p_mod_d = '0;
    z_per_d = '0;

    // BUG: CSR coefficients 'p' must be normalized (p % z) before calculating 'q'.
    // Shifter underflow occurs if raw p >> z_per_d.
    // Perform calculations using d as a multiplexer select
    case (d)
      ZC_SMALL: begin
        for (int i = 0; i < NUM_CS; i++) begin
          q[i] = p[i][6:0];
        end
        p_mod_d = '0;
        z_per_d = z[6:0];
      end
      ZC_MEDIUM: begin
        for (int i = 0; i < NUM_CS/2; i++) begin
          q[i*2]         = p[i*2+1][7:1];
          q[i*2+1]       = p[i*2+1][7:1];
          p_mod_d[i*2]   = {1'b0, p[i*2+1][0]};
          p_mod_d[i*2+1] = {1'b0, p[i*2+1][0]};
        end
        z_per_d = z[7:1];
      end
      ZC_LARGE: begin
        for (int i = 0; i < NUM_CS; i++) begin
          q[i]       = p[NUM_CS-1][8:2];
          p_mod_d[i] = p[NUM_CS-1][1:0];
        end
        z_per_d = z[8:2];
      end
      default: begin
        // Handled by default assignments at the top
      end
    endcase

    // q_plus is q + 1
    for (int i = 0; i < NUM_CS; i++) begin
      q_plus[i] = q[i] + 7'd1;
    end
  end

endmodule