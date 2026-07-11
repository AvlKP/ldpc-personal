# Output Buffer Implementation Report — `main` branch

*2026-07-07 — Claude (Fable 5). All changes uncommitted, pending review.*

## Summary

The output buffer from `Drawing.png` is implemented on `main` as a rewrite of
`rtl/output_buffer.sv`, wired through the core and top level, and verified in
the IIC-OSIC-TOOLS container at three levels:

| Test | Command (in `sim/`) | Result |
|---|---|---|
| Integration: `codeword_generator` + `output_buffer` | `make test_output_buffer` | 4/4 PASS |
| Friend's standalone cwgen TB (RTL untouched) | `make test_codeword_generator` | 10/10 PASS |
| Full chain, black-box, bit-exact vs golden model | `make test_ldpc_encoder_core` | SMALL 35 frames, MEDIUM 8, LARGE 8 — 0 errors |

Full-chain sweeps run with 30 % random output backpressure built into the
monitor. Toolchain: Verilator 5.048 + cocotb 2.0.1 (`docker start
iic-osic-tools`, repo mounted at `/foss/designs/1-projects/ldpc-personal`).

---

## 1. Branch difference: `main` vs `cwgen-rewrite`

Both branches forked at `28ccf69` ("LSB refactor") and solved the codeword
readout problem independently:

| | `cwgen-rewrite` (Fable) | `main` (friend) |
|---|---|---|
| cwgen storage layout | Folded: SMALL packs 4 columns per address, MEDIUM 2, LARGE 1. Explicit `info_col_i` addressing, `add_parity_mask_i` for duplicate labels, internal edge-detect + staged one-row-per-cycle PA drain | One column per address across 4×96-bit banks with a `bank_valid_o[3:0]` sideband. Beat-counter INFO phase; `init_i` / `last_block_i` / `ready_o` frame handshake |
| output_buffer | Gearbox with `get_r_addr` folded addressing + `spill_register` | Was the old folded version (incompatible with the new cwgen); now replaced by the Drawing.png implementation |
| Top level | `rtl/ldpc_encoder.v` (Verilog-2001, self-contained CSRs, Vivado-proven) | `rtl/ldpc_encoder.sv` (SV + Bender `axi_lite_regs`) + `ldpc_encoder_wrapper.v`; `rtl/ldpc_encoder.v` on main is an empty file |
| Performance | PRE_NORM / PRE_MOD modulo cuts; HW-proven at 23 MHz, "push to 30 MHz" | None of these cuts — expect roughly the pre-cut ~15–17 MHz ceiling until ported |
| Extras | `pynq/` driver notebook + golden model, `sim/run_core_test.sh` | 1176-line standalone cwgen TB (10 tests) + `codeword_generator.mk` |

Before this session `main` did not even elaborate as a full chain:

- The core instantiated cwgen with `input_last_subblock_i` (a rewrite-branch
  port) against the friend's cwgen, which has `last_block_i` / `init_i` /
  `ready_o` instead.
- `bank_valid_o` was left dangling; `cw_ready` was hardcoded to 1.
- The old `output_buffer` ignored `bank_valid` entirely and assumed the old
  folded storage layout.

## 2. The generator→buffer contract (from the friend's cwgen + its TB)

- Read address **==** codeword column index (0..67 for BG1, 0..51 for BG2).
- Each address holds exactly **one column**: its Zc bits span the banks
  flagged in `bank_valid_o` in increasing bank order, 96 bits per bank,
  zero-padded above Zc ("data with padding, bit mask to remove").
- Reads have one cycle of latency; `r_data_o` and `bank_valid_o` are aligned.
- `codeword_done_i` is a 1-cycle pulse; the ping-pong read side (and the
  forwarded `lifting_size_o` / `base_graph_o` config) swaps one cycle later,
  so the consumer must not re-launch during the done cycle.
- Valid-bank patterns: one-hot (SMALL), `0011`/`1100` (MEDIUM), `1111`
  (LARGE) — plus extra high banks at the same address from the core's final
  half row-group duplicate labels (see §4).

## 3. Drawing.png → RTL mapping (`rtl/output_buffer.sv`)

