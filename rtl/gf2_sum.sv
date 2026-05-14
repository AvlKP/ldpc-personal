module gf2_sum #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    input  logic                                 clk,
    input  logic                                 rst_n,
    input logic clr,
    input  logic [NUM_CS-1:0]                    en,
    input  logic [NUM_CS*ZC_PER_CS-1:0]             data_in,
    output logic [NUM_CS*ZC_PER_CS-1:0]             data_out
);

    logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_in_2d;
    assign data_in_2d = data_in;

    logic [NUM_CS-1:0][ZC_PER_CS-1:0] comb_sum;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_out_internal;

    always_comb begin
        for (int i = 0; i < NUM_CS; i++) begin
            comb_sum[i] = data_in_2d[i] ^ data_out_internal[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out_internal <= '0;
        end else begin
            if (clr) begin
                for (int i = 0; i < NUM_CS; i++) begin
                    data_out_internal[i] <= data_in_2d[i];
                end
            end else begin
                for (int i = 0; i < NUM_CS; i++) begin
                    if (en[i]) begin
                        data_out_internal[i] <= comb_sum[i];
                    end
                end
            end
        end
    end

    assign data_out = data_out_internal;

endmodule