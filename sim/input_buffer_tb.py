import logging
import random
from dataclasses import dataclass
from typing import List

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

LOG = logging.getLogger("input_buffer_tb")

DATA_WIDTH = 32
INPUT_BITS_MAX = 8448
ZC_MAX = 384
KB_MAX = 22


@dataclass
class LdpcScenario:
	name: str
	base_graph: str
	zc: int
	info_group: int
	input_bits: int
	ready_drop_chance: float
	read_start_gap: int
	done_delay_cycles: int


def _out_sel(zc: int) -> int:
	out_sel_0 = 0 if zc <= (ZC_MAX >> 1) else 1
	out_sel_1 = 0 if zc <= (ZC_MAX >> 2) else 1
	return (out_sel_1 << 1) | out_sel_0


def _required_input_bits(zc: int, info_group: int) -> int:
	prod = zc * info_group
	base_pointer = prod >> 7
	# Need enough words so all addressed chunks are deterministic.
	max_word_index = ((base_pointer + _out_sel(zc)) * 4) + 3
	return (max_word_index + 1) * DATA_WIDTH


def _normalize_scenario(scn: LdpcScenario) -> LdpcScenario:
	if scn.zc <= 0 or scn.zc > ZC_MAX:
		raise AssertionError(f"Invalid lifting size Zc={scn.zc} for scenario {scn.name}")
	if scn.info_group < 0 or scn.info_group > KB_MAX:
		raise AssertionError(
			f"Invalid info_group={scn.info_group} for scenario {scn.name}"
		)

	required_bits = _required_input_bits(scn.zc, scn.info_group)
	target_bits = max(scn.input_bits, required_bits)
	target_bits = ((target_bits + DATA_WIDTH - 1) // DATA_WIDTH) * DATA_WIDTH
	if target_bits > INPUT_BITS_MAX:
		raise AssertionError(
			f"Scenario {scn.name} requires {target_bits} input bits, "
			f"exceeds INPUT_BITS_MAX={INPUT_BITS_MAX}"
		)

	return LdpcScenario(
		name=scn.name,
		base_graph=scn.base_graph,
		zc=scn.zc,
		info_group=scn.info_group,
		input_bits=target_bits,
		ready_drop_chance=scn.ready_drop_chance,
		read_start_gap=scn.read_start_gap,
		done_delay_cycles=scn.done_delay_cycles,
	)


def _safe_int(signal, name: str) -> int:
	try:
		return int(signal.value)
	except Exception as exc:
		bits = getattr(signal.value, "binstr", str(signal.value))
		raise AssertionError(f"Signal {name} is not fully resolved: {bits}") from exc


def _build_payload(scn: LdpcScenario, block_idx: int) -> List[int]:
	words = scn.input_bits // DATA_WIDTH
	rng = random.Random((0x5A17 << 8) ^ (block_idx * 0x1F3) ^ scn.zc ^ (scn.info_group << 4))
	payload = []

	for i in range(words):
		tag = ((block_idx & 0xFF) << 24) | ((scn.zc & 0xFF) << 16)
		tag ^= ((scn.info_group & 0x1F) << 11) | (i & 0x7FF)
		payload.append((tag ^ rng.getrandbits(32)) & 0xFFFF_FFFF)

	return payload


def _build_scenarios() -> List[LdpcScenario]:
	# Start simple (small BG2/Zc, no backpressure), then increase complexity.
	directed = [
		LdpcScenario(
			name="bg2_simple_z24",
			base_graph="BG2",
			zc=24,
			info_group=0,
			input_bits=256,
			ready_drop_chance=0.0,
			read_start_gap=0,
			done_delay_cycles=1,
		),
		LdpcScenario(
			name="bg2_medium_z96",
			base_graph="BG2",
			zc=96,
			info_group=1,
			input_bits=1024,
			ready_drop_chance=0.10,
			read_start_gap=1,
			done_delay_cycles=2,
		),
		LdpcScenario(
			name="bg1_transition_z192",
			base_graph="BG1",
			zc=192,
			info_group=3,
			input_bits=3072,
			ready_drop_chance=0.20,
			read_start_gap=2,
			done_delay_cycles=3,
		),
		LdpcScenario(
			name="bg1_large_z384",
			base_graph="BG1",
			zc=384,
			info_group=6,
			input_bits=6144,
			ready_drop_chance=0.30,
			read_start_gap=3,
			done_delay_cycles=4,
		),
	]

	rng = random.Random(0x1D5C)
	zc_pool = [2, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384]
	random_phase = []
	for i in range(6):
		zc = zc_pool[rng.randrange(len(zc_pool))]
		info_group = rng.randrange(0, min(KB_MAX, 20) + 1)
		input_bits = rng.randrange(16, 220) * DATA_WIDTH
		bg = "BG2" if input_bits <= 3840 else "BG1"
		random_phase.append(
			LdpcScenario(
				name=f"continuous_random_{i}",
				base_graph=bg,
				zc=zc,
				info_group=info_group,
				input_bits=input_bits,
				ready_drop_chance=min(0.55, 0.20 + (0.05 * i)),
				read_start_gap=1 + (i % 4),
				done_delay_cycles=1 + (i % 5),
			)
		)

	return [_normalize_scenario(s) for s in (directed + random_phase)]


async def _reset_dut(dut) -> None:
	dut.arst_ni.value = 0
	dut.s_axis_tdata.value = 0
	dut.s_axis_tvalid.value = 0
	dut.ldpc_ready_i.value = 0
	dut.ldpc_done_i.value = 0
	dut.lifting_size_i.value = 0
	dut.input_bits_i.value = 0
	dut.info_group_i.value = 0

	for _ in range(6):
		await RisingEdge(dut.clk_i)

	dut.arst_ni.value = 1
	for _ in range(4):
		await RisingEdge(dut.clk_i)


async def _pulse_reset(dut, low_cycles: int = 3, settle_cycles: int = 2) -> None:
	# Asynchronous reset pulse for mid-transaction reset coverage.
	dut.arst_ni.value = 0
	dut.s_axis_tvalid.value = 0
	dut.s_axis_tdata.value = 0
	dut.ldpc_ready_i.value = 0
	dut.ldpc_done_i.value = 0

	for _ in range(low_cycles):
		await RisingEdge(dut.clk_i)

	dut.arst_ni.value = 1
	for _ in range(settle_cycles):
		await RisingEdge(dut.clk_i)


async def _drive_axis_block(dut, scn: LdpcScenario, payload: List[int]) -> int:
	words = len(payload)
	handshakes = 0
	saw_ready_low = False

	dut.lifting_size_i.value = scn.zc
	dut.input_bits_i.value = scn.input_bits
	dut.info_group_i.value = scn.info_group

	word_idx = 0
	while word_idx < words:
		dut.s_axis_tvalid.value = 1
		dut.s_axis_tdata.value = payload[word_idx]

		await RisingEdge(dut.clk_i)

		ready = _safe_int(dut.s_axis_tready, "s_axis_tready")
		if ready == 0:
			saw_ready_low = True
		if ready == 1:
			handshakes += 1
			word_idx += 1

	dut.s_axis_tvalid.value = 0
	dut.s_axis_tdata.value = 0

	if not saw_ready_low:
		for _ in range(12):
			await RisingEdge(dut.clk_i)
			if _safe_int(dut.s_axis_tready, "s_axis_tready") == 0:
				saw_ready_low = True
				break

	if not saw_ready_low:
		raise AssertionError(f"{scn.name}: s_axis_tready never deasserted after full write")
	if handshakes != words:
		raise AssertionError(
			f"{scn.name}: handshake count mismatch ({handshakes} != {words})"
		)

	return handshakes


async def _consume_one_block(dut, scn: LdpcScenario, rng: random.Random) -> int:
	# Keep ready low while spacing out reads for continuous behavior.
	dut.ldpc_ready_i.value = 0
	dut.ldpc_done_i.value = 0

	for _ in range(scn.read_start_gap):
		await RisingEdge(dut.clk_i)

	# Kick read engine in DUT.
	dut.ldpc_ready_i.value = 1
	await RisingEdge(dut.clk_i)
	dut.ldpc_ready_i.value = 0

	# Conservative wait so read pipeline can collect data before consumption.
	min_wait = 6 + ((_out_sel(scn.zc) + 1) * 2)
	timeout = 1200
	baseline_batch = _safe_int(dut.data_batch_o, "data_batch_o")
	cycles = 0
	observed = None

	while cycles < timeout:
		cycles += 1
		ready = 0
		if cycles >= min_wait:
			ready = 0 if (rng.random() < scn.ready_drop_chance) else 1

		dut.ldpc_ready_i.value = ready
		await RisingEdge(dut.clk_i)

		valid = _safe_int(dut.ldpc_valid_o, "ldpc_valid_o")
		if cycles >= min_wait and ready == 1 and valid == 1:
			candidate = _safe_int(dut.data_batch_o, "data_batch_o")
			# Prefer a newly produced batch; force progress if valid is stuck high.
			if candidate != baseline_batch or cycles >= (min_wait + 64):
				observed = candidate
				break

	dut.ldpc_ready_i.value = 0
	if observed is None:
		raise AssertionError(f"{scn.name}: timeout waiting for ldpc_valid_o handshake")

	for _ in range(scn.done_delay_cycles):
		await RisingEdge(dut.clk_i)

	dut.ldpc_done_i.value = 1
	await RisingEdge(dut.clk_i)
	dut.ldpc_done_i.value = 0
	await RisingEdge(dut.clk_i)

	return observed


@cocotb.test()
async def input_buffer_continuous_progressive_test(dut):
	"""
	Continuous cocotb test for input_buffer with progressively harder 5G-LDPC-like scenarios.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	scenarios = _build_scenarios()
	rng = random.Random(0xC0C07B)
	observed_batches: List[int] = []
	total_words = 0

	LOG.info("Starting continuous progressive test with %d scenarios", len(scenarios))
	for idx, scn in enumerate(scenarios):
		payload = _build_payload(scn, idx)
		LOG.info(
			"[%02d/%02d] %s: BG=%s Zc=%d Kb=%d input_bits=%d words=%d drop=%.2f",
			idx + 1,
			len(scenarios),
			scn.name,
			scn.base_graph,
			scn.zc,
			scn.info_group,
			scn.input_bits,
			len(payload),
			scn.ready_drop_chance,
		)

		total_words += await _drive_axis_block(dut, scn, payload)
		batch_val = await _consume_one_block(dut, scn, rng)
		observed_batches.append(batch_val)

	unique_count = len(set(observed_batches))
	if unique_count < max(2, len(observed_batches) // 3):
		raise AssertionError(
			"Observed data batches are unexpectedly repetitive; "
			f"unique={unique_count}, total={len(observed_batches)}"
		)

	if not any(v != 0 for v in observed_batches):
		raise AssertionError("All observed data_batch_o values are zero")

	LOG.info(
		"Completed progressive continuous run: blocks=%d total_words=%d unique_batches=%d",
		len(scenarios),
		total_words,
		unique_count,
	)


@cocotb.test()
async def input_buffer_zc_boundary_edge_cases_test(dut):
	"""
	Exercise Zc boundaries around output selection transitions and edge values.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	edge_scenarios = [
		LdpcScenario(
			name="zc2_kbmax",
			base_graph="BG2",
			zc=2,
			info_group=22,
			input_bits=32,
			ready_drop_chance=0.00,
			read_start_gap=0,
			done_delay_cycles=1,
		),
		LdpcScenario(
			name="zc95_boundary_low",
			base_graph="BG2",
			zc=95,
			info_group=1,
			input_bits=256,
			ready_drop_chance=0.10,
			read_start_gap=1,
			done_delay_cycles=1,
		),
		LdpcScenario(
			name="zc96_boundary",
			base_graph="BG2",
			zc=96,
			info_group=22,
			input_bits=512,
			ready_drop_chance=0.15,
			read_start_gap=1,
			done_delay_cycles=2,
		),
		LdpcScenario(
			name="zc97_boundary_high",
			base_graph="BG2",
			zc=97,
			info_group=22,
			input_bits=768,
			ready_drop_chance=0.20,
			read_start_gap=2,
			done_delay_cycles=2,
		),
		LdpcScenario(
			name="zc191_boundary_low",
			base_graph="BG1",
			zc=191,
			info_group=10,
			input_bits=1024,
			ready_drop_chance=0.25,
			read_start_gap=2,
			done_delay_cycles=2,
		),
		LdpcScenario(
			name="zc192_boundary",
			base_graph="BG1",
			zc=192,
			info_group=22,
			input_bits=2048,
			ready_drop_chance=0.25,
			read_start_gap=2,
			done_delay_cycles=3,
		),
		LdpcScenario(
			name="zc193_boundary_high",
			base_graph="BG1",
			zc=193,
			info_group=22,
			input_bits=2048,
			ready_drop_chance=0.30,
			read_start_gap=3,
			done_delay_cycles=3,
		),
		LdpcScenario(
			name="zc384_max",
			base_graph="BG1",
			zc=384,
			info_group=6,
			input_bits=6144,
			ready_drop_chance=0.35,
			read_start_gap=3,
			done_delay_cycles=4,
		),
	]

	edge_scenarios = [_normalize_scenario(s) for s in edge_scenarios]
	rng = random.Random(0x0B0A0D)
	seen_modes = set()

	for idx, scn in enumerate(edge_scenarios):
		seen_modes.add(_out_sel(scn.zc))
		payload = _build_payload(scn, idx + 200)
		await _drive_axis_block(dut, scn, payload)
		_ = await _consume_one_block(dut, scn, rng)

	if seen_modes != {0, 2, 3}:
		raise AssertionError(f"Expected all out_sel modes {{0,2,3}}, got {seen_modes}")


@cocotb.test()
async def input_buffer_midstream_reset_edge_cases_test(dut):
	"""
	Assert reset robustness during active write and active read windows.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	# 1) Reset while write stream is active.
	write_scn = _normalize_scenario(
		LdpcScenario(
			name="reset_during_write",
			base_graph="BG1",
			zc=192,
			info_group=8,
			input_bits=4096,
			ready_drop_chance=0.10,
			read_start_gap=1,
			done_delay_cycles=2,
		)
	)
	payload = _build_payload(write_scn, 500)

	dut.lifting_size_i.value = write_scn.zc
	dut.input_bits_i.value = write_scn.input_bits
	dut.info_group_i.value = write_scn.info_group

	handshakes = 0
	word_idx = 0
	while handshakes < 20 and word_idx < len(payload):
		dut.s_axis_tvalid.value = 1
		dut.s_axis_tdata.value = payload[word_idx]
		await RisingEdge(dut.clk_i)
		if _safe_int(dut.s_axis_tready, "s_axis_tready") == 1:
			handshakes += 1
			word_idx += 1

	await _pulse_reset(dut, low_cycles=4, settle_cycles=3)

	if _safe_int(dut.ldpc_valid_o, "ldpc_valid_o") != 0:
		raise AssertionError("ldpc_valid_o should be cleared after reset during write")

	# Recovery block after write-reset.
	recover_scn_a = _normalize_scenario(
		LdpcScenario(
			name="post_write_reset_recovery",
			base_graph="BG2",
			zc=96,
			info_group=4,
			input_bits=2048,
			ready_drop_chance=0.15,
			read_start_gap=1,
			done_delay_cycles=2,
		)
	)
	rng = random.Random(0x0E5E7A)
	await _drive_axis_block(dut, recover_scn_a, _build_payload(recover_scn_a, 501))
	_ = await _consume_one_block(dut, recover_scn_a, rng)

	# 2) Reset while read phase is in progress.
	read_scn = _normalize_scenario(
		LdpcScenario(
			name="reset_during_read",
			base_graph="BG1",
			zc=193,
			info_group=12,
			input_bits=4096,
			ready_drop_chance=0.30,
			read_start_gap=2,
			done_delay_cycles=3,
		)
	)
	await _drive_axis_block(dut, read_scn, _build_payload(read_scn, 502))

	dut.ldpc_ready_i.value = 1
	await RisingEdge(dut.clk_i)
	dut.ldpc_ready_i.value = 0
	for _ in range(4):
		await RisingEdge(dut.clk_i)

	await _pulse_reset(dut, low_cycles=4, settle_cycles=3)

	if _safe_int(dut.ldpc_valid_o, "ldpc_valid_o") != 0:
		raise AssertionError("ldpc_valid_o should be cleared after reset during read")

	# Recovery block after read-reset.
	recover_scn_b = _normalize_scenario(
		LdpcScenario(
			name="post_read_reset_recovery",
			base_graph="BG2",
			zc=97,
			info_group=5,
			input_bits=2048,
			ready_drop_chance=0.20,
			read_start_gap=1,
			done_delay_cycles=2,
		)
	)
	await _drive_axis_block(dut, recover_scn_b, _build_payload(recover_scn_b, 503))
	_ = await _consume_one_block(dut, recover_scn_b, rng)


@cocotb.test()
async def input_buffer_payload_size_edge_cases_test(dut):
	"""
	Exercise very small and maximum input_bits configurations with continuous operation.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	scenarios = [
		LdpcScenario(
			name="min_payload_bits",
			base_graph="BG2",
			zc=2,
			info_group=0,
			input_bits=32,
			ready_drop_chance=0.00,
			read_start_gap=0,
			done_delay_cycles=1,
		),
		LdpcScenario(
			name="min_payload_bits_kbmax",
			base_graph="BG2",
			zc=2,
			info_group=22,
			input_bits=32,
			ready_drop_chance=0.05,
			read_start_gap=1,
			done_delay_cycles=1,
		),
		LdpcScenario(
			name="max_payload_bits",
			base_graph="BG1",
			zc=24,
			info_group=1,
			input_bits=INPUT_BITS_MAX,
			ready_drop_chance=0.20,
			read_start_gap=2,
			done_delay_cycles=3,
		),
	]

	rng = random.Random(0x51AE)
	observed = []
	for idx, raw_scn in enumerate(scenarios):
		scn = _normalize_scenario(raw_scn)
		await _drive_axis_block(dut, scn, _build_payload(scn, 700 + idx))
		observed.append(await _consume_one_block(dut, scn, rng))

	if not any(v != 0 for v in observed):
		raise AssertionError("Payload edge-case test observed only zero outputs")

