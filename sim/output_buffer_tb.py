"""Integration TB: codeword_generator + output_buffer (outbuff_integration).

Drives the generator's write side with the same core-like driver the
standalone codeword_generator TB uses, then checks the output_buffer's
AXI-Stream against the golden packed codeword: columns 0..mb-1 concatenated
LSB-first, 32-bit words, TLAST on the final (possibly partial) word.

Unlike the standalone TB this drives the FULL additional-parity set
(42 for BG1, 38 for BG2) so every column exists; the ZC_SMALL tail beat
carries filler lanes, either out-of-range (bank_valid guarded away) or
duplicate row labels with zero data (mimicking the encoder core's final
half row-group, which the output_buffer must ignore).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles
import random

from codeword_generator_tb import (
    ZC_SMALL, ZC_MEDIUM, ZC_LARGE,
    KB_BG1, KB_BG2, BG1_COL_N, BG2_COL_N, COL_WIDTH, LANE_BITS,
    zc_to_group, generate_subblock, pack_into_lanes,
    assign_dut_value, CodewordDriver,
)


def bg_params_full(base_graph):
    """(kb, mb, num_additional) with the FULL additional-parity count."""
    if base_graph:
        return KB_BG2, BG2_COL_N, BG2_COL_N - KB_BG2 - 4  # 38
    return KB_BG1, BG1_COL_N, BG1_COL_N - KB_BG1 - 4      # 42


def expected_axis_words(columns, zc):
    """Golden AXIS words: columns packed LSB-first into one bitstream."""
    stream = 0
    mask = (1 << zc) - 1
    for i, col in enumerate(columns):
        stream |= (col & mask) << (i * zc)
    total_bits = len(columns) * zc
    n_words = (total_bits + 31) // 32
    return [(stream >> (32 * i)) & 0xFFFFFFFF for i in range(n_words)]


async def drive_add_parity_full(dut, subblocks, indices, order, zc, zc_group,
                                dup_filler=False):
    """Friend-driver-compatible PA phase, but with the full row count.

    SMALL tail beat filler lanes: out-of-range indices (dup_filler=False,
    bank_valid write is address-guarded) or duplicates of the beat's real
    lanes with zero data (dup_filler=True, real-core behaviour).
    """
    n = len(subblocks)

    if zc_group == ZC_SMALL:
        for i in range(0, n, 4):
            lane_idx = []
            lane_data = []
            for j in range(4):
                k = i + j
                if k < n:
                    lane_idx.append(indices[order[k]])
                    lane_data.append(subblocks[order[k]])
                elif dup_filler:
                    # duplicate label of lane j-2, zeroed accumulator
                    lane_idx.append(lane_idx[j - 2])
                    lane_data.append(0)
                else:
                    lane_idx.append(BG1_COL_N + j)  # out of bank_valid range
                    lane_data.append(0)

            packed_idx = 0
            packed_data = 0
            for j in range(4):
                packed_idx |= (lane_idx[j] & ((1 << COL_WIDTH) - 1)) << (j * COL_WIDTH)
                packed_data |= (lane_data[j] & ((1 << LANE_BITS) - 1)) << (j * LANE_BITS)

            assign_dut_value(dut.add_parity_idx_i, packed_idx)
            assign_dut_value(dut.add_parity_data_i, packed_data)
            assign_dut_value(dut.add_parity_valid_i, 1)
            assign_dut_value(dut.last_block_i, 1 if (i + 4 >= n) else 0)
            await RisingEdge(dut.clk_i)

    elif zc_group == ZC_MEDIUM:
        assert n % 2 == 0, "MEDIUM PA count must be even (42/38 both are)"
        for i in range(0, n, 2):
            idx_a = indices[order[i]]
            idx_b = indices[order[i + 1]]
            lanes_a = pack_into_lanes(subblocks[order[i]], zc, 2)
            lanes_b = pack_into_lanes(subblocks[order[i + 1]], zc, 2)

            packed_idx = 0
            packed_data = 0
            for j, idx in enumerate([idx_a, idx_a, idx_b, idx_b]):
                packed_idx |= (idx & ((1 << COL_WIDTH) - 1)) << (j * COL_WIDTH)
            for j, lane in enumerate([lanes_a[0], lanes_a[1], lanes_b[0], lanes_b[1]]):
                packed_data |= (lane & ((1 << LANE_BITS) - 1)) << (j * LANE_BITS)

            assign_dut_value(dut.add_parity_idx_i, packed_idx)
            assign_dut_value(dut.add_parity_data_i, packed_data)
            assign_dut_value(dut.add_parity_valid_i, 1)
            assign_dut_value(dut.last_block_i, 1 if (i + 2 >= n) else 0)
            await RisingEdge(dut.clk_i)

    else:  # LARGE
        for i in range(n):
            idx = indices[order[i]]
            lanes = pack_into_lanes(subblocks[order[i]], zc, 4)
            packed_idx = 0
            packed_data = 0
            for j in range(4):
                packed_idx |= (idx & ((1 << COL_WIDTH) - 1)) << (j * COL_WIDTH)
                packed_data |= (lanes[j] & ((1 << LANE_BITS) - 1)) << (j * LANE_BITS)

            assign_dut_value(dut.add_parity_idx_i, packed_idx)
            assign_dut_value(dut.add_parity_data_i, packed_data)
            assign_dut_value(dut.add_parity_valid_i, 1)
            assign_dut_value(dut.last_block_i, 1 if (i + 1 >= n) else 0)
            await RisingEdge(dut.clk_i)

    assign_dut_value(dut.add_parity_valid_i, 0)
    assign_dut_value(dut.last_block_i, 0)


async def drive_frame(dut, driver, base_graph, zc, rng, shuffle_pa=False,
                      dup_filler=False):
    """Write one full frame into the generator. Returns golden column list."""
    zc_group = zc_to_group(zc)
    kb, mb, num_additional = bg_params_full(base_graph)

    info = [generate_subblock(zc, rng) for _ in range(kb)]
    pc = [generate_subblock(zc, rng) for _ in range(4)]
    pa_indices = list(range(4, 4 + num_additional))
    pa = [generate_subblock(zc, rng) for _ in range(num_additional)]
    pa_order = list(range(num_additional))
    if shuffle_pa:
        rng.shuffle(pa_order)
        if zc_group == ZC_SMALL and dup_filler:
            # real core hands the final half-group last; keep tail = last rows
            pa_order = sorted(pa_order[:-2]) + pa_order[-2:]

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
    await drive_add_parity_full(dut, pa, pa_indices, pa_order, zc, zc_group,
                                dup_filler=dup_filler)
    driver._idle_dut_inputs()

    # columns in codeword order: info, core parity, additional (col = kb+idx)
    columns = list(info) + list(pc)
    by_idx = {pa_indices[k]: pa[k] for k in range(num_additional)}
    columns += [by_idx[i] for i in range(4, 4 + num_additional)]
    assert len(columns) == mb
    return columns


async def axis_sink(dut, rng, p_ready=1.0, max_cycles=200000):
    """Collect one TLAST-delimited packet with random backpressure."""
    words = []
    for _ in range(max_cycles):
        assign_dut_value(dut.m_axis_tready, 1 if rng.random() < p_ready else 0)
        await FallingEdge(dut.clk_i)
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            words.append(int(dut.m_axis_tdata.value))
            if int(dut.m_axis_tlast.value):
                await RisingEdge(dut.clk_i)
                assign_dut_value(dut.m_axis_tready, 0)
                return words
        await RisingEdge(dut.clk_i)
    raise AssertionError(f"AXIS sink timeout after {max_cycles} cycles "
                         f"({len(words)} words collected)")


def check_words(label, got, exp):
    assert len(got) == len(exp), \
        f"{label}: word count {len(got)} != expected {len(exp)}"
    for i, (g, e) in enumerate(zip(got, exp)):
        assert g == e, f"{label}: word {i}: got {g:#010x} expected {e:#010x}"


async def reset_dut(dut, cycles=5):
    assign_dut_value(dut.arst_ni, 0)
    assign_dut_value(dut.m_axis_tready, 0)
    await ClockCycles(dut.clk_i, cycles)
    assign_dut_value(dut.arst_ni, 1)
    await ClockCycles(dut.clk_i, cycles)


async def run_one(dut, driver, base_graph, zc, rng, p_ready=1.0,
                  shuffle_pa=False, dup_filler=False, label=""):
    columns = await drive_frame(dut, driver, base_graph, zc, rng,
                                shuffle_pa=shuffle_pa, dup_filler=dup_filler)
    words = await axis_sink(dut, rng, p_ready=p_ready)
    check_words(label, words, expected_axis_words(columns, zc))
    dut._log.info(f"  {label}: {len(words)} words OK")


@cocotb.test()
async def test_integration_sweep(dut):
    """Directed BG x Zc sweep, full throughput, sorted PA."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(1001)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    configs = [
        (0, 2), (0, 32), (0, 48), (0, 96),      # BG1 SMALL (min, word, mid, bank edge)
        (1, 16), (1, 80),                        # BG2 SMALL
        (0, 104), (0, 128), (0, 192),            # BG1 MEDIUM
        (1, 144), (1, 176),                      # BG2 MEDIUM
        (0, 208), (0, 384),                      # BG1 LARGE (min, max)
        (1, 240), (1, 288),                      # BG2 LARGE
    ]
    for bg, zc in configs:
        await run_one(dut, driver, bg, zc, rng,
                      label=f"sweep_bg{2 if bg else 1}_zc{zc}")
    dut._log.info("integration sweep PASSED")


@cocotb.test()
async def test_integration_backpressure(dut):
    """Random tready stalls + shuffled PA arrival order."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(2002)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    for bg, zc in [(0, 48), (0, 128), (0, 384), (1, 2)]:
        await run_one(dut, driver, bg, zc, rng, p_ready=0.5, shuffle_pa=True,
                      label=f"bp_bg{2 if bg else 1}_zc{zc}")
    dut._log.info("integration backpressure PASSED")


@cocotb.test()
async def test_integration_duplicate_labels(dut):
    """ZC_SMALL final half-group duplicates (real-core tail) must be ignored."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(3003)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    for bg, zc in [(0, 48), (1, 80), (0, 96)]:
        await run_one(dut, driver, bg, zc, rng, dup_filler=True,
                      label=f"dup_bg{2 if bg else 1}_zc{zc}")
    dut._log.info("duplicate-label robustness PASSED")


@cocotb.test()
async def test_integration_pingpong(dut):
    """Two frames with different configs back to back through the ping-pong."""
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    rng = random.Random(4004)
    driver = CodewordDriver(dut, rng)
    await reset_dut(dut)

    cols0 = await drive_frame(dut, driver, 0, 128, rng)
    cols1 = await drive_frame(dut, driver, 1, 80, rng)  # fills the pong bank

    words0 = await axis_sink(dut, rng, p_ready=0.7)
    check_words("pingpong_frame0", words0, expected_axis_words(cols0, 128))
    words1 = await axis_sink(dut, rng, p_ready=0.7)
    check_words("pingpong_frame1", words1, expected_axis_words(cols1, 80))
    dut._log.info("ping-pong PASSED")
