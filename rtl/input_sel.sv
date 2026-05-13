import ldpc_pkg::*;

module pc_rearrange #(
  parameter int ZC_PER_CS = 96,
  parameter int NUM_CS = 4
)(
    input logic [$clog2(NUM_CS)-1:0] pc_sel,
    input logic [1:0] d,
    input logic [NUM_CS-1:0][ZC_MAX-1:0] pc_in,
    output logic [NUM_CS-1:0][ZC_PER_CS-1:0] pc_out
);

  always_comb begin
    case (d)
      2'b00:
        for (int i = 0; i < NUM_CS; i++) begin
          pc_out[i] = pc_in[pc_sel][ZC_MAX-1 -: ZC_PER_CS];
        end
      2'b01: begin
        pc_out[3] = pc_in[pc_sel][unsigned'(ZC_MAX)-1 -: ZC_PER_CS];
        pc_out[2] = pc_in[pc_sel][unsigned'(ZC_MAX)-1-unsigned'(ZC_PER_CS) -: ZC_PER_CS];
        pc_out[1] = pc_in[pc_sel][unsigned'(ZC_MAX)-1 -: ZC_PER_CS];
        pc_out[0] = pc_in[pc_sel][unsigned'(ZC_MAX)-1-unsigned'(ZC_PER_CS) -: ZC_PER_CS];
      end
      2'b11:
        for (int i = 0; i < NUM_CS; i++) begin
          pc_out[NUM_CS-1-i] = pc_in[pc_sel][unsigned'(ZC_MAX)-1-unsigned'(i*ZC_PER_CS) -: ZC_PER_CS];
        end
      default: begin
        pc_out = '0;
      end
    endcase
  end

endmodule