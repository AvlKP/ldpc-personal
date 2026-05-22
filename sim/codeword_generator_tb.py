import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

# Lifting groups matching ldpc_pkg
ZC_SMALL  = 0
ZC_MEDIUM = 1
ZC_LARGE  = 3

def pack_vector(v, element_bits):
    flat_val = 0
    for i in range(len(v)):
        flat_val |= (int(v[i]) & ((1 << element_bits) - 1)) << (i * element_bits)
    return flat_val

async def reset_dut(dut):
    dut.arst_ni.value = 0
    dut.lifting_size_i.value = 0
    dut.zc_group_i.value = ZC_SMALL
    dut.base_graph_i.value = 0
    dut.info_valid_i.value = 0
    dut.info_data_i.value = 0
    dut.core_parity_valid_i.value = 0
    dut.core_parity_data_i.value = 0
    dut.add_parity_valid_i.value = 0
    dut.add_parity_idx_i.value = 0
    dut.add_parity_data_i.value = 0
    dut.input_last_subblock_i.value = 0
    dut.r_addr_i.value = 0
    dut.codeword_done_i.value = 0
    
    # Reset internal memory arrays to prevent inter-testcase leakage
    try:
        for bank in range(4):
            for addr in range(256):
                dut.ram[bank][addr].value = 0
    except Exception as e:
        dut._log.warning(f"Could not reset internal RAM: {e}")
        
    await ClockCycles(dut.clk_i, 5)
    dut.arst_ni.value = 1
    await ClockCycles(dut.clk_i, 5)

class CodewordGenModel:
    def __init__(self, base_graph, zc_group):
        # 4 banks of 256 depth
        self.ram = [[0]*256 for _ in range(4)]
        self.w_swap = 0
        self.r_swap = 0
        self.w_seq_addr = 0
        self.bank_full = [0, 0]
        self.base_graph = base_graph
        self.zc_group = zc_group
        self.core_beat_idx = 0
        
    def write_systematic(self, info_data):
        w_en = [0]*4
        w_addr = [0]*4
        
        if self.zc_group == ZC_SMALL:
            bank = self.w_seq_addr & 3
            w_en[bank] = 1
            row = self.w_seq_addr >> 2
            for i in range(4):
                w_addr[i] = (self.w_swap << 7) | row
        elif self.zc_group == ZC_MEDIUM:
            if (self.w_seq_addr & 1) == 0:
                w_en[0] = 1
                w_en[1] = 1
            else:
                w_en[2] = 1
                w_en[3] = 1
            row = self.w_seq_addr >> 1
            for i in range(4):
                w_addr[i] = (self.w_swap << 7) | row
        else: # ZC_LARGE
            w_en = [1, 1, 1, 1]
            row = self.w_seq_addr
            for i in range(4):
                w_addr[i] = (self.w_swap << 7) | row
                
        for i in range(4):
            if w_en[i]:
                self.ram[i][w_addr[i]] = info_data[i]
                
    def write_core_parity(self, core_parity_data):
        w_addr = [0]*4
        
        if self.base_graph == 0: # BG1
            if self.zc_group == ZC_SMALL:
                row = 6
            elif self.zc_group == ZC_MEDIUM:
                row = 11 + self.core_beat_idx
            else:
                row = 22 + self.core_beat_idx
        else: # BG2
            if self.zc_group == ZC_SMALL:
                row = 3
            elif self.zc_group == ZC_MEDIUM:
                row = 5 + self.core_beat_idx
            else:
                row = 10 + self.core_beat_idx
                
        for i in range(4):
            w_addr[i] = (self.w_swap << 7) | row
            
        for i in range(4):
            self.ram[i][w_addr[i]] = core_parity_data[i]
            
        self.core_beat_idx += 1
            
    def write_add_parity(self, add_parity_idx, add_parity_data):
        w_addr = [0]*4
        rel_idx = [idx - 4 for idx in add_parity_idx]
        
        if self.base_graph == 0: # BG1
            if self.zc_group == ZC_SMALL:
                for i in range(4):
                    row = 7 + (rel_idx[i] >> 2)
                    w_addr[i] = (self.w_swap << 7) | row
            elif self.zc_group == ZC_MEDIUM:
                row_0_1 = 13 + (rel_idx[0] >> 1)
                row_2_3 = 13 + (rel_idx[1] >> 1)
                w_addr[0] = (self.w_swap << 7) | row_0_1
                w_addr[1] = (self.w_swap << 7) | row_0_1
                w_addr[2] = (self.w_swap << 7) | row_2_3
                w_addr[3] = (self.w_swap << 7) | row_2_3
            else: # ZC_LARGE
                row = 26 + rel_idx[0]
                for i in range(4):
                    w_addr[i] = (self.w_swap << 7) | row
        else: # BG2
            if self.zc_group == ZC_SMALL:
                for i in range(4):
                    row = 4 + (rel_idx[i] >> 2)
                    w_addr[i] = (self.w_swap << 7) | row
            elif self.zc_group == ZC_MEDIUM:
                row_0_1 = 7 + (rel_idx[0] >> 1)
                row_2_3 = 7 + (rel_idx[1] >> 1)
                w_addr[0] = (self.w_swap << 7) | row_0_1
                w_addr[1] = (self.w_swap << 7) | row_0_1
                w_addr[2] = (self.w_swap << 7) | row_2_3
                w_addr[3] = (self.w_swap << 7) | row_2_3
            else: # ZC_LARGE
                row = 14 + rel_idx[0]
                for i in range(4):
                    w_addr[i] = (self.w_swap << 7) | row
                    
        for i in range(4):
            self.ram[i][w_addr[i]] = add_parity_data[i]

