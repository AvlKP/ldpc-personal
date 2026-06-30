module core_parity_bit_calculator #(
    parameter int ZC_PER_CS = 96,
    parameter int NUM_CS = 4
)(
    input  logic                                    clk,
    input  logic                                    rst_n,
    input  logic [NUM_CS-1:0]                       en,
    input  logic                                    base_graph,
    input  logic [8:0]                              z,
    input  logic [NUM_CS-1:0][NUM_CS*ZC_PER_CS-1:0] data_in,
    output logic [NUM_CS-1:0][NUM_CS*ZC_PER_CS-1:0] data_out
);
    localparam int W = NUM_CS*ZC_PER_CS;

    logic [NUM_CS-1:0][W-1:0] data_in_reg;
    logic [W-1:0]             cs_in, cs_out;
    logic [W-1:0]             p_c1, pa_pc1;
    logic [2:0]               i_ls;
    logic [8:0]               pa_shift, pb_shift;
    logic [8:0]               shifter_amt;
    logic [8:0]               shifter_amt_q;   // shifter_amt % z, registered (frame-constant)
    logic                     shifter_dir;
    logic                     pa_active;

    // 5G NR lifting set index iLS from Z (TS 38.212 Table 5.3.2-1)
    always_comb begin
        case (z)
            9'd2,  9'd4,  9'd8,  9'd16, 9'd32, 9'd64, 9'd128, 9'd256: i_ls = 3'd0;
            9'd3,  9'd6,  9'd12, 9'd24, 9'd48, 9'd96, 9'd192, 9'd384: i_ls = 3'd1;
            9'd5,  9'd10, 9'd20, 9'd40, 9'd80, 9'd160, 9'd320:        i_ls = 3'd2;
            9'd7,  9'd14, 9'd28, 9'd56, 9'd112, 9'd224:               i_ls = 3'd3;
            9'd9,  9'd18, 9'd36, 9'd72, 9'd144, 9'd288:               i_ls = 3'd4;
            9'd11, 9'd22, 9'd44, 9'd88, 9'd176, 9'd352:               i_ls = 3'd5;
            9'd13, 9'd26, 9'd52, 9'd104, 9'd208:                      i_ls = 3'd6;
            9'd15, 9'd30, 9'd60, 9'd120, 9'd240:                      i_ls = 3'd7;
            default:                                                  i_ls = 3'd0;
        endcase
    end

    // 3GPP TS 38.212 Section 5.3.2: P_A and P_B shifts per (base_graph, i_ls)
    //   BG1 -> {pa=1, pb=0} except i_ls=6 -> {pa=0, pb=105}
    //   BG2 -> {pa=0, pb=1} except i_ls={3,7} -> {pa=1, pb=0}
    always_comb begin
        pa_shift = 9'd0;
        pb_shift = 9'd0;
        if (!base_graph) begin
            case (i_ls)
                3'd6:    begin pa_shift = 9'd0; pb_shift = 9'd105; end
                default: begin pa_shift = 9'd1; pb_shift = 9'd0;   end
            endcase
        end else begin
            case (i_ls)
                3'd3, 3'd7: begin pa_shift = 9'd1; pb_shift = 9'd0; end
                default:    begin pa_shift = 9'd0; pb_shift = 9'd1; end
            endcase
        end
    end

    // One shifter computes either p_c1 = P_B^-1 . sum_lambda (when pa=0) or
    // pa_pc1 = P_A . sum_lambda (when pb=0). For 5G NR exactly one of {pa, pb}
    // is non-zero per (BG, i_ls), so a single shifter suffices.
    //   GM _circ_shift(vec, k)            == RTL right-rotate by k
    //   p_c1   = _circ_shift(sum, Z - pb) == RTL left-rotate  by pb
    //   pa_pc1 = _circ_shift(p_c1, pa)    == RTL right-rotate by pa
    assign pa_active   = (pa_shift != 9'd0);
    assign shifter_amt = pa_active ? pa_shift : pb_shift;
    assign shifter_dir = pa_active;                 // 1=right (PA path), 0=left (P_B^-1 path)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_in_reg <= '0;
        end else begin
            for (int i = 0; i < NUM_CS; i++) begin
                if (en[i]) begin
                    data_in_reg[i] <= data_in[i];
                end
            end
        end
    end

    // shifter_amt (= pa/pb) and z are frame-constant, so shifter_amt % z never
    // changes during a frame. Register it once so the runtime modulo (a divider)
    // stays off the critical path; z is latched in LOAD, long before the first
    // CALC_PC shift, so shifter_amt_q is always settled when used. Guard z==0 to
    // avoid an x from %0 while idle.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) shifter_amt_q <= '0;
        else        shifter_amt_q <= (z != 0) ? (shifter_amt % z) : '0;
    end

    assign cs_in = data_in_reg[0] ^ data_in_reg[1] ^ data_in_reg[2] ^ data_in_reg[3];

    // PRE_NORM: shifter_amt_q is already < z, so the shifter skips its own modulo.
    barrel_shifter #(
        .ZC_PER_CS(W),
        .PRE_NORM (1'b1)
    ) shifter_inst (
        .data_in   (cs_in),
        .zc_in     (z),
        .shift_amt (shifter_amt_q),
        .direction (shifter_dir),
        .data_out  (cs_out)
    );

    // When pa!=0, pb=0: p_c1 = sum (cs_in), pa_pc1 = cs_out
    // When pa=0, pb!=0: p_c1 = cs_out,      pa_pc1 = p_c1 = cs_out
    assign p_c1   = pa_active ? cs_in : cs_out;
    assign pa_pc1 = cs_out;

    // Output mapping (preserves existing data_out[i] -> p_c{1,2,3,4} convention):
    //   data_out[3] = p_c1
    //   data_out[0] = p_c2 = pa_pc1 ^ lambda[0]
    //   data_out[2] = p_c4 = pa_pc1 ^ lambda[3]
    //   data_out[1] = p_c3 -> BG1: lambda[2] ^ p_c4 ; BG2: lambda[1] ^ p_c2
    always_comb begin
        data_out[3] = p_c1;
        data_out[0] = pa_pc1 ^ data_in_reg[0];
        data_out[2] = pa_pc1 ^ data_in_reg[3];
        data_out[1] = base_graph ? (data_out[0] ^ data_in_reg[1])
                                 : (data_out[2] ^ data_in_reg[2]);
    end

endmodule