| Drawing element | RTL |
|---|---|
| 7-bit counter, `>= 68/52` muxed by BG → "last block" | `col_cnt_q` / `col_last`; `r_addr_o = col_cnt_q` |
| 4×96-bit bank registers, "automatically rewritten on fetch" | `bank_q` loaded in CAPTURE; selected bank shifted `>>32` per drain step (the `[95:32]` feedback path) |
| Reverse priority encoder + 2-to-4 decoder → buff en | Lowest set bit of `bank_valid_q` selects the bank; indexed writeback; valid bit cleared after 3 slices ("update after consuming bank") |
| Lifting size `[8:5]` step counter, `[4:0]` thermometer decoder, '1 mux | Folded into one per-column countdown `col_rem_q`; `take = min(32, col_rem)`; mask `~('1 << take)` applied only on the final partial slice |
| 64-bit barrel shifter (`<<`, AMT 6) + OR append + 64-bit output reg | `out_q |= slice << fill_q`; low word is the AXIS beat; a handshake pops 32 bits; append stalls when `fill + take > 64` |
| "Non-zero when last subblock…" | FLUSH state: `tvalid = fill > 0`, `TLAST = fill <= 32` |

Design decisions:

- **`zc_group_i` dropped.** The drawing uses only lifting size + BG — correct,
  because `bank_valid` + Zc fully determine the drain for every group. The
  port is removed from `output_buffer` and the top.
- **No `spill_register`.** The 64-bit append register is itself the AXIS
  holding stage: while ≥32 bits are pending, appends land at bit `fill ≥ 32`,
  so `tdata`'s low word is stable under a stalled `tvalid` as AXIS requires.
- **Leftover valid banks after Zc bits are discarded.** This is what makes
  the core's duplicate row labels harmless (§4) without the rewrite branch's
  `add_parity_mask_i`.
- **FSM: IDLE → FETCH → CAPTURE → DRAIN (→ FETCH …) → FLUSH.** The 2-cycle
  fetch bubble per column matches the drawing's non-pipelined form; the pink
  "pipeline potential" note (prefetch the next address during drain) is left
  for future work.
- Simulation-only `$error` guards catch contract violations (empty
  `bank_valid` at capture, banks exhausted mid-column).

## 4. Core seam fixes (`rtl/ldpc_encoder_core.sv`, `rtl/ldpc_encoder.sv`)

The friend's cwgen itself is **unchanged** (its 10-test TB still passes).
Everything below is on the core/top side, mostly transplanted from the
already-verified `cwgen-rewrite` core:

1. **Registered `cw_last_col`.** The combinational version
   (`(row_cnt_n >= row_limit) & rowgrp_changed_qdly`) can never fire:
   `row_cnt_q` is reset one cycle before `rowgrp_changed_qdly` pulses.
2. **Corrected `parity_core_packed`.** Main's version had p_c2 ↔ p_c4 swapped
   for ZC_SMALL and ignored `pc_state_cnt_q` for MEDIUM/LARGE (every CALC_PC
   beat carried the same data).
3. **Per-lane PA index remap.** `actual_row_qdly` is per-row-position; the
   folded modes need the same `med_base` / `merge_d_cycle` remap as
   `gf2_en_eff` so each physical lane carries the row it is a sub-lane of.
4. **cwgen hookup.** `init_i` = the LOAD→CALC_LAMBDA transition cycle
   (config settled, CSR valid); `last_block_i = cw_last_col`;
   `ready_o → cw_ready` (replacing the hardcoded 1); `bank_valid_o` threaded
   core → top → `output_buffer`.
5. **Edge-detected `parity_additional_valid`** — the real bug found in
   full-chain debug, below.

Note: the friend's simple `info_valid = (state == CALC_LAMBDA)` gating works
as-is: the first row-group pass walks info columns 0..KB-1 in order and the
cwgen's beat counter stops listening after KB beats, so the folded modes'
repeat passes and the E-column cycles land afterwards and are ignored.

## 5. Debug story: the ghost parity write

First full-chain run: every frame corrupted from some column onward, while
every internal probe (shift vectors, lambda, per-row additional parity)
matched the golden model. Mapping the actual all-zero columns from the AXIS
trace (frame 0, BG2 Zc=208) gave dead parity rows
`{14, 15, 22, 23, 26, 31, 34, 37, 41}` — killed by **row label**, not by
arrival order.

A cycle dump of the PA hand-off showed the mechanism:

- `rowgrp_changed_qdly` is high for **two cycles** per row-group pass (and
  sticks high through IDLE after the final group), so
  `parity_additional_valid` fired twice per pass.
- Cycle 1 is the real hand-off. By cycle 2, `gf2_clear` has zeroed the
  accumulators and `actual_row_qdly` / `merge_d_cycle` have moved on — the
  cwgen (which writes on *every* valid cycle) wrote **zeros** a second time.
- Mid-group, the ghost lands on the *next* pass's row and is overwritten by
  its real hand-off five cycles later (self-healing). At a **group
  boundary**, `merge_d_cycle` has wrapped (or clamped, before a half group)
  while `actual_row_qdly` still holds the old group's labels → the ghost
  zeroes an **already-written** row. One dead row per group; the predicted
  victim set matched the observed dead set exactly.

The rewrite branch never hit this because its cwgen edge-detects
`add_parity_valid_i` internally (`pa_event`), and its header comment even
documents the two-cycle behaviour. Fix on main, core-side, one flop:

```systemverilog
assign parity_additional_valid = ((state_q == CALC_PA) | (state_q == IDLE))
                               & rowgrp_changed_qdly & ~rowgrp_changed_qdly2;
