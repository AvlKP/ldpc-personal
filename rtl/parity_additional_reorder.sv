import ldpc_pkg::*;

// Reorders parity_additional rows that arrive out of order due to the
// Petrović row-schedule optimization.
//
// Each upstream event packs 4/2/1 INDEPENDENT rows into data_i (one per
// 96/192/384-bit chunk). Chunk k is keyed by actual_row_i[k] (for ZC_SMALL;
// for wider zc_groups see the table below). The rows within an event are
// not guaranteed to be in order.
//
// The buffer is direct-indexed by (actual_row - FIRST_ADD_ROW): slot s holds
// the row whose absolute index is (FIRST_ADD_ROW + s). FIRST_ADD_ROW = 4
// (rows 0..3 are core parity). On every cycle, if the slot at the current
// expected_row_q is valid, that row is forwarded to the consumer and
// expected_row_q advances by one. Strict in-order emission is enforced
// implicitly: if row X+1 arrives before row X, it sits in its slot until
// row X is drained and expected_row_q catches up.
//
// Across codewords, the buffer self-resets: when expected_row_q reaches
// row_limit (46 for BG1, 42 for BG2), it wraps back to FIRST_ADD_ROW. The
// upstream encoder does NOT need to pulse flush_i between codewords; the
// buffer keeps draining during the encoder's IDLE state and is ready for
// the next codeword once it has emitted every row.
//
// valid_i is held high for >=2 cycles by the upstream (the rowgrp_changed
// pulse straddles csr_decoder's INIT/VALID transition). To avoid stashing
// the same event twice, only the rising edge of valid_i is treated as a
// fresh event.
//
// Row → chunk → key mapping:
//   ZC_SMALL : chunk k = data_i[96*k  +: 96 ], key = actual_row_i[k]   (k=0..3)
//   ZC_MEDIUM: chunk k = data_i[192*k +: 192], key = actual_row_i[2*k] (k=0..1)
//   ZC_LARGE : chunk 0 = data_i[383:0],        key = actual_row_i[0]
//
// Each extracted chunk is lifted to the top of a 384-bit slot so that the
// Z active bits land at [ZC_MAX-1:ZC_MAX-Z]. The output data_o uses the same
// MSB-packed convention. Consumer downstream sees one row per cycle (Z bits
// at the top of data_o, the rest zero).

