`timescale 1ns / 1ps

module core_parity_bit_calculator_tb;

    localparam int ZC_PER_CS = 96;
    localparam int NUM_CS = 4;
    localparam int BUS_W  = NUM_CS * ZC_PER_CS;

    logic                               clk;
    logic                               rst_n;
    logic [NUM_CS-1:0] en;
    logic                               base_graph;
    logic [8:0]                         z;
    logic [NUM_CS-1:0][BUS_W-1:0]       data_in;
    logic [NUM_CS-1:0][BUS_W-1:0]       data_out;

    core_parity_bit_calculator #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en(en),
        .base_graph (base_graph),
        .z          (z),
        .data_in    (data_in),
        .data_out   (data_out)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz clock
    end

    task run_test(input logic test_bg, input logic [8:0] test_z);
        begin
            base_graph = test_bg;
            z          = test_z;

            data_in[3] = '0; data_in[3][BUS_W-1] = 1'b1; 
            data_in[2] = '0; data_in[2][BUS_W-5] = 1'b1;
            data_in[1] = '0; data_in[1][BUS_W-9] = 1'b1;
            data_in[0] = '0; data_in[0][BUS_W-13] = 1'b1;

            en = '1;

            // Wait for clock edge to register inputs
            @(posedge clk);
            #1; // Wait 1 time unit for combinational outputs to settle
            
            $display("---------------------------------------------------------");
            $display("TEST CASE: base_graph = %b | z = %0d", base_graph, z);
            $display("---------------------------------------------------------");
            
            $display("data_out[3] [95:80] : %b", data_out[3][BUS_W-1 -: 16]);
            $display("data_out[2] [95:80] : %b", data_out[2][BUS_W-1 -: 16]);
            $display("data_out[1] [95:80] : %b", data_out[1][BUS_W-1 -: 16]);
            $display("data_out[0] [95:80] : %b", data_out[0][BUS_W-1 -: 16]);
        end
    endtask

    initial begin
        // Initialize
        rst_n      = 0;
        base_graph = 0;
        z          = 0;
        data_in    = '0;

        $display("Starting Core Parity Bit Calculation Testbench (MSB Monitoring)...");

        #15;
        rst_n = 1;
        @(posedge clk);

        $display("\n>>> Testing Base Graph 0");
        run_test(1'b0, 9'd96);
        run_test(1'b0, 9'd192);
        run_test(1'b0, 9'd384);

        $display("\n>>> Testing Base Graph 1");
        run_test(1'b1, 9'd96);
        run_test(1'b1, 9'd192);
        run_test(1'b1, 9'd384);

        $display("=========================================================");
        $display("Simulation Complete.");
        $finish;
    end

endmodule