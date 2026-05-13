# Initial Concept
Implementation of a flexible 5G New Radio (NR) LDPC Encoder IP based on Petrović et al. (2021) architecture, targeted at SDR prototyping on Xilinx Vivado.

# Product Definition - 5G NR LDPC Encoder IP

## Product Vision
A flexible, high-efficiency 5G NR LDPC Encoder IP core designed for Software Defined Radio (SDR) prototyping and 5G testbeds. The product leverages a partially parallel architecture to maximize Hardware Usage Efficiency (HUE) across all 5G NR lifting sizes, supporting both high-throughput and resource-constrained FPGA targets.

## Target User
- FPGA Developers and Digital Design Engineers building 5G physical layer (PHY) components.
- SDR Researchers needing a flexible, standards-compliant LDPC implementation for testbeds.

## Key Goals
- **Maximize Hardware Usage Efficiency (HUE):** Minimize idle hardware processing units during the encoding of both long and short codes.
- **High Throughput:** Support multi-gigabit throughput rates suitable for 5G broadband applications.
- **Flexibility:** Complete support for all 5G NR LDPC codes and lifting sizes defined by the standard.

## Technical Specifications
- **RTL Implementation:** Synthesizable SystemVerilog HDL.
- **Interfaces:**
    - **AXI4-Stream (Data):** High-performance streaming interface for information bits and parity bits.
    - **AXI4-Lite (CSRs):** Memory-mapped interface for register-based configuration (refer to `doc/ldpc_encoder_register_map.md`).
- **Target Platform:** Xilinx Vivado (Optimized for Zynq-7000 XC7Z020).
- **Verification Strategy:** cocotb testbenches using Verilator for fast and reliable Python-based verification.

## Architecture Highlights
- Based on the Petrović et al. (2021) architecture.
- Features a flexible circular shifting network.
- Optimized encoding schedules using Genetic Algorithms (GA) to reduce clock cycles per codeword.
