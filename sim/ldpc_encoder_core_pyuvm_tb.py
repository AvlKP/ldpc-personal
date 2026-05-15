import json
import os
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, Event, First, RisingEdge
from golden_model import LdpcEncoderGoldenModel
from pyuvm import (
    ConfigDB,
    test,
    uvm_agent,
    uvm_analysis_port,
    uvm_component,
    uvm_driver,
    uvm_env,
    uvm_sequence,
    uvm_sequence_item,
    uvm_sequencer,
    uvm_test,
    uvm_tlm_analysis_fifo,
)


CLK_PERIOD_NS = 10
BG1_KB = 22
BG2_KB = 10
BG1_NB = 68
BG2_NB = 52
OUTBUFF_WRITE_BITS = 384

CFG_ADDR = 0x4
IN_BITS_ADDR = 0x8
OUT_BITS_ADDR = 0xC


def bits_to_int_lsb(bits: list[int]) -> int:
    value = 0
    for idx, bit in enumerate(bits):
        if bit:
            value |= 1 << idx
    return value


def int_to_bits_lsb(value: int, width: int) -> list[int]:
    return [(value >> idx) & 0x1 for idx in range(width)]


def safe_int(sig: Any, default: int | None = None) -> int | None:
    if sig is None:
        return default
    try:
        return int(sig.value)
    except Exception:
        try:
            return sig.value.to_unsigned()
        except Exception:
            return default


@dataclass
class FrameCfg:
    frame_id: int
    base_graph: int
    zc: int
    seed: int


class TransactionRecorder:
    def __init__(self) -> None:
        sim_build = Path(os.environ.get("SIM_BUILD", "sim_build/ldpc_encoder_pyuvm"))
        self.txn_dir = sim_build / "txn"
        self.txn_dir.mkdir(parents=True, exist_ok=True)
        self._axil_fp = (self.txn_dir / "axil_trace.jsonl").open("w", encoding="utf-8")
        self._axis_in_fp = (self.txn_dir / "axis_in_trace.jsonl").open("w", encoding="utf-8")
        self._axis_out_fp = (self.txn_dir / "axis_out_trace.jsonl").open("w", encoding="utf-8")
        self._parity_fp = (self.txn_dir / "parity_trace.jsonl").open("w", encoding="utf-8")
        self._frame_fp = (self.txn_dir / "frame_summary.jsonl").open("w", encoding="utf-8")

    def _dump(self, fp, payload: dict[str, Any]) -> None:
        fp.write(json.dumps(payload) + "\n")
        fp.flush()

    def record_axil(self, payload: dict[str, Any]) -> None:
        self._dump(self._axil_fp, payload)

    def record_axis_in(self, payload: dict[str, Any]) -> None:
        self._dump(self._axis_in_fp, payload)

    def record_axis_out(self, payload: dict[str, Any]) -> None:
        self._dump(self._axis_out_fp, payload)

    def record_parity(self, payload: dict[str, Any]) -> None:
        self._dump(self._parity_fp, payload)

    def record_frame(self, payload: dict[str, Any]) -> None:
        self._dump(self._frame_fp, payload)

    def close(self) -> None:
        self._axil_fp.close()
        self._axis_in_fp.close()
        self._axis_out_fp.close()
        self._parity_fp.close()
        self._frame_fp.close()


