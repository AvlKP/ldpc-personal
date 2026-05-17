# Fix Timing Logs and Internal Scoreboard

## Objective
1. Make `LdpcInternalScoreboard` actually receive and process data by using `uvm_tlm_analysis_fifo` and `cocotb.start_soon` tasks instead of unconnected `uvm_analysis_port`s.
2. Fix the log timing mismatch by having `LdpcOutputMonitor` record the `time_ns` (using `cocotb.utils.get_sim_time('ns')`) for each output word, parity chunk, and internal write. 
3. Update `LdpcScoreboard` to use these recorded timestamps in its `logger.error` messages so the user knows exactly when the mismatch occurred, rather than seeing the time at the end of the frame.

## Key Files & Context
- `sim/pyuvm_tb/scoreboards.py`
- `sim/pyuvm_tb/monitors.py`
- `sim/pyuvm_tb/agent_env.py`

## Implementation Steps
1. **Update `monitors.py`**:
   - In `LdpcOutputMonitor`, import `cocotb.utils`.
   - Update `actual_parity_chunks` to include `"time_ns": cocotb.utils.get_sim_time('ns')`.
   - Update `actual_internal_writes` to store dicts `{"data": raw_wr & mask, "time_ns": cocotb.utils.get_sim_time('ns')}`.
   - Update `captured_bits` handling to store `actual_words` as `{"data": raw, "time_ns": cocotb.utils.get_sim_time('ns')}`.

2. **Update `scoreboards.py` (LdpcScoreboard)**:
   - When checking output bits, correlate the bit mismatch index back to the 32-bit word index to get the exact `time_ns`.
   - When checking parity chunks, extract `time_ns` from the chunk dictionary and include it in the log message: `f"[Time: {chunk['time_ns']} ns] Parity group mismatch..."`.
   - Do the same for internal writes, using the recorded `time_ns`.

3. **Update `scoreboards.py` (LdpcInternalScoreboard)**:
   - Replace `uvm_analysis_port` instantiations with `uvm_tlm_analysis_fifo`.
   - Add an `async def run_phase(self)` that spawns four `cocotb.start_soon()` loops to continuously pop from `input_fifo`, `shifter_fifo`, `gf2_fifo`, and `lambda_fifo`.
   - Rename `write_input_export` to `check_input`, and similar for the others, and call them from the loops.
   - In the check functions, include `cocotb.utils.get_sim_time('ns')` in the logs to be precise if they don't already match the current sim time (they should match since they pop immediately, but we can be explicit).

4. **Update `agent_env.py`**:
   - Change `.connect(self.internal_scoreboard.input_export)` to `.connect(self.internal_scoreboard.input_fifo.analysis_export)`. (Do this for all 4 internal monitors).

## Verification & Testing
- Run `make test_ldpc_encoder_core` in the `sim` directory.
- Verify that `pyuvm_test.log` contains detailed `LdpcInternalScoreboard` logs.
- Verify that `LdpcScoreboard` mismatch logs show the exact simulation time of the mismatch inside the message text.