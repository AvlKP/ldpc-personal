import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

# Typical 5G NR LDPC parameters (Should match ldpc_pkg)
ZC_MAX = 384
DATA_WIDTH = 32

async def reset_dut(dut):
    """Asserts reset and initializes all control signals."""
    dut.arst_ni.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.ldpc_clear_i.value = 0
    dut.lifting_size_i.value = 0
    dut.input_bits_i.value = 0
    dut.info_group_i.value = 0
    
    await ClockCycles(dut.clk_i, 5)
    dut.arst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)

async def axis_master(dut, data_words, zc, total_bits):
    """Drives the AXI Stream input."""
    # Setup configuration for the block
    dut.lifting_size_i.value = zc
    dut.input_bits_i.value = total_bits
    
    idx = 0
    while idx < len(data_words):
        # Optional: Randomize valid drops to test FSM W_IDLE/W_PACK transitions
        valid = random.choice([0, 1]) if random.random() < 0.3 else 1
        dut.s_axis_tvalid.value = valid
        
        if valid:
            dut.s_axis_tdata.value = data_words[idx]
        else:
            dut.s_axis_tdata.value = 0xDEADBEEF # Junk data
            
        await RisingEdge(dut.clk_i)
        
        # If transaction was valid and ready, advance
        if valid and dut.s_axis_tready.value == 1:
            idx += 1
            
    # Deassert at the end
    dut.s_axis_tvalid.value = 0
    await RisingEdge(dut.clk_i)

async def ldpc_sink(dut, expected_data, zc, info_groups, delay_reads=False):
    """Monitors ldpc_valid_o, reads from RAM, and verifies the output with 1-cycle latency."""
    await RisingEdge(dut.clk_i)
    
    while dut.ldpc_valid_o.value == 0:
        await RisingEdge(dut.clk_i)
        
    if delay_reads:
        await ClockCycles(dut.clk_i, random.randint(10, 50))
        
    actual_data = []
    
    # Continuously stream addresses 1 per cycle
    for group in range(info_groups):
        # 1. Drive the read address (stable setup before next RisingEdge)
        dut.info_group_i.value = group
        
        # 2. Wait for the clock edge that latches the data into data_batch_o
        await RisingEdge(dut.clk_i) 
        
        # 3. Wait for the falling edge to safely read the registered output 
        #    and exit the strict simulation delta-cycle phases
        await FallingEdge(dut.clk_i)
        
        # FIX: Replaced deprecated .integer with .to_unsigned()
        raw_output = dut.data_batch_o.value.to_unsigned()
        
        # Determine how the output was supposed to be duplicated by out_sel
        if zc > (ZC_MAX >> 1):   # > 192 (out_sel 2'b11)
            extracted_val = raw_output & ((1 << ZC_MAX) - 1)
        elif zc > (ZC_MAX >> 2): # > 96 (out_sel 2'b01)
            extracted_val = raw_output & ((1 << (ZC_MAX >> 1)) - 1)
            copy2 = (raw_output >> (ZC_MAX >> 1)) & ((1 << (ZC_MAX >> 1)) - 1)
            assert extracted_val == copy2, f"Duplication failed for Zc={zc}"
        else:                    # <= 96 (out_sel 2'b00)
            extracted_val = raw_output & ((1 << (ZC_MAX >> 2)) - 1)
            for j in range(1, 4):
                copy_j = (raw_output >> ((ZC_MAX >> 2) * j)) & ((1 << (ZC_MAX >> 2)) - 1)
                assert extracted_val == copy_j, f"Duplication failed for Zc={zc} at section {j}"
                
        extracted_val = extracted_val & ((1 << zc) - 1)
        actual_data.append(extracted_val)
        
    # Assert ldpc_clear_i to swap buffers
    dut.ldpc_clear_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.ldpc_clear_i.value = 0
    
    # Verify the actual grouped data against expected
    for i in range(info_groups):
        assert actual_data[i] == expected_data[i], \
            f"Data mismatch at info group {i}. Expected: {hex(expected_data[i])}, Actual: {hex(actual_data[i])}"
            
    dut._log.info(f"Successfully validated block of Zc={zc}, Info Groups={info_groups}")


# ==============================================================================
# TESTS
# ==============================================================================

