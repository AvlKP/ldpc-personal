# Architecture Mapping: Petrović 2021 to Current RTL

This document maps the concepts from the reference paper to the SystemVerilog modules in the `rtl/` directory.

## Core Architectural Differences
**Novelty - Compressed Sparse Row (CSR) Schedule:** 
Unlike the hardcoded schedule optimized via Genetic Algorithm in the paper, this implementation uses a CSR decoder (`csr_decoder.sv`) backed by ROMs (`rtl/mem/*.mem`) to dynamically drive the shifter schedule. The `csr_decoder` iterates over non-zero elements of the PCM rows. It uses a valid/ready handshake, starting an execution block via `start_i` when `row_i` changes, and signaling completion with `rg_changed_o`.

## Figure 11: Proposed 5G NR LDPC encoder architecture

| Paper Concept / Block | Corresponding RTL Module | Notes |
| :--- | :--- | :--- |
| **Encoder Core (Dotted Line)** | `ldpc_encoder_core.sv` | The main computational engine. Instantiates the shifter, CSR decoder, and parity calculators. |
| **Top-Level Wrapper** | `ldpc_encoder.sv` | Wraps the core. Instantiates `input_buffer.sv`, `output_buffer.sv`, and implements AXI4-Stream (Data) and AXI4-Lite (CSR) interfaces. |
| **Input Buffer** | `input_buffer.sv` | Dual-port memory for double buffering. Instantiated in `ldpc_encoder.sv`. |
| **Flexible Cyclic Shifter (CS)** | `top_level_shifter.sv` | Implements the shifting network. Sub-modules require scrutiny during evaluation due to coding style. |
| **GF(2) Sum** | `gf2_sum.sv` | XOR summation network for λ vector calculation. |
| **Merge / Select λ** | `merge_sel_lambda.sv` | Arranges λ vectors for core parity bit calculation. |
| **Calculate core parity bits** | `core_parity_bit_calculator.sv` | Calculates the initial core parity bits ($p_{c,1}$ through $p_{c,4}$). Note: `parity_core_calc.sv` is deprecated. |
| **Output code word generator** | `codeword_generator.sv` | Collects information and parity bits for output. |
| **Output Buffer** | `output_buffer.sv` | Instantiated in `ldpc_encoder.sv`. |

## Figure 10: Shifting network architecture

| Paper Concept / Block | Corresponding RTL Module | Notes |
| :--- | :--- | :--- |
| **Direct bit permutation** | `direct_bit_permutation.sv` | Rearranges bits before shifting for large lifting sizes. Needs scrutiny. |
| **Shifter 1-4 ($Z \le 96$)** | `barrel_shifter.sv` | The core 96-bit pre-rotator/QSN shifters. Needs scrutiny. |
| **Group reordering** | `group_reordering.sv` | Reorders bits after shifting depending on the shift remainder. Needs scrutiny. |
| **Inverse bit permutation** | *(Likely integrated into group reordering or top level)* | To be verified during code inspection. |
| **Parameters calculation** | `parameter_calculation.sv` | Calculates $D$, $P \bmod D$, $Z/D$, $Q/Q+1$ values for the shifting network. |

## Parameter Calculation / Decoders
- `zc_decoder.sv`: Decodes the lifting size index ($Z_c$) into the actual lifting size ($Z$).
- `set_index_decoder.sv`: Decodes the base graph lifting set index.
- `csr_decoder.sv`: Decodes the CSR ROMs (`mem/`) to provide shift values and CPM positions to the shifting network.
