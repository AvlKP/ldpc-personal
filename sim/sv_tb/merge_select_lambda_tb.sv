`timescale 1ns / 1ps
import ldpc_pkg::*;

module tb_merge_select_lambda;

    localparam int ZC_PER_CS = 96;
    localparam int NUM_CS = 4;
    localparam int OUT_WIDTH = NUM_CS * ZC_PER_CS;

    cases_e                                 d;
    logic [1:0]                                 d_cycle;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0]              data_in;
    logic [NUM_CS-1:0][OUT_WIDTH-1:0]           data_out;

    merge_select_lambda #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) dut (
        .d        (d),
        .d_cycle  (d_cycle),
        .data_in  (data_in),
        .data_out (data_out)
    );

    task run_test(input cases_e test_d, input logic [1:0] test_d_cycle);
        begin
            d       = test_d;
            d_cycle = test_d_cycle;
            
            #5; // Wait for combinational logic to settle
            
            $display("==========================================================================");
            $display("TEST CASE: d = 2'b%b, d_cycle = %0d", d, d_cycle);
            $display("--------------------------------------------------------------------------");
            
            for (int i = 0; i < NUM_CS; i++) begin
                $display("data_out[%0d] = %x", i, data_out[i]);
            end
        end
    endtask

    initial begin
        data_in[0] = {24{4'hA}}; // AAAAAAAAAAAAAAAAAAAAAAAA
        data_in[1] = {24{4'hB}}; // BBBBBBBBBBBBBBBBBBBBBBBB
        data_in[2] = {24{4'hC}}; // CCCCCCCCCCCCCCCCCCCCCCCC
        data_in[3] = {24{4'hD}}; // DDDDDDDDDDDDDDDDDDDDDDDD

        $display("\nStarting merge_select_lambda Testbench...");
        $display("Input mapping:");
        $display("data_in[0] = %x", data_in[0]);
        $display("data_in[1] = %x", data_in[1]);
        $display("data_in[2] = %x", data_in[2]);
        $display("data_in[3] = %x\n", data_in[3]);

        run_test(CASE_A, 2'b00);

        run_test(CASE_B, 2'b00); // Writes to data_out[0] and data_out[1]
        run_test(CASE_B, 2'b01); // Writes to data_out[2] and data_out[3]

        run_test(CASE_C, 2'b00); // Packs into data_out[0]
        run_test(CASE_C, 2'b01); // Packs into data_out[1]
        run_test(CASE_C, 2'b10); // Packs into data_out[2]
        run_test(CASE_C, 2'b11); // Packs into data_out[3]

        $display("==========================================================================");
        $display("Simulation Complete.");
        $finish;
    end

endmodule