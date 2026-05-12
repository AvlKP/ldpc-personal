module write_aligned_buffer #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned MAX_ZC     = 384,
  parameter int unsigned MAX_CHUNKS = 22
) (
  input  logic clk_i,
  input  logic arst_ni,

  // LDPC Configuration
  input  logic [8:0]            zc_size_i,
  input  logic                  reset_buffer_i, // Pulse high to clear for next frame/ping-pong

  // AXI Stream Input
  input  logic [DATA_WIDTH-1:0] s_axis_tdata_i,
  input  logic                  s_axis_tvalid_i,
  output logic                  s_axis_tready_o,

  // LDPC Read Port (1-Cycle Latency)
  input  logic [$clog2(MAX_CHUNKS)-1:0] read_chunk_idx_i,
  output logic [MAX_ZC-1:0]             read_data_o
);

  // --------------------------------------------------------
  // Internal Declarations
  // --------------------------------------------------------
  localparam int unsigned ACCUM_WIDTH = MAX_ZC + DATA_WIDTH;
  
  logic [ACCUM_WIDTH-1:0]               accum_data;
  logic [$clog2(ACCUM_WIDTH+1)-1:0]     accum_count;
  logic [$clog2(MAX_CHUNKS)-1:0]        write_idx;

  logic can_unpack;
  logic [MAX_ZC-1:0] zc_mask;

  // 1D Array maps to highly efficient LUTRAM
  logic [MAX_ZC-1:0] ram [0:MAX_CHUNKS-1];

  // --------------------------------------------------------
  // FSM Control Signals
  // --------------------------------------------------------
  // We can unpack if we have accumulated at least Zc bits
  assign can_unpack = (accum_count >= zc_size_i) && (zc_size_i > 0);
  
  // AXI backpressure: Stop taking data if we are busy unpacking to RAM
  assign s_axis_tready_o = ~can_unpack;

  // Dynamic mask to ensure unused upper bits in the RAM are strictly zero
  assign zc_mask = (MAX_ZC'(1) << zc_size_i) - 1;

  // --------------------------------------------------------
  // Write-Side Deserializer / Unpacker FSM
  // --------------------------------------------------------
  always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
      accum_data  <= '0;
      accum_count <= '0;
      write_idx   <= '0;
    end else if (reset_buffer_i) begin
      accum_data  <= '0;
      accum_count <= '0;
      write_idx   <= '0;
    end else begin
      
      // PRIORITY 1: Unpack Data to RAM
      if (can_unpack) begin
        // Slice exactly Zc bits, mask out garbage, and store in RAM
        ram[write_idx] <= accum_data[MAX_ZC-1:0] & zc_mask;

        // Shift the accumulator down by Zc and decrement count
        accum_data  <= accum_data >> zc_size_i;
        accum_count <= accum_count - zc_size_i;
        
        // Move to the next chunk index
        write_idx <= write_idx + 1;
      end
      
      // PRIORITY 2: Accept incoming AXI Stream Data
      else if (s_axis_tvalid_i && s_axis_tready_o) begin
        // Shift incoming 32-bit word up by the current bit count and append it
        accum_data  <= accum_data | (ACCUM_WIDTH'(s_axis_tdata_i) << accum_count);
        accum_count <= accum_count + DATA_WIDTH;
      end

    end
  end

  // --------------------------------------------------------
  // Read Side (Trivial 1-Cycle Lookup)
  // --------------------------------------------------------
  always_ff @(posedge clk_i) begin
    read_data_o <= ram[read_chunk_idx_i];
  end

endmodule