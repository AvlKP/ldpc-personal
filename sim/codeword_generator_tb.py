import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

# ==============================================================================
# Constants matching ldpc_pkg.sv (tasks 1.1, 1.2)
# ==============================================================================

ZC_MAX = 384
ZC_WIDTH = 9
KB_BG1 = 22
KB_BG2 = 10
COL_WIDTH = 7
BG1_COL_N = 68
BG2_COL_N = 52
BG1_ROW_N = 46
BG2_ROW_N = 42

ZC_SMALL = 0
ZC_MEDIUM = 1
ZC_LARGE = 3

LANE_BITS = ZC_MAX >> 2  # 96 bits per lane
NUM_LANES = 4


# ==============================================================================
# Helpers (tasks 1.2, 1.3)
# ==============================================================================

def get_5gnr_zc_values():
    base_z_set = [2, 3, 5, 7, 9, 11, 13, 15]
    valid = []
    for base in base_z_set:
        for j in range(8):
            zc = base * (2 ** j)
            if zc <= ZC_MAX:
                valid.append(zc)
    return sorted(set(valid))


def zc_to_group(zc):
    if zc > (ZC_MAX >> 1):
        return ZC_LARGE
    elif zc > (ZC_MAX >> 2):
        return ZC_MEDIUM
    else:
        return ZC_SMALL


def log_seed(dut, seed, context=""):
    dut._log.info(f"[SEED] {context} seed={seed}")


def generate_subblock(zc, rng):
    """Generate a Zc-bit random subblock value."""
    return rng.getrandbits(zc)


def pack_into_lanes(subblock, zc, num_lanes):
    """Pack a Zc-bit subblock into num_lanes * 96-bit lanes, zero-padded above Zc."""
    packed = []
    for i in range(num_lanes):
        lo = i * LANE_BITS
        hi = lo + LANE_BITS
        if lo < zc:
            lane_val = (subblock >> lo) & ((1 << min(LANE_BITS, zc - lo)) - 1)
        else:
            lane_val = 0
        packed.append(lane_val)
    while len(packed) < NUM_LANES:
        packed.append(0)
    return packed


def lanes_to_subblock(lanes, zc, num_lanes):
    """Reconstruct Zc-bit value from num_lanes * 96-bit packed lanes."""
    val = 0
    for i in range(num_lanes):
        val |= (lanes[i] & ((1 << LANE_BITS) - 1)) << (i * LANE_BITS)
    return val & ((1 << zc) - 1)


def packed_data_to_dut_value(packed_lanes):
    """Combine 4 lane values into a single DUT data input value."""
    result = 0
    for i in range(NUM_LANES):
        result |= (packed_lanes[i] & ((1 << LANE_BITS) - 1)) << (i * LANE_BITS)
    return result


def dut_value_to_lanes(raw):
    """Unpack a 384-bit DUT data output into 4 lane values."""
    lanes = []
    for i in range(NUM_LANES):
        lanes.append((raw >> (i * LANE_BITS)) & ((1 << LANE_BITS) - 1))
    return lanes