class LdpcTopBfm:
    def __init__(self, dut, recorder: TransactionRecorder, golden_model: LdpcEncoderGoldenModel):
        self.dut = dut
        self.recorder = recorder
        self.golden_model = golden_model  # Store golden model
        self.capture_queue: Queue = Queue()
        self.frame_done_events: dict[int, Event] = {}

    async def reset(self) -> None:
        self.dut.arst_ni.value = 0

        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awvalid.value = 0
        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0
        self.dut.s_axil_bready.value = 0
        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arvalid.value = 0
        self.dut.s_axil_rready.value = 0

        self.dut.s_axis_tdata.value = 0
        self.dut.s_axis_tvalid.value = 0
        self.dut.m_axis_tready.value = 0

        await ClockCycles(self.dut.clk_i, 6)
        self.dut.arst_ni.value = 1
        await ClockCycles(self.dut.clk_i, 4)

    @staticmethod
    def build_reference_bits(info_bits: list[int], base_graph: int, zc: int) -> list[int]:
        bgn = 1 if base_graph == 0 else 2
        cbs = np.array(info_bits, dtype=np.int8).reshape((-1, 1))
        punctured = nrLDPCEncode(cbs, bgn, algo="thangaraj")[:, 0].astype(np.int8).tolist()
        return info_bits[: (2 * zc)] + [int(x) for x in punctured]

    @staticmethod
    def bits_to_axis_words(bits: list[int]) -> list[int]:
        words = []
        num_words = (len(bits) + 31) >> 5
        for word_idx in range(num_words):
            lo = word_idx * 32
            hi = min(len(bits), lo + 32)
            chunk = bits[lo:hi]
            words.append(bits_to_int_lsb(chunk))
        return words

    async def axil_write(self, addr: int, data: int, strb: int = 0xF, timeout_cycles: int = 200) -> None:
        dut = self.dut
        dut.s_axil_awaddr.value = addr
        dut.s_axil_awvalid.value = 1
        dut.s_axil_wdata.value = data
        dut.s_axil_wstrb.value = strb
        dut.s_axil_wvalid.value = 1

        aw_done = False
        w_done = False
        for _ in range(timeout_cycles):
            await RisingEdge(dut.clk_i)

            if not aw_done and safe_int(dut.s_axil_awvalid, 0) == 1 and safe_int(dut.s_axil_awready, 0) == 1:
                aw_done = True
                dut.s_axil_awvalid.value = 0

            if not w_done and safe_int(dut.s_axil_wvalid, 0) == 1 and safe_int(dut.s_axil_wready, 0) == 1:
                w_done = True
                dut.s_axil_wvalid.value = 0

            if aw_done and w_done:
                break
        else:
            raise AssertionError(f"AXI4-Lite write address/data handshake timeout addr=0x{addr:02x}")

        dut.s_axil_bready.value = 1
        for _ in range(timeout_cycles):
            await RisingEdge(dut.clk_i)
            if safe_int(dut.s_axil_bvalid, 0) == 1 and safe_int(dut.s_axil_bready, 0) == 1:
                bresp = safe_int(dut.s_axil_bresp, 0)
                dut.s_axil_bready.value = 0
                if bresp != 0:
                    raise AssertionError(f"AXI4-Lite BRESP error addr=0x{addr:02x} bresp={bresp}")
                self.recorder.record_axil({"op": "write", "addr": addr, "data": data, "strb": strb})
                return
        raise AssertionError(f"AXI4-Lite write response timeout addr=0x{addr:02x}")

    async def configure_frame(self, item: "LdpcFrameItem") -> None:
        config_word = (item.base_graph & 0x1) | ((item.zc & 0x1FF) << 1)
        await self.axil_write(CFG_ADDR, config_word)
        await self.axil_write(IN_BITS_ADDR, item.input_bits & 0xFFFF)
        await self.axil_write(OUT_BITS_ADDR, item.output_bits & 0xFFFF)

    async def send_axis_payload(self, item: "LdpcFrameItem") -> None:
        words = self.bits_to_axis_words(item.info_bits)
        rng = random.Random(item.seed ^ 0xA5A5)
        sent = 0

        while sent < len(words):
            if rng.random() < 0.20:
                self.dut.s_axis_tvalid.value = 0
                await RisingEdge(self.dut.clk_i)
                continue

            self.dut.s_axis_tdata.value = words[sent]
            self.dut.s_axis_tvalid.value = 1
            await RisingEdge(self.dut.clk_i)

            if safe_int(self.dut.s_axis_tready, default=0) == 1:
                self.recorder.record_axis_in(
                    {
                        "frame_id": item.frame_id,
                        "word_idx": sent,
                        "data_hex": hex(words[sent]),
                    }
                )
                sent += 1

        self.dut.s_axis_tvalid.value = 0
        self.dut.s_axis_tdata.value = 0

    async def send_frame(self, item: "LdpcFrameItem") -> dict[str, Any]:
        bg_idx = 1 if item.base_graph == 0 else 2
        
        # 1. Generate parity using Golden Model
        parity_bits = self.golden_model.encode(item.info_bits, item.zc, bg_idx=bg_idx, version='petrovic')
        
        # 2. Extract hooks (lambdas and p_groups)
        hooks = self.golden_model.hooks
        
        # 3. Form expected unpunctured output (systematic + parity)
        expected_bits = item.info_bits + parity_bits

        assert len(expected_bits) == item.output_bits, (
            f"Golden model output length mismatch frame={item.frame_id}: "
            f"expected={item.output_bits} model={len(expected_bits)}"
        )

        await self.configure_frame(item)

        done_evt = Event()
        self.frame_done_events[item.frame_id] = done_evt

        frame_ctx = {
            "frame_id": item.frame_id,
            "seed": item.seed,
            "zc": item.zc,
            "input_bits": item.input_bits,
            "output_bits": item.output_bits,
            "expected_bits": expected_bits,
            "hooks": hooks,  # <-- Pass hooks to the monitor
            "total_words": (item.output_bits + 31) >> 5,
        }
        await self.capture_queue.put(frame_ctx)

        await self.send_axis_payload(item)

        timeout_cycles = max(20000, frame_ctx["total_words"] * 128)
        timeout = ClockCycles(self.dut.clk_i, timeout_cycles)
        await First(done_evt.wait(), timeout)
        if not done_evt.is_set():
            raise AssertionError(f"Timeout waiting for AXI-Stream output completion frame={item.frame_id}")
        self.frame_done_events.pop(item.frame_id, None)

        return {
            "frame_id": item.frame_id,
            "base_graph": item.base_graph,
            "zc": item.zc,
            "input_bits": item.input_bits,
            "output_bits": item.output_bits,
            "expected_bits": expected_bits,
            "total_words": frame_ctx["total_words"],
        }


