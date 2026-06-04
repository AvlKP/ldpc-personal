import ldpc_pkg::*;

module merge_select_lambda #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    // input [1:0] d,
    input zc_group_t zc_group,
    input logic [1:0] d_cycle,
    input  logic [NUM_CS-1:0][ZC_PER_CS-1:0]        data_in,
    output logic [NUM_CS-1:0][ZC_MAX-1:0] data_out
);

    always_comb begin
      for (int i = 0; i < NUM_CS; i++) begin
        data_out[i] = '0;
      end

      case (zc_group)
        ZC_SMALL: begin
          // Place each 96-bit lane at the LSB of its 384-bit slot.
          for (int i = 0; i < NUM_CS; i++) begin
            data_out[i][ZC_PER_CS-1:0] = data_in[i];
          end
        end
        ZC_MEDIUM: begin
          // Reconstruct a 192-bit row at [191:0] of the 384-bit slot.
          // Lane 0 (bottom 96) at [95:0], lane 1 (top 96) at [191:96].
          data_out[2*(d_cycle-1)  ][ZC_PER_CS-1   -: ZC_PER_CS] = data_in[0];
          data_out[2*(d_cycle-1)  ][2*ZC_PER_CS-1 -: ZC_PER_CS] = data_in[1];
          data_out[2*(d_cycle-1)+1][ZC_PER_CS-1   -: ZC_PER_CS] = data_in[2];
          data_out[2*(d_cycle-1)+1][2*ZC_PER_CS-1 -: ZC_PER_CS] = data_in[3];
        end
        ZC_LARGE: begin
          for (int j = 0; j < NUM_CS; j++) begin
            data_out[d_cycle][(NUM_CS-j)*ZC_PER_CS-1 -: ZC_PER_CS] = data_in[NUM_CS-j-1];
          end
        end
        default: begin
          for (int i = 0; i < NUM_CS; i++) begin
            data_out[i] = '0;
          end
        end
      endcase
    end

endmodule