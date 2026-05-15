// Assuming ldpc_pkg contains ZC_MAX, BG1_WEFF, etc.
import ldpc_pkg::*;

module ldpc_encoder_core_tb();

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int ZC_PER_CS       = 96;
    localparam int NUM_CS          = 4;
    localparam int OUTPUT_BITS_MAX = 26112;
    
    // Fallback parameters (in case they aren't in the package)
    localparam int ZC_MAX          = 384; 
    localparam int BG1_WEFF        = 26;

    // =========================================================================
    // Signals
    // =========================================================================
    logic                                clk;
    logic                                rst_n;
    
    logic                                start;
    logic                                done;
    
    logic [8:0]                          z;
    logic [NUM_CS-1:0][8:0]              p;
    logic                                base_graph;
    
    logic [NUM_CS-1:0]                   data_in_sel;
    logic [$clog2(BG1_WEFF)-1:0]         next_col_ctr;
    logic                                row_ctr_en;
    int unsigned row_ctr;
    logic [NUM_CS-1:0]                   gf2_en;
    logic [$clog2(NUM_CS)-1:0]           pc_sel;
    logic [NUM_CS-1:0]         rand_gf2_en;
    logic [NUM_CS-1:0]         rand_data_in_sel;
    logic [$clog2(NUM_CS)-1:0] rand_pc_sel;
    
    int unsigned                         next_val;

    logic [ZC_MAX-1:0]                   data_in;
    logic [INPUT_BITS_MAX-1:0]           full_data_in;
    logic [ZC_MAX-1:0]                   full_data_in_packed[INPUT_BITS_MAX/ZC_MAX-1:0];
    logic [INPUT_BITS_MAX-1:0]           rand_full_data;
    logic [INPUT_BITS_MAX-1:0]           shifted_full;
    logic [ZC_MAX-1:0]                   generic_chunk;
    logic [ZC_MAX-1:0]                   data_out [OUTPUT_BITS_MAX/ZC_MAX-1:0];
    logic [OUTPUT_BITS_MAX-1:0]          data_out_unpacked;
    logic                                tb_active; // Flag to enable randomized generation

    // =========================================================================
    // Device Under Test (DUT)
    // =========================================================================
    ldpc_encoder_core #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS),
        .OUTPUT_BITS_MAX(OUTPUT_BITS_MAX)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .z(z),
        .p(p),
        .base_graph(base_graph),
        .data_in_sel(data_in_sel),
        .next_col_ctr(next_col_ctr),
        .row_ctr_en(row_ctr_en),
        .gf2_en(gf2_en),
        .pc_sel(pc_sel),
        .data_in(data_in),
        .data_out(data_out_unpacked)
    );

    genvar i;
    generate
        for (i = 0; i < OUTPUT_BITS_MAX/ZC_MAX; i++) begin : data_out_unpack_loop
            assign data_out[i] = data_out_unpacked[ (i+1)*ZC_MAX - 1 : i*ZC_MAX ];
        end
    endgenerate
    generate
        for (i = 0; i < INPUT_BITS_MAX/ZC_MAX; i++) begin : data_in_pack_loop
            assign full_data_in_packed[i] = full_data_in[ (i+1)*ZC_MAX - 1 : i*ZC_MAX ];
        end
    endgenerate

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        // 1. Initialize Default Values
        rst_n        = 0;
        start        = 0;
        tb_active    = 0;
        
        z            = 9'd0;
        base_graph   = 1'b0;
        

        // 2. Apply Reset
        #20;
        rst_n = 1;
        #10;
        
        @(posedge clk);
        
        // --- Test CASE_A (Z <= 96) ---
        $display("Testing CASE_A (Z=8)");
        z          = 9'd8;  // Multiple of 4
        base_graph = 1'b0;
        void'(std::randomize(rand_full_data));
        full_data_in = rand_full_data & ~( {INPUT_BITS_MAX{1'b1}} >> (22*int'(z)) );
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        tb_active = 1'b1;
        repeat (100) @(posedge clk);
        tb_active = 1'b0;

        // Reset for next test
        rst_n = 0;
        #20;
        rst_n = 1;
        #10;
        @(posedge clk);

        // --- Test CASE_B (96 < Z <= 192) ---
        $display("Testing CASE_B (Z=128)");
        z          = 9'd128; // Multiple of 4
        base_graph = 1'b0;
        void'(std::randomize(rand_full_data));
        full_data_in = rand_full_data & ~( {INPUT_BITS_MAX{1'b1}} >> (22*int'(z)) );
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        tb_active = 1'b1;
        repeat (100) @(posedge clk);
        tb_active = 1'b0;

        // Reset for next test
        rst_n = 0;
        #20;
        rst_n = 1;
        #10;
        @(posedge clk);

        // --- Test CASE_C (Z > 192) ---
        $display("Testing CASE_C (Z=256)");
        z          = 9'd256; // Multiple of 4
        base_graph = 1'b0;
        void'(std::randomize(rand_full_data));
        full_data_in = rand_full_data & ~( {INPUT_BITS_MAX{1'b1}} >> (22*int'(z)) );
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        tb_active = 1'b1;
        repeat (100) @(posedge clk);
        tb_active = 1'b0;
        
        $display("Simulation complete.");
        $finish;
    end

    // =========================================================================
    // Cycle-by-Cycle Randomization Logic
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            next_col_ctr <= '0;
            row_ctr_en   <= 1'b0;
            data_in      <= '0; // Good practice to reset your stimulus
            row_ctr      <= '0;
            next_val <= '0;
        end 
        else if (tb_active) begin
            
            // Randomize p array
            for (int i = 0; i < NUM_CS; i++) begin
                p[i] <= $urandom_range(0, z-1);
            end

            // --- NEW data_in BEHAVIOR ---
            shifted_full = full_data_in << (next_col_ctr * int'(z));
            
            // Extract ZC_MAX bits and mask so only the z MSBs are kept
            generic_chunk = shifted_full[INPUT_BITS_MAX-1 -: ZC_MAX] & ~( {ZC_MAX{1'b1}} >> int'(z) );
            
            if (z <= 96) begin
                data_in <= {4{generic_chunk[ZC_MAX-1 : ZC_MAX-96]}};
            end 
            else if (z <= 192) begin
                data_in <= {2{generic_chunk[ZC_MAX-1 : ZC_MAX-192]}};
            end 
            else begin
                data_in <= generic_chunk;
            end
            // ----------------------------

            // Constrained Randomization for interrelated control signals
            void'(std::randomize(rand_gf2_en, rand_data_in_sel, rand_pc_sel) with {
                (rand_data_in_sel | rand_gf2_en) == rand_gf2_en;
                
                if (rand_data_in_sel == 0) {
                    rand_pc_sel == 0;
                } else {
                    rand_pc_sel > 0;
                    rand_pc_sel <= 3;
                }

                if (row_ctr < 4) {
                    rand_data_in_sel == '0;
                }
            });

            gf2_en      <= rand_gf2_en;
            data_in_sel <= rand_data_in_sel;
            pc_sel      <= rand_pc_sel;

            next_val = next_col_ctr + ((row_ctr == 0) ? 1 : $urandom_range(1, 3));
            
            if (next_val >= (base_graph ? BG2_WEFF - 4 : BG1_WEFF - 4)) begin // Assume that the 4 leftmost non trivial columns doesn't exists
                next_col_ctr <= $urandom_range(0, 3);
                row_ctr_en   <= 1'b1;
                if (z <= 96) begin
                    row_ctr <= row_ctr + 4;
                end 
                else if (z <= 192) begin
                    row_ctr <= row_ctr + 2;
                end 
                else begin
                    row_ctr <= row_ctr + 1;
                end
            end else begin
                next_col_ctr <=  next_val;
                row_ctr_en   <= 1'b0;
            end
            
        end
    end

endmodule