def generate_test_data(zc, info_groups):
    """Helper to generate AXIS words and expected Zc-sized chunks."""
    total_bits = zc * info_groups
    
    # Generate random bitstream
    bitstream = random.getrandbits(total_bits)
    
    # Slice into 32-bit AXI words
    num_words = (total_bits + 31) // 32
    axis_words = []
    for i in range(num_words):
        axis_words.append((bitstream >> (i * 32)) & 0xFFFFFFFF)
        
    # Slice into expected Zc sized vectors for validation
    expected_zc_chunks = []
    for i in range(info_groups):
        expected_zc_chunks.append((bitstream >> (i * zc)) & ((1 << zc) - 1))
        
    return axis_words, expected_zc_chunks, total_bits


@cocotb.test()
async def test_basic_transfer(dut):
    """Test a simple back-to-back transfer without stalls."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    zc = 384
    info_groups = 10
    axis_words, expected, total_bits = generate_test_data(zc, info_groups)
    
    # Launch sender and receiver
    driver_task = cocotb.start_soon(axis_master(dut, axis_words, zc, total_bits))
    sink_task = cocotb.start_soon(ldpc_sink(dut, expected, zc, info_groups))
    
    await driver_task
    await sink_task

@cocotb.test()
async def test_lifting_size_duplication(dut):
    """Test the dynamic vector duplication logic for various lifting sizes."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    # Test boundary limits for the output duplicator
    test_zcs = [384, 256, 192, 128, 96, 64]
    info_groups = 5
    
    for zc in test_zcs:
        axis_words, expected, total_bits = generate_test_data(zc, info_groups)
        
        driver_task = cocotb.start_soon(axis_master(dut, axis_words, zc, total_bits))
        sink_task = cocotb.start_soon(ldpc_sink(dut, expected, zc, info_groups))
        
        await driver_task
        await sink_task
        await ClockCycles(dut.clk_i, 5)

@cocotb.test()
async def test_ping_pong_backpressure(dut):
    """Test the ping pong buffer's ability to stall AXI stream when both RAMs are full."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    zc = 100 # Arbitrary offset
    info_groups = 8
    
    # Generate 4 separate blocks of data to feed sequentially
    blocks = [generate_test_data(zc, info_groups) for _ in range(4)]
    
    async def continuous_axis_driver():
        for axis_words, _, total_bits in blocks:
            await axis_master(dut, axis_words, zc, total_bits)
            
    async def delayed_sink():
        for _, expected, _ in blocks:
            # Delay reads heavily to ensure W_STALL is hit
            await ldpc_sink(dut, expected, zc, info_groups, delay_reads=True)
            
    driver_task = cocotb.start_soon(continuous_axis_driver())
    sink_task = cocotb.start_soon(delayed_sink())
    
    await driver_task
    await sink_task
    
# ==============================================================================
# Randomized Zc based on 5G NR LDPC parameters
# ==============================================================================

def get_5gnr_zc():
    """Generates a valid 5G NR LDPC lifting size (Zc)."""
    base_z_set = [2, 3, 5, 7, 9, 11, 13, 15]
    valid_zcs = []
    
    for base in base_z_set:
        for j in range(8): # j = 0 to 7
            zc = base * (2 ** j)
            # Filter out sizes that exceed the hardware maximum
            if zc <= ZC_MAX:
                valid_zcs.append(zc)
                
    return random.choice(valid_zcs)

@cocotb.test()
async def test_randomized_zc_5gnr(dut):
    """Test using dynamically generated valid 5G NR LDPC lifting sizes."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    # Run a few iterations with different valid Zc values
    for _ in range(5):
        zc = get_5gnr_zc()
        info_groups = random.randint(2, 8)
        
        dut._log.info(f"Testing randomized 5G NR Zc: {zc} with {info_groups} Info Groups")
        axis_words, expected, total_bits = generate_test_data(zc, info_groups)
        
        driver_task = cocotb.start_soon(axis_master(dut, axis_words, zc, total_bits))
        sink_task = cocotb.start_soon(ldpc_sink(dut, expected, zc, info_groups))
        
        await driver_task
        await sink_task

# ==============================================================================
# Changing inputs during a transaction
# ==============================================================================