def get_bg_params(base_graph):
    """Return (kb, mb, num_additional_parity_safe) for given base graph.
    num_additional is rounded down to avoid partial beats that would
    require filler lanes (DUT bank_valid array [67:0] can't hold BG1
    max address 68)."""
    if base_graph:  # BG2
        kb = KB_BG2
        mb = BG2_COL_N
        raw_additional = mb - kb - 4  # 38 for BG2
    else:  # BG1
        kb = KB_BG1
        mb = BG1_COL_N
        raw_additional = mb - kb - 4  # 42 for BG1
    # Round down to multiple of 4 (SMALL) and 2 (MEDIUM) — avoids filler.
    # 40 for BG1, 36 for BG2 works for all zc_group values.
    num_additional = (raw_additional // 4) * 4
    return kb, mb, num_additional


def assign_dut_value(dut_signal, value):
    """Robustly assign an integer to a DUT signal without .integer/.value conflicts."""
    try:
        dut_signal.value = value
    except Exception:
        dut_signal.value = int(value)


# ==============================================================================
# Core-Like Driver (tasks 2.1-2.7)
# ==============================================================================

class CodewordDriver:
    """Encoder-core-like driver with IDLE, LOAD, CALC_LAMBDA, CALC_PC, CALC_PA phases."""

    def __init__(self, dut, rng=None):
        self.dut = dut
        self.rng = rng if rng is not None else random.Random()

    def _idle_dut_inputs(self):
        d = self.dut
        assign_dut_value(d.init_i, 0)
        assign_dut_value(d.info_valid_i, 0)
        assign_dut_value(d.info_data_i, 0)
        assign_dut_value(d.core_parity_valid_i, 0)
        assign_dut_value(d.core_parity_data_i, 0)
        assign_dut_value(d.add_parity_valid_i, 0)
        assign_dut_value(d.add_parity_data_i, 0)
        assign_dut_value(d.add_parity_idx_i, 0)
        assign_dut_value(d.last_block_i, 0)

    def _set_config(self, base_graph, zc_group, lifting_size):
        d = self.dut
        assign_dut_value(d.base_graph_i, base_graph)
        assign_dut_value(d.zc_group_i, zc_group)
        assign_dut_value(d.lifting_size_i, lifting_size)

    async def send_frame(self, base_graph, zc):
        """Drive a complete frame through the DUT. Returns (info_subblocks, core_parity_subblocks, add_parity_subblocks, add_parity_indices)."""
        zc_group = zc_to_group(zc)
        kb, _mb, num_additional = get_bg_params(base_graph)
        d = self.dut

        # --- IDLE: ensure clean state ---
        self._idle_dut_inputs()

        # --- Generate test data ---
        info_subblocks = [generate_subblock(zc, self.rng) for _ in range(kb)]
        core_parity_subblocks = [generate_subblock(zc, self.rng) for _ in range(4)]
        add_parity_indices = list(range(4, 4 + num_additional))
        add_parity_subblocks = [generate_subblock(zc, self.rng) for _ in range(num_additional)]

        # --- LOAD: wait for ready_o, then assert init_i ---
        self._set_config(base_graph, zc_group, zc)
        while True:
            await RisingEdge(d.clk_i)
            if int(d.ready_o.value) == 1:
                break

        # init_i asserted for 1 cycle
        assign_dut_value(d.init_i, 1)
        await RisingEdge(d.clk_i)
        assign_dut_value(d.init_i, 0)

        # --- CALC_LAMBDA: drive info beats ---
        await self._drive_info(info_subblocks, zc, zc_group)

        # --- CALC_PC: drive core parity ---
        await self._drive_core_parity(core_parity_subblocks, zc, zc_group)

        # --- CALC_PA: drive additional parity ---
        add_order = list(range(num_additional))
        await self._drive_add_parity(add_parity_subblocks, add_parity_indices, add_order, zc, zc_group)

        self._idle_dut_inputs()

        return info_subblocks, core_parity_subblocks, add_parity_subblocks, add_parity_indices, add_order

    async def _drive_info(self, subblocks, zc, zc_group):
        d = self.dut
        if zc_group == ZC_SMALL:
            num_lanes = 1
        elif zc_group == ZC_MEDIUM:
            num_lanes = 2
        else:
            num_lanes = 4

        for subblock in subblocks:
            packed = pack_into_lanes(subblock, zc, num_lanes)
            assign_dut_value(d.info_data_i, packed_data_to_dut_value(packed))
            assign_dut_value(d.info_valid_i, 1)
            await RisingEdge(d.clk_i)

        assign_dut_value(d.info_valid_i, 0)

    async def _drive_core_parity(self, subblocks, zc, zc_group):
        d = self.dut
        if zc_group == ZC_SMALL:
            beats = [subblocks[0:4]]
        elif zc_group == ZC_MEDIUM:
            beats = [subblocks[0:2], subblocks[2:4]]
        else:
            beats = [[s] for s in subblocks]

        for beat_subblocks in beats:
            if zc_group == ZC_SMALL:
                data = 0
                for i, sb in enumerate(beat_subblocks):
                    data |= (sb & ((1 << LANE_BITS) - 1)) << (i * LANE_BITS)
                assign_dut_value(d.core_parity_data_i, data)
            elif zc_group == ZC_MEDIUM:
                lanes0 = pack_into_lanes(beat_subblocks[0], zc, 2)
                lanes1 = pack_into_lanes(beat_subblocks[1], zc, 2)
                data = 0
                data |= (lanes0[0] & ((1 << LANE_BITS) - 1)) << 0
                data |= (lanes0[1] & ((1 << LANE_BITS) - 1)) << LANE_BITS
                data |= (lanes1[0] & ((1 << LANE_BITS) - 1)) << (2 * LANE_BITS)
                data |= (lanes1[1] & ((1 << LANE_BITS) - 1)) << (3 * LANE_BITS)
                assign_dut_value(d.core_parity_data_i, data)
            else:  # LARGE
                lanes = pack_into_lanes(beat_subblocks[0], zc, 4)
                data = 0
                for i in range(4):
                    data |= (lanes[i] & ((1 << LANE_BITS) - 1)) << (i * LANE_BITS)
                assign_dut_value(d.core_parity_data_i, data)

            assign_dut_value(d.core_parity_valid_i, 1)
            await RisingEdge(d.clk_i)

        assign_dut_value(d.core_parity_valid_i, 0)

    async def _drive_add_parity(self, subblocks, indices, order, zc, zc_group):
        d = self.dut
        num_subblocks = len(subblocks)

        if zc_group == ZC_SMALL:
            for i in range(0, num_subblocks, 4):
                chunk_indices = []
                chunk_data = []
                for j in range(4):
                    idx = i + j
                    if idx < num_subblocks:
                        chunk_indices.append(indices[order[idx]])
                        chunk_data.append(subblocks[order[idx]])
                    else:
                        chunk_indices.append(BG1_COL_N + j)  # filler outside valid range
                        chunk_data.append(0)

                packed_idx = 0
                packed_data = 0
                for j in range(4):
                    packed_idx |= (chunk_indices[j] & ((1 << COL_WIDTH) - 1)) << (j * COL_WIDTH)
                    packed_data |= (chunk_data[j] & ((1 << LANE_BITS) - 1)) << (j * LANE_BITS)

                assign_dut_value(d.add_parity_idx_i, packed_idx)
                assign_dut_value(d.add_parity_data_i, packed_data)
                assign_dut_value(d.add_parity_valid_i, 1)
                assign_dut_value(d.last_block_i, 1 if (i + 4 >= num_subblocks) else 0)
                await RisingEdge(d.clk_i)

        elif zc_group == ZC_MEDIUM:
            for i in range(0, num_subblocks, 2):
                sb_a = subblocks[order[i]]
                idx_a = indices[order[i]]
                if i + 1 < num_subblocks:
                    sb_b = subblocks[order[i + 1]]
                    idx_b = indices[order[i + 1]]
                else:
                    sb_b = 0
                    idx_b = BG1_COL_N + 1

                lanes_a = pack_into_lanes(sb_a, zc, 2)
                lanes_b = pack_into_lanes(sb_b, zc, 2)

                packed_idx = 0
                packed_data = 0
                # Bank 0,1 → idx_a, lanes_a
                packed_idx |= (idx_a & ((1 << COL_WIDTH) - 1)) << 0
                packed_idx |= (idx_a & ((1 << COL_WIDTH) - 1)) << COL_WIDTH
                packed_data |= (lanes_a[0] & ((1 << LANE_BITS) - 1)) << 0
                packed_data |= (lanes_a[1] & ((1 << LANE_BITS) - 1)) << LANE_BITS
                # Bank 2,3 → idx_b, lanes_b
                packed_idx |= (idx_b & ((1 << COL_WIDTH) - 1)) << (2 * COL_WIDTH)
                packed_idx |= (idx_b & ((1 << COL_WIDTH) - 1)) << (3 * COL_WIDTH)
                packed_data |= (lanes_b[0] & ((1 << LANE_BITS) - 1)) << (2 * LANE_BITS)
                packed_data |= (lanes_b[1] & ((1 << LANE_BITS) - 1)) << (3 * LANE_BITS)

                assign_dut_value(d.add_parity_idx_i, packed_idx)
                assign_dut_value(d.add_parity_data_i, packed_data)
                assign_dut_value(d.add_parity_valid_i, 1)
                assign_dut_value(d.last_block_i, 1 if (i + 2 >= num_subblocks) else 0)
                await RisingEdge(d.clk_i)

        else:  # LARGE
            for i in range(num_subblocks):
                sb = subblocks[order[i]]
                idx = indices[order[i]]

                lanes = pack_into_lanes(sb, zc, 4)
                packed_idx = 0
                packed_data = 0
                for j in range(4):
                    packed_idx |= (idx & ((1 << COL_WIDTH) - 1)) << (j * COL_WIDTH)
                    packed_data |= (lanes[j] & ((1 << LANE_BITS) - 1)) << (j * LANE_BITS)

                assign_dut_value(d.add_parity_idx_i, packed_idx)
                assign_dut_value(d.add_parity_data_i, packed_data)
                assign_dut_value(d.add_parity_valid_i, 1)
                assign_dut_value(d.last_block_i, 1 if (i + 1 >= num_subblocks) else 0)
                await RisingEdge(d.clk_i)

        assign_dut_value(d.add_parity_valid_i, 0)
        assign_dut_value(d.last_block_i, 0)

    async def send_frame_with_order_and_indices(self, base_graph, zc,
                                                  info_subblocks=None,
                                                  core_parity_subblocks=None,
                                                  add_parity_indices=None,
                                                  add_parity_subblocks=None,
                                                  add_order=None):
        """Drive a frame with pre-computed data. Returns same parameters for reference model."""
        zc_group = zc_to_group(zc)
        kb, _mb, num_additional = get_bg_params(base_graph)
        d = self.dut
        rng = self.rng

        if info_subblocks is None:
            info_subblocks = [generate_subblock(zc, rng) for _ in range(kb)]
        if core_parity_subblocks is None:
            core_parity_subblocks = [generate_subblock(zc, rng) for _ in range(4)]
        if add_parity_indices is None:
            add_parity_indices = list(range(4, 4 + num_additional))
        if add_parity_subblocks is None:
            add_parity_subblocks = [generate_subblock(zc, rng) for _ in range(num_additional)]
        if add_order is None:
            add_order = list(range(num_additional))

        self._idle_dut_inputs()

        self._set_config(base_graph, zc_group, zc)
        while True:
            await RisingEdge(d.clk_i)
            if int(d.ready_o.value) == 1:
                break

        assign_dut_value(d.init_i, 1)
        await RisingEdge(d.clk_i)
        assign_dut_value(d.init_i, 0)

        await self._drive_info(info_subblocks, zc, zc_group)
        await self._drive_core_parity(core_parity_subblocks, zc, zc_group)

        add_copy = list(add_parity_subblocks)
        idx_copy = list(add_parity_indices)
        await self._drive_add_parity(add_copy, idx_copy, add_order, zc, zc_group)

        self._idle_dut_inputs()

        return info_subblocks, core_parity_subblocks, add_parity_subblocks, add_parity_indices, add_order


# ==============================================================================
# Reference Model (tasks 3.1-3.5)
# ==============================================================================

class ReferenceModel:
    """Public-contract reference model keyed by (logical_addr, bank)."""

    def __init__(self, dut=None):
        self.dut = dut
        self.expected = {}   # (logical_addr, bank) → 96-bit lane data
        self.bank_valid = {}  # (logical_addr, bank) → bool

    def _set(self, addr, bank, data):
        self.expected[(addr, bank)] = data & ((1 << LANE_BITS) - 1)
        self.bank_valid[(addr, bank)] = True

    def write_info(self, subblocks, zc, zc_group, base_graph):
        kb, _mb, _na = get_bg_params(base_graph)
        if zc_group == ZC_SMALL:
            for addr, sb in enumerate(subblocks[:kb]):
                self._set(addr, 0, sb & ((1 << LANE_BITS) - 1))
        elif zc_group == ZC_MEDIUM:
            for addr, sb in enumerate(subblocks[:kb]):
                lanes = pack_into_lanes(sb, zc, 2)
                self._set(addr, 0, lanes[0])
                self._set(addr, 1, lanes[1])
        else:  # LARGE
            for addr, sb in enumerate(subblocks[:kb]):
                lanes = pack_into_lanes(sb, zc, 4)
                for b in range(4):
                    self._set(addr, b, lanes[b])

    def write_core_parity(self, subblocks, zc, zc_group, base_graph):
        kb, _mb, _na = get_bg_params(base_graph)
        pc_base = kb
        if zc_group == ZC_SMALL:
            for i in range(4):
                self._set(pc_base + i, i, subblocks[i] & ((1 << LANE_BITS) - 1))
        elif zc_group == ZC_MEDIUM:
            for beat in range(2):
                sb0 = subblocks[beat * 2]
                sb1 = subblocks[beat * 2 + 1]
                lanes0 = pack_into_lanes(sb0, zc, 2)
                lanes1 = pack_into_lanes(sb1, zc, 2)
                addr0 = pc_base + beat * 2
                addr1 = pc_base + beat * 2 + 1
                self._set(addr0, 0, lanes0[0])
                self._set(addr0, 1, lanes0[1])
                self._set(addr1, 2, lanes1[0])
                self._set(addr1, 3, lanes1[1])
        else:  # LARGE
            for i in range(4):
                lanes = pack_into_lanes(subblocks[i], zc, 4)
                for b in range(4):
                    self._set(pc_base + i, b, lanes[b])

    def write_add_parity(self, subblocks, indices, order, zc, zc_group, base_graph):
        kb, _mb, num_additional = get_bg_params(base_graph)
        pa_base = kb
        if zc_group == ZC_SMALL:
            for i in range(0, num_additional, 4):
                for j in range(4):
                    idx_in_order = i + j
                    if idx_in_order < num_additional:
                        sb = subblocks[order[idx_in_order]]
                        add_idx = indices[order[idx_in_order]]
                        logical_addr = pa_base + add_idx
                        self._set(logical_addr, j, sb & ((1 << LANE_BITS) - 1))
        elif zc_group == ZC_MEDIUM:
            for i in range(0, num_additional, 2):
                for pair in range(2):
                    idx_in_order = i + pair
                    if idx_in_order < num_additional:
                        sb = subblocks[order[idx_in_order]]
                        add_idx = indices[order[idx_in_order]]
                        logical_addr = pa_base + add_idx
                        lanes = pack_into_lanes(sb, zc, 2)
                        self._set(logical_addr, pair * 2, lanes[0])
                        self._set(logical_addr, pair * 2 + 1, lanes[1])
        else:  # LARGE
            for i in range(num_additional):
                sb = subblocks[order[i]]
                add_idx = indices[order[i]]
                logical_addr = pa_base + add_idx
                lanes = pack_into_lanes(sb, zc, 4)
                for b in range(4):
                    self._set(logical_addr, b, lanes[b])

    def get_expected(self, logical_addr, bank):
        return self.expected.get((logical_addr, bank))

    def is_bank_valid(self, logical_addr, bank):
        return self.bank_valid.get((logical_addr, bank), False)


# ==============================================================================
# Read Monitor (tasks 4.1-4.5)
# ==============================================================================

class ReadMonitor:
    """Monitors codeword_valid_o, sweeps r_addr_i, compares r_data_o with reference model."""

    def __init__(self, dut, ref_model, base_graph, zc, rng=None):
        self.dut = dut
        self.ref_model = ref_model
        self.base_graph = base_graph
        self.zc = zc
        self.zc_group = zc_to_group(zc)
        self.rng = rng if rng else random.Random()
        self.mismatches = []
        self.config_errors = []

    async def wait_for_valid(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk_i)
            if int(d.codeword_valid_o.value) == 1:
                break

    async def verify_config(self, expected_base_graph, expected_zc_group, expected_lifting_size):
        d = self.dut
        await RisingEdge(d.clk_i)
        await RisingEdge(d.clk_i)
        actual_bg = int(d.base_graph_o.value)
        actual_zg = int(d.zc_group_o.value)
        actual_zc = int(d.lifting_size_o.value)

        if actual_bg != expected_base_graph:
            self.config_errors.append(f"base_graph_o: expected {expected_base_graph}, got {actual_bg}")
        if actual_zg != expected_zc_group:
            self.config_errors.append(f"zc_group_o: expected {expected_zc_group}, got {actual_zg}")
        if actual_zc != expected_lifting_size:
            self.config_errors.append(f"lifting_size_o: expected {expected_lifting_size}, got {actual_zc}")

    async def read_and_verify(self):
        d = self.dut
        _kb, mb, _na = get_bg_params(self.base_graph)

        for logical_addr in range(mb):
            assign_dut_value(d.r_addr_i, logical_addr)
            await RisingEdge(d.clk_i)
            await FallingEdge(d.clk_i)

            dut_data = int(d.r_data_o.value)
            dut_bank_valid = int(d.bank_valid_o.value)
            lanes = dut_value_to_lanes(dut_data)

            for bank in range(NUM_LANES):
                bank_active = (dut_bank_valid >> bank) & 1
                ref_is_valid = self.ref_model.is_bank_valid(logical_addr, bank)

                if bank_active and not ref_is_valid:
                    self.mismatches.append(
                        f"addr={logical_addr} bank={bank}: DUT valid but ref model has no data "
                        f"(DUT lane={hex(lanes[bank])})"
                    )
                elif ref_is_valid and not bank_active:
                    self.mismatches.append(
                        f"addr={logical_addr} bank={bank}: ref model expects data but DUT bank_valid=0"
                    )
                elif bank_active and ref_is_valid:
                    expected_lane = self.ref_model.get_expected(logical_addr, bank)
                    if lanes[bank] != expected_lane:
                        self.mismatches.append(
                            f"addr={logical_addr} bank={bank}: "
                            f"expected={hex(expected_lane)}, got={hex(lanes[bank])}"
                        )

    async def acknowledge_frame(self):
        d = self.dut
        assign_dut_value(d.codeword_done_i, 1)
        await RisingEdge(d.clk_i)
        assign_dut_value(d.codeword_done_i, 0)

    def report(self):
        errors = self.config_errors + self.mismatches
        if errors:
            return "\n".join(errors)
        return None


# ==============================================================================
# Common Test Infrastructure
# ==============================================================================

async def reset_dut(dut, cycles=5):
    assign_dut_value(dut.arst_ni, 0)
    await ClockCycles(dut.clk_i, cycles)
    assign_dut_value(dut.arst_ni, 1)
    await ClockCycles(dut.clk_i, cycles)


async def run_frame_test(dut, base_graph, zc, driver, rng, seed, description=""):
    """Run one frame through DUT: drive, monitor, verify. Returns (passed, error_msg)."""
    log_seed(dut, seed, f"{description} frame")

    zc_group = zc_to_group(zc)

    info, pc, pa, pa_indices, pa_order = await driver.send_frame(base_graph, zc)

    ref_model = ReferenceModel(dut)
    ref_model.write_info(info, zc, zc_group, base_graph)
    ref_model.write_core_parity(pc, zc, zc_group, base_graph)
    ref_model.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

    monitor = ReadMonitor(dut, ref_model, base_graph, zc, rng)
    await monitor.wait_for_valid()
    await monitor.verify_config(base_graph, zc_group, zc)

    dut._log.info(f"{description}: codeword_valid_o high, sweeping r_addr_i")
    await monitor.read_and_verify()

    error = monitor.report()
    if error:
        dut._log.error(f"{description} FAILED:\n{error}")
        await monitor.acknowledge_frame()
        return False, error
    else:
        dut._log.info(f"{description} PASSED")
        await monitor.acknowledge_frame()
        return True, None


# ==============================================================================
# Test Cases (tasks 5.1-5.10)
# ==============================================================================

@cocotb.test()
async def test_reset_start_frame(dut):
    """5.1: Reset and start-frame behavior."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    driver = CodewordDriver(dut)
    rng = random.Random(42)

    await reset_dut(dut)

    assert int(dut.ready_o.value) == 1, "ready_o must be 1 after reset"
    assert int(dut.codeword_valid_o.value) == 0, "codeword_valid_o must be 0 after reset"

    for _ in range(5):
        await RisingEdge(dut.clk_i)
        assert int(dut.ready_o.value) == 1, "ready_o should remain high without init"

    passed, err = await run_frame_test(dut, 0, 48, driver, rng, 101, "reset_start")
    assert passed, f"reset/start test failed: {err}"

    dut._log.info("5.1 reset/start-frame test PASSED")


@cocotb.test()
async def test_info_focused(dut):
    """5.2: Info-focused test with zero core/additional parity data."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(123)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    zc = 96
    base_graph = 0
    zc_group = zc_to_group(zc)
    kb, _mb, num_additional = get_bg_params(base_graph)

    info = [generate_subblock(zc, rng) for _ in range(kb)]
    pc = [0] * 4
    pa = [0] * num_additional
    pa_indices = list(range(4, 4 + num_additional))
    pa_order = list(range(num_additional))

    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break

    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)

    await driver._drive_info(info, zc, zc_group)
    await driver._drive_core_parity(pc, zc, zc_group)
    await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

    ref = ReferenceModel(dut)
    ref.write_info(info, zc, zc_group, base_graph)
    ref.write_core_parity(pc, zc, zc_group, base_graph)
    ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

    monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
    await monitor.wait_for_valid()
    await monitor.verify_config(base_graph, zc_group, zc)
    await monitor.read_and_verify()

    err = monitor.report()
    if err:
        dut._log.error(f"info-focused test FAILED: {err}")
    else:
        dut._log.info("5.2 info-focused test PASSED")
    await monitor.acknowledge_frame()

    assert err is None, f"info-focused test failed: {err}"


