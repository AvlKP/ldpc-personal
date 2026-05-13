module direct_bit_permutation #(
    parameter int ZC_PER_CS = 96, 
    parameter int NUM_CS = 4,
    parameter logic is_reverse = 0
)(
    input  logic [NUM_CS*ZC_PER_CS-1:0] data_in,
    input  logic [1:0]                    d,       // [00 = 1, 01 = 2, 11 = 4]
    output logic [NUM_CS*ZC_PER_CS-1:0] data_out
);

  generate
    if (is_reverse) begin : gen_reverse
      always_comb begin
        // Default assignment to prevent latch inference
        data_out = data_in; 
        
        case (d)
          2'b01: begin
            for (int j = 0; j < NUM_CS/2; j++) begin
              for (int i = 0; i < ZC_PER_CS*2; i++) begin
                data_out[j*(ZC_PER_CS*2) + i] = data_in[ j*(ZC_PER_CS*2) + (i & 1) * ZC_PER_CS + (i >> 1) ];
              end
            end
          end
          
          2'b11: begin
            for (int j = 0; j < NUM_CS/4; j++) begin
              for (int i = 0; i < ZC_PER_CS*4; i++) begin
                data_out[j*(ZC_PER_CS*4) + i] = data_in[ j*(ZC_PER_CS*4) + (i & 3) * ZC_PER_CS + (i >> 2) ];
              end
            end
          end
          
          default: begin
            // Handled by default assignment
          end
        endcase
      end
    end else begin : gen_forward
      always_comb begin
        // Default assignment to prevent latch inference
        data_out = data_in;
        
        case (d)
          2'b01: begin
            for (int j = 0; j < NUM_CS/2; j++) begin
              for (int i = 0; i < ZC_PER_CS*2; i++) begin
                data_out[ j*(ZC_PER_CS*2) + (i & 1) * ZC_PER_CS + (i >> 1) ] = data_in[j*(ZC_PER_CS*2) + i];
              end
            end
          end
          
          2'b11: begin
            for (int j = 0; j < NUM_CS/4; j++) begin
              for (int i = 0; i < ZC_PER_CS*4; i++) begin
                data_out[ j*(ZC_PER_CS*4) + (i & 3) * ZC_PER_CS + (i >> 2) ] = data_in[j*(ZC_PER_CS*4) + i];
              end
            end
          end
          
          default: begin
            // Handled by default assignment
          end
        endcase
      end
    end
  endgenerate

endmodule