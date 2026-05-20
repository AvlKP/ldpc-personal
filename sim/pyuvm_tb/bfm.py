import json
import os
import random
from pathlib import Path
from typing import Any
import cocotb
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, Event, First, RisingEdge
import numpy as np

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
    def __init__(self, dut, recorder: TransactionRecorder, golden_model):
        self.dut = dut
        self.recorder = recorder
        self.golden_model = golden_model
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

    async def configure_frame(self, item) -> None:
        config_word = (item.base_graph & 0x1) | ((item.zc & 0x1FF) << 1)
        await self.axil_write(CFG_ADDR, config_word)
        await self.axil_write(IN_BITS_ADDR, item.input_bits & 0xFFFF)
        await self.axil_write(OUT_BITS_ADDR, item.output_bits & 0xFFFF)

    async def send_axis_payload(self, item) -> None:
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

    async def send_frame(self, item) -> dict[str, Any]:
        bg_idx = 1 if item.base_graph == 0 else 2
        parity_bits = self.golden_model.encode(item.info_bits, item.zc, bg_idx=bg_idx, version='3gpp')
        hooks = self.golden_model.hooks
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
            "hooks": hooks,
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
            "hooks": hooks,
            "total_words": frame_ctx["total_words"],
        }