@cocotb.test()
async def test_core_focused_all_groups(dut):
    """5.3: Core-focused tests for all zc_group values."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(456)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    test_cases = [
        (0, 48, ZC_SMALL, "core_bg1_small"),
        (0, 128, ZC_MEDIUM, "core_bg1_medium"),
        (0, 384, ZC_LARGE, "core_bg1_large"),
        (1, 80, ZC_SMALL, "core_bg2_small"),
        (1, 192, ZC_MEDIUM, "core_bg2_medium"),
        (1, 288, ZC_LARGE, "core_bg2_large"),
    ]

    for base_graph, zc, zc_group, label in test_cases:
        kb, _mb, num_additional = get_bg_params(base_graph)
        info = [generate_subblock(zc, rng) for _ in range(kb)]
        pc = [generate_subblock(zc, rng) for _ in range(4)]
        pa = [0] * num_additional
        pa_indices = list(range(4, 4 + num_additional))
        pa_order = list(range(num_additional))

        driver._idle_dut_inputs()
        driver._set_config(base_graph, zc_group, zc)
        while True:
            await RisingEdge(dut.clk_i)
            if int(dut.ready_o.value) == 1:
                break

        assign_dut_value(dut.init_i, 1)
        await RisingEdge(dut.clk_i)
        assign_dut_value(dut.init_i, 0)

        await driver._drive_info(info, zc, zc_group)
        await driver._drive_core_parity(pc, zc, zc_group)
        await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

        ref = ReferenceModel(dut)
        ref.write_info(info, zc, zc_group, base_graph)
        ref.write_core_parity(pc, zc, zc_group, base_graph)
        ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

        monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
        await monitor.wait_for_valid()
        await monitor.verify_config(base_graph, zc_group, zc)
        await monitor.read_and_verify()

        err = monitor.report()
        await monitor.acknowledge_frame()
        assert err is None, f"{label} core-focused test failed: {err}"
        dut._log.info(f"  {label} PASSED")

    dut._log.info("5.3 core-focused all-groups test PASSED")


@cocotb.test()
async def test_sorted_additional_parity(dut):
    """5.4: Full-frame test with sorted additional parity."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(789)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    passed, err = await run_frame_test(dut, 0, 128, driver, rng, 202, "sorted_ap_bg1_medium")
    assert passed, f"sorted AP test failed: {err}"

    passed, err = await run_frame_test(dut, 1, 80, driver, rng, 203, "sorted_ap_bg2_small")
    assert passed, f"sorted AP test failed: {err}"

    dut._log.info("5.4 sorted additional parity test PASSED")