```

**Invariant for future consumers:** any strobe derived from
`rowgrp_changed_qdly` must be edge-detected.

## 6. Testbench work

- **`sim/output_buffer_tb.py`** (rewritten) + **`sim/sv_tb/outbuff_integration.sv`**
  (new harness wiring cwgen ↔ output_buffer exactly like the core/top):
  reuses the friend's `CodewordDriver`; golden = columns packed LSB-first
  into 32-bit words. Covers: 15-config BG×Zc sweep (Zc 2..384, group and
  word-boundary edges), 50 % backpressure + shuffled PA order,
  duplicate-label robustness (real-core tail behaviour), and back-to-back
  ping-pong frames with a config switch. Drives the **full** additional
  parity set (42/38 rows) unlike the standalone TB's rounded-down count.
- **`sim/Makefiles/output_buffer.mk`**: integration target (skips the
  Bender `verilator.f`, not needed).
- **`sim/pyuvm_tb/scoreboards.py`**: checks #2/#3 probed the *old* cwgen
  ext-stream / 384-bit output-buffer write interface (`ext_valid`,
  `outbuff_wr_en`, …) which no longer exists on either current architecture;
  they produced false ERRORs on every frame. Now gated to run only when the
  probes actually observe something. Real coverage on the new architecture:
  bit-exact AXIS output + TLAST + the internal scoreboard's per-row golden
  model checks.

## 7. Change set (all uncommitted)

```
M  rtl/output_buffer.sv            (full rewrite per Drawing.png)
M  rtl/ldpc_encoder_core.sv        (seam fixes §4, §5)
M  rtl/ldpc_encoder.sv             (bank_valid wiring, zc_group drop)
M  sim/output_buffer_tb.py         (new integration TB)
A  sim/sv_tb/outbuff_integration.sv
M  sim/Makefiles/output_buffer.mk
M  sim/pyuvm_tb/scoreboards.py     (stale-check gating)
```

(`.vscode/settings.json` was already modified before this session and is
untouched.)

## 8. Open items / notes for review

- `rtl/test.sv` contains a stale duplicate `module codeword_generator` (an
  old draft with the `input_last_subblock_i` interface). It is not in any
  build file list but confuses IDE linting — candidate for deletion.
- Main's core lacks the rewrite branch's PRE_NORM / PRE_MOD modulo cuts, so
  its critical path is the pre-cut one (~15–17 MHz ceiling on the Zynq-7020).
  Porting those two cuts is the obvious next step toward the 23 MHz target.
- Output buffer throughput: 2-cycle fetch bubble per column (drawing's
  non-pipelined form). Fine functionally — readout is far faster than frame
  production — but the drawing's "pipeline potential" prefetch would remove
  it if ever needed.
