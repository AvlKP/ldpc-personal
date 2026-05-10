module csr_col_ctl #(
  parameter int unsigned COL_WIDTH = 9
) (
  input logic clk_i,
  input logic arst_ni,

  input logic [COL_WIDTH-1:0] col_idx_i [0:3],
  output logic [COL_WIDTH-1:0] col_curr_o,
  output logic row_change_o // signals that the row has changed
);
  
logic [COL_WIDTH:0] cidx_temp [0:1];
logic [COL_WIDTH-1:0] col_idx_prev [0:3];
logic [3:0] col_decreased_prev, col_decreased, col_decreased_hold;

assign col_decreased_hold = col_decreased_prev | col_decreased;
assign row_change_o = &col_decreased_hold;

// append the damn col_decreased bit to avoid next row columns interference on comparators
// HAHAHA
logic [COL_WIDTH:0] cidx_dec_app [0:3];

always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    col_decreased[i] = col_idx_i[i] < col_idx_prev[i];
    cidx_dec_app[i] = {col_decreased_hold[i], col_idx_i[i]};
  end
end

// compare row 1 and 2
assign cidx_temp[0] = 
(cidx_dec_app[0] <= cidx_dec_app[1]) ? cidx_dec_app[0] : cidx_dec_app[1];
// compare row 3 and 4
assign cidx_temp[1] = 
(cidx_dec_app[2] <= cidx_dec_app[3]) ? cidx_dec_app[2] : cidx_dec_app[3];

// get minimum of all 4 rows
assign col_curr_o = (cidx_temp[0] <= cidx_temp[1]) ?
  cidx_temp[0][COL_WIDTH-1:0] : cidx_temp[1][COL_WIDTH-1:0];

always_ff @(posedge clk_i or negedge arst_ni) begin
  // register previous value
  for (int unsigned i = 0; i < 4; i++) begin
    if (!arst_ni) col_idx_prev[i] <= '0;
    else if (row_change_o) col_idx_prev[i] <= '0;
    else col_idx_prev[i] <= col_idx_i[i];
  end

  // compare previous value with current one
  if (!arst_ni) col_decreased_prev <= '0;
  else if (row_change_o) col_decreased_prev <= '0;
  else begin
    for (int unsigned i = 0; i < 4; i++) begin
      if (~col_decreased_prev[i]) 
        col_decreased_prev[i] <= col_decreased[i];
    end
  end
end

endmodule
