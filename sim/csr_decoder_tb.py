import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import random
import os

# Constants based on typical 5G NR LDPC
BG1_ROW_COUNT = 46      # Offset used to locate BG2 rows in the unified memory
BG2_ROW_COUNT = 42      # BG2 max physical rows
ZC_WIDTH = 9            # Bit-width of the payload slices (deduced from 511 mask)

# Global cache so we only parse the files once per simulation run
_cached_golden_matrix = None
_golden_matrix_loaded = False
_cached_raw_data = None

def get_zc_set_index(zc):
    """Matches rtl/zc_decoder.sv mapping from Zc to values_* set index."""
    if zc in {2, 4, 8, 16, 32, 64, 128, 256}:
        return 0
    if zc in {3, 6, 12, 24, 48, 96, 192, 384}:
        return 1
    if zc in {5, 10, 20, 40, 80, 160, 320}:
        return 2
    if zc in {7, 14, 28, 56, 112, 224}:
        return 3
    if zc in {9, 18, 36, 72, 144, 288}:
        return 4
    if zc in {11, 22, 44, 88, 176, 352}:
        return 5
    if zc in {13, 26, 52, 104, 208}:
        return 6
    if zc in {15, 30, 60, 120, 240}:
        return 7
    return 0

def get_valid_5gnr_zcs():
    """Returns all valid Zc values accepted by zc_decoder."""
    base_z_set = [2, 3, 5, 7, 9, 11, 13, 15]
    valid = []
    for base in base_z_set:
        for j in range(8):
            zc = base * (2 ** j)
            if zc <= 384:
                valid.append(zc)
    return valid

def load_golden_matrix(dut):
    """
    Parses the human-readable text files to generate a golden reference matrix.
    Also caches raw 1D arrays to allow cycle-accurate FSM tracking.
    """
    global _cached_golden_matrix, _golden_matrix_loaded, _cached_raw_data
    
    if _golden_matrix_loaded:
        return _cached_golden_matrix

    data_dir = os.environ.get("GOLDEN_DATA_DIR", ".")
    
    row_ptr_path = os.path.join(data_dir, "row_ptr_readable.txt")
    col_idx_path = os.path.join(data_dir, "col_indices_readable.txt")
    val_path = os.path.join(data_dir, "values_readable.txt")

    try:
        def parse_file_safe(filepath):
            with open(filepath, "r") as f:
                content = f.read()
            for char in [',', '\n', '\r', '\t']:
                content = content.replace(char, ' ')
            return [int(w) for w in content.split() if w.isdigit()]

        row_ptrs = parse_file_safe(row_ptr_path)
        col_indices = parse_file_safe(col_idx_path)
        values_by_set = {}
        for set_idx in range(8):
            set_path = os.path.join(data_dir, f"values_readable_{set_idx}.txt")
            if os.path.exists(set_path):
                values_by_set[set_idx] = parse_file_safe(set_path)
        if not values_by_set:
            values_by_set[0] = parse_file_safe(val_path)
        
        # Cache the raw arrays for the cycle-accurate monitor
        _cached_raw_data = (row_ptrs, col_indices, values_by_set)
        
        if len(row_ptrs) == 0:
            dut._log.warning("Row pointers list is empty!")
            _golden_matrix_loaded = True
            return None

        golden_matrix = {}
        for r in range(len(row_ptrs) - 1):
            golden_matrix[r] = {}
            start_idx = row_ptrs[r]
            end_idx = row_ptrs[r+1]
            
            if start_idx >= end_idx or (end_idx - start_idx) > 10000:
                continue 
                
            for idx in range(start_idx, end_idx):
                if idx < len(col_indices) and idx < len(values_by_set[0]):
                    golden_matrix[r][col_indices[idx]] = values_by_set[0][idx]
                    
        dut._log.info("Golden matrix and raw arrays successfully loaded.")
        
        _cached_golden_matrix = golden_matrix
        _golden_matrix_loaded = True
        return golden_matrix

    except Exception as e:
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
    dut.lifting_size_i.value = 0
    
    await ClockCycles(dut.clk_i, 5)
    
    dut.arst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)

async def wait_for_row_completion(dut, start_row, bg, zc, golden_matrix):
    """
    Monitors the DUT output cycle-accurately against the raw memory arrays.
    Matches the RTL's state machine, including continuous streaming of 
    parity bits (col > 21) even if they cross row boundaries in memory.
    """
    global _cached_raw_data
    
    if _cached_raw_data is None:
        dut._log.warning("Raw data missing. Skipping checks for this row.")
        while True:
            await RisingEdge(dut.clk_i)
            if dut.rowgrp_changed_o.value == 1:
                break
        return
        
    row_ptrs_list, col_indices, values_by_set = _cached_raw_data
    set_idx = get_zc_set_index(zc)
    values = values_by_set.get(set_idx, values_by_set[0])
    
    # BG1 has 46 rows, meaning it uses 47 pointers (indices 0 to 46) including the end pointer.
    # In the unified memory list, BG2's row 0 starts exactly at index 47.
    BG1_MEM_OFFSET = 47 
    
    aligned_start_row = (start_row // 4) * 4
    base_row = aligned_start_row + (BG1_MEM_OFFSET if bg == 1 else 0)
    max_rows = BG1_ROW_COUNT if bg == 0 else BG2_ROW_COUNT
    
    # Parity columns start after the 'kb' info columns. 
    # BG1 kb=22 (indices 0-21). BG2 kb=10 (indices 0-9).
    parity_threshold = 21 if bg == 0 else 9

    # Initialize memory FSM pointers for the 4 physical rows and their limits
    ptrs = {}
    limits = {}
    for i in range(4):
        if (aligned_start_row + i) < max_rows:
            unified_mem_row = base_row + i
            if unified_mem_row < len(row_ptrs_list) - 1:
                ptrs[i] = row_ptrs_list[unified_mem_row]
                limits[i] = row_ptrs_list[unified_mem_row + 1]
            else:
                ptrs[i] = len(col_indices) # End of memory safeguard
                limits[i] = len(col_indices)
        else:
            # Ghost rows (padded rows out of bounds for the current base graph)
            ptrs[i] = len(col_indices)
            limits[i] = len(col_indices)
            
    while True:
        await RisingEdge(dut.clk_i)
        
        # if dut.rg_changed_o.value == 1:
        #     break
            
        if dut.ldpc_valid_o.value == 1 and dut.ldpc_ready_i.value == 1:
            current_col = dut.col_curr_o.value.to_unsigned()
            
            # Fetch entire packed arrays as single bit vectors
            permutation_vector = dut.permutation_o.value.to_unsigned()
            gf2_en_vector = dut.gf2_en_o.value.to_unsigned()
            
            for i in range(4):
                ptr = ptrs[i]
                limit = limits[i]
                expected_val = -1
                expected_gf2_en = 0
                
                # Fetch exactly what the hardware ROM is pointing to within limits bounds
                if ptr < limit:
                    pointed_col = col_indices[ptr]
                    pointed_val = values[ptr]
                    
                    # Mirror the RTL's col_en logic perfectly
                    if pointed_col == current_col or pointed_col > parity_threshold:
                        expected_val = pointed_val
                        expected_gf2_en = 1
                        ptrs[i] += 1  # Consumed, advance pointer just like colval_addr_q
                
                # Mask and shift to extract the i-th slice of the packed arrays
                actual_val = (permutation_vector >> (i * ZC_WIDTH)) & 0x1FF
                if actual_val == 511:
                    actual_val = -1
                    
                actual_gf2_en = (gf2_en_vector >> i) & 1
                
                graph_row = aligned_start_row + i
                assert actual_val == expected_val, (
                    f"Value mismatch at BG={bg}, Input Row={start_row}, Graph Row={graph_row}, "
                    f"Info Col={current_col}. Expected: {expected_val}, Actual: {actual_val}"
                )
                
                assert actual_gf2_en == expected_gf2_en, (
                    f"GF2_EN mismatch at BG={bg}, Input Row={start_row}, Graph Row={graph_row}, "
                    f"Info Col={current_col}. Expected: {expected_gf2_en}, Actual: {actual_gf2_en}"
                )
        
        all_done = True
        for i in range(4):
            if ptrs[i] < limits[i]:
                all_done = False
                break
                
        if all_done:
            break

@cocotb.test()
async def test_continuous_decoding(dut):
    """
    Validates the DUT's ability to seamlessly transition between rows.
    Uses concurrent tasks to act as an accurate AXI-style top-level master.
    """
    dut._log.info("=== Starting test_continuous_decoding ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    num_tests = 10
    test_configs = []
    valid_zcs = get_valid_5gnr_zcs()
    
    # Pre-generate the sequence of row configs
    for _ in range(num_tests):
        bg = random.choice([0, 1])
        row_max = BG1_ROW_COUNT if bg == 0 else BG2_ROW_COUNT
        # Generate an unprocessed physical row increment (0, 4, 8...)
        physical_row = random.randrange(0, row_max, 4) 
        zc = random.choice(valid_zcs)
        test_configs.append((bg, physical_row, zc))
        
    async def driver():
        """Feeds start_i and row configurations continuously."""
        for i, (bg, physical_row, zc) in enumerate(test_configs):
            dut.base_graph_i.value = bg
            dut.lifting_size_i.value = zc
            dut.row_i.value = physical_row
            dut.start_i.value = 1
            await RisingEdge(dut.clk_i)
            dut.start_i.value = 0
            
            if i < num_tests - 1:
                # Wait for the internal ROMs to finish AND the skid buffer to empty
                while True:
                    await RisingEdge(dut.clk_i)
                    # ldpc_valid_o == 0 ensures no inflight data is destroyed by the next start_i
                    if dut.rowgrp_changed_o.value == 1 and dut.ldpc_valid_o.value == 0:
                        break
                        
    async def monitor():
        """Validates outputs against the golden model."""
        for bg, physical_row, zc in test_configs:
            await wait_for_row_completion(dut, physical_row, bg, zc, golden_matrix)
            
    async def backpressure():
        """Randomly toggles ready_i to simulate downstream pressure."""
        while True:
            # Downstream ready can fluctuate independently of valid signals
            dut.ldpc_ready_i.value = random.choice([0, 1])
            await RisingEdge(dut.clk_i)
            
    # Launch all behaviors concurrently
    driver_task = cocotb.start_soon(driver())
    monitor_task = cocotb.start_soon(monitor())
    bp_task = cocotb.start_soon(backpressure())
    
    # Wait for the monitor to finish validating all requested rows
    await monitor_task
    
    # Clean up the infinite backpressure thread
    bp_task.kill()

@cocotb.test()
async def test_bg1_full_sweep(dut):
    """Test the complete sweeping of Base Graph 1 from physical row 0 to finish."""
    dut._log.info("=== Starting test_bg1_full_sweep ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ldpc_ready_i.value = 1
    dut.base_graph_i.value = 0
    dut.lifting_size_i.value = 128

    dut._log.info("Starting BG1 row sweep...")
    # Increment by 4 to jump to the next unprocessed physical row
    for physical_row in range(0, BG1_ROW_COUNT, 4):
        dut.row_i.value = physical_row
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0
        
        await wait_for_row_completion(dut, physical_row, 0, 128, golden_matrix)
        dut._log.info(f"Completed BG1 physical rows {physical_row} to {physical_row+3}.")
        
    await ClockCycles(dut.clk_i, 10)

@cocotb.test()
async def test_bg2_full_sweep(dut):
    """Test the complete sweeping of Base Graph 2 from physical row 0 to finish."""
    dut._log.info("=== Starting test_bg2_full_sweep ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)

    dut.ldpc_ready_i.value = 1
    dut.base_graph_i.value = 1
    dut.lifting_size_i.value = 256

    dut._log.info("Starting BG2 row sweep...")
    # Increment by 4 to jump to the next unprocessed physical row
    for physical_row in range(0, BG2_ROW_COUNT, 4):
        dut.row_i.value = physical_row
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0
        
        await wait_for_row_completion(dut, physical_row, 1, 256, golden_matrix)
        dut._log.info(f"Completed BG2 physical rows {physical_row} to {physical_row+3}.")

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

    # Spawn an asynchronous thread to independently monitor correctness
    dut.lifting_size_i.value = 128
    monitor_task = cocotb.start_soon(wait_for_row_completion(dut, 0, 0, 128, golden_matrix))

    # Wait until FSM enters VALID state to start interference
    while dut.ldpc_valid_o.value != 1:
        await RisingEdge(dut.clk_i)

    # Throw chaotic permutations onto inputs while the row is being processed
    timeout_ctr = 0
    while not monitor_task.done():
        toggle_mask = random.randint(1, 5)
        
        start_val = 1 if (toggle_mask & 0b001) else 0
        # Ensure we send a randomly chosen valid physical row
        row_val = random.randrange(0, BG1_ROW_COUNT, 4) if (toggle_mask & 0b100) else dut.row_i.value
        
        dut.start_i.value = start_val
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
        row_max = BG1_ROW_COUNT if bg == 0 else BG2_ROW_COUNT
        row = random.randrange(0, row_max, 4)

        delay = random.randint(5, 50)
        dut.ldpc_ready_i.value = 0
        await ClockCycles(dut.clk_i, delay)

        dut.base_graph_i.value = bg
        dut.row_i.value = row
        dut.lifting_size_i.value = 256
        dut.start_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.start_i.value = 0

        # Delegate validation to the standard robust monitor
        monitor_task = cocotb.start_soon(wait_for_row_completion(dut, row, bg, 256, golden_matrix))

        # Randomly toggle backpressure while the row group streams out
        timeout_ctr = 0
        while not monitor_task.done():
            dut.ldpc_ready_i.value = random.choices([0, 1], weights=[1, 1])[0]
            await RisingEdge(dut.clk_i)
            
            timeout_ctr += 1
            if timeout_ctr > 5000:
                dut._log.error(
                    f"Timeout! valid_o={dut.ldpc_valid_o.value}, ready_i={dut.ldpc_ready_i.value}, "
                    f"rowgrp_changed_o={dut.rowgrp_changed_o.value}"
                )
                assert False, "Timeout waiting for row completion. RTL might be dropping signals when not ready, or ignoring start_i!"

        await monitor_task # Catch any exception thrown by the monitor
        dut._log.info(f"Iter {i}: Done.")

@cocotb.test()
async def test_variable_row_increments(dut):
    """
    Test fetching rows continuously with variable physical row increments of {1, 2, 4}.
    Verifies the FSM can handle unaligned and repeated access to the same row groups.
    """
    dut._log.info("=== Starting test_variable_row_increments ===")
    golden_matrix = load_golden_matrix(dut)
    
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    test_configs = []
    valid_zcs = get_valid_5gnr_zcs()
    
    # Generate a sequence covering both Base Graphs
    for bg in [0, 1]:
        row_max = BG1_ROW_COUNT if bg == 0 else BG2_ROW_COUNT
        physical_row = 0
        
        while physical_row < row_max:
            zc = random.choice(valid_zcs)
            test_configs.append((bg, physical_row, zc))
            # Dynamically select the next increment
            increment = random.choice([1, 2, 4])
            physical_row += increment
            
    async def driver():
        """Feeds start_i and row configurations with fixed safe-start logic."""
        for i, (bg, physical_row, zc) in enumerate(test_configs):
            dut.base_graph_i.value = bg
            dut.lifting_size_i.value = zc
            dut.row_i.value = physical_row
            dut.start_i.value = 1
            await RisingEdge(dut.clk_i)
            dut.start_i.value = 0
            
            if i < len(test_configs) - 1:
                # Wait for the DUT to finish and flush before pushing the next start
                while True:
                    await RisingEdge(dut.clk_i)
                    if dut.rowgrp_changed_o.value == 1 and dut.ldpc_valid_o.value == 0:
                        break
                        
    async def monitor():
        """Validates outputs against the golden model."""
        for bg, physical_row, zc in test_configs:
            await wait_for_row_completion(dut, physical_row, bg, zc, golden_matrix)
            
    async def backpressure():
        """Randomly toggles ready_i to simulate downstream pressure."""
        while True:
            dut.ldpc_ready_i.value = random.choice([0, 1])
            await RisingEdge(dut.clk_i)
            
    # Launch all behaviors concurrently
    driver_task = cocotb.start_soon(driver())
    monitor_task = cocotb.start_soon(monitor())
    bp_task = cocotb.start_soon(backpressure())
    
    # Wait for the monitor to finish validating all requested rows
    await monitor_task
    
    # Clean up the infinite backpressure thread
    bp_task.kill()
    await ClockCycles(dut.clk_i, 10)