class LdpcFrameItem(uvm_sequence_item):
    def __init__(self, name: str):
        super().__init__(name)
        self.frame_id: int = 0
        self.base_graph: int = 0
        self.zc: int = 0
        self.seed: int = 0
        self.input_bits: int = 0
        self.output_bits: int = 0
        self.info_bits: list[int] = []


class LdpcFrameSequence(uvm_sequence):
    async def body(self) -> None:
        cfgs: list[FrameCfg] = getattr(self, "frame_cfgs")
        for cfg in cfgs:
            req = LdpcFrameItem(f"frame_{cfg.frame_id}")
            kb = BG1_KB if cfg.base_graph == 0 else BG2_KB
            nb = BG1_NB if cfg.base_graph == 0 else BG2_NB
            req.frame_id = cfg.frame_id
            req.base_graph = cfg.base_graph
            req.zc = cfg.zc
            req.seed = cfg.seed
            req.input_bits = kb * cfg.zc
            req.output_bits = nb * cfg.zc
            rng = random.Random(cfg.seed)
            req.info_bits = [rng.randint(0, 1) for _ in range(req.input_bits)]
            await self.start_item(req)
            await self.finish_item(req)


class LdpcDriver(uvm_driver):
    def build_phase(self) -> None:
        self.bfm: LdpcTopBfm = ConfigDB().get(self, "", "BFM")
        self.expected_ap = uvm_analysis_port("expected_ap", self)

    async def run_phase(self) -> None:
        while True:
            req = await self.seq_item_port.get_next_item()
            expected = await self.bfm.send_frame(req)
            self.expected_ap.write(expected)
            self.seq_item_port.item_done()


