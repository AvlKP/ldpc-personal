import ldpc_pkg::*;

// INPUT BUFFER
// takes an AXI Stream input of code block that is to be processed by LDPC core
// takes several configuration signals from control registers
// can take the next code block to be processed before current one is done
// outputs a 384-bit data that is cleared on handshake
// output can be:
// - 1 384-bit vector
// - 2 192-bit vectors
// - 4 96-bit vectors
// multiple vector output contain the same data
// output vectors might contain extra data that is not part of the Zc-bit info group

module input_buffer #(
  // recalculate as needed
  localparam int unsigned DATA_WIDTH = 32
) (
  input logic clk_i,
  input logic arst_ni,

  // AXI Stream
  input  logic [DATA_WIDTH-1:0] s_axis_tdata,
  input  logic s_axis_tvalid,
  output logic s_axis_tready,

  // use positive edge of transition when done processing to clear read buffer
  input logic ldpc_clear_i,
  // a valid input is available for read
  output logic ldpc_valid_o,

  // FROM CONFIG REG
  // store in inner register local to each RAM
  // change upon first AXIS handshake after counter >= input_bits_i
  input logic [ZC_WIDTH-1:0] lifting_size_i,
  // store in inner register
  // change upon first AXIS handshake after counter >= input_bits_i
  input logic [15:0] input_bits_i, 
  input logic [15:0] output_bits_i,
  input logic base_graph_i,

  // PASS TO CORE
  output logic [ZC_WIDTH-1:0] lifting_size_o,
  output logic [15:0] input_bits_o, 
  output logic [15:0] output_bits_o,
  output logic base_graph_o,

  // store in inner register
  // change upon LDPC inner handshake
  input logic [KB_WIDTH-1:0] info_group_sel_i,
  output logic [ZC_MAX-1:0] info_group_o
);

localparam int unsigned ACCUM_SIZE = ZC_MAX + DATA_WIDTH;
localparam int unsigned ACCUM_WIDTH = $clog2(ACCUM_SIZE);
localparam int unsigned COUNTER_WIDTH = $clog2(INPUT_BITS_MAX/DATA_WIDTH);

logic [ACCUM_SIZE-1:0] accum_data_q;
logic [ACCUM_WIDTH-1:0] accum_count_q;

logic [1:0] ram_full_q;
logic ram_bg_q [0:1];
logic [ZC_WIDTH-1:0] ram_zc_q [0:1];
logic [15:0] ram_input_bits_q [0:1];
logic [15:0] ram_output_bits_q [0:1];

logic w_swap_q;
logic [ZC_MAX-1:0] w_mask, w_data;
logic [KB_WIDTH-1:0] w_addr_q;
logic [COUNTER_WIDTH-1:0] w_limit_q, w_cnt_q;

logic r_swap_q;
logic [KB_WIDTH-1:0] r_addr;
logic [ZC_MAX-1:0] r_data [0:1];

typedef enum  { 
  W_IDLE,
  W_PACK,
  W_UNPACK,
  W_STALL
} w_state_t;
w_state_t w_state_n, w_state_q;

logic axis_handshake;
assign axis_handshake = s_axis_tready & s_axis_tvalid;

// --------------------------------------------------------
// Optimized Output Control Logic (Decoupled from w_state_n)
// --------------------------------------------------------
assign tran_en         = axis_handshake; 
assign accum_to_ram_en = (accum_count_q >= ram_zc_q[w_swap_q]);

assign tran_init       = (w_state_q == W_IDLE) & axis_handshake;
assign tran_done       = ((w_state_q == W_PACK) | (w_state_q == W_UNPACK)) 
                       & (accum_count_q < ram_zc_q[w_swap_q]) 
                       & (w_cnt_q >= w_limit_q);

assign stall_en        = (ram_full_q == 2'b11);

// s_axis_tready cleanly defines when the module can accept data
assign s_axis_tready   = (w_cnt_q < w_limit_q)
                       & (accum_count_q < ram_zc_q[w_swap_q])
                       & ~stall_en;

// --------------------------------------------------------
// FSM State Transition Logic
// --------------------------------------------------------
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    w_state_q <= W_IDLE;
  end else begin
    w_state_q <= w_state_n;
  end
end

always_comb begin
  // Use unique case for optimal LUT synthesis and latch prevention
  unique case (w_state_q)
    W_IDLE:
      if (axis_handshake) w_state_n = W_PACK;
      else                w_state_n = W_IDLE;
      
    W_PACK: 
      if (accum_count_q >= ram_zc_q[w_swap_q]) w_state_n = W_UNPACK;
      else if (w_cnt_q >= w_limit_q)           w_state_n = W_IDLE;
      else if (axis_handshake)                 w_state_n = W_PACK;
      else                                     w_state_n = W_STALL;
      
    W_UNPACK:
      if (accum_count_q >= ram_zc_q[w_swap_q]) w_state_n = W_UNPACK;
      else if (w_cnt_q >= w_limit_q)           w_state_n = W_IDLE;
      else if (axis_handshake)                 w_state_n = W_PACK;
      else                                     w_state_n = W_STALL;
      
    W_STALL:
      if (axis_handshake) w_state_n = W_PACK;
      else                w_state_n = W_STALL;
      
    default: 
      // Safe state recovery pattern
      w_state_n = W_IDLE; 
  endcase
end

// RAM Control
always_ff @(posedge clk_i or negedge arst_ni) begin : ram_control
  if (!arst_ni) begin
    w_limit_q <= '1;

    ram_full_q <= 2'b00;

    for (int unsigned i = 0; i < 2; i++) begin
      ram_zc_q[i] <= '1;
      ram_bg_q[i] <= 0;
      ram_input_bits_q[i] <= 0;
      ram_output_bits_q[i] <= 0;
    end

    w_swap_q <= 0;
    r_swap_q <= 0;
  end else begin
    for (int unsigned i = 0; i < 2; i++) begin
      if (ldpc_clear_i & (r_swap_q == i)) begin
        ram_zc_q[i] <= '1;
        ram_bg_q[i] <= 0;
        ram_input_bits_q[i] <= 0;
        ram_output_bits_q[i] <= 0;
      end 
      else if (tran_init & (w_swap_q == i)) begin
        ram_zc_q[i] <= lifting_size_i;
        ram_bg_q[i] <= base_graph_i;
        ram_input_bits_q[i] <= input_bits_i;
        ram_output_bits_q[i] <= output_bits_i;
      end 

      if (ldpc_clear_i & (r_swap_q == i)) ram_full_q[i] <= 0;
      else if (tran_done & (w_swap_q == i)) ram_full_q[i] <= 1; 
    end

    if (tran_init) 
      w_limit_q <= COUNTER_WIDTH'((input_bits_i + 16'(DATA_WIDTH - 1))
                                  >> $clog2(DATA_WIDTH));
    else if (tran_done) w_limit_q <= '1;
  
    if (ldpc_clear_i) r_swap_q <= ~r_swap_q;
    if (tran_done) w_swap_q <= ~w_swap_q;
  end
