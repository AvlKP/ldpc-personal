# Specification - RTL Audit and Evaluation

## Goal
Perform a comprehensive static analysis and architectural review of the current SystemVerilog RTL implementation to ensure alignment with the Petrović et al. (2021) architecture and Xilinx Vivado best practices.

## Scope
- **Analysis:** All files in the `rtl/` directory.
- **Mapping:** Creation of a module hierarchy and interconnection map.
- **Evaluation:** Generation of detailed reports for core modules (LDPC Encoder, Shifters, Parity Calculators, Buffers).
- **Audit:** Identifying potential bugs, timing bottlenecks, and optimization opportunities (DSP48, BRAM).

## Deliverables
- Module interconnection map (documented in `doc/`).
- Evaluation reports for major modules in `doc/` following the `GEMINI.md` template.
- Identification of any architectural deviations from the reference paper.

## Constraints
- **No Simulation:** This track is strictly for analysis and documentation.
- **Read-Only Analysis:** No modifications to the RTL code are permitted in this track.
- **Target:** Xilinx XC7Z020 FPGA.