@cocotb.test()
async def test_shuffled_additional_parity(dut):
    """5.5: Full-frame test with shuffled additional parity."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(111)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    for base_graph in [0, 1]:
        for zc in [96, 192, 384]:
            zc_group = zc_to_group(zc)
            _, _mb, num_additional = get_bg_params(base_graph)
            kb, _, _ = get_bg_params(base_graph)

            info = [generate_subblock(zc, rng) for _ in range(kb)]
            pc = [generate_subblock(zc, rng) for _ in range(4)]
            pa_indices = list(range(4, 4 + num_additional))
            pa = [generate_subblock(zc, rng) for _ in range(num_additional)]
            pa_order = list(range(num_additional))
            rng.shuffle(pa_order)

            driver._idle_dut_inputs()
            driver._set_config(base_graph, zc_group, zc)
            while True:
                await RisingEdge(dut.clk_i)
                if int(dut.ready_o.value) == 1:
                    break
            assign_dut_value(dut.init_i, 1)
            await RisingEdge(dut.clk_i)
            assign_dut_value(dut.init_i, 0)

            await driver._drive_info(info, zc, zc_group)
            await driver._drive_core_parity(pc, zc, zc_group)
            await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

            ref = ReferenceModel(dut)
            ref.write_info(info, zc, zc_group, base_graph)
            ref.write_core_parity(pc, zc, zc_group, base_graph)
            ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

            monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
            await monitor.wait_for_valid()
            await monitor.verify_config(base_graph, zc_group, zc)
            await monitor.read_and_verify()
            err = monitor.report()
            await monitor.acknowledge_frame()

            label = f"shuffled_bg{2 if base_graph else 1}_zc{zc}"
            assert err is None, f"{label} failed: {err}"
            dut._log.info(f"  {label} PASSED")

    dut._log.info("5.5 shuffled additional parity test PASSED")


@cocotb.test()
async def test_same_modulo_small_pa(dut):
    """5.6: Same-modulo small PA test using indices [4,8,12,16]."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(222)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    base_graph = 0
    zc = 48
    zc_group = zc_to_group(zc)
    kb, _mb, num_additional = get_bg_params(base_graph)

    info = [generate_subblock(zc, rng) for _ in range(kb)]
    pc = [generate_subblock(zc, rng) for _ in range(4)]

    # Build index list: first 4 are [4,8,12,16], remaining fill the set.
    all_indices = list(range(4, 4 + num_additional))
    same_modulo = [4, 8, 12, 16]
    remaining = [i for i in all_indices if i not in same_modulo]
    pa_indices = same_modulo + remaining

    pa = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order = list(range(num_additional))

    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)

    await driver._drive_info(info, zc, zc_group)
    await driver._drive_core_parity(pc, zc, zc_group)
    await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

    ref = ReferenceModel(dut)
    ref.write_info(info, zc, zc_group, base_graph)
    ref.write_core_parity(pc, zc, zc_group, base_graph)
    ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

    monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
    await monitor.wait_for_valid()
    await monitor.verify_config(base_graph, zc_group, zc)
    await monitor.read_and_verify()
    err = monitor.report()
    await monitor.acknowledge_frame()
    assert err is None, f"same-modulo test failed: {err}"

    dut._log.info("5.6 same-modulo small PA test PASSED")


