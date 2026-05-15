`timescale 1ns / 1ps

module tb_parameter_calculation;

    localparam int NUM_CS = 4;

    // Inputs
    logic [8:0] z;
    logic [NUM_CS-1:0][8:0] p;

    // Outputs
    logic [1:0] d;
    logic [NUM_CS-1:0][1:0] p_mod_d;
    logic [6:0] z_per_d;
    logic [NUM_CS-1:0][6:0] q;
    logic [NUM_CS-1:0][6:0] q_plus;

    // Instantiate the Unit Under Test (UUT)
    parameter_calculation #(
        .ZC_PER_CS(96),
        .NUM_CS(NUM_CS)
    ) dut (
        .z(z),
        .p(p),
        .d(d),
        .p_mod_d(p_mod_d),
        .z_per_d(z_per_d),
        .q(q),
        .q_plus(q_plus)
    );

    initial begin
        // Monitor outputs for debugging
        $monitor("Time=%0t | z=%0d | p={%0d, %0d, %0d, %0d} | d=%b | q={%0d, %0d, %0d, %0d} | q_plus={%0d, %0d, %0d, %0d}", 
                 $time, z, p[3], p[2], p[1], p[0], d, q[3], q[2], q[1], q[0], q_plus[3], q_plus[2], q_plus[1], q_plus[0]);

        // -----------------------------------------------------------
        // Case 1: Z <= 96 (d = 0)
        // Rule: All four Ps are independent
        // -----------------------------------------------------------
        z = 9'd50;  
        p = {9'd40, 9'd30, 9'd20, 9'd10}; // p[3]=40, p[2]=30, p[1]=20, p[0]=10
        #1;
        
        // Edge Case: Z = 96
        z = 9'd96;  
        p = {9'd44, 9'd33, 9'd22, 9'd11};
        #1;

        // -----------------------------------------------------------
        // Case 2: 96 < Z <= 192 (d = 1)
        // Rule: p[3]=p[2] and p[1]=p[0]
        // -----------------------------------------------------------
        z = 9'd100; 
        p = {9'd22, 9'd22, 9'd11, 9'd11}; // p[3]=22, p[2]=22, p[1]=11, p[0]=11
        #1;
        
        // Edge Case: Z = 97
        z = 9'd97;  
        p = {9'd20, 9'd20, 9'd10, 9'd10};
        #1;

        // Edge Case: Z = 192
        z = 9'd192; 
        p = {9'd40, 9'd40, 9'd20, 9'd20};
        #1;

        // -----------------------------------------------------------
        // Case 3: Z > 192 (d = 2)
        // Rule: p[3]=p[2]=p[1]=p[0]
        // -----------------------------------------------------------
        z = 9'd200; 
        p = {9'd15, 9'd15, 9'd15, 9'd15}; // All Ps identical
        #1;
        
        // Edge Case: Z = 193
        z = 9'd193; 
        p = {9'd40, 9'd40, 9'd40, 9'd40};
        #1;

        // Test with p at max value for q (7-bit limit)
        z = 9'd200; 
        p = {9'd511, 9'd511, 9'd511, 9'd511}; // 511 >> 2 = 127 (max for 7 bits)
        #1;

        $finish;
    end

endmodule