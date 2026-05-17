# Refactor pyUVM Testbench into Separate Components

## Objective
Refactor the monolithic `sim/ldpc_encoder_core_pyuvm_tb.py` into a modular, multi-file structure within `sim/pyuvm/` adhering to pyUVM/cocotb best practices while maintaining whitebox verification hooks. Do not modify the `golden_model.py` parity calculation logic.

## Key Files & Context
- `sim/ldpc_encoder_core_pyuvm_tb.py` (Current monolithic testbench)
- `sim/pyuvm/` (New directory for components)
- `sim/pyuvm/seq_items.py`
- `sim/pyuvm/bfm.py`
- `sim/pyuvm/driver.py`
- `sim/pyuvm/monitors.py`
- `sim/pyuvm/scoreboards.py`
- `sim/pyuvm/agent_env.py`
- `sim/pyuvm/test.py`

## Implementation Steps
1. **Create `seq_items.py`**: Extract `LdpcFrameItem` and `LdpcFrameSequence`, along with the `FrameCfg` dataclass.
2. **Create `bfm.py`**: Extract `TransactionRecorder` and `LdpcTopBfm`.
3. **Create `driver.py`**: Extract `LdpcDriver`.
4. **Create `monitors.py`**: Extract `LdpcInputBufferMonitor`, `LdpcShifterMonitor`, `LdpcGf2Monitor`, `LdpcLambdaMonitor`, and `LdpcOutputMonitor`.
5. **Create `scoreboards.py`**: Extract `LdpcInternalScoreboard` and `LdpcScoreboard`.
6. **Create `agent_env.py`**: Extract `LdpcAgent` and `LdpcEnv`.
7. **Create `test.py` (or keep `ldpc_encoder_core_pyuvm_tb.py` as entry point)**: Update the main test file to import these components and assemble the test. We will keep `sim/ldpc_encoder_core_pyuvm_tb.py` as the main entry point to avoid breaking the Makefile, but have it import everything from `sim/pyuvm/`.
8. **Python imports**: Ensure all classes have the necessary imports from `cocotb`, `pyuvm`, and standard libraries within their new files. Provide `golden_model.py` import correctly (adjusting for path if necessary or putting everything in `sim/`).

## Verification & Testing
- Run `make test_ldpc_encoder_core` in the `sim` directory.
- Verify the test compiles and runs as before. The mismatch error will still occur (as requested by user to leave it), but the structure will be modularized.