# Verilator Cocotb Flow Guide

This directory provides a cocotb-based verification flow for the LDPC IP cores using Verilator.

## Directory Overview

- `Makefile`: Main simulation entry point and core testbench engine.
- `Makefiles/`: Directory containing modular target definitions (e.g., `input_buffer.mk`, `csr_decoder.mk`).
- `*_tb.py`: Cocotb Python testbench modules.
- `sim_build/<target>/`: Sandboxed directories keeping build outputs and run artifacts isolated per test.
- `results*.xml`: JUnit-style regression results.

## Prerequisites

1. Verilator available on PATH.
2. Python with cocotb installed.
3. `cocotb-config` available on PATH.
4. Optional waveform viewer: Surfer or GTKWave (with FST support).
5. For LDPC core pyuvm verification: `python3 -m pip install pyuvm py3gpp`

## Quick Start

From the `sim` directory, you can run all tests across all modules:

```bash
make all
```

To run test suites for specific modules:

```bash
make group_input_buffer
make group_csr_decoder
make group_ldpc_core
```

## Run Individual Tests

You can launch specific test variants by invoking their targets. 
These targets automatically sandbox themselves into unique `sim_build/<target>` folders.

**Input Buffer:**
- `make test_input_buffer`
- `make test_progressive`
- `make test_zc_edges`
- `make test_reset_edges`
- `make test_payload_edges`
- `make test_bg1_info_sweep`

**CSR Decoder:**
- `make test_csr_decoder`
- `make test_csr_bg1`
- `make test_csr_bg2`
- `make test_csr_arbitrary`
- `make test_csr_backpressure`

**LDPC Encoder Top-Level (pyuvm):**
- `make test_ldpc_encoder_core`

## Waveform Generation and Viewing

Tracing is enabled by default in the new unified `Makefile` via `WAVES ?= 1` and tracing arguments output in FST format (`--trace-fst`). 

When a test completes, any dumped `.fst` files will be placed either natively in the test's `sim_build/<target>/` directory or in the root `sim/` folder.

To view them, you can use Surfer:
```bash
surfer dump.fst
```
*(Or GTKWave if preferred)*

## Useful Outputs

- Regression summary: Printed in the terminal by cocotb.
- JUnit-style reports: Found at `sim_build/<target>/results.xml`.
- Build artifacts: `sim_build/<target>/`.

## Troubleshooting

1. Test selection not working:
- Confirm test function names match the `COCOTB_TEST_FILTER` in the respective `Makefiles/*.mk` definitions.

2. Adding new modules:
- Create a new `.mk` in the `Makefiles/` folder (it will be auto-included).
- Define your new targets using the `run_test` macro.
- Add your new group summary to the `all` dependency list in the top-level `Makefile`.
- Run `make clean` before kicking off tests after a structural change.