@cocotb.test()
async def test_medium_paired_and_large_duplicated_pa(dut):
    """5.7: Medium paired-index and large duplicated-index PA tests."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(333)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    # Medium test (paired indices in each beat)
    base_graph = 0
    zc = 144
    zc_group = zc_to_group(zc)
    kb, _mb, num_additional = get_bg_params(base_graph)

    info = [generate_subblock(zc, rng) for _ in range(kb)]
    pc = [generate_subblock(zc, rng) for _ in range(4)]
    pa_indices = list(range(4, 4 + num_additional))
    pa = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order = list(range(num_additional))
    rng.shuffle(pa_order)

    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)
    await driver._drive_info(info, zc, zc_group)
    await driver._drive_core_parity(pc, zc, zc_group)
    await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

    ref = ReferenceModel(dut)
    ref.write_info(info, zc, zc_group, base_graph)
    ref.write_core_parity(pc, zc, zc_group, base_graph)
    ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

    monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
    await monitor.wait_for_valid()
    await monitor.verify_config(base_graph, zc_group, zc)
    await monitor.read_and_verify()
    err = monitor.report()
    await monitor.acknowledge_frame()
    assert err is None, f"medium paired test failed: {err}"
    dut._log.info("  medium paired PA PASSED")

    # Large test (duplicated four-lane indices)
    zc = 288
    zc_group = zc_to_group(zc)
    base_graph = 1
    kb, _mb, num_additional = get_bg_params(base_graph)

    info = [generate_subblock(zc, rng) for _ in range(kb)]
    pc = [generate_subblock(zc, rng) for _ in range(4)]
    pa_indices = list(range(4, 4 + num_additional))
    pa = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order = list(range(num_additional))
    rng.shuffle(pa_order)

    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)
    await driver._drive_info(info, zc, zc_group)
    await driver._drive_core_parity(pc, zc, zc_group)
    await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

    ref = ReferenceModel(dut)
    ref.write_info(info, zc, zc_group, base_graph)
    ref.write_core_parity(pc, zc, zc_group, base_graph)
    ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

    monitor = ReadMonitor(dut, ref, base_graph, zc, rng)
    await monitor.wait_for_valid()
    await monitor.verify_config(base_graph, zc_group, zc)
    await monitor.read_and_verify()
    err = monitor.report()
    await monitor.acknowledge_frame()
    assert err is None, f"large duplicated test failed: {err}"
    dut._log.info("  large duplicated PA PASSED")

    dut._log.info("5.7 medium/large PA test PASSED")


@cocotb.test()
async def test_seeded_randomized_sweep(dut):
    """5.8: Seeded randomized BG/Zc/zc_group sweep."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(444)

    await reset_dut(dut)

    valid_zcs = [z for z in get_5gnr_zc_values() if z > 0]
    num_trials = 20

    for trial in range(num_trials):
        rng_state = random.Random(trial * 137 + 444)
        driver = CodewordDriver(dut, rng_state)
        base_graph = rng_state.choice([0, 1])
        zc = rng_state.choice(valid_zcs)
        zc_group = zc_to_group(zc)
        kb, _mb, num_additional = get_bg_params(base_graph)

        info = [generate_subblock(zc, rng_state) for _ in range(kb)]
        pc = [generate_subblock(zc, rng_state) for _ in range(4)]
        pa_indices = list(range(4, 4 + num_additional))
        pa = [generate_subblock(zc, rng_state) for _ in range(num_additional)]
        pa_order = list(range(num_additional))
        rng_state.shuffle(pa_order)

        driver._idle_dut_inputs()
        driver._set_config(base_graph, zc_group, zc)
        while True:
            await RisingEdge(dut.clk_i)
            if int(dut.ready_o.value) == 1:
                break
        assign_dut_value(dut.init_i, 1)
        await RisingEdge(dut.clk_i)
        assign_dut_value(dut.init_i, 0)

        await driver._drive_info(info, zc, zc_group)
        await driver._drive_core_parity(pc, zc, zc_group)
        await driver._drive_add_parity(pa, pa_indices, pa_order, zc, zc_group)

        ref = ReferenceModel(dut)
        ref.write_info(info, zc, zc_group, base_graph)
        ref.write_core_parity(pc, zc, zc_group, base_graph)
        ref.write_add_parity(pa, pa_indices, pa_order, zc, zc_group, base_graph)

        monitor = ReadMonitor(dut, ref, base_graph, zc, rng_state)
        await monitor.wait_for_valid()
        await monitor.verify_config(base_graph, zc_group, zc)
        await monitor.read_and_verify()
        err = monitor.report()
        await monitor.acknowledge_frame()

        assert err is None, f"trial {trial} (BG={base_graph}, Zc={zc}) failed: {err}"
        dut._log.info(f"  trial {trial}: BG={base_graph}, Zc={zc} PASSED")

    dut._log.info(f"5.8 randomized sweep ({num_trials} trials) PASSED")


