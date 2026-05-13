# LDPC Encoder Interconnection Map

This document outlines the structural connectivity and data flow of the 5G NR LDPC Encoder IP.

## Top-Level Interconnect (`ldpc_encoder.sv`)

The top-level module is responsible for bridging the standard AXI interfaces to the internal IP core logic.

### Expected Hierarchy
```text
ldpc_encoder.sv (Top Level)
├── axi_lite_regs (ldpc_regs) - Instantiated. Manages CSRs.
├── input_buffer.sv           - Missing Instantiation. Handles AXI4-Stream data ingest.
├── output_buffer.sv          - Missing Instantiation. Handles AXI4-Stream data egress.
└── ldpc_encoder_core.sv      - Missing Instantiation. The main processing engine.
```

### Module Status: Incomplete Integration
The `ldpc_encoder.sv` currently ONLY instantiates the `axi_lite_regs` module. The AXI Stream input, AXI Stream output, and the actual `LDPC Core` (`ldpc_encoder_core.sv`) are marked with comments but are **not instantiated**.

Furthermore, `ldpc_encoder_core.sv` is currently an **empty file**. 

## Expected Data Flow (Based on Architecture Mapping)

Once implemented, the expected data flow should be:

1. **Configuration:** The CPU writes to the configuration registers via the AXI4-Lite interface (handled by `axi_lite_regs`). This sets the `base_graph`, `lifting_size`, and block lengths.
2. **Data Ingest:** Unencoded data blocks arrive via the `s_axis` AXI4-Stream interface and are written into the `input_buffer.sv`. The input buffer provides double-buffering.
3. **Core Processing:** 
   - The `ldpc_encoder_core` initiates encoding.
   - The `csr_decoder` (inside the core) reads the sparse matrix ROMs and generates the shifting schedule.
   - The `input_buffer` streams wide data vectors to the `top_level_shifter`.
   - The shifted vectors are accumulated in `gf2_sum`.
   - `core_parity_bit_calculator` computes the initial parity bits.
4. **Data Egress:** Parity and information bits are gathered by the `codeword_generator` and written to the `output_buffer.sv`.
5. **Output Stream:** The encoded block is streamed out via the `m_axis` AXI4-Stream interface.

## Critical Incompleteness
- `ldpc_encoder_core.sv`: Completely empty. Needs full implementation linking the CS network, parity calculators, and CSR decoder.
- `ldpc_encoder.sv`: Missing instantiations for `input_buffer`, `output_buffer`, and `ldpc_encoder_core`.
