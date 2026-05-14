module pipeline_delay #(
  parameter int unsigned WIDTH  = 32,
  parameter int unsigned CYCLES = 1
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             valid_i, // Optional: clock enable for power savings
  input  logic [WIDTH-1:0] data_i,
  output logic [WIDTH-1:0] data_o
);

generate
  if (CYCLES == 0) begin : gen_zero_delay
    assign data_o = data_i;
  end else begin : gen_delay
    logic [CYCLES-1:0][WIDTH-1:0] delay_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        delay_q <= '0;
      end else if (valid_i) begin
        delay_q[0] <= data_i;
        for (int i = 1; i < CYCLES; i++) begin
          delay_q[i] <= delay_q[i-1];
        end
      end
    end

    assign data_o = delay_q[CYCLES-1];
  end
endgenerate

endmodule