# 5G NR LDPC Encoder IP

This project is an implementation of a 5G New Radio (NR) LDPC Encoder IP, optimized for high hardware usage efficiency.
The implementation is an adaptation of Petrović's paper. It adds the novelty of using Compressed Sparse Row (CSR) format to store base graphs.

## Architecture & Design
- **Source:** Based on Petrović et al. (2021) "Flexible 5G New Radio LDPC Encoder Optimized for High Hardware Usage Efficiency".
- **RTL Language:** SystemVerilog HDL.
- **Target Platform:** Xilinx Vivado.
- **Target FPGA:** XC7Z020 (Zynq-7000).
- **Optimization Mandate:** Use platform-specific primitives (DSP48, BRAM, LUTRAM) when they provide PPA benefits.
- **Verification:** 
  - [cocotb](https://www.cocotb.org/) (Python-based verification framework).
  - SystemVerilog testbenches.
  - Simulator: Verilator (configured via `verilator.f` and `sim/Makefile`).

## RTL Analysis Rules

### Combinational Logic
- Thoroughly analyze and review all combinational modules using the `sv-synth` skill.
- Ensure logic is clean, synthesizable, and follows best practices.

### Sequential Logic
- Perform preliminary analysis using the `sv-synth` and `rtl-verify` skills.
- If understanding is insufficient, **ASK** for further instructions.
- If instructed, write a **simple, separate cocotb testbench** focused on logic inspection (e.g., using Python loggers) rather than full functional verification.
- For instantiated modules, focus analysis on I/O behavior and interface timing.

### Evaluation Report
After analysis, provide an evaluation containing:
1. **Resource Estimation:** Predicted LUT/FF/BRAM/DSP usage.
2. **Timing & Performance:** Estimated clock frequency (Fmax) and throughput/latency.
3. **Best Practices:** Recommendations for RTL improvement.
4. **Bug Analysis:** Identification of potential race conditions, reset issues, or logic errors.

## Workflow Mandates

### Skill Activation
To ensure consistent quality and adherence to domain-specific best practices, the following skills **MUST** be activated based on the task:

- **RTL Coding / Synthesis:** Always activate the `sv-synth` skill.
- **Verification / Simulation:** Always activate the `rtl-verify` (modern-verification-methodologies) skill.

### Directory Structure
- `rtl/`: SystemVerilog source files.
- `sim/`: Verification environment, cocotb testbenches, and Makefiles.
- `doc/`: Architectural documentation and reference papers.
- `scripts/`: Build and automation scripts.

## Verification Details
Cocotb testbenches are executed using Verilator. Use the provided `sim/Makefile` for running simulations.

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
