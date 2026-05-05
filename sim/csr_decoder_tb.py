import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import random
import os
import re

# Constants based on typical 5G NR LDPC
BG1_MAX_ROW_GROUP = 12  # ceil(46/4)
BG2_MAX_ROW_GROUP = 11  # ceil(42/4)
BG1_ROW_COUNT = 46      # Offset used to locate BG2 rows in the unified memory

# Global cache so we only parse the files once per simulation run
_cached_golden_matrix = None
_golden_matrix_loaded = False

def load_golden_matrix(dut):
    """
    Parses the human-readable text files to generate a golden reference matrix.
    Format: golden_matrix[physical_row][col] = value
    """
    global _cached_golden_matrix, _golden_matrix_loaded
    
    if _golden_matrix_loaded:
        return _cached_golden_matrix

    data_dir = os.environ.get("GOLDEN_DATA_DIR", ".")
    
    # Safely construct the full absolute paths
    row_ptr_path = os.path.join(data_dir, "row_ptr_readable.txt")
    col_idx_path = os.path.join(data_dir, "col_indices_readable.txt")
    val_path = os.path.join(data_dir, "values_readable.txt")

    try:
        def parse_file_safe(filepath):
            with open(filepath, "r") as f:
                content = f.read()
            # Replace common separators with spaces
            for char in [',', '\n', '\r', '\t']:
                content = content.replace(char, ' ')
            # Safely extract pure digits only (avoids words like "36-bit")
            return [int(w) for w in content.split() if w.isdigit()]

        row_ptrs = parse_file_safe(row_ptr_path)
        col_indices = parse_file_safe(col_idx_path)
        values = parse_file_safe(val_path)
        
        # Sanity checking to avoid infinite loops
        if len(row_ptrs) == 0:
            dut._log.warning("Row pointers list is empty!")
            _golden_matrix_loaded = True
            return None

        golden_matrix = {}
        for r in range(len(row_ptrs) - 1):
            golden_matrix[r] = {}
            start_idx = row_ptrs[r]
            end_idx = row_ptrs[r+1]
            
            # Protect against invalid ranges and corrupted parsing bounds
            if start_idx >= end_idx or (end_idx - start_idx) > 10000:
                continue 
                
            for idx in range(start_idx, end_idx):
                if idx < len(col_indices) and idx < len(values):
                    golden_matrix[r][col_indices[idx]] = values[idx]
                    
        dut._log.info("Golden matrix successfully loaded and mapped.")
        
        _cached_golden_matrix = golden_matrix
        _golden_matrix_loaded = True
        return golden_matrix

    except Exception as e:
        # Catch ALL exceptions (like ValueErrors, OSErrors) so the coroutine doesn't silently die
        dut._log.warning(f"Golden data loading failed, skipping integrity checks. Error: {e}")
        _golden_matrix_loaded = True
        return None

async def reset_dut(dut):
    """Asserts reset and initializes all control signals."""
    dut.arst_ni.value = 0
    dut.ldpc_ready_i.value = 0
    dut.start_i.value = 0
    dut.base_graph_i.value = 0
    dut.row_i.value = 0
    
    await ClockCycles(dut.clk_i, 5)
    
    dut.arst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)

async def wait_for_row_completion(dut, row_group, bg, golden_matrix):
    """
    Monitors the DUT output and compares it against the golden matrix.
    Validates column-by-column as dictated by dut.col_curr_o to handle
    sparse missing values (-1).
    """
    # Base graph offsets: BG1 starts at physical row 0, BG2 starts at row 46
    bg1_row_count = 46
    base_row = (row_group * 4) + (bg1_row_count if bg == 1 else 0)
    max_rows = 46 if bg == 0 else 42
    
    while True:
        await RisingEdge(dut.clk_i)
        
        # 1. Sample only on a valid handshake
        if dut.ldpc_valid_o.value == 1 and dut.ldpc_ready_i.value == 1:
            
            # 2. Extract the absolute column index from the DUT
            current_col = dut.col_curr_o.value.to_unsigned()
            
            # 3. Verify each of the 4 parallel physical rows
            for i in range(4):
                physical_row = base_row + i
                
                # Handle ghost rows (out of bounds for the base graph)
                if (row_group * 4 + i) >= max_rows:
                    expected_val = -1
                else:
                    # Extract the expected value for the current column
                    # This gracefully handles both List[Dict] and List[List] golden matrices
                    row_data = golden_matrix[physical_row]
                    if isinstance(row_data, dict):
                        expected_val = row_data.get(current_col, -1)
                    else:
                        try:
                            expected_val = row_data[current_col]
                        except IndexError:
                            expected_val = -1
                
                # Read actual values from the DUT
                actual_val = dut.permutation_o[i].value.to_unsigned()
                
                # In 9-bit unsigned two's complement, -1 is 511 (0x1FF)
                if actual_val == 511:  
                    actual_val = -1
                    
                # Bit extraction for gf2_en_o 
                actual_gf2_en = (dut.gf2_en_o.value.to_unsigned() >> i) & 1
                expected_gf2_en = 1 if expected_val != -1 else 0
                
                # Assertions
                assert actual_val == expected_val, (
                    f"Value mismatch at BG={bg}, Row Group={row_group}, Physical Row={physical_row}, "
                    f"Col={current_col}. Expected: {expected_val}, Actual: {actual_val}"
                )
                
                assert actual_gf2_en == expected_gf2_en, (
                    f"GF2_EN mismatch at BG={bg}, Row Group={row_group}, Physical Row={physical_row}, "
                    f"Col={current_col}. Expected: {expected_gf2_en}, Actual: {actual_gf2_en}"
                )
                
            # 4. Exit condition: row_change_o flags the end of the row group processing
            if dut.row_change_o.value == 1:
                break

