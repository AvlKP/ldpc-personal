# LDPC Encoder IP - Bug Report (2026-05-17)

## 1. Core FSM Row Counter Logic
**File:** `rtl/ldpc_encoder_core.sv`
**Description:** The row counter increment logic in `always_comb` block is reversed relative to the parallelism group.
- **Current Behavior:** 
    - `ZC_SMALL` (4x parallelism) increments `row_cnt` by 1.
    - `ZC_LARGE` (1x parallelism) increments `row_cnt` by 4.
- **Impact:** FSM processes incorrect number of rows or hangs due to incorrect `row_limit` checks.
- **Recommended Fix:** Swap the increment values (SMALL -> 4, LARGE -> 1).

## 2. Shift Coefficient Normalization
**File:** `rtl/parameter_calculation.sv`
**Description:** The RTL extracts bits for the sub-parallel shifter amount `q` directly from the CSR values without performing a modulo Z operation.
- **Current Behavior:** If a CSR coefficient P is large (e.g., 250) and Z is small (e.g., 96), the extracted q can exceed the `zc_in` parameter of the `barrel_shifter`.
- **Impact:** `barrel_shifter.sv` zeroes out the `data_out` if `shift_amt >= zc_in`, leading to incorrect GF(2) accumulations.
- **Recommended Fix:** Implement `p_mod_z = p % z` (using subtractions/comparisons for efficiency) before the `case(d)` block.

## 3. Input Buffer Monitor Timing
**File:** `sim/pyuvm_tb/monitors.py` (`LdpcInputBufferMonitor`)
**Description:** Handshake timing mismatch.
- **Current Behavior:** The monitor samples `info_group_sel_o` and `info_group_i` in the same clock cycle.
- **Impact:** Because `input_buffer.sv` registers its output, `info_group_i` is actually the data for the *previous* `info_group_sel_o`.
- **Recommended Fix:** Latch the address and wait one cycle to capture the corresponding data.

## 4. Pipeline Metadata Alignment
**File:** `sim/pyuvm_tb/monitors.py` (`LdpcShifterMonitor`, `LdpcGf2Monitor`)
**Description:** Fragile metadata tracking.
- **Current Behavior:** Uses `prev_col` and `prev_rows` to track pipeline stage data.
- **Impact:** If `csr_valid_q` or `gf2_en_q` stalls or gaps, the alignment between metadata and the `_qdly` results might slip.
- **Recommended Fix:** Better to latch metadata specifically when `csr_valid_q` is high into a dedicated monitor-side queue or shadow register.

## 5. Top-Level Shifter `use_q_plus` Connection
**File:** `rtl/top_level_shifter.sv`
**Description:** The `use_q_plus` signal is declared but not driven by `group_reordering`.
- **Current Behavior:** `use_q_plus` is likely floating or undeclared-zero.
- **Impact:** Sub-parallel shifters may use the wrong q value during `ZC_MEDIUM` or `ZC_LARGE` modes.
- **Recommended Fix:** Connect the `use_q_plus` output from `group_reordering` (if implemented) or fix the logic in `param_calc_inst`.
