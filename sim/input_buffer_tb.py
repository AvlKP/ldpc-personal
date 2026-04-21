import logging
import random
from dataclasses import dataclass
from typing import List, Optional

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

LOG = logging.getLogger("input_buffer_tb")

DATA_WIDTH = 32
INPUT_BITS_MAX = 8448
ZC_MAX = 384
KB_MAX = 22
BG2_INFO_GROUP_MAX = 10


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
	fetch_size = _fetch_size_bits(zc)
	start_bit = zc * (info_group - 1)
	return start_bit + fetch_size


def _fetch_size_bits(zc: int) -> int:
	if zc <= (ZC_MAX >> 2):
		return ZC_MAX >> 2
	if zc <= (ZC_MAX >> 1):
		return ZC_MAX >> 1
	if zc <= ZC_MAX:
		return ZC_MAX
	raise AssertionError(f"Unsupported lifting size zc={zc}")


def _compute_expected_data_batch(payload: List[int], zc: int, info_group: int) -> int:
	"""
	Non-cycle-accurate reference model:
	- choose fetch size from zc: {96, 192, 384}
	- start bit = zc * (info_group - 1)
	- slice fetch-size bits from input code block vector
	- duplicate 96/192 slices up to 384 bits
	"""
	code_block = 0
	for idx, word in enumerate(payload):
		code_block |= (word & 0xFFFF_FFFF) << (idx * DATA_WIDTH)

	start_bit = zc * (info_group - 1)
	fetch_size = _fetch_size_bits(zc)
	unit_mask = (1 << fetch_size) - 1
	unit = (code_block >> start_bit) & unit_mask

	if fetch_size == (ZC_MAX >> 2):
		expected = 0
		for j in range(4):
			expected |= unit << (j * fetch_size)
	elif fetch_size == (ZC_MAX >> 1):
		expected = unit | (unit << fetch_size)
	else:
		expected = unit

	return expected & ((1 << ZC_MAX) - 1)


def _assert_data_batch_matches(
	actual: int,
	payload: List[int],
	zc: int,
	info_group: int,
	scenario_name: str,
) -> None:
	expected = _compute_expected_data_batch(payload, zc, info_group)
	if actual != expected:
		raise AssertionError(
			f"{scenario_name}: data_batch_o mismatch for zc={zc}, info_group={info_group}; "
			f"expected=0x{expected:096x} actual=0x{actual:096x}"
		)


def _info_group_max_for_base_graph(base_graph: str) -> int:
	bg = base_graph.upper()
	if bg == "BG1":
		return KB_MAX
	if bg == "BG2":
		return min(KB_MAX, BG2_INFO_GROUP_MAX)
	raise AssertionError(f"Unsupported base graph {base_graph}")


def _is_standard_info_group(base_graph: str, info_group: int) -> bool:
	bg = base_graph.upper()
	if bg == "BG1":
		return 1 <= info_group <= KB_MAX
	if bg == "BG2":
		return 1 <= info_group <= BG2_INFO_GROUP_MAX
	raise AssertionError(f"Unsupported base graph {base_graph}")


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
			info_group=1,
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
		input_bits = rng.randrange(16, 220) * DATA_WIDTH
		bg = "BG2" if input_bits <= 3840 else "BG1"
		if bg == "BG2":
			info_group = rng.randrange(1, BG2_INFO_GROUP_MAX + 1)
		else:
			info_group = rng.randrange(1, KB_MAX + 1)
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


async def _pulse_done(dut, delay_cycles: int = 0) -> None:
	for _ in range(delay_cycles):
		await RisingEdge(dut.clk_i)

	dut.ldpc_done_i.value = 1
	await RisingEdge(dut.clk_i)
	dut.ldpc_done_i.value = 0
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


async def _drive_axis_until_backpressure(dut, scn: LdpcScenario, payload: List[int]) -> int:
	words = len(payload)
	if words == 0:
		raise AssertionError(f"{scn.name}: payload must contain at least one word")

	handshakes = 0
	max_cycles = (words * 4) + 64

	dut.lifting_size_i.value = scn.zc
	dut.input_bits_i.value = scn.input_bits
	dut.info_group_i.value = scn.info_group

	for _ in range(max_cycles):
		data_idx = handshakes if handshakes < words else (words - 1)
		dut.s_axis_tvalid.value = 1
		dut.s_axis_tdata.value = payload[data_idx]

		await RisingEdge(dut.clk_i)

		ready = _safe_int(dut.s_axis_tready, "s_axis_tready")
		if ready == 0:
			break
		if ready == 1:
			handshakes += 1
	else:
		raise AssertionError(f"{scn.name}: timeout waiting for s_axis_tready deassertion")

	dut.s_axis_tvalid.value = 0
	dut.s_axis_tdata.value = 0

	expected_handshakes = scn.input_bits // DATA_WIDTH
	if handshakes != expected_handshakes:
		raise AssertionError(
			f"{scn.name}: handshakes before backpressure mismatch "
			f"({handshakes} != {expected_handshakes})"
		)

	return handshakes


async def _consume_one_block(
	dut,
	scn: LdpcScenario,
	rng: random.Random,
	payload: List[int],
	fetch_info_group: Optional[int] = None,
	pulse_done: bool = True,
) -> int:
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
	info_group = scn.info_group if fetch_info_group is None else fetch_info_group
	standard_info_group = _is_standard_info_group(scn.base_graph, info_group)
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
				if standard_info_group:
					_assert_data_batch_matches(
						actual=candidate,
						payload=payload,
						zc=scn.zc,
						info_group=info_group,
						scenario_name=scn.name,
					)
				observed = candidate
				break

	dut.ldpc_ready_i.value = 0
	if observed is None:
		raise AssertionError(f"{scn.name}: timeout waiting for ldpc_valid_o handshake")

	if pulse_done:
		await _pulse_done(dut, delay_cycles=scn.done_delay_cycles)

	return observed


async def _sweep_info_groups_for_block(
	dut,
	base_graph: str,
	zc: int,
	block_idx: int,
	rng_seed: int,
	write_until_backpressure: bool = False,
) -> List[int]:
	max_info_group = _info_group_max_for_base_graph(base_graph)
	scn = _normalize_scenario(
		LdpcScenario(
			name=f"{base_graph.lower()}_full_info_group_sweep",
			base_graph=base_graph,
			zc=zc,
			info_group=max_info_group,
			input_bits=2048,
			ready_drop_chance=0.0,
			read_start_gap=0,
			done_delay_cycles=1,
		)
	)

	payload = _build_payload(scn, block_idx)
	if write_until_backpressure:
		await _drive_axis_until_backpressure(dut, scn, payload)
	else:
		await _drive_axis_block(dut, scn, payload)

	rng = random.Random(rng_seed)
	observed = []
	for info_group in range(1, max_info_group + 1):
		dut.info_group_i.value = info_group
		observed.append(
			await _consume_one_block(
				dut,
				scn,
				rng,
				payload=payload,
				fetch_info_group=info_group,
				pulse_done=False,
			)
		)

	await _pulse_done(dut, delay_cycles=scn.done_delay_cycles)

	if _safe_int(dut.ldpc_valid_o, "ldpc_valid_o") != 0:
		raise AssertionError(f"{base_graph}: ldpc_valid_o should clear after done")

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
		batch_val = await _consume_one_block(dut, scn, rng, payload=payload)
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
			name="zc2_bg2_max_info",
			base_graph="BG2",
			zc=2,
			info_group=BG2_INFO_GROUP_MAX,
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
			info_group=BG2_INFO_GROUP_MAX,
			input_bits=512,
			ready_drop_chance=0.15,
			read_start_gap=1,
			done_delay_cycles=2,
		),
		LdpcScenario(
			name="zc97_boundary_high",
			base_graph="BG2",
			zc=97,
			info_group=BG2_INFO_GROUP_MAX,
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
		_ = await _consume_one_block(dut, scn, rng, payload=payload)

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
	recover_payload_a = _build_payload(recover_scn_a, 501)
	await _drive_axis_block(dut, recover_scn_a, recover_payload_a)
	_ = await _consume_one_block(dut, recover_scn_a, rng, payload=recover_payload_a)

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
	recover_payload_b = _build_payload(recover_scn_b, 503)
	await _drive_axis_block(dut, recover_scn_b, recover_payload_b)
	_ = await _consume_one_block(dut, recover_scn_b, rng, payload=recover_payload_b)


@cocotb.test()
async def input_buffer_bg1_full_info_group_sweep_test(dut):
	"""
	For one BG1 block, consume all info_group_i values before asserting done.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	observed = await _sweep_info_groups_for_block(
		dut=dut,
		base_graph="BG1",
		zc=192,
		block_idx=900,
		rng_seed=0xB61A,
	)

	if len(observed) != KB_MAX:
		raise AssertionError(f"BG1 sweep count mismatch ({len(observed)} != {KB_MAX})")


@cocotb.test()
async def input_buffer_bg2_full_info_group_sweep_test(dut):
	"""
	For one BG2 block, consume all info_group_i values before asserting done.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	bg2_max = _info_group_max_for_base_graph("BG2")
	observed = await _sweep_info_groups_for_block(
		dut=dut,
		base_graph="BG2",
		zc=96,
		block_idx=901,
		rng_seed=0xB62B,
	)

	if len(observed) != bg2_max:
		raise AssertionError(f"BG2 sweep count mismatch ({len(observed)} != {bg2_max})")


@cocotb.test()
async def input_buffer_bg_info_sweep_write_until_backpressure_test(dut):
	"""
	Sweep BG2 and BG1 info groups after streaming AXI input until backpressure.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	sweep_cases = [
		("BG2", 96, 920, 0xB71E),
		("BG1", 192, 921, 0xB72F),
	]

	for base_graph, zc, block_idx, seed in sweep_cases:
		observed = await _sweep_info_groups_for_block(
			dut=dut,
			base_graph=base_graph,
			zc=zc,
			block_idx=block_idx,
			rng_seed=seed,
			write_until_backpressure=True,
		)

		expected = _info_group_max_for_base_graph(base_graph)
		if len(observed) != expected:
			raise AssertionError(
				f"{base_graph} backpressure sweep count mismatch ({len(observed)} != {expected})"
			)

		if not any(v != 0 for v in observed):
			raise AssertionError(f"{base_graph} backpressure sweep observed only zero outputs")


@cocotb.test()
async def input_buffer_back_to_back_without_done_test(dut):
	"""
	Write two complete inputs back-to-back before ldpc_done_i of the first input.
	"""
	cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
	await _reset_dut(dut)

	scn_a = _normalize_scenario(
		LdpcScenario(
			name="back_to_back_first",
			base_graph="BG2",
			zc=96,
			info_group=4,
			input_bits=2048,
			ready_drop_chance=0.15,
			read_start_gap=1,
			done_delay_cycles=2,
		)
	)
	scn_b = _normalize_scenario(
		LdpcScenario(
			name="back_to_back_second",
			base_graph="BG2",
			zc=97,
			info_group=5,
			input_bits=2048,
			ready_drop_chance=0.20,
			read_start_gap=1,
			done_delay_cycles=2,
		)
	)

	rng = random.Random(0xB2B0A2)
	payload_a = _build_payload(scn_a, 820)
	payload_b = _build_payload(scn_b, 821)

	# Fill first block and consume one batch without signaling done.
	await _drive_axis_block(dut, scn_a, payload_a)
	first_batch = await _consume_one_block(dut, scn_a, rng, payload=payload_a, pulse_done=False)
	if _safe_int(dut.ldpc_done_i, "ldpc_done_i") != 0:
		raise AssertionError("ldpc_done_i must stay low before second write")

	# Write second block while the first is still pending done.
	await _drive_axis_block(dut, scn_b, payload_b)

	# Retire first, then retire second and check activity.
	await _pulse_done(dut, delay_cycles=scn_a.done_delay_cycles)
	second_batch = await _consume_one_block(dut, scn_b, rng, payload=payload_b, pulse_done=True)

	if first_batch == 0 and second_batch == 0:
		raise AssertionError("Back-to-back test observed zero data_batch_o for both blocks")


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
		payload = _build_payload(scn, 700 + idx)
		await _drive_axis_block(dut, scn, payload)
		observed.append(await _consume_one_block(dut, scn, rng, payload=payload))

	if not any(v != 0 for v in observed):
		raise AssertionError("Payload edge-case test observed only zero outputs")