async def axis_master_mutating_config(dut, data_words, original_zc, total_bits):
    """Drives the AXI Stream while mutating config midway to test register latching."""
    dut.lifting_size_i.value = original_zc
    dut.input_bits_i.value = total_bits
    
    idx = 0
    while idx < len(data_words):
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value = data_words[idx]
        await RisingEdge(dut.clk_i)
        
        if dut.s_axis_tready.value == 1:
            idx += 1
            
            # INTERFERENCE: Change configs exactly halfway through the block packing
            if idx == len(data_words) // 2:
                fake_zc = get_5gnr_zc()
                dut._log.info(f"Mutating inputs mid-transaction! Zc: {original_zc} -> {fake_zc}")
                dut.lifting_size_i.value = fake_zc
                dut.input_bits_i.value = 9999 # Chaos value
                
    dut.s_axis_tvalid.value = 0
    await RisingEdge(dut.clk_i)

@cocotb.test()
async def test_config_change_during_transaction(dut):
    """Verifies that changing lifting_size_i and input_bits_i midway is ignored safely."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    zc = 112
    info_groups = 6
    axis_words, expected, total_bits = generate_test_data(zc, info_groups)
    
    # Drive with the mutating master, but the sink still validates against the ORIGINAL expected
    driver_task = cocotb.start_soon(axis_master_mutating_config(dut, axis_words, zc, total_bits))
    sink_task = cocotb.start_soon(ldpc_sink(dut, expected, zc, info_groups))
    
    await driver_task
    await sink_task
    
    dut._log.info("Transaction completed successfully using only latched initial inputs.")

# ==============================================================================
# Buggy LDPC Core (Dropped/Glitchy Clear Signal)
# ==============================================================================

async def ldpc_sink_buggy_clear(dut, expected_data, zc, info_groups):
    """Monitors ldpc_valid_o but simulates a buggy clear signal with 1-cycle latency reads."""
    await RisingEdge(dut.clk_i)
    
    while dut.ldpc_valid_o.value == 0:
        await RisingEdge(dut.clk_i)
        
    actual_data = []
    for group in range(info_groups):
        dut.info_group_i.value = group
        await RisingEdge(dut.clk_i) 
        await FallingEdge(dut.clk_i) # Safe sample point
        
        # FIX: Replaced deprecated .integer with .to_unsigned()
        raw_output = dut.data_batch_o.value.to_unsigned()
        extracted_val = raw_output & ((1 << ZC_MAX) - 1) 
        extracted_val = extracted_val & ((1 << zc) - 1)
        actual_data.append(extracted_val)
        
    # --- BUG INJECTION ---
    bug_type = random.choice(["DROPPED", "STUCK"])
    
    if bug_type == "DROPPED":
        dut._log.info("Buggy Core: Dropped clear signal (stalling for 100 cycles)...")
        await ClockCycles(dut.clk_i, 100)
        dut.ldpc_clear_i.value = 1
        await RisingEdge(dut.clk_i)
        dut.ldpc_clear_i.value = 0
        
    elif bug_type == "STUCK":
        dut._log.info("Buggy Core: Stuck clear signal (asserted for 5 cycles)...")
        dut.ldpc_clear_i.value = 1
        await ClockCycles(dut.clk_i, 5)
        dut.ldpc_clear_i.value = 0
        
    for i in range(info_groups):
        assert actual_data[i] == expected_data[i], "Data corrupted by buggy clear!"

@cocotb.test()
async def test_buggy_ldpc_clear(dut):
    """Tests the input buffer's resilience to a buggy LDPC core clear signal."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    zc = 96
    info_groups = 4
    
    # We send two blocks to ensure that the buggy clear from the first block
    # doesn't completely break the FSM for the second block.
    blocks = [generate_test_data(zc, info_groups) for _ in range(2)]
    
    async def driver():
        for axis_words, _, total_bits in blocks:
            # Wait for clear input before pushing next to avoid standard backpressure locking
            dut.lifting_size_i.value = zc
            dut.input_bits_i.value = total_bits
            await axis_master(dut, axis_words, zc, total_bits)
            
    async def sink():
        for _, expected, _ in blocks:
            await ldpc_sink_buggy_clear(dut, expected, zc, info_groups)
            
    await cocotb.start_soon(driver())
    await sink()

# ==============================================================================
# Sweeping BG1 and BG2 Info Groups
# ==============================================================================

