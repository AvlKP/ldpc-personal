# Implementation Plan: Golden Algorithmic Model

## Phase 1: Foundation and CSR Parsing
- [x] Task: Set up the Python module structure (e.g., `sim/golden_model.py`). 3d61d01
- [~] Task: Implement the logic to read and parse the CSR `.mem` files from `rtl/mem/`.
- [ ] Task: Write unit tests to verify the CSR parsing logic accurately reflects the matrices.
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Foundation and CSR Parsing' (Protocol in workflow.md)

## Phase 2: Core Algorithm Implementation & Validation
- [ ] Task: Implement the core encoding algorithm based on the Petrović et al. (2021) architecture.
- [ ] Task: Implement step-by-step intermediate data extraction (hooks) for sub-operations like shift-network and base graph processing.
- [ ] Task: Verify the golden algorithmic model's final encoding result against the `py3gpp` library to ensure standard compliance.
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Core Algorithm Implementation & Validation' (Protocol in workflow.md)

## Phase 3: Integration and Verification
- [ ] Task: Integrate the Python module into an existing cocotb testbench setup.
- [ ] Task: Run end-to-end verification comparing intermediate and final results from the golden model against RTL outputs.
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Integration and Verification' (Protocol in workflow.md)