module parity_additional_reorder #(
  parameter int unsigned N_BUF      = 48,
  localparam int unsigned ROW_WIDTH = $clog2(BG1_ROW_N),
  localparam int unsigned IDX_W     = $clog2(N_BUF)
) (
  input  logic                      clk_i,
  input  logic                      arst_ni,
  // Explicit re-init. Normal operation doesn't need this — the buffer wraps
  // expected_row_q itself when it reaches row_limit, so it is ready for the
  // next codeword without an external pulse. Drive '0 in typical use.
  input  logic                      flush_i,

  input  logic                      base_graph_i,
  input  zc_group_t                 zc_group_i,
  // Sub-cycle within the current rowgrp_base. csr_decoder produces 4 row
  // indices per rowgrp_base; the encoder consumes them at different rates:
  //   ZC_SMALL : all 4 rows in 1 event       (sub_cycle_i unused)
  //   ZC_MEDIUM: 2 rows per event, 2 events  (sub_cycle_i[0]: 0 picks [0,1], 1 picks [2,3])
  //   ZC_LARGE : 1 row  per event, 4 events  (sub_cycle_i[1:0] picks actual_row_i[k])
  input  logic [1:0]                sub_cycle_i,

  input  logic                      valid_i,
  input  logic [ZC_MAX-1:0]         data_i,
  input  logic [3:0][ROW_WIDTH-1:0] actual_row_i,

  output logic                      valid_o,
  output logic [ZC_MAX-1:0]         data_o
);
  // Direct-indexed storage.
  logic                  buf_valid_q [0:N_BUF-1];
  logic [ZC_MAX-1:0]     buf_data_q  [0:N_BUF-1];

  localparam logic [ROW_WIDTH-1:0] FIRST_ADD_ROW = ROW_WIDTH'(4);
  logic [ROW_WIDTH-1:0] expected_row_q;
  logic [IDX_W-1:0]     expected_idx;
  assign expected_idx = expected_row_q - FIRST_ADD_ROW;

  // Last absolute row index + 1. Once expected_row_q reaches this, all PA
  // rows for the current codeword have been emitted and we wrap to
  // FIRST_ADD_ROW so the buffer is ready for the next codeword.
  logic [ROW_WIDTH-1:0] row_limit;
  assign row_limit = base_graph_i ? ROW_WIDTH'(BG2_ROW_N) : ROW_WIDTH'(BG1_ROW_N);

  // Edge detect on valid_i (upstream pulse is >=2 cycles).
  logic valid_i_q;
  always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) valid_i_q <= 1'b0;
    else          valid_i_q <= valid_i;
  end
  logic accept_event;
  assign accept_event = valid_i & ~valid_i_q;

  // Per-chunk extraction.
  // ZC_SMALL : 4 chunks of 96, each MSB-packed, keyed by actual_row_i[k].
  // ZC_MEDIUM: 2 chunks of 192. sub_cycle_i[0] selects which pair of
  //            actual_row_i entries are the keys (sub=0 -> [0,1], sub=1 -> [2,3]).
  // ZC_LARGE : 1 chunk of 384, keyed by actual_row_i[sub_cycle_i].
  logic [3:0]                       row_used;
  logic [3:0][ZC_MAX-1:0]           row_data;
  logic [3:0][ROW_WIDTH-1:0]        row_key;
  always_comb begin
    row_used = '0;
    row_data = '0;
    row_key  = '0;
    case (zc_group_i)
      ZC_SMALL: begin
        for (int unsigned k = 0; k < 4; k++) begin
          row_used[k] = 1'b1;
          row_data[k] = {data_i[96*k +: 96], 288'b0};
          row_key[k]  = actual_row_i[k];
        end
        // The base-graph height is not a multiple of 4, so the final row
        // group holds only 2 real rows. csr_decoder pads the unused entries
        // by duplicating earlier keys (actual_row[2]==[0], [3]==[1]) while
        // the matching cyclic shifters [2],[3] stay inactive and emit zero.
        // Drop any chunk whose key duplicates an earlier chunk so the zero
        // data does not clobber the valid row sharing that slot.
        for (int unsigned k = 1; k < 4; k++)
          for (int unsigned j = 0; j < k; j++)
            if (actual_row_i[k] == actual_row_i[j]) row_used[k] = 1'b0;
      end
      ZC_MEDIUM: begin
        row_used[0] = 1'b1;
        row_data[0] = {data_i[191:0],   192'b0};
        row_key[0]  = actual_row_i[{sub_cycle_i[0], 1'b0}]; // [0] or [2]
        row_used[1] = 1'b1;
        row_data[1] = {data_i[383:192], 192'b0};
        row_key[1]  = actual_row_i[{sub_cycle_i[0], 1'b1}]; // [1] or [3]
      end
      ZC_LARGE: begin
        row_used[0] = 1'b1;
        row_data[0] = data_i;
        row_key[0]  = actual_row_i[sub_cycle_i];
      end
      default: ;
    endcase
  end

  logic buf_hit;
  assign buf_hit = buf_valid_q[expected_idx];

  always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
      valid_o        <= 1'b0;
      data_o         <= '0;
      expected_row_q <= FIRST_ADD_ROW;
      for (int unsigned k = 0; k < N_BUF; k++) begin
        buf_valid_q[k] <= 1'b0;
        buf_data_q[k]  <= '0;
      end
    end else begin
      valid_o <= 1'b0;

      if (flush_i) begin
        expected_row_q <= FIRST_ADD_ROW;
        for (int unsigned k = 0; k < N_BUF; k++) begin
          buf_valid_q[k] <= 1'b0;
        end
      end else begin
        // Drain: if expected slot is valid, emit it and advance. When we
        // emit the last row of the codeword (expected_row_q+1 == row_limit),
        // wrap back to FIRST_ADD_ROW so we're ready for the next codeword
        // without needing an external flush.
        if (buf_hit) begin
          valid_o                   <= 1'b1;
          data_o                    <= buf_data_q[expected_idx];
          buf_valid_q[expected_idx] <= 1'b0;
          if ((expected_row_q + 1'b1) >= row_limit)
            expected_row_q <= FIRST_ADD_ROW;
          else
            expected_row_q <= expected_row_q + 1'b1;
        end

        // Stash a fresh event's rows into their direct-indexed slots.
        if (accept_event) begin
          for (int unsigned k = 0; k < 4; k++) begin
            if (row_used[k]) begin
              automatic logic [IDX_W-1:0] slot;
              slot = row_key[k] - FIRST_ADD_ROW;
              buf_valid_q[slot] <= 1'b1;
              buf_data_q[slot]  <= row_data[k];
            end
          end
        end
      end
    end
  end

endmodule
