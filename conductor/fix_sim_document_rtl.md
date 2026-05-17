# Plan: Implement Sim Fixes and Document RTL Bugs

## Objective
Document identified RTL bugs with comments and implement functional fixes for timing-related simulation bugs in the cocotb monitors.

## Key Files
- `rtl/ldpc_encoder_core.sv`
- `rtl/parameter_calculation.sv`
- `rtl/top_level_shifter.sv`
- `sim/pyuvm_tb/monitors.py`

## Implementation Steps

### 1. Document RTL Bugs (Comments Only)
- **`rtl/ldpc_encoder_core.sv`**: Add a `// BUG:` comment to the `row_cnt_n` increment logic noting that `ZC_SMALL` and `ZC_LARGE` cases are reversed.
- **`rtl/parameter_calculation.sv`**: Add a `// BUG:` comment noting that the raw coefficient `p` must be normalized (`p % z`) before calculating the sub-parallel shift amount `q`.
- **`rtl/top_level_shifter.sv`**: Add a `// TODO:` comment noting that `use_q_plus` is declared but currently disconnected from the `group_reordering` module.

### 2. Fix Simulation Timing Bugs (`sim/pyuvm_tb/monitors.py`)
- **`LdpcInputBufferMonitor`**:
    - Refactor to latch `kb_idx` when `inbuff_valid_i` is high.
    - Wait for the next clock cycle to read the corresponding `info_group_i` (since the buffer output is registered).
- **`LdpcShifterMonitor`**:
    - Use a `collections.deque` to queue metadata (`col`, `rows`) when `csr_valid_q` is high.
    - Pop from the queue and write to the analysis port when `csr_valid_qdly` is high, ensuring alignment with the delayed shifter output.
- **`LdpcGf2Monitor`**:
    - Apply the same `deque` pattern as the shifter monitor to align metadata with `gf2_en_qdly` results.

## Verification & Testing
- Manual review of RTL comments to ensure they accurately describe the bugs.
- Run the `pyuvm` test suite to verify that the internal monitors no longer report false-positive mismatches due to timing misalignment.
- Ensure the `golden_model.py` comparison in the scoreboard remains valid with the updated monitors.
