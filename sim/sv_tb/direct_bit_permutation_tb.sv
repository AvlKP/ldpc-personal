module direct_bit_permutation_tb();

    // 1. Testbench Parameters
    localparam int ZC_PER_CS = 96;
    localparam int NUM_CS = 4;

    // 2. Signals
    logic [NUM_CS*ZC_PER_CS-1:0] data_in;
    logic [1:0]               d;
    logic [NUM_CS*ZC_PER_CS-1:0] data_mid;     // Output of normal, input to reverse
    logic [NUM_CS*ZC_PER_CS-1:0] data_out_rev; // Final output of reverse module

    // 3a. Instantiate the Forward DUT (Normal Mode)
    direct_bit_permutation #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS),
        .is_reverse(0) // Forward mode
    ) dut_forward (
        .data_in (data_in),
        .d       (d),
        .data_out(data_mid)
    );

    // 3b. Instantiate the Reverse DUT
    direct_bit_permutation #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS),
        .is_reverse(1) // Reverse mode
    ) dut_reverse (
        .data_in (data_mid),
        .d       (d),
        .data_out(data_out_rev)
    );

    // 4. Helper Task: Prints the arrays and verifies the result
    task print_state(string test_name);
        $display("-------------------------------------------------");
        $display("TEST: %s | d: %2b", test_name, d);
        
        $display("  IN  : [ %0d, %0d, %0d, %0d ]", 
            data_in[4*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_in[3*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_in[2*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_in[1*ZC_PER_CS-1 -: ZC_PER_CS]
        );
        
        $display("  MID : [ %0d, %0d, %0d, %0d ] (Scrambled)", 
            data_mid[4*ZC_PER_CS-1 -: ZC_PER_CS],
            data_mid[3*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_mid[2*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_mid[1*ZC_PER_CS-1 -: ZC_PER_CS]
        );
        
        $display("  OUT : [ %0d, %0d, %0d, %0d ] (Restored)",
            data_out_rev[4*ZC_PER_CS-1 -: ZC_PER_CS],
            data_out_rev[3*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_out_rev[2*ZC_PER_CS-1 -: ZC_PER_CS], 
            data_out_rev[1*ZC_PER_CS-1 -: ZC_PER_CS]
        );

        // Automatic pass/fail check
        if (data_in === data_out_rev) begin
            $display("  STATUS: ** PASS ** (Data reconstructed perfectly)");
        end else begin
            $display("  STATUS: !! FAIL !! (Mismatch detected)");
        end
    endtask

    // 5. Stimulus Generation
    initial begin
        // Setup distinct asymmetric dummy data to easily track the bits
        data_in[4*ZC_PER_CS-1 -: ZC_PER_CS] = 96'hA5A5A5A5_5A5A5A5A_12345678_87654321; 
        data_in[3*ZC_PER_CS-1 -: ZC_PER_CS] = '0; 
        data_in[2*ZC_PER_CS-1 -: ZC_PER_CS] = 96'h84C2A6E1_1E6A2C48_5A5A5A5A_A5A5A5A5;
        data_in[1*ZC_PER_CS-1 -: ZC_PER_CS] = '0;
        d = '0;

        $display("\n=== Starting Permutation Verification Simulation ===");

        // --- TEST CASE 1: Group Size 2 (d = 01) ---
        #10;
        d = 2'b01; 
        #1; // Delay to allow combinational logic to resolve
        print_state("Permutation Size 2");

        // --- TEST CASE 2: Group Size 4 (d = 10) ---
        #10;
        d = 2'b10;
        #1;
        print_state("Permutation Size 4 (Hex Data)");

        // --- TEST CASE 3: Default/Bypass (d = 00) ---
        #10;
        d = 2'b00; 
        #1;
        print_state("Default Bypass (d=00)");

        $display("-------------------------------------------------");
        $display("=== Simulation Complete ===\n");
        $finish;
    end

endmodule