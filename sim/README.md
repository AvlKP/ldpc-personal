# Verilator Cocotb Flow Guide

This directory provides a cocotb-based verification flow for the `input_buffer` DUT using Verilator.

## Directory Overview

- `Makefile`: main simulation entry point and test targets.
- `input_buffer_tb.py`: cocotb testbench module.
- `sim_build/`: Verilator build outputs.
- `results.xml`: cocotb regression results file.
- `dump.vcd`: waveform dump file (when tracing is enabled).

## Prerequisites

1. Verilator available on PATH.
2. Python with cocotb installed.
3. `cocotb-config` available on PATH.
4. Optional waveform viewer: GTKWave.

## Quick Start

From repository root:

```bash
cd /foss/designs/ldpc_personal/sim
make test_all
```

This runs all cocotb tests defined in `input_buffer_tb.py`.

## Run Individual Tests

From the `sim` directory:

- Progressive continuous scenario test:

```bash
make test_progressive
```

- Zc boundary/edge scenarios:

```bash
make test_zc_edges
```

- Mid-stream reset edge scenarios:

```bash
make test_reset_edges
```

- Payload size edge scenarios:

```bash
make test_payload_edges
```

## Waveform Generation and Viewing

For Verilator, tracing must be enabled at build/run time.

1. Clean any previous non-trace build:

```bash
make clean
```

2. Rebuild and run with tracing enabled:

```bash
make test_all VERILATOR_TRACE=1
```

3. Open waveform:

```bash
gtkwave /foss/designs/ldpc_personal/sim/dump.vcd
```

Notes:

- If you see `--trace requires the design to be built with trace support`, run `make clean` and rerun with `VERILATOR_TRACE=1`.
- The waveform file is produced as `dump.vcd` in this `sim` directory.

## Common Targets

- `make test_all`
- `make test_progressive`
- `make test_zc_edges`
- `make test_reset_edges`
- `make test_payload_edges`
- `make clean`

## Useful Outputs

- Regression summary: printed in terminal by cocotb.
- JUnit-style report: `results.xml`.
- Build artifacts: `sim_build/`.
- Waveform dump (trace-enabled runs): `dump.vcd`.

## Troubleshooting

1. `cocotb-config` not found:

- Ensure cocotb is installed in the active Python environment.
- Verify PATH includes the environment scripts/bin directory.

2. Verilator not found:

- Install Verilator and ensure it is on PATH.

3. No waveform file after run:

- Use `VERILATOR_TRACE=1`.
- Run `make clean` before rerunning.

4. Test selection not working:

- Use the provided Make targets.
- Confirm test names in `input_buffer_tb.py` when adding new tests.

## Extending the Flow

- Add new cocotb tests in `input_buffer_tb.py`.
- Add corresponding convenience targets in `Makefile` using `COCOTB_TEST_FILTER`.
- Keep the clean target updated for any new generated artifacts.