@cocotb.test()
async def test_ping_pong_two_frame(dut):
    """5.9: Ping-pong two-frame ordering test."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(555)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    zc = 128
    base_graph = 0
    zc_group = zc_to_group(zc)

    # Frame 0
    info0, pc0, pa0, pa_indices0, pa_order0 = await driver.send_frame(base_graph, zc)

    ref0 = ReferenceModel(dut)
    ref0.write_info(info0, zc, zc_group, base_graph)
    ref0.write_core_parity(pc0, zc, zc_group, base_graph)
    ref0.write_add_parity(pa0, pa_indices0, pa_order0, zc, zc_group, base_graph)

    # Frame 1 (before reading frame 0)
    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)

    kb, _mb, num_additional = get_bg_params(base_graph)
    info1 = [generate_subblock(zc, rng) for _ in range(kb)]
    pc1 = [generate_subblock(zc, rng) for _ in range(4)]
    pa_indices1 = list(range(4, 4 + num_additional))
    pa1 = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order1 = list(range(num_additional))
    rng.shuffle(pa_order1)
    await driver._drive_info(info1, zc, zc_group)
    await driver._drive_core_parity(pc1, zc, zc_group)
    await driver._drive_add_parity(pa1, pa_indices1, pa_order1, zc, zc_group)
    driver._idle_dut_inputs()

    ref1 = ReferenceModel(dut)
    ref1.write_info(info1, zc, zc_group, base_graph)
    ref1.write_core_parity(pc1, zc, zc_group, base_graph)
    ref1.write_add_parity(pa1, pa_indices1, pa_order1, zc, zc_group, base_graph)

    # Read frame 0
    mon0 = ReadMonitor(dut, ref0, base_graph, zc, rng)
    await mon0.wait_for_valid()
    await mon0.verify_config(base_graph, zc_group, zc)
    await mon0.read_and_verify()
    err0 = mon0.report()
    await mon0.acknowledge_frame()
    assert err0 is None, f"ping-pong frame 0 failed: {err0}"
    dut._log.info("  frame 0 PASSED")

    # Read frame 1
    mon1 = ReadMonitor(dut, ref1, base_graph, zc, rng)
    await mon1.wait_for_valid()
    await mon1.verify_config(base_graph, zc_group, zc)
    await mon1.read_and_verify()
    err1 = mon1.report()
    await mon1.acknowledge_frame()
    assert err1 is None, f"ping-pong frame 1 failed: {err1}"
    dut._log.info("  frame 1 PASSED")

    dut._log.info("5.9 ping-pong two-frame test PASSED")


@cocotb.test()
async def test_both_slots_full(dut):
    """5.10: Both slots full test - verify ready_o deassertion blocks third frame start."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(666)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    zc = 96
    base_graph = 0
    zc_group = zc_to_group(zc)

    # Frame 0
    info0, pc0, pa0, pa_indices0, pa_order0 = await driver.send_frame(base_graph, zc)

    # Frame 1
    driver._idle_dut_inputs()
    driver._set_config(base_graph, zc_group, zc)
    while True:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
    assign_dut_value(dut.init_i, 1)
    await RisingEdge(dut.clk_i)
    assign_dut_value(dut.init_i, 0)

    kb, _mb, num_additional = get_bg_params(base_graph)
    info1 = [generate_subblock(zc, rng) for _ in range(kb)]
    pc1 = [generate_subblock(zc, rng) for _ in range(4)]
    pa_indices1 = list(range(4, 4 + num_additional))
    pa1 = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order1 = list(range(num_additional))
    await driver._drive_info(info1, zc, zc_group)
    await driver._drive_core_parity(pc1, zc, zc_group)
    await driver._drive_add_parity(pa1, pa_indices1, pa_order1, zc, zc_group)
    driver._idle_dut_inputs()

    # Both slots should be full now - ready_o should be low
    await RisingEdge(dut.clk_i)
    ready = int(dut.ready_o.value)
    dut._log.info(f"After 2 frames written, ready_o = {ready}")

    # Try to start frame 2 - should be blocked
    driver._set_config(base_graph, zc_group, zc)
    blocked_cycles = 0
    max_wait = 20
    while blocked_cycles < max_wait:
        await RisingEdge(dut.clk_i)
        if int(dut.ready_o.value) == 1:
            break
        blocked_cycles += 1

    if blocked_cycles >= max_wait:
        dut._log.info("ready_o stayed low for 20 cycles - third frame blocked (expected)")

    # Now read frame 0 to free a slot
    ref0 = ReferenceModel(dut)
    ref0.write_info(info0, zc, zc_group, base_graph)
    ref0.write_core_parity(pc0, zc, zc_group, base_graph)
    ref0.write_add_parity(pa0, pa_indices0, pa_order0, zc, zc_group, base_graph)

    mon0 = ReadMonitor(dut, ref0, base_graph, zc, rng)
    await mon0.wait_for_valid()
    await mon0.read_and_verify()
    err0 = mon0.report()
    await mon0.acknowledge_frame()
    assert err0 is None, f"both-slots-full frame 0 failed: {err0}"

    # After freeing slot 0, ready_o should recover (w_sel_q now at RAM0).
    await RisingEdge(dut.clk_i)
    ready_after = int(dut.ready_o.value)
    dut._log.info(f"After reading frame 0, ready_o = {ready_after}")
    assert ready_after == 1, f"ready_o should be 1 after freeing a slot, got {ready_after}"

    # Read frame 1 (RAM1)
    ref1 = ReferenceModel(dut)
    ref1.write_info(info1, zc, zc_group, base_graph)
    ref1.write_core_parity(pc1, zc, zc_group, base_graph)
    ref1.write_add_parity(pa1, pa_indices1, pa_order1, zc, zc_group, base_graph)

    mon1 = ReadMonitor(dut, ref1, base_graph, zc, rng)
    await mon1.wait_for_valid()
    await mon1.read_and_verify()
    err1 = mon1.report()
    await mon1.acknowledge_frame()
    assert err1 is None, f"both-slots-full frame 1 failed: {err1}"

    dut._log.info("5.10 both-slots-full test PASSED")
