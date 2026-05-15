`timescale 1ns/1ps

module tb_barrel_shifter;

    // Parameters
    parameter int ZC_PER_CS = 96;  // Maximum size of the barrel shifter
    logic [31:0] Zc;  // Small value for easier visualization

    // Testbench signals
    logic [ZC_PER_CS-1:0] data_in;
    logic [6:0] shift_amt;
    logic direction;
    logic [ZC_PER_CS-1:0] data_out;

    // DUT instantiation
    barrel_shifter #(.ZC_PER_CS(ZC_PER_CS)) dut (
        .data_in(data_in),
        .zc_in(Zc),
        .shift_amt(shift_amt),
        .direction(direction),
        .data_out(data_out)
    );

    // Test procedure
    initial begin
        $display("=== Barrel Shifter Testbench ===");

        direction = 0;

        // Case 1: No shift
        Zc = 32'd8;  // Set a small value for easier visualization
        data_in = 96'h5a5a5a5a1234567887654321;
        shift_amt = 7'b0000000;
        #1 
        // Case 2: Right shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 3: Left shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 4: Full wrap (shift = Zc)
        shift_amt = Zc;
        #1 
        
        // Case 5: shift_amt = -1 (expect all 0s)
        shift_amt = 7'b0111111;  // This is a special case
        #1
        
        // Case 6: shift by Zc - 1
        shift_amt = Zc - 1;
        #1 

                // Case 1: No shift
        Zc = 32'd96;  // Set a small value for easier visualization
        data_in = 96'h5a5a5a5a1234567887654321;
        shift_amt = 7'b0000000;
        #1 
        // Case 2: Right shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 3: Left shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 4: Full wrap (shift = Zc)
        shift_amt = Zc;
        #1 
        
        // Case 5: shift_amt = -1 (expect all 0s)
        shift_amt = 7'b0111111;  // This is a special case
        #1
        
        // Case 6: shift by Zc - 1
        shift_amt = Zc - 1;
        #1 

        direction = 1;

        // Case 1: No shift
        Zc = 32'd8;  // Set a small value for easier visualization
        data_in = 96'h5a5a5a5a1234567887654321;
        shift_amt = 7'b0000000;
        #1 
        // Case 2: Right shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 3: Left shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 4: Full wrap (shift = Zc)
        shift_amt = Zc;
        #1 
        
        // Case 5: shift_amt = -1 (expect all 0s)
        shift_amt = 7'b0111111;  // This is a special case
        #1
        
        // Case 6: shift by Zc - 1
        shift_amt = Zc - 1;
        #1 

                // Case 1: No shift
        Zc = 32'd96;  // Set a small value for easier visualization
        data_in = 96'h5a5a5a5a1234567887654321;
        shift_amt = 7'b0000000;
        #1 
        // Case 2: Right shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 3: Left shift by 2
        shift_amt = 7'b0000010;
        #1 

        // Case 4: Full wrap (shift = Zc)
        shift_amt = Zc;
        #1 
        
        // Case 5: shift_amt = -1 (expect all 0s)
        shift_amt = 7'b0111111;  // This is a special case
        #1
        
        // Case 6: shift by Zc - 1
        shift_amt = Zc - 1;
        #1 
        
        $display("=== End of Test ===");
        $finish;
    end

endmodule
