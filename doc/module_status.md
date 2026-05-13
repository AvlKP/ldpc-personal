# RTL Module Status

This document tracks the completion status of the modules in the `rtl/` directory based on static analysis.

## Incomplete / Skeleton Modules
- `ldpc_encoder_core.sv`: **CRITICAL**. File is essentially a skeleton/empty. Contains a TODO: `// TODO: only change after permutation and input bit is synced after delay`.
- `top_level_shifter.sv`: Contains TODO: `// Select between q and q_plus for this specific shifter TODO get use_q_plus from group reordering`.
- `parity_core_calc.sv`: Marked as deprecated in `architecture_mapping.md`.

## Modules requiring scrutiny (per user notes)
- `barrel_shifter.sv`
- `direct_bit_permutation.sv`
- `group_reordering.sv`
- `top_level_shifter.sv`

## Implemented Modules (Pending Evaluation)
- `codeword_generator.sv`
- `core_parity_bit_calculator.sv`
- `csr_decoder.sv`
- `gf2_sum.sv`
- `input_buffer.sv`
- `input_sel.sv`
- `ldpc_encoder.sv` (Top-level wrapper, missing core instantiation)
- `lutram.sv`
- `lutrom.sv`
- `merge_sel_lambda.sv`
- `output_buffer.sv`
- `parameter_calculation.sv`
- `rom_dp.sv`
- `set_index_decoder.sv`
- `zc_decoder.sv`