async def run_codeword_gen_test(dut, zc_group, base_graph, lifting_size):
    dut._log.info(f"Starting test: zc_group={zc_group}, base_graph={base_graph}, lifting_size={lifting_size}")
    
    model = CodewordGenModel(base_graph, zc_group)
    
    kb = 10 if base_graph else 22
    core_p = 4
    add_p = 38 if base_graph else 42
    
    if zc_group == ZC_SMALL:
        num_core_beats = core_p // 4
        num_add_beats = add_p // 4
    elif zc_group == ZC_MEDIUM:
        num_core_beats = core_p // 2
        num_add_beats = add_p // 2
    else:
        num_core_beats = core_p
        num_add_beats = add_p
        
    num_sys_beats = kb
    total_beats = num_sys_beats + num_core_beats + num_add_beats
    
    dut.lifting_size_i.value = lifting_size
    dut.zc_group_i.value = zc_group
    dut.base_graph_i.value = base_graph
    
    sys_vectors = [[random.getrandbits(96) for _ in range(4)] for _ in range(num_sys_beats)]
    core_vectors = [[random.getrandbits(96) for _ in range(4)] for _ in range(num_core_beats)]
    add_vectors = [[random.getrandbits(96) for _ in range(4)] for _ in range(num_add_beats)]
    add_indices = [[random.randint(4, add_p + 3) for _ in range(4)] for _ in range(num_add_beats)]
    
    async def monitor_assertions():
        while True:
            await RisingEdge(dut.clk_i)
            # Safe sampling
            try:
                w_swap_val = int(dut.w_swap_q.value)
                # w_addr is packed [3:0][7:0] = 32 bits
                w_addr_flat = int(dut.w_addr.value)
                for i in range(4):
                    addr_val = (w_addr_flat >> (i * 8)) & 0xFF
                    assert (addr_val >> 7) == w_swap_val, f"Address bit-width overlap check failed at bank {i}. w_swap={w_swap_val}, addr={hex(addr_val)}"
                
                if dut.info_valid_i.value == 1 and dut.zc_group_i.value == ZC_SMALL and dut.upstream_ready_o.value == 1:
                    ram_w_en = int(dut.w_en.value)
                    ones_count = bin(ram_w_en).count('1')
                    assert ones_count == 1, f"Write enable isolation check failed. ram_w_en={bin(ram_w_en)}, expected 1 bit enabled"
            except ValueError:
                # Catch simulator startup 'X' or 'Z' values
                pass

    assertion_task = cocotb.start_soon(monitor_assertions())
    
    # A. Drive Systematic Phase
    for beat in range(num_sys_beats):
        while True:
            if random.random() < 0.2:
                dut.info_valid_i.value = 0
                await RisingEdge(dut.clk_i)
                continue
            
            dut.info_valid_i.value = 1
            dut.info_data_i.value = pack_vector(sys_vectors[beat], 96)
            
            is_last = (beat == total_beats - 1)
            dut.input_last_subblock_i.value = 1 if is_last else 0
            
            await RisingEdge(dut.clk_i)
            if dut.upstream_ready_o.value == 1:
                model.write_systematic(sys_vectors[beat])
                model.w_seq_addr += 1
                break
                
    dut.info_valid_i.value = 0
    
    # B. Drive Core Parity Phase
    for beat in range(num_core_beats):
        while True:
            if random.random() < 0.2:
                dut.core_parity_valid_i.value = 0
                await RisingEdge(dut.clk_i)
                continue
            
            dut.core_parity_valid_i.value = 1
            dut.core_parity_data_i.value = pack_vector(core_vectors[beat], 96)
            
            is_last = (num_sys_beats + beat == total_beats - 1)
            dut.input_last_subblock_i.value = 1 if is_last else 0
            
            await RisingEdge(dut.clk_i)
            if dut.upstream_ready_o.value == 1:
                model.write_core_parity(core_vectors[beat])
                break
                
    dut.core_parity_valid_i.value = 0
    
    # C. Drive Additional Parity Phase
    for beat in range(num_add_beats):
        while True:
            if random.random() < 0.2:
                dut.add_parity_valid_i.value = 0
                await RisingEdge(dut.clk_i)
                continue
                
            dut.add_parity_valid_i.value = 1
            dut.add_parity_data_i.value = pack_vector(add_vectors[beat], 96)
            dut.add_parity_idx_i.value = pack_vector(add_indices[beat], 7)
            
            is_last = (num_sys_beats + num_core_beats + beat == total_beats - 1)
            dut.input_last_subblock_i.value = 1 if is_last else 0
            
            await RisingEdge(dut.clk_i)
            if dut.upstream_ready_o.value == 1:
                model.write_add_parity(add_indices[beat], add_vectors[beat])
                break
                
    dut.add_parity_valid_i.value = 0
    dut.input_last_subblock_i.value = 0
    
    await RisingEdge(dut.clk_i)
    
    model.w_swap = 1 - model.w_swap
    assert int(dut.codeword_valid_o.value) == 1, "codeword_valid_o did not assert after final transaction block write"
    
    for r_addr in range(128):
        dut.r_addr_i.value = r_addr
        await RisingEdge(dut.clk_i)
        await FallingEdge(dut.clk_i)
        
        expected_word = 0
        actual_word = int(dut.r_data_o.value)
        
        model_addr = (model.r_swap << 7) | r_addr
        for bank in range(4):
            val = model.ram[bank][model_addr]
            expected_word |= (val << (bank * 96))
            
        assert actual_word == expected_word, f"Read mismatch at address {r_addr}. Expected: {hex(expected_word)}, Actual: {hex(actual_word)}"
        
    dut.codeword_done_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.codeword_done_i.value = 0
    
    model.r_swap = 1 - model.r_swap
    await RisingEdge(dut.clk_i)
    
    assertion_task.cancel()
    dut._log.info(f"Verification Successful for configuration!")

@cocotb.test()
async def test_bg1_small(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_SMALL, base_graph=0, lifting_size=48)

@cocotb.test()
async def test_bg1_medium(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_MEDIUM, base_graph=0, lifting_size=144)

@cocotb.test()
async def test_bg1_large(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_LARGE, base_graph=0, lifting_size=384)

@cocotb.test()
async def test_bg2_small(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_SMALL, base_graph=1, lifting_size=80)

@cocotb.test()
async def test_bg2_medium(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_MEDIUM, base_graph=1, lifting_size=192)

@cocotb.test()
async def test_bg2_large(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset_dut(dut)
    await run_codeword_gen_test(dut, zc_group=ZC_LARGE, base_graph=1, lifting_size=288)
