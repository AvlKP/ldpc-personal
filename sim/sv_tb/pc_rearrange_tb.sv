import ldpc_pkg::*;

module tb_pc_rearrange();

    // --- Time Format ---
    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (Matching DUT defaults) ---
    parameter int ZC_PER_CS = 96;
    parameter int NUM_CS = 4;

    // --- Signals ---
    logic [$clog2(NUM_CS)-1:0] pc_sel;
    cases_e d;
    logic [NUM_CS-1:0][ZC_MAX-1:0] pc_in;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0] pc_out;

    // --- DUT Instantiation ---
    pc_rearrange #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) dut (
        .pc_sel(pc_sel),
        .d(d),
        .pc_in(pc_in),
        .pc_out(pc_out)
    );

    // --- Main Stimulus ---
    initial begin
        $display("=================================================");
        $display("Starting pc_rearrange Testbench");
        $display("=================================================");

        // Loop through all 3 cases in the enum (CASE_A=0, CASE_B=1, CASE_C=2)
        for (int case_idx = 0; case_idx < 3; case_idx++) begin
            d = cases_e'(case_idx);
            $display("\n=================================================");
            $display("--- Testing Mode: %s ---", d.name());
            $display("=================================================");

            // Loop through all 4 possible values of pc_sel
            for (int sel = 0; sel < NUM_CS; sel++) begin
                pc_sel = sel;
                
                // Randomize all 4x384 bits of pc_in
                void'(std::randomize(pc_in));

                // Wait 10ns for combinational logic to propagate
                #10; 

                $display("\n[pc_sel = %0d]", pc_sel);
                
                // Print the source data (broken into 96-bit chunks for easy reading)
                $display("Source Data (pc_in[%0d]):", pc_sel);
                $display("  [Chunk 0 / Top 96] : %x", pc_in[pc_sel][ZC_MAX-1 -: ZC_PER_CS]);
                $display("  [Chunk 1 / Nxt 96] : %x", pc_in[pc_sel][ZC_MAX-1-ZC_PER_CS -: ZC_PER_CS]);
                $display("  [Chunk 2 / 3rd 96] : %x", pc_in[pc_sel][ZC_MAX-1-2*ZC_PER_CS -: ZC_PER_CS]);
                $display("  [Chunk 3 / Bot 96] : %x", pc_in[pc_sel][ZC_MAX-1-3*ZC_PER_CS -: ZC_PER_CS]);

                $display("Output Mapping (pc_out):");
                // Print from 3 down to 0 to match visual MSB->LSB flow
                for (int out_idx = NUM_CS-1; out_idx >= 0; out_idx--) begin
                    $display("  -> pc_out[%0d]       : %x", out_idx, pc_out[out_idx]);
                end
                
                $display("-------------------------------------------------");
            end
        end

        $display("\n=================================================");
        $display("Simulation Complete.");
        $display("=================================================");
        $finish;
    end

endmodule