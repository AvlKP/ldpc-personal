# Refactor pyUVM Scoreboard and Monitors for Best Practices

## Objective
Fix the UVM component inheritance and assertion logic to adhere to UVM best practices:
1. `LdpcOutputMonitor` and `LdpcScoreboard` should inherit from `uvm_monitor` and `uvm_scoreboard` respectively.
2. `LdpcOutputMonitor` should be completely stripped of assertion (`assert`) checks. It should only capture data and push an `actual` dictionary into its `actual_ap`.
3. `LdpcScoreboard` should take over the checking logic and use `self.logger.error()` instead of Python `assert`, allowing the simulation to continue and aggregate errors without hard-crashing.

## Key Files & Context
- `sim/pyuvm_tb/monitors.py`
- `sim/pyuvm_tb/scoreboards.py`

## Implementation Steps
1. **Update `monitors.py`**:
   - Change `LdpcOutputMonitor(uvm_component)` to `LdpcOutputMonitor(uvm_monitor)`.
   - Remove all `assert` logic from `LdpcOutputMonitor.capture_frame`.
   - Store all observed `ext_data` (parity chunk writes) into an `actual_parity_chunks` list.
   - Store all `outbuff_data` writes into an `actual_internal_writes` list.
   - Return these lists in the `actual` dictionary along with `tlast` state.

2. **Update `scoreboards.py`**:
   - Change `LdpcScoreboard(uvm_component)` to `LdpcScoreboard(uvm_scoreboard)`.
   - In `compare()`, retrieve `actual_parity_chunks` and `actual_internal_writes` from the `actual` dictionary.
   - Replicate the length and data comparisons previously in the monitor using `self.logger.error()` for failures.
   - Replace the `assert` checks in the existing `LdpcScoreboard.compare` (for output bit matching) with `self.logger.error()`.

## Verification & Testing
- Run `make test_ldpc_encoder_core` in the `sim` directory.
- The simulation will still fail on the exact same mismatched parity bits, but it will fail gracefully via UVM `logger.error` output, aggregating errors instead of crashing immediately.