@cocotb.test()
async def test_bg1_full_sweep(dut):
    """Test the complete sweeping of Base Graph 1 from row group 0 to finish."""
    dut._log.info("=== Starting test_bg1_full_sweep ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ldpc_ready_i.value = 1
    dut.base_graph_i.value = 0

    dut._log.info("Starting BG1 row sweep...")
    for row_idx in range(BG1_MAX_ROW_GROUP):
        dut.row_i.value = row_idx
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0
        
        await wait_for_row_completion(dut, row_idx, 0, golden_matrix)
        dut._log.info(f"Completed BG1 row group {row_idx}.")
        
    await ClockCycles(dut.clk_i, 10)

@cocotb.test()
async def test_bg2_full_sweep(dut):
    """Test the complete sweeping of Base Graph 2 from row group 0 to finish."""
    dut._log.info("=== Starting test_bg2_full_sweep ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ldpc_ready_i.value = 1
    dut.base_graph_i.value = 1

    dut._log.info("Starting BG2 row sweep...")
    for row_idx in range(BG2_MAX_ROW_GROUP):
        dut.row_i.value = row_idx
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0
        
        await wait_for_row_completion(dut, row_idx, 1, golden_matrix)
        dut._log.info(f"Completed BG2 row group {row_idx}.")

    await ClockCycles(dut.clk_i, 10)

@cocotb.test()
async def test_arbitrary_input_changes(dut):
    """Verifies that start_i and other input changes are ignored safely during VALID state."""
    dut._log.info("=== Starting test_arbitrary_input_changes ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ldpc_ready_i.value = 1
    dut.base_graph_i.value = 0
    dut.row_i.value = 0
    dut.start_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.start_i.value = 0

    # Wait until FSM enters VALID state to start interference
    while dut.ldpc_valid_o.value != 1:
        await RisingEdge(dut.clk_i)

    # Spawn an asynchronous thread to independently monitor correctness
    monitor_task = cocotb.start_soon(wait_for_row_completion(dut, 0, 0, golden_matrix))

    # Throw chaotic permutations onto inputs while the row is being processed
    timeout_ctr = 0
    while not monitor_task.done():
        toggle_mask = random.randint(1, 7)
        
        start_val = 1 if (toggle_mask & 0b001) else 0
        bg_val = random.choice([0, 1]) if (toggle_mask & 0b010) else dut.base_graph_i.value
        row_val = random.randint(0, 11) if (toggle_mask & 0b100) else dut.row_i.value
        
        dut.start_i.value = start_val
        dut.base_graph_i.value = bg_val
        dut.row_i.value = row_val
        
        await RisingEdge(dut.clk_i)
        timeout_ctr += 1
        if timeout_ctr > 5000:
            assert False, "Timeout! RTL deadlocked during arbitrary input changes."
        
    await monitor_task # Ensure monitor completed without exceptions

    # Cleanup and verify graceful finishing
    dut.start_i.value = 0
    await ClockCycles(dut.clk_i, 20)

@cocotb.test()
async def test_backpressure_and_delays(dut):
    """Test randomized backpressure and arbitrary start delays between row fetches."""
    dut._log.info("=== Starting test_backpressure_and_delays ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    for i in range(10): 
        bg = random.choice([0, 1])
        row_max = BG1_MAX_ROW_GROUP if bg == 0 else BG2_MAX_ROW_GROUP
        row = random.randint(0, row_max - 1)

        delay = random.randint(5, 50)
        dut.ldpc_ready_i.value = 0
        await ClockCycles(dut.clk_i, delay)

        dut.base_graph_i.value = bg
        dut.row_i.value = row
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0

        # Delegate validation to the standard robust monitor
        monitor_task = cocotb.start_soon(wait_for_row_completion(dut, row, bg, golden_matrix))

        # Randomly toggle backpressure while the row group streams out
        timeout_ctr = 0
        while not monitor_task.done():
            dut.ldpc_ready_i.value = random.choices([0, 1], weights=[1, 1])[0]
            await RisingEdge(dut.clk_i)
            
            timeout_ctr += 1
            if timeout_ctr > 5000:
                dut._log.error(f"Timeout! valid_o={dut.ldpc_valid_o.value}, ready_i={dut.ldpc_ready_i.value}, row_change_o={dut.row_change_o.value}")
                assert False, "Timeout waiting for row completion. RTL might be dropping signals when not ready, or ignoring start_i!"

        await monitor_task # Catch any exception thrown by the monitor
        dut._log.info(f"Iter {i}: Done.")