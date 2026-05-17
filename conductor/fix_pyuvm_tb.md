# Fix pyUVM Testbench Internal Monitoring

## Objective
Fix the internal monitors and scoreboard in the pyUVM testbench for `ldpc_encoder_core` to properly track and verify internal states without modifying the RTL.

## Key Files & Context
- `sim/ldpc_encoder_core_pyuvm_tb.py`
- `sim/golden_model.py` (Referenced for hooks)

## Implementation Steps
1. **Fix Python Keyword Conflict:** 
   - Update `LdpcLambdaMonitor` to access the `lambda` signal using `getattr(core, "lambda")` instead of `core.lambda_`, which causes syntax errors in Python.
2. **Cycle-Accurate Pipeline Tracking:**
   - Enhance `LdpcShifterMonitor` and `LdpcGf2Monitor` to latch `col_curr_q` and `actual_row_q` on `csr_valid_q` / `gf2_en_q` (start of pipeline), and output them along with the result during `_qdly` (end of pipeline).
3. **Internal Scoreboard Implementation:**
   - Implement `write_shifter_export` to verify the permutation/shift values for each active row against `gm.hooks['shifted_vectors']`.
   - Implement `write_gf2_export` to verify the 96-bit accumulated XOR sums for each row against `gm.hooks['gf2_sums']`.
4. **Wiring & Configuration:**
   - Connect the internal monitors (`inbuff_monitor`, `shifter_monitor`, `gf2_monitor`, `lambda_monitor`) to `internal_scoreboard` in `LdpcEnv.connect_phase()`.
   - Pass the `golden_model` instance to the `LdpcInternalScoreboard` via `ConfigDB` in the test `build_phase`.

## Verification & Testing
- The internal scoreboard will now actively compare input, shifter, GF(2), and lambda stages against the Golden Model hooks for every frame.
- Ensure the testbench executes without Python AttributeError and successfully validates the monitored steps.