end

// Write logic
always_ff @(posedge clk_i or negedge arst_ni) begin
  if (!arst_ni) begin
    accum_data_q <= '0;
    accum_count_q <= '0;
    w_addr_q <= '0;

    w_cnt_q <= '0;
  end else if (tran_done) begin
    accum_data_q <= '0;
    accum_count_q <= '0;
    w_addr_q <= '0;

    w_cnt_q <= '0;    
  end else begin
    if (accum_to_ram_en) begin
      accum_count_q <= accum_count_q - ram_zc_q[w_swap_q];
      accum_data_q <= accum_data_q >> ram_zc_q[w_swap_q];
      w_addr_q <= w_addr_q + 1;
    end
    else if (tran_en) begin
      accum_data_q <= accum_data_q 
                    | (ACCUM_SIZE'(s_axis_tdata) << accum_count_q);
      accum_count_q <= accum_count_q + ACCUM_WIDTH'(DATA_WIDTH);
    end

    if (tran_en) begin
      w_cnt_q <= w_cnt_q + 1;    
    end
  end
end

assign w_mask = (ZC_MAX'(1'b1) << ram_zc_q[w_swap_q]) - 1'b1;
assign w_data = accum_data_q[ZC_MAX-1:0] & w_mask;

// RAM instances
generate
  genvar i;
  for (i = 0; i < 2; i++) begin : ram_gen
    logic we;
    assign we = accum_to_ram_en & (w_swap_q == i);

    lutram #(
      .WORD_WIDTH(ZC_MAX),
      .SIZE      (KB_BG1),
      .NUM_RPORTS(1),
      .MEM_INIT  (),
      .MERGE_ADDR(0)
     ) lutram (
      .clk_i  (clk_i),
      .we     (we),
      .waddr_i(w_addr_q),
      .din_i  (w_data),
      .raddr_i(r_addr),
      .dout_o (r_data[i])
    );
  end
endgenerate

// // Read logic
// logic [1:0] out_sel; // select data_batch size according to zc
// assign out_sel[1] = (ram_zc_q[r_swap_q] > ZC_MAX >> 1); // zc > 192
// assign out_sel[0] = (ram_zc_q[r_swap_q] > ZC_MAX >> 2); // zc > 96

assign r_addr = info_group_sel_i;
assign ldpc_valid_o = ram_full_q[r_swap_q];

always_ff @(posedge clk_i) begin : out_selector
  if (!arst_ni) begin
    info_group_o <= '0;
    lifting_size_o <= '0;
    input_bits_o <= '0;
    output_bits_o <= '0;
    base_graph_o <= 0;
  end else begin
    // case (out_sel)
    //   2'b00: begin
    //     for (int unsigned j = 0; j < 4; j++) begin
    //       info_group_o[(ZC_MAX >> 2)*j +: (ZC_MAX >> 2)] 
    //         <= {r_data[r_swap_q]}[0 +: (ZC_MAX >> 2)];
    //     end
    //   end
    //   2'b01: begin
    //     for (int unsigned j = 0; j < 2; j++) begin
    //       info_group_o[(ZC_MAX >> 1)*j +: (ZC_MAX >> 1)] 
    //         <= {r_data[r_swap_q]}[0 +: (ZC_MAX >> 1)];
    //     end
    //   end
    //   2'b11: info_group_o <= r_data[r_swap_q];
    //   default: info_group_o <= '0;
    // endcase
    // Left-align the Zc active bits into the MSB of the ZC_MAX-wide slot
    info_group_o <= r_data[r_swap_q] << (ZC_MAX - ram_zc_q[r_swap_q]);
    lifting_size_o <= ram_zc_q[r_swap_q];
    input_bits_o <= ram_input_bits_q[r_swap_q];
    output_bits_o <= ram_output_bits_q[r_swap_q];
    base_graph_o <= ram_bg_q[r_swap_q];
  end
end

endmodule
