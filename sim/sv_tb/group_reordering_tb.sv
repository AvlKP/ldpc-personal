module group_reordering_tb();

    localparam int ZC_PER_CS = 96;
    localparam int NUM_CS = 4;

    logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_in;
    logic [1:0]                    d;
    logic [1:0]                    p_mod_d;
    logic [NUM_CS-1:0]             use_q_plus;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0] data_out;

    group_reordering #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) dut (
        .data_in (data_in),
        .d       (d),
        .p_mod_d (p_mod_d),
        .use_q_plus(use_q_plus),
        .data_out(data_out)
    );

    task print_state(string test_name);
        $display("-------------------------------------------------");
        $display("TEST: %s | d: %2b | p_mod_d: %0d", test_name, d, p_mod_d);
        // Printing indices [0, 1, 2, 3] from left to right for easier reading
        $display("  IN : [ %0d, %0d, %0d, %0d ]", data_in[0], data_in[1], data_in[2], data_in[3]);
        $display("  OUT: [ %0d, %0d, %0d, %0d ]", data_out[0], data_out[1], data_out[2], data_out[3]);
    endtask

    initial begin
        // Dummy data
        data_in[0] = 96'd11; 
        data_in[1] = 96'd22;
        data_in[2] = 96'd33;
        data_in[3] = 96'd44;
        d       = '0;
        p_mod_d = '0;

        $display("\n=== Starting Group Reordering Simulation ===");

        // --- TEST CASE 1: Group Size 2 (d = 01) ---
        d = 2'b01; 
        for (int i = 0; i < 2; i++) begin
            p_mod_d = i;
            #1; // Delay of 1 time unit to allow combinational logic to resolve
            print_state($sformatf("Size 2, Shift %0d", i));
        end

        // --- TEST CASE 2: Group Size 4 (d = 10) ---
        d = 2'b10;
        for (int i = 0; i < 4; i++) begin
            p_mod_d = i;
            #1;
            print_state($sformatf("Size 4, Shift %0d", i));
        end

        // --- TEST CASE 3: Default/Bypass (d = 00 or 11) ---
        d = 2'b00; 
        p_mod_d = 2'd2; // Shouldn't matter
        #1;
        print_state("Default (d=00)");

        $display("-------------------------------------------------");
        $display("=== Simulation Complete ===\n");
        $finish;
    end

endmodule