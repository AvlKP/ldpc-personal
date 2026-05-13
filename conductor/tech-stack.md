# Technology Stack - 5G NR LDPC Encoder IP

## Design & Implementation
- **HDL Language:** SystemVerilog (IEEE 1800)
- **Synthesis & Implementation:** Xilinx Vivado
- **Target Platform:** Xilinx XC7Z020 (Zynq-7000 SoC)
- **Key IP Primitives:**
    - DSP48E1 (Arithmetic operations)
    - Block RAM / LUTRAM (Buffers and PCM Exponent Storage)

## Verification Environment
- **Simulator:** Verilator (Open-source SystemVerilog simulator)
- **Verification Framework:** [cocotb](https://www.cocotb.org/) (Coroutines-based Co-simulation Testbench)
- **Language:** Python 3
- **Testbench Execution:** `make` based flow for simulator integration.

## Build & Automation
- **Package Manager:** Bender (Dependency management for SystemVerilog)
- **Build Scripts:** Tcl (Vivado project automation) and Python (simulation management)
