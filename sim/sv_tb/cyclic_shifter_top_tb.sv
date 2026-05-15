`timescale 1ns / 1ps

module tb_top_level_shifter;

    localparam int MAX_ZC = 96;
    localparam int NUM_CS = 4;
    localparam int DATA_W = MAX_ZC * NUM_CS;

    logic [DATA_W-1:0] data_in;
    logic [8:0]        z;
    logic [NUM_CS-1:0][8:0]        p;
    logic [DATA_W-1:0] data_out;
    logic [1:0] d;

    top_level_shifter #(
        .MAX_ZC(MAX_ZC),
        .NUM_CS(NUM_CS)
    ) dut (
        .data_in  (data_in),
        .z        (z),
        .p        (p),
        .data_out (data_out),
        .d(d)
    );

    task run_test(
        input logic [8:0]               test_z, 
        input logic [NUM_CS-1:0][8:0]   test_p,
        input logic [DATA_W-1:0]        test_data
    );
        begin
            z       = test_z;
            p       = test_p;
            data_in = test_data;
            
            // Wait a few time units for combinational logic to settle
            #10; 
            
            $display("---------------------------------------------------------");
            $display("Test Case: Z = %0d, P = {%0d, %0d, %0d, %0d}", z, p[3], p[2], p[1], p[0]);
            $display("DATA IN  : %x", data_in);
            $display("DATA OUT : %x", data_out);
        end
    endtask

    initial begin
        // Initialize signals
        data_in = '0;
        z       = '0;
        p       = '0;

        $display("Starting Cyclic Shifter Testbench...");

        run_test(96, {9'd20, 9'd16, 9'd12, 9'd08}, 384'h123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643);
        run_test(192, {9'd36, 9'd20, 9'd32, 9'd12}, 384'h123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643);
        run_test(384, {9'd48, 9'd08, 9'd20, 9'd16}, 384'h123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643123456789ABCDEDCBA987643);

        $display("---------------------------------------------------------");
        $display("Simulation Complete.");
        $finish;
    end

endmodule