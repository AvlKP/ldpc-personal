import ldpc_pkg::*;

module pc_rearrange #(
  parameter int ZC_PER_CS = 96,
  parameter int NUM_CS = 4
)(
    input logic [NUM_CS-1:0][$clog2(NUM_CS)-1:0] pc_sel,
    input zc_group_t d,
    input logic [NUM_CS-1:0][ZC_MAX-1:0] pc_in,
    output logic [NUM_CS-1:0][ZC_PER_CS-1:0] pc_out
);

  always_comb begin
    case (d)
      ZC_SMALL:
        // parity_core is LSB-packed: active Zc bits in [Zc-1:0].
        // Take the bottom 96 bits of the selected parity_core word.
        for (int i = 0; i < NUM_CS; i++) begin
          pc_out[i] = pc_in[pc_sel[i]][ZC_PER_CS-1:0];
        end
      ZC_MEDIUM: begin
        // Bottom 192 bits: lane 0 at [95:0], lane 1 at [191:96].
        pc_out[0] = pc_in[pc_sel[0]][ZC_PER_CS-1 -: ZC_PER_CS];
        pc_out[1] = pc_in[pc_sel[0]][2*unsigned'(ZC_PER_CS)-1 -: ZC_PER_CS];
        pc_out[2] = pc_in[pc_sel[2]][ZC_PER_CS-1 -: ZC_PER_CS];
        pc_out[3] = pc_in[pc_sel[2]][2*unsigned'(ZC_PER_CS)-1 -: ZC_PER_CS];
      end
      ZC_LARGE:
        // Full 384 bits used; existing mapping already puts lane 0 at [95:0].
        for (int i = 0; i < NUM_CS; i++) begin
          pc_out[NUM_CS-1-i] = pc_in[pc_sel[0]][unsigned'(ZC_MAX)-1-unsigned'(i*ZC_PER_CS) -: ZC_PER_CS];
        end
      default: begin
        pc_out = '0;
      end
    endcase
  end

endmodule