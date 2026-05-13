module core_parity_bit_calculator #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    input logic clk,
    input logic rst_n,
    input logic [NUM_CS-1:0] en,
    input logic base_graph,
    input  logic [8:0] z,
    input logic [NUM_CS-1:0][NUM_CS*ZC_PER_CS-1:0] data_in,
    output logic [NUM_CS-1:0][NUM_CS*ZC_PER_CS-1:0] data_out
);
    logic [NUM_CS-1:0][NUM_CS*ZC_PER_CS-1:0] data_in_reg;
    logic [NUM_CS*ZC_PER_CS-1:0] cs_in, cs_out;

    barrel_shifter #(
        .ZC_PER_CS(NUM_CS*ZC_PER_CS)
    ) shifter_inst (
        .data_in   (cs_in),
        .zc_in     (z),
        .shift_amt (1),
        .direction(base_graph),
        .data_out  (cs_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in_reg <= '0;
        end else begin
            for (int i = 0; i < NUM_CS; i++) begin
                if (en[i]) begin
                    data_in_reg[i] <= data_in[i];
                end
            end
        end
    end

    always_comb begin
      cs_in = data_in_reg[3] ^ data_in_reg[2] ^ data_in_reg[1] ^ data_in_reg[0];
      data_out[3] = base_graph ? cs_out : cs_in;
      data_out[2] = data_in_reg[3] ^ cs_out;
      data_out[0] = cs_out ^ data_in_reg[0];
      data_out[1] = base_graph ? (data_out[2] ^ data_in_reg[2]) : (data_out[0] ^ data_in_reg[1]);
    end

endmodule