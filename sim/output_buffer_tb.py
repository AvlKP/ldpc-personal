import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

# Lifting groups matching ldpc_pkg
ZC_SMALL  = 0
ZC_MEDIUM = 1
ZC_LARGE  = 3

async def reset_dut(dut):
    dut.arst_ni.value = 0
    dut.base_graph_i.value = 0
    dut.zc_group_i.value = ZC_SMALL
    dut.lifting_size_i.value = 0
    dut.codeword_valid_i.value = 0
    dut.r_data_i.value = 0
    dut.m_axis_tready.value = 1
    await ClockCycles(dut.clk_i, 5)
    dut.arst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)

async def bram_responder(dut, ram_data):
    """Models a BRAM with 1-cycle read latency relative to r_addr_o updates."""
    while True:
        await FallingEdge(dut.clk_i)
        addr = int(dut.r_addr_o.value)
        if addr < len(ram_data):
            dut.r_data_i.value = ram_data[addr]
        else:
            dut.r_data_i.value = 0

async def run_output_buffer_test(dut, zc_group, base_graph, lifting_size, backpressure=False):
    dut._log.info(f"Starting Output Buffer Test: zc_group={zc_group}, base_graph={base_graph}, lifting_size={lifting_size}, backpressure={backpressure}")
    
    col_max = 52 if base_graph else 68 # BG2: 52, BG1: 68
    
    # 1. Generate random column data and pack into BRAM rows
    # ZC_SMALL: 4 columns/row. ZC_MEDIUM: 2 columns/row. ZC_LARGE: 1 column/row.
    columns = [random.getrandbits(lifting_size) for _ in range(col_max)]
    
    # Construct continuous bitstream of golden output
    golden_bitstream = 0
    for i, col in enumerate(columns):
        golden_bitstream |= (col << (i * lifting_size))
    
    total_bits = col_max * lifting_size
    num_axis_words = (total_bits + 31) // 32
    expected_words = []
    for i in range(num_axis_words):
        word = (golden_bitstream >> (i * 32)) & 0xFFFFFFFF
        expected_words.append(word)
        
    # Pack columns into RAM words (384-bit wide) matching physical codeword generator layout
    ram_data = [0] * 256
    sys_limit = 10 if base_graph else 22
    
    # 1. Pack Systematic
    if zc_group == ZC_SMALL:
        for c in range(sys_limit):
            row = c // 4
            slot = c % 4
            ram_data[row] |= (columns[c] << (slot * 96))
    elif zc_group == ZC_MEDIUM:
        for c in range(sys_limit):
            row = c // 2
            slot = c % 2
            ram_data[row] |= (columns[c] << (slot * 192))
    else: # ZC_LARGE
        for c in range(sys_limit):
            ram_data[c] = columns[c]
            
    # 2. Pack Core Parity
    if zc_group == ZC_SMALL:
        cp_base = 3 if base_graph else 6
        row_val = 0
        for i in range(4):
            col_val = columns[sys_limit + i]
            row_val |= (col_val << (i * 96))
        ram_data[cp_base] = row_val
    elif zc_group == ZC_MEDIUM:
        cp_base = 5 if base_graph else 11
        row_val_0 = columns[sys_limit] | (columns[sys_limit + 1] << 192)
        row_val_1 = columns[sys_limit + 2] | (columns[sys_limit + 3] << 192)
        ram_data[cp_base] = row_val_0
        ram_data[cp_base + 1] = row_val_1
    else: # ZC_LARGE
        cp_base = 10 if base_graph else 22
        for i in range(4):
            ram_data[cp_base + i] = columns[sys_limit + i]
            
    # 3. Pack Additional Parity
    ap_cols = columns[sys_limit + 4 :]
    if zc_group == ZC_SMALL:
        cp_base = 3 if base_graph else 6
        ap_base = cp_base + 1
        for i, col in enumerate(ap_cols):
            row = ap_base + (i // 4)
            slot = i % 4
            ram_data[row] |= (col << (slot * 96))
    elif zc_group == ZC_MEDIUM:
        cp_base = 5 if base_graph else 11
        ap_base = cp_base + 2
        for i, col in enumerate(ap_cols):
            row = ap_base + (i // 2)
            slot = i % 2
            ram_data[row] |= (col << (slot * 192))
    else: # ZC_LARGE
        cp_base = 10 if base_graph else 22
        ap_base = cp_base + 4
        for i, col in enumerate(ap_cols):
            row = ap_base + i
            ram_data[row] = col
            
    # Start BRAM responder task
    bram_task = cocotb.start_soon(bram_responder(dut, ram_data))
    
    # Set config inputs
    dut.base_graph_i.value = base_graph
    dut.zc_group_i.value = zc_group
    dut.lifting_size_i.value = lifting_size
    
    # Start background task to catch codeword_done_o pulse asynchronously and robustly
    done_event = cocotb.triggers.Event()
    async def catch_done():
        while True:
            await RisingEdge(dut.clk_i)
            if dut.codeword_done_o.value == 1:
                done_event.set()
                break
    cocotb.start_soon(catch_done())

    # Assert codeword_valid_i
    dut.codeword_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.codeword_valid_i.value = 0
    
    # 2. Latency Check: State transitions IDLE -> FETCH -> WAIT_RAM -> STREAM
    # The FSM state is state_q
    # IDLE is 000, FETCH is 001, WAIT_RAM is 010, STREAM is 011
    # We just transition, wait for FETCH (1 cycle), then WAIT_RAM (1 cycle).
    # So 2 cycles total of setup latency before STREAM.
    # Let's assert state transition timing.
    await FallingEdge(dut.clk_i)
    # Right after RisingEdge where codeword_valid_i was seen, state should be FETCH
    assert int(dut.state_q.value) == 1, f"State is not FETCH, got {int(dut.state_q.value)}"
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    assert int(dut.state_q.value) == 2, f"State is not WAIT_RAM, got {int(dut.state_q.value)}"
    await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    assert int(dut.state_q.value) == 3, f"State is not STREAM, got {int(dut.state_q.value)}"
    
    # 3. Stream & verify output words
    actual_words = []
    beats_count = 0
    
    async def debug_monitor(dut):
        cycle = 0
        while True:
            await RisingEdge(dut.clk_i)
            await cocotb.triggers.Timer(1, units="ps")
            dut._log.info(
                f"Cycle {cycle:04d}: state={dut.state_q.value} col={int(dut.col_idx_q.value)} r_addr={int(dut.r_addr_q.value)} "
                f"accum_cnt={int(dut.accum_cnt_q.value)} shifter_cnt={int(dut.shifter_cnt_q.value)} "
                f"eff_shift={int(dut.effective_shifter_cnt.value)} tot_bits={int(dut.total_bits_left.value)} "
                f"col_depl={int(dut.col_depleted.value)} ram_exh={int(dut.ram_word_exhausted.value)} "
                f"i_val={int(dut.internal_valid.value)} i_rdy={int(dut.internal_ready.value)} i_last={int(dut.internal_last.value)} "
                f"m_val={int(dut.m_axis_tvalid.value)} m_rdy={int(dut.m_axis_tready.value)} m_last={int(dut.m_axis_tlast.value)}"
            )
            cycle += 1

    monitor_task = cocotb.start_soon(debug_monitor(dut))

    # 1. Independent Monitor Loop
    async def axis_monitor():
        while len(actual_words) < num_axis_words:
            await RisingEdge(dut.clk_i)
            if dut.m_axis_tvalid.value == 1 and dut.m_axis_tready.value == 1:
                data = int(dut.m_axis_tdata.value)
                last = int(dut.m_axis_tlast.value)
                actual_words.append(data)
                
                # Verify TLAST alignment
                is_last_word = (len(actual_words) == num_axis_words)
                assert last == (1 if is_last_word else 0), f"m_axis_tlast mismatch. Expected: {1 if is_last_word else 0}, Actual: {last} at word {len(actual_words)-1}/{num_axis_words}"

    monitor_tb_task = cocotb.start_soon(axis_monitor())

    # 2. Driver Loop for backpressure
    while len(actual_words) < num_axis_words:
        if backpressure and random.random() < 0.2:
            dut.m_axis_tready.value = 0
        else:
            dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk_i)

    # Make sure monitor task completes and any assertions are raised
    await monitor_tb_task

    # Deassert ready
    dut.m_axis_tready.value = 0
    
    # Wait for codeword_done_o pulse caught asynchronously
    await done_event.wait()
        
    await RisingEdge(dut.clk_i)
    
    # Verify the output data
    for i in range(num_axis_words):
        assert actual_words[i] == expected_words[i], \
            f"Data mismatch at AXI word {i}. Expected: {hex(expected_words[i])}, Actual: {hex(actual_words[i])}"
            
    bram_task.cancel()
    monitor_task.cancel()
    dut._log.info(f"Verification Successful for zc_group={zc_group}, lifting_size={lifting_size}!")

@cocotb.test()
async def test_bg1_small(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_SMALL, base_graph=0, lifting_size=48)

@cocotb.test()
async def test_bg1_medium(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_MEDIUM, base_graph=0, lifting_size=144)

@cocotb.test()
async def test_bg1_large(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_LARGE, base_graph=0, lifting_size=384)

@cocotb.test()
async def test_bg2_small(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_SMALL, base_graph=1, lifting_size=80)

@cocotb.test()
async def test_bg2_medium(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_MEDIUM, base_graph=1, lifting_size=192)

@cocotb.test()
async def test_bg2_large(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_LARGE, base_graph=1, lifting_size=288)

@cocotb.test()
async def test_backpressure_bg1_small(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_SMALL, base_graph=0, lifting_size=48, backpressure=True)

@cocotb.test()
async def test_backpressure_bg2_large(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_output_buffer_test(dut, zc_group=ZC_LARGE, base_graph=1, lifting_size=288, backpressure=True)