@cocotb.test()
async def test_bg1_bg2_sweep(dut):
    """
    Test 1: The LDPC core consumes/sweeps through all the info bit groups 
    for BG1 (22 groups) and BG2 (10 groups).
    """
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    # 5G NR constants for Info Groups (kb)
    KB_BG1 = 22
    KB_BG2 = 10
    
    # BG1 Sweep
    zc_bg1 = 128
    dut._log.info(f"Starting BG1 sweep: Zc={zc_bg1}, Info Groups={KB_BG1}")
    axis_words_1, expected_1, total_bits_1 = generate_test_data(zc_bg1, KB_BG1)
    
    driver_task_1 = cocotb.start_soon(axis_master(dut, axis_words_1, zc_bg1, total_bits_1))
    sink_task_1 = cocotb.start_soon(ldpc_sink(dut, expected_1, zc_bg1, KB_BG1))
    
    await driver_task_1
    await sink_task_1
    dut._log.info("BG1 sweep completed successfully.")
    
    await ClockCycles(dut.clk_i, 10)
    
    # BG2 Sweep
    zc_bg2 = 256
    dut._log.info(f"Starting BG2 sweep: Zc={zc_bg2}, Info Groups={KB_BG2}")
    axis_words_2, expected_2, total_bits_2 = generate_test_data(zc_bg2, KB_BG2)
    
    driver_task_2 = cocotb.start_soon(axis_master(dut, axis_words_2, zc_bg2, total_bits_2))
    sink_task_2 = cocotb.start_soon(ldpc_sink(dut, expected_2, zc_bg2, KB_BG2))
    
    await driver_task_2
    await sink_task_2
    dut._log.info("BG2 sweep completed successfully.")


# ==============================================================================
# Full Ping-Pong Saturation & Resumption
# ==============================================================================

@cocotb.test()
async def test_ping_pong_stall_and_resume(dut):
    """
    Test 2: Fill both RAMs to force a stall, wait for AXI-Stream to hang.
    Consume one RAM, verify AXI resumes writing to the freed RAM while 
    the core waits to consume again.
    """
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    
    zc = 96
    info_groups = 5 # Arbitrary block size
    
    blocks = [generate_test_data(zc, info_groups) for _ in range(3)]
    
    async def overzealous_driver():
        for i, (axis_words, _, total_bits) in enumerate(blocks):
            dut._log.info(f"AXI Master: Attempting to send Block {i}")
            dut.lifting_size_i.value = zc
            dut.input_bits_i.value = total_bits
            await axis_master(dut, axis_words, zc, total_bits)
            dut._log.info(f"AXI Master: Finished sending Block {i}")

    async def deliberate_sink():
        # 1. Wait until AXI stream triggers a SUSTAINED stall
        dut._log.info("LDPC Sink: Waiting for both RAMs to fill and stall the AXI bus...")
        
        stall_cycles = 0
        while True:
            await RisingEdge(dut.clk_i)
            if dut.s_axis_tready.value == 0 and dut.s_axis_tvalid.value == 1:
                stall_cycles += 1
                if stall_cycles >= 15: 
                    break
            else:
                stall_cycles = 0
                
        dut._log.info("LDPC Sink: Sustained stall verified. Consuming RAM 0 to free up space...")
        
        # 2. Read Block 0 (RAM 0). This clears RAM 0.
        _, expected_0, _ = blocks[0]
        await ldpc_sink(dut, expected_0, zc, info_groups)
        
        # Verify that the stall is broken and AXI resumes writing Block 2
        # We check over a 10-cycle window because tready drops momentarily during W_UNPACK
        resumed = False
        for _ in range(10):
            await RisingEdge(dut.clk_i)
            if dut.s_axis_tready.value == 1:
                resumed = True
                break
                
        assert resumed, "AXI stream failed to resume after clear!"
        
        # 3. Read Block 1 (RAM 1).
        dut._log.info("LDPC Sink: Consuming RAM 1...")
        _, expected_1, _ = blocks[1]
        await ldpc_sink(dut, expected_1, zc, info_groups)
        
        # 4. Read Block 2 (from the newly re-written RAM 0)
        dut._log.info("LDPC Sink: Consuming Block 2 (reused RAM)...")
        _, expected_2, _ = blocks[2]
        await ldpc_sink(dut, expected_2, zc, info_groups)
        
        dut._log.info("LDPC Sink: All blocks processed seamlessly!")

    # Execute concurrently
    driver_task = cocotb.start_soon(overzealous_driver())
    sink_task = cocotb.start_soon(deliberate_sink())
    
    await driver_task
    await sink_task