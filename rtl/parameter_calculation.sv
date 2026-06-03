import ldpc_pkg::*;

module parameter_calculation #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    input  logic [8:0] z,
    input  logic [NUM_CS-1:0][8:0] p,
    input  zc_group_t d,
    // Selects which p lane(s) feed q, mirroring the encoder's merge_d_cycle:
    //   ZC_SMALL : unused (q[i] <- p[i] one-to-one)
    //   ZC_MEDIUM: pair {q[2i+1],q[2i]} <- p[2i + (merge_d_cycle-1)]
    //              (d_cycle=2 -> odd p[1],p[3]; d_cycle=1 -> even p[0],p[2])
    //   ZC_LARGE : all q lanes <- p[merge_d_cycle] (d_cycle=3->p[3] .. 0->p[0])
    input  logic [1:0] merge_d_cycle,
    output logic [NUM_CS-1:0][1:0] p_mod_d,
    output logic [6:0] z_per_d,
    output logic [NUM_CS-1:0][6:0] q,
    output logic [NUM_CS-1:0][6:0] q_plus
);

  // p normalized to [0, z): supports CSR coefficients where p >= z
  logic [NUM_CS-1:0][8:0] p_norm;

  always_comb begin
    int src;
    // Default assignments strictly prevent latch inference
    q       = '0;
    p_mod_d = '0;
    z_per_d = '0;
    src     = 0;

    // Normalize p: subtract z when p >= z, preserving the null marker (9'h1FF).
    // z is always divisible by d in each Zc group, so p_mod_d is unchanged by this.
    for (int i = 0; i < NUM_CS; i++) begin
      p_norm[i] = (p[i] != 9'h1FF) ? (p[i] % z) : p[i];
    end

    case (d)
      ZC_SMALL: begin
        for (int i = 0; i < NUM_CS; i++) begin
          q[i] = p_norm[i][6:0];
        end
        p_mod_d = '0;
        z_per_d = z[6:0];
      end
      ZC_MEDIUM: begin
        // Lane-pair {2k,2k+1} processes absolute row 2*(merge_d_cycle-1)+k, so
        // it takes that row's permutation p[2*(merge_d_cycle-1)+k]:
        //   d_cycle=2 -> rows 2,3 (p[2],p[3]); d_cycle=1 -> rows 0,1 (p[0],p[1]).
        // This must agree with the gf2 enable remap and merge_select_lambda,
        // which place the result into lambda[2*(merge_d_cycle-1)+k].
        for (int i = 0; i < NUM_CS/2; i++) begin
          src            = 2*(int'(merge_d_cycle) - 1) + i;
          q[i*2]         = p_norm[src][7:1];
          q[i*2+1]       = p_norm[src][7:1];
          p_mod_d[i*2]   = {1'b0, p_norm[src][0]};
          p_mod_d[i*2+1] = {1'b0, p_norm[src][0]};
        end
        z_per_d = z[7:1];
      end
      ZC_LARGE: begin
        // All four lanes share one row; merge_d_cycle picks p[3..0].
        src = int'(merge_d_cycle);
        for (int i = 0; i < NUM_CS; i++) begin
          q[i]       = p_norm[src][8:2];
          p_mod_d[i] = p_norm[src][1:0];
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