`timescale 1ns / 1ps

module gf2_sum_tb;

    localparam int ZC_PER_CS = 96;
    localparam int NUM_CS = 4;
    localparam int DATA_W = ZC_PER_CS * NUM_CS;

    logic              clk;
    logic              rst_n;
    logic [NUM_CS-1:0] en;
    logic [DATA_W-1:0] data_in;
    logic [DATA_W-1:0] data_out;

    logic [ZC_PER_CS-1:0] out3, out2, out1, out0;
    assign {out3, out2, out1, out0} = data_out;

    gf2_sum #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .data_in  (data_in),
        .data_out (data_out)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns period (100 MHz)
    end

    initial begin
        rst_n   = 0;
        en      = '0;
        data_in = '0;

        $display("=========================================================");
        $display("Starting GF(2) Accumulator Testbench...");
        $display("=========================================================");

        #15;
        rst_n = 1;
        
        @(posedge clk); #1; 

        $display("\n--- Test 1: Initial Load (en = 4'b1111) ---");
        data_in = { {24{4'hA}}, {24{4'hB}}, {24{4'hC}}, {24{4'hD}} };
        en      = 4'b1111;
        
        @(posedge clk); #1; // Wait for flip-flops to capture
        $display("Out3 = %x", out3);
        $display("Out2 = %x", out2);
        $display("Out1 = %x", out1);
        $display("Out0 = %x", out0);

        $display("\n--- Test 2: Accumulate / XOR (en = 4'b1111) ---");
        data_in = { {24{4'h1}}, {24{4'h2}}, {24{4'h3}}, {24{4'h4}} };
        en      = 4'b1111;
        
        @(posedge clk); #1;
        $display("Out3 = %x  (Expected B...)", out3);
        $display("Out2 = %x  (Expected 9...)", out2);
        $display("Out1 = %x  (Expected F...)", out1);
        $display("Out0 = %x  (Expected 9...)", out0);

        $display("\n--- Test 3: Selective Enable (en = 4'b0101) ---");
        data_in = { {24{4'hF}}, {24{4'hF}}, {24{4'hF}}, {24{4'hF}} };
        en      = 4'b0101; 
        
        @(posedge clk); #1;
        $display("Out3 = %x  (HELD)", out3);
        $display("Out2 = %x  (XOR'd with F)", out2);
        $display("Out1 = %x  (HELD)", out1);
        $display("Out0 = %x  (XOR'd with F)", out0);

        $display("\n--- Test 4: Disable All (en = 4'b0000) ---");
        data_in = { {24{4'h8}}, {24{4'h8}}, {24{4'h8}}, {24{4'h8}} };
        en      = 4'b0000;
        
        @(posedge clk); #1;
        $display("Out3 = %x  (HELD)", out3);
        $display("Out2 = %x  (HELD)", out2);
        $display("Out1 = %x  (HELD)", out1);
        $display("Out0 = %x  (HELD)", out0);

        $display("=========================================================");
        $display("Simulation Complete.");
        $finish;
    end

endmodule