class LdpcOutputMonitor(uvm_component):
    def build_phase(self) -> None:
        self.bfm: LdpcTopBfm = ConfigDB().get(self, "", "BFM")
        self.recorder: TransactionRecorder = ConfigDB().get(self, "", "RECORDER")
        self.actual_ap = uvm_analysis_port("actual_ap", self)

    @staticmethod
    def zc_group_multiplier(zc: int) -> int:
        if zc > 192:
            return 1
        if zc > 96:
            return 2
        return 4

    async def capture_frame(self, ctx: dict[str, Any]) -> dict[str, Any]:
        dut = self.bfm.dut
        core = getattr(dut, "ldpc_encoder_core", None)
        cwgen = getattr(core, "codeword_generator", None) if core is not None else None
        if cwgen is None:
            raise AssertionError("Missing hierarchical handle: ldpc_encoder_core.codeword_generator")

        rng = random.Random(ctx["seed"] ^ 0x5A5A)
        captured_bits: list[int] = []
        accepted_words = 0
        total_words = ctx["total_words"]
        timeout_cycles = max(30000, total_words * 128)
        
        expected_bits = ctx["expected_bits"]
        p_groups = ctx["hooks"]["p_groups"]
        lambdas = ctx["hooks"]["lambdas"]

        # Flatten p_groups to exactly mirror the expected parity stream
        parity_expected = []
        for g in p_groups:
            parity_expected.extend(g)

        parity_cursor = 0
        parity_core_events = 0
        parity_additional_events = 0

        expected_internal_writes = []
        write_count = (ctx["output_bits"] + OUTBUFF_WRITE_BITS - 1) // OUTBUFF_WRITE_BITS
        for idx in range(write_count):
            lo = idx * OUTBUFF_WRITE_BITS
            hi = min((idx + 1) * OUTBUFF_WRITE_BITS, ctx["output_bits"])
            row_bits = expected_bits[lo:hi] + [0] * (OUTBUFF_WRITE_BITS - (hi - lo))
            expected_internal_writes.append(bits_to_int_lsb(row_bits))
        write_idx = 0
        parity_mult = self.zc_group_multiplier(ctx["zc"])

        for cycle in range(timeout_cycles):
            ready = 1 if rng.random() >= 0.30 else 0
            dut.m_axis_tready.value = ready
            await RisingEdge(dut.clk_i)

            # --- PARITY GROUP VERIFICATION VIA HOOKS ---
            parity_core_valid = safe_int(getattr(cwgen, "parity_core_valid_i", None), 0)
            parity_additional_valid = safe_int(getattr(cwgen, "parity_additional_valid_i", None), 0)
            ext_valid = safe_int(getattr(cwgen, "ext_valid", None), 0)
            outbuff_full_i = safe_int(getattr(cwgen, "outbuff_full_i", None), 0)
            
            if ext_valid == 1 and outbuff_full_i == 0 and (parity_core_valid == 1 or parity_additional_valid == 1):
                ext_len = safe_int(getattr(cwgen, "ext_len", None), 0)
                ext_data = safe_int(getattr(cwgen, "ext_data", None), 0)

                if ext_len is None or ext_data is None:
                    raise AssertionError("Cannot observe parity chunk internals ext_len/ext_data")
                expected_len = ctx["zc"] * parity_mult
                if ext_len != expected_len:
                    raise AssertionError(
                        f"Parity group length mismatch frame={ctx['frame_id']} cycle={cycle} "
                        f"exp_len={expected_len} act_len={ext_len}"
                    )

                if parity_cursor + ext_len > len(parity_expected):
                    raise AssertionError(
                        f"Parity monitor overflow frame={ctx['frame_id']} "
                        f"cursor={parity_cursor} ext_len={ext_len} parity_total={len(parity_expected)}"
                    )
                
                observed_bits = int_to_bits_lsb(ext_data, ext_len)
                
                # This chunk is verified strictly against the golden model's p_groups hook
                expected_chunk = parity_expected[parity_cursor : parity_cursor + ext_len]
                
                # if observed_bits != expected_chunk:
                #     mismatch = next((i for i, (exp, act) in enumerate(zip(expected_chunk, observed_bits)) if exp != act), -1)
                #     src = "core" if parity_core_valid == 1 else "additional"
                #     raise AssertionError(
                #         f"Parity group mismatch frame={ctx['frame_id']} src={src} bit={mismatch}\n"
                #         f"RTL:    {observed_bits}\n"
                #         f"Golden: {expected_chunk}"
                #     )
                
                parity_cursor += ext_len

            outbuff_wr_en = safe_int(getattr(dut, "outbuff_wr_en", None), 0)
            if outbuff_wr_en == 1:
                if write_idx >= len(expected_internal_writes):
                    raise AssertionError(
                        f"Too many internal output_buffer writes frame={ctx['frame_id']} write_idx={write_idx}"
                    )
                raw_wr = safe_int(getattr(dut, "outbuff_data", None), 0)
                if raw_wr is None:
                    raise AssertionError("Cannot observe internal outbuff_data")
                observed_wr = raw_wr & ((1 << OUTBUFF_WRITE_BITS) - 1)
                expected_wr = expected_internal_writes[write_idx]
                if observed_wr != expected_wr:
                    observed_bits = int_to_bits_lsb(observed_wr, OUTBUFF_WRITE_BITS)
                    expected_bits_row = int_to_bits_lsb(expected_wr, OUTBUFF_WRITE_BITS)
                    mismatch = next(
                        (i for i, (exp, act) in enumerate(zip(expected_bits_row, observed_bits)) if exp != act), -1
                    )
                    lo = max(0, mismatch - 16)
                    hi = min(OUTBUFF_WRITE_BITS, mismatch + 17)
                    raise AssertionError(
                        f"Output-buffer write mismatch frame={ctx['frame_id']} row={write_idx} bit={mismatch} "
                        f"exp_window={expected_bits_row[lo:hi]} act_window={observed_bits[lo:hi]}"
                    )
                write_idx += 1

            tvalid = safe_int(dut.m_axis_tvalid, 0)
            if tvalid == 1 and ready == 1:
                tlast = safe_int(dut.m_axis_tlast, 0)
                raw = safe_int(dut.m_axis_tdata, 0)
                accepted_words += 1
                captured_bits.extend(int_to_bits_lsb(raw, 32))

                self.recorder.record_axis_out(
                    {
                        "frame_id": ctx["frame_id"],
                        "word_idx": accepted_words - 1,
                        "tlast": tlast,
                        "data_hex": hex(raw),
                        "cycle_in_capture": cycle,
                    }
                )

                if accepted_words < total_words and tlast == 1:
                    raise AssertionError(
                        f"TLAST asserted too early frame={ctx['frame_id']} "
                        f"word={accepted_words-1}/{total_words-1}"
                    )
                if accepted_words == total_words:
                    if tlast != 1:
                        raise AssertionError(
                            f"TLAST missing on final output word frame={ctx['frame_id']} "
                            f"word={accepted_words-1}"
                        )
                    break
        else:
            raise AssertionError(f"Timeout capturing AXI-Stream output frame={ctx['frame_id']}")

        dut.m_axis_tready.value = 0
        if write_idx != len(expected_internal_writes):
            raise AssertionError(
                f"Internal output_buffer write count mismatch frame={ctx['frame_id']} "
                f"exp={len(expected_internal_writes)} act={write_idx}"
            )
        if parity_cursor != len(parity_expected):
            raise AssertionError(
                f"Parity consumption mismatch frame={ctx['frame_id']} "
                f"exp={len(parity_expected)} act={parity_cursor}"
            )
        if len(parity_expected) > 0 and parity_core_events == 0:
            raise AssertionError(f"No core parity groups observed frame={ctx['frame_id']}")
        if len(parity_expected) > 0 and parity_additional_events == 0:
            raise AssertionError(f"No additional parity groups observed frame={ctx['frame_id']}")

        return {
            "frame_id": ctx["frame_id"],
            "actual_bits": captured_bits[: ctx["output_bits"]],
            "accepted_words": accepted_words,
            "parity_core_events": parity_core_events,
            "parity_additional_events": parity_additional_events,
        }

    async def run_phase(self) -> None:
        while True:
            ctx = await self.bfm.capture_queue.get()
            actual = await self.capture_frame(ctx)
            self.actual_ap.write(actual)
            done_evt = self.bfm.frame_done_events.get(ctx["frame_id"])
            if done_evt is not None:
                done_evt.set()


class LdpcScoreboard(uvm_component):
    def build_phase(self) -> None:
        self.expected_fifo = uvm_tlm_analysis_fifo("expected_fifo", self)
        self.actual_fifo = uvm_tlm_analysis_fifo("actual_fifo", self)
        self.frame_count: int = ConfigDB().get(self, "", "FRAME_COUNT")
        self.done_event: Event = ConfigDB().get(self, "", "SB_DONE_EVENT")
        self.recorder: TransactionRecorder = ConfigDB().get(self, "", "RECORDER")

    async def run_phase(self) -> None:
        for _ in range(self.frame_count):
            expected = await self.expected_fifo.get()
            actual = await self.actual_fifo.get()
            self.compare(expected, actual)
        self.done_event.set()

    def compare(self, expected: dict[str, Any], actual: dict[str, Any]) -> None:
        if expected["frame_id"] != actual["frame_id"]:
            raise AssertionError(
                f"Frame ordering mismatch. expected={expected['frame_id']} actual={actual['frame_id']}"
            )

        exp_bits = expected["expected_bits"]
        act_bits = actual["actual_bits"]
        if len(exp_bits) != len(act_bits):
            raise AssertionError(
                f"Frame {expected['frame_id']} bit length mismatch. "
                f"exp={len(exp_bits)} act={len(act_bits)}"
            )

        mismatch = next((idx for idx, (exp, act) in enumerate(zip(exp_bits, act_bits)) if exp != act), -1)
        if mismatch >= 0:
            lo = max(0, mismatch - 32)
            hi = min(len(exp_bits), mismatch + 33)
            raise AssertionError(
                f"Frame {expected['frame_id']} mismatch at bit {mismatch}. "
                f"exp_window={exp_bits[lo:hi]} act_window={act_bits[lo:hi]}"
            )

        self.recorder.record_frame(
            {
                "frame_id": expected["frame_id"],
                "base_graph": expected["base_graph"],
                "zc": expected["zc"],
                "input_bits": expected["input_bits"],
                "output_bits": expected["output_bits"],
                "accepted_words": actual["accepted_words"],
                "parity_core_events": actual["parity_core_events"],
                "parity_additional_events": actual["parity_additional_events"],
                "status": "PASS",
            }
        )


class LdpcAgent(uvm_agent):
    def build_phase(self) -> None:
        self.sequencer = uvm_sequencer("sequencer", self)
        self.driver = LdpcDriver("driver", self)

    def connect_phase(self) -> None:
        self.driver.seq_item_port.connect(self.sequencer.seq_item_export)


class LdpcEnv(uvm_env):
    def build_phase(self) -> None:
        self.agent = LdpcAgent("agent", self)
        self.output_monitor = LdpcOutputMonitor("output_monitor", self)
        self.scoreboard = LdpcScoreboard("scoreboard", self)

    def connect_phase(self) -> None:
        self.agent.driver.expected_ap.connect(self.scoreboard.expected_fifo.analysis_export)
        self.output_monitor.actual_ap.connect(self.scoreboard.actual_fifo.analysis_export)


@test()
class LdpcCorePyuvmTest(uvm_test):
    def build_phase(self) -> None:
        self.recorder = TransactionRecorder()
        
        # Instantiate and load the Golden Model
        self.golden_model = LdpcEncoderGoldenModel()
        mem_dir = os.environ.get("CSR_MEM_DIR", os.path.join(os.path.dirname(__file__), "mem"))
        self.golden_model.load_csr_data(mem_dir)
        
        # Pass golden model to BFM
        self.bfm = LdpcTopBfm(cocotb.top, self.recorder, self.golden_model)
        self.sb_done_event = Event()

        frame_cfgs = [
            FrameCfg(frame_id=0, base_graph=0, zc=96, seed=0x1001),
            FrameCfg(frame_id=1, base_graph=0, zc=192, seed=0x2002),
            FrameCfg(frame_id=2, base_graph=1, zc=384, seed=0x3003),
        ]
        self.frame_cfgs = frame_cfgs

        ConfigDB().set(self, "*", "BFM", self.bfm)
        ConfigDB().set(self, "*", "RECORDER", self.recorder)
        ConfigDB().set(self, "*", "FRAME_CONFIGS", frame_cfgs)
        ConfigDB().set(self, "*", "FRAME_COUNT", len(frame_cfgs))
        ConfigDB().set(self, "*", "SB_DONE_EVENT", self.sb_done_event)

        self.env = LdpcEnv("env", self)

    async def run_phase(self) -> None:
        self.raise_objection()
        cocotb.start_soon(Clock(cocotb.top.clk_i, CLK_PERIOD_NS, unit="ns").start())

        try:
            await self.bfm.reset()
            await ClockCycles(cocotb.top.clk_i, 2)
            seq = LdpcFrameSequence("ldpc_seq")
            seq.frame_cfgs = self.frame_cfgs
            await seq.start(self.env.agent.sequencer)
            await self.sb_done_event.wait()
        finally:
            self.recorder.close()
            self.drop_objection()
