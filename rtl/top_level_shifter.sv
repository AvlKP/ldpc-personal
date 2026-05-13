import ldpc_pkg::*;

module top_level_shifter #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    input  logic [NUM_CS*ZC_PER_CS-1:0] data_in,
    input  logic [8:0]               z,
    input  logic [NUM_CS-1:0][8:0]               p,
    output logic [NUM_CS*ZC_PER_CS-1:0] data_out,
    input  logic [1:0] d
    // output cases_e d
);
    
    // From parameter_calculation
    logic [NUM_CS-1:0][1:0] p_mod_d;
    logic [6:0] z_per_d;
    logic [NUM_CS-1:0][6:0] q;
    logic [NUM_CS-1:0][6:0] q_plus;

    // Pipeline interconnects
    logic [NUM_CS*ZC_PER_CS-1:0]        dbp_fwd_out;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0]   gr_in;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0]   gr_out;
    logic [NUM_CS-1:0]               use_q_plus;
    logic [NUM_CS-1:0][ZC_PER_CS-1:0]   shifter_out;
    logic [NUM_CS*ZC_PER_CS-1:0]        dbp_rev_in;

    parameter_calculation #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) param_calc_inst (
        .z       (z),
        .p       (p),
        .d       (d),
        .p_mod_d (p_mod_d),
        .z_per_d (z_per_d),
        .q       (q),
        .q_plus  (q_plus)
    );

    direct_bit_permutation #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS),
        .is_reverse(0)
    ) dbp_fwd_inst (
        .data_in  (data_in),
        .d        (d),
        .data_out (dbp_fwd_out)
    );

    // Cast
    assign gr_in = {>>{dbp_fwd_out}};

    group_reordering #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS)
    ) gr_inst (
        .data_in  (gr_in),
        .d        (d),
        .p_mod_d  (p_mod_d),
        .use_q_plus(use_q_plus),
        .data_out (gr_out)
    );

    genvar i;
    generate
        for (i = 0; i < NUM_CS; i++) begin : gen_shifters
            
            logic [6:0] actual_shift_amt;
            // Select between q and q_plus for this specific shifter TODO get `use_q_plus` from group reordering
            assign actual_shift_amt = use_q_plus[i] ? q_plus[i] : q[i];

            barrel_shifter #(
                .ZC_PER_CS(ZC_PER_CS)
            ) shifter_inst (
                .data_in   (gr_out[i]),
                .zc_in     (z_per_d),
                .shift_amt (actual_shift_amt),
                .direction (1'b0),
                .data_out  (shifter_out[i])
            );
        end
    endgenerate

    // Cast back
    assign dbp_rev_in = {>>{shifter_out}};

    direct_bit_permutation #(
        .ZC_PER_CS(ZC_PER_CS),
        .NUM_CS(NUM_CS),
        .is_reverse(1)
    ) dbp_rev_inst (
        .data_in  (dbp_rev_in),
        .d        (d),
        .data_out (data_out)
    );

endmodule