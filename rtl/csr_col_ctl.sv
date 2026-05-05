module csr_col_ctl #(
  parameter int unsigned COL_WIDTH = 9
) (
  input logic clk_i,
  input logic arst_ni,

  input logic [COL_WIDTH-1:0] col_idx_i [0:3],
  output logic [COL_WIDTH-1:0] col_curr,
  output logic row_change_o // signals that the row has changed
);
  
logic [COL_WIDTH-1:0] cidx_temp [0:1];

// compare row 1 and 2
assign cidx_temp[0] = (col_idx_i[0] <= col_idx_i[1]) ? col_idx_i[0] : col_idx_i[1];
// compare row 3 and 4
assign cidx_temp[1] = (col_idx_i[2] <= col_idx_i[3]) ? col_idx_i[2] : col_idx_i[3];

// get minimum of all 4 rows
assign col_curr = (cidx_temp[0] <= cidx_temp[1]) ? cidx_temp[0] : cidx_temp[1];

logic [COL_WIDTH-1:0] col_idx_prev [0:3];
logic [3:0] col_decreased_prev, col_decreased, col_decreased_hold;

assign col_decreased_hold = col_decreased_prev | col_decreased;
assign row_change_o = &col_decreased_hold;

always_comb begin
  
end

always_comb begin
  for (int unsigned i = 0; i < 4; i++) begin
    col_decreased[i] = col_idx_i[i] < col_idx_prev[i];
  end
end

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
