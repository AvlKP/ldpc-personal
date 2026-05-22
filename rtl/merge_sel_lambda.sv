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
          for (int i = 0; i < NUM_CS; i++) begin
            data_out[i][ZC_MAX-1 -: ZC_PER_CS] = data_in[i];
          end
        end
        ZC_MEDIUM: begin
          for (int j = 0; j < NUM_CS/2; j++) begin
            data_out[2*d_cycle][(NUM_CS-j)*ZC_PER_CS-1 -: ZC_PER_CS] = data_in[NUM_CS-j-3];
            data_out[2*d_cycle+1][(NUM_CS-j)*ZC_PER_CS-1 -: ZC_PER_CS] = data_in[NUM_CS-j-1];
          end
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