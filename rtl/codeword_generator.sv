import ldpc_pkg::*;

module codeword_generator (
  input logic clk_i,
  input logic arst_ni,
  
  // Upstream Encoder Core Interface
  input logic [ZC_WIDTH-1:0] lifting_size_i,
  input zc_group_t zc_group_i,
  input logic base_graph_i,
  
  input logic info_valid_i,
  input logic [3:0][(ZC_MAX >> 2)-1:0] info_data_i,
  
  input logic core_parity_valid_i,
  input logic [3:0][(ZC_MAX >> 2)-1:0] core_parity_data_i,
  
  input logic add_parity_valid_i,
  input logic [3:0][COL_WIDTH-1:0] add_parity_idx_i, 
  input logic [3:0][(ZC_MAX >> 2)-1:0] add_parity_data_i,
  
  input logic last_block_i,
  input logic init_i,
  output logic ready_o,
  
  // Inter-Module Interface to Output Buffer
  input logic [COL_WIDTH-1:0] r_addr_i,
  output logic [ZC_MAX-1:0] r_data_o,
  output logic [3:0] bank_valid_o, // marks which bank has data
  output logic codeword_valid_o, // a ping/pong bram is ready
  input logic codeword_done_i,
  
  output logic [ZC_WIDTH-1:0] lifting_size_o,
  output zc_group_t zc_group_o,
  output logic base_graph_o
);

// signals
(* ram_style = "block" *) logic [(ZC_MAX >> 2)-1:0] ram [0:3][0:255];

typedef enum logic { RAM0 = 1'b0, RAM1 = 1'b1 } ram_state_t;
typedef enum logic [1:0] { INIT, INFO, PAR_CORE, PAR_ADD } ldpc_state_t;

ram_state_t w_sel_q, w_sel_n;
ram_state_t r_sel_q, r_sel_n;
ldpc_state_t ldpc_state_q, ldpc_state_n;

logic [3:0][(ZC_MAX >> 2)-1:0] w_data;
logic [7:0] w_addr;
logic [7:0] w_bank_addr [0:3];
logic [3:0] w_en;

logic [7:0] r_addr;

logic [1:0] ram_full_q;
logic [3:0][67:0] bank_valid_q [0:1];

logic ldpc_rst; // triggers when PAR_ADD -> INIT
logic pingpong_rst; // triggers when ping/pong is fully read (codeword_done_i)
logic [KB_WIDTH-1:0] info_col_cnt_q, info_col_lim;
logic [1:0] core_idx_q, core_idx_lim;

logic [ZC_WIDTH-1:0] lifting_size_q [0:1];
zc_group_t zc_group_q [0:1];
logic base_graph_q [0:1];

logic addr_sel, latch_config;

// control
assign info_col_lim = (base_graph_q[w_sel_q])? (KB_BG2 - 1) : (KB_BG1 - 1);
assign codeword_valid_o = ram_full_q[r_sel_q];
assign ready_o = ~ram_full_q[w_sel_q];

always_ff @(posedge clk_i or negedge arst_ni) begin : fsm_registering
  if (!arst_ni) begin
    ldpc_state_q <= INIT;
    w_sel_q <= RAM0;
    r_sel_q <= RAM0;
  end else begin
    ldpc_state_q <= ldpc_state_n;
    w_sel_q <= w_sel_n;
    r_sel_q <= r_sel_n;
  end
end

// TODO: what happens when pong/ping is full tooo? how will it transition again?
always_comb begin : fsm_transition
  // write pingpong
  w_sel_n = w_sel_q;
  unique case (w_sel_q)
    RAM0: begin
      if ((ldpc_state_q == PAR_ADD) & last_block_i
          & ram_full_q[~w_sel_q]) 
        w_sel_n = RAM1;
    end
    RAM1: begin
      if ((ldpc_state_q == PAR_ADD) & last_block_i
          & ram_full_q[~w_sel_q]) 
        w_sel_n = RAM0;
    end
  endcase

  // read pingpong
  r_sel_n = r_sel_q;
  unique case (r_sel_q)
    RAM0: begin
      if (codeword_valid_o & codeword_done_i)
        r_sel_n = RAM1;
    end
    RAM1: begin
      if (codeword_valid_o & codeword_done_i) 
        r_sel_n = RAM0;
    end
  endcase

  // LDPC phases
  unique case (ldpc_state_q)
    INIT: begin
      if (init_i) ldpc_state_n = INFO;
      else ldpc_state_n = INIT;
    end
    INFO: begin 
      if ((info_col_cnt_q >= info_col_lim)
          & info_valid_i) ldpc_state_n = PAR_CORE;
      else ldpc_state_n = INFO;
    end
    PAR_CORE: begin
      if ((core_idx_q >= core_idx_lim)
          & core_parity_valid_i) ldpc_state_n = PAR_ADD;
      else ldpc_state_n = PAR_CORE;
    end
    PAR_ADD: begin
      // if (last_block_i) ldpc_state_n = INIT;
      // else ldpc_state_n = PAR_ADD;
      // NOTE: ^ should be handled by ldpc_rst, i guess ^
      ldpc_state_n = PAR_ADD;
    end
  endcase
  if (ldpc_rst) ldpc_state_n = INIT;
end

always_ff @(posedge clk_i or negedge arst_ni) begin : pingpong_state
  for (int i = 0; i < 2; i++) begin
    if (!arst_ni) begin
      ram_full_q[i] <= 0;    
    end else begin
      if ((i == r_sel_q) & pingpong_rst) ram_full_q[i] <= 0;
      else if ((i == w_sel_q) 
            & (ldpc_state_q == PAR_ADD) 
            & (last_block_i)) ram_full_q[i] <= 1; 
    end
  end
end

always_comb begin : control_signalling
  latch_config = 0;
  ldpc_rst = 0;
  pingpong_rst = 0;

  unique case (ldpc_state_q)
    INIT: begin
      addr_sel = 0;
      if (init_i) latch_config = 1; 
    end
    INFO: begin
      addr_sel = 0;            
    end
    PAR_CORE: begin
      addr_sel = 1;
    end
    PAR_ADD: begin
      addr_sel = 1;
      if (last_block_i) ldpc_rst = 1;
    end
  endcase

  if (codeword_valid_o & codeword_done_i) pingpong_rst = 1;
end

// datapath
assign  r_addr = {r_sel_q, r_addr_i};

// latch LDPC config for ping-pong
always_ff @(posedge clk_i or negedge arst_ni) begin : config_latching
  for (int i = 0; i < 2; i++) begin
    if (!arst_ni) begin
      lifting_size_q[i] <= '0;
      zc_group_q[i] <= ZC_SMALL;
      base_graph_q[i] <= '0;
    end else begin
      if (i == r_sel_q & pingpong_rst) begin
        lifting_size_q[i] <= '0;
        zc_group_q[i] <= ZC_SMALL;
        base_graph_q[i] <= '0;
      end 
      else if ((i == w_sel_q) & latch_config) begin
        lifting_size_q[i] <= lifting_size_i;
        zc_group_q[i] <= zc_group_i;
        base_graph_q[i] <= base_graph_i;
      end
    end
  end
end

assign lifting_size_o = lifting_size_q[r_sel_q];
assign zc_group_o = zc_group_q[r_sel_q];
assign base_graph_o = base_graph_q[r_sel_q];

// count the current column of info bit
always_ff @(posedge clk_i or negedge arst_ni) begin : info_col_counting
  if (!arst_ni) info_col_cnt_q <= '0;
  else begin
    if (ldpc_rst) info_col_cnt_q <= '0;
    else if ((ldpc_state_q == INFO) & info_valid_i) 
      info_col_cnt_q <= info_col_cnt_q + 1;
  end 
end

// select base write address
// 1 bit offset for stages after INFO
// 128 bit offset when writing to other ping pong
always_comb begin : w_addr_sel
  unique case ({addr_sel, w_sel_q})
    2'b00 : w_addr = 8'(info_col_cnt_q) + 8'd0;
    2'b01 : w_addr = 8'(info_col_cnt_q) + 8'd128;
    2'b10 : w_addr = 8'(info_col_cnt_q) + 8'd1;
    2'b11 : w_addr = 8'(info_col_cnt_q) + 8'd129;
  endcase
end

// counting the current phase of core parity bit calculation
always_ff @(posedge clk_i or negedge arst_ni) begin : core_idx_counting
   if (!arst_ni) core_idx_q <= 2'b00;
   else begin
    if (ldpc_rst) core_idx_q <= 2'b00;
    else if ((ldpc_state_q == PAR_CORE) & core_parity_valid_i) 
      core_idx_q <= core_idx_q + 2'b01;
   end
end

// for state transition and limiting counter
always_comb begin : core_idx_limarison
  unique case (zc_group_q[w_sel_q])
    ZC_SMALL: core_idx_lim = 2'b00;
    ZC_MEDIUM: core_idx_lim = 2'b01;
    ZC_LARGE: core_idx_lim = 2'b11;
    default: core_idx_lim = 2'b00;
  endcase
end

// calculate the address for each bank
// special case when core parity bit stage
// TODO: change core_idx_q to 2-bit [x]
always_comb begin : w_bank_addr_calculation
  if (ldpc_state_q == PAR_CORE) begin
    unique case (zc_group_q[w_sel_q])
      ZC_SMALL: begin
        w_bank_addr[0] = w_addr + 8'(core_idx_q + 2'd0); 
        w_bank_addr[1] = w_addr + 8'(core_idx_q + 2'd1);  
        w_bank_addr[2] = w_addr + 8'(core_idx_q + 2'd2); 
        w_bank_addr[3] = w_addr + 8'(core_idx_q + 2'd3); 
      end 
      ZC_MEDIUM: begin
        w_bank_addr[0] = w_addr + 8'((core_idx_q << 1) + 2'd0); 
        w_bank_addr[1] = w_addr + 8'((core_idx_q << 1) + 2'd0);  
        w_bank_addr[2] = w_addr + 8'((core_idx_q << 1) + 2'd1); 
        w_bank_addr[3] = w_addr + 8'((core_idx_q << 1) + 2'd1); 
      end
      ZC_LARGE: begin
        w_bank_addr[0] = w_addr + 8'(core_idx_q); 
        w_bank_addr[1] = w_addr + 8'(core_idx_q);  
        w_bank_addr[2] = w_addr + 8'(core_idx_q); 
        w_bank_addr[3] = w_addr + 8'(core_idx_q); 
      end
      default: begin
        w_bank_addr[0] = w_addr + 8'(core_idx_q + 2'd0); 
        w_bank_addr[1] = w_addr + 8'(core_idx_q + 2'd1);  
        w_bank_addr[2] = w_addr + 8'(core_idx_q + 2'd2); 
        w_bank_addr[3] = w_addr + 8'(core_idx_q + 2'd3); 
      end
    endcase
  end else begin
    for (int i = 0; i < 4; i++) begin
      if (ldpc_state_q == PAR_ADD)
        w_bank_addr[i] = w_addr + 8'(add_parity_idx_i[i]);
      else
        w_bank_addr[i] = w_addr;
    end
  end
end

// selecting which bank to read to
always_comb begin : w_en_selection
  w_en = 4'b0000;

  if (ldpc_state_q == INFO & info_valid_i) begin
    unique case (zc_group_q[w_sel_q])
      ZC_SMALL: w_en = 4'b0001;
      ZC_MEDIUM: w_en = 4'b0011;
      ZC_LARGE: w_en = 4'b1111;
      default: w_en = 4'b0001;
    endcase
  end 
  else if (ldpc_state_q == PAR_CORE & core_parity_valid_i)
    w_en <= 4'b1111;
  else if (ldpc_state_q == PAR_ADD & add_parity_valid_i)
    w_en <= 4'b1111;
end

// select write data
always_comb begin : w_data_selection
  unique case (ldpc_state_q)
    INIT: w_data = '0;
    INFO: w_data = info_data_i;
    PAR_CORE: w_data = core_parity_data_i;
    PAR_ADD: w_data = add_parity_data_i;
  endcase
end

// bram write and read
// TODO: route r_addr based on r_sel_q [x]
always_ff @(posedge clk_i) begin : bram_process
  for (int i = 0; i < 4; i++) begin
    if (w_en[i]) ram[i][w_bank_addr[i]] <= w_data[i];
    r_data_o[i*(ZC_MAX>>2) +: (ZC_MAX>>2)] <= ram[i][r_addr];
  end
end

// keep track of which bank is used to store the data
always_ff @(posedge clk_i or negedge arst_ni) begin : bank_validity_keeper
  for (int i = 0; i < 2; i++) begin
    if (!arst_ni) bank_valid_q[i] <= '0;
    else begin
      if (i == r_sel_q & pingpong_rst) bank_valid_q[i] <= '0; // reset - highest prio
      else begin
        // write
        if (i == w_sel_q)
          for (int j = 0; j < 4; j++) begin
            bank_valid_q[i][j][w_bank_addr[j]] <= w_en[j];
          end

        // read - sync to bram by 1 clk delay
        if (i == r_sel_q)
          for (int j = 0; j < 4; j++) begin
            bank_valid_o[j] <= bank_valid_q[i][j][r_addr];
          end
      end
    end
  end
end

endmodule
