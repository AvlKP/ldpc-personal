import random
import cocotb.utils
from enum import IntEnum, auto
from typing import Any
from collections import deque
from cocotb.triggers import RisingEdge, ReadOnly
from pyuvm import uvm_monitor, uvm_analysis_port, ConfigDB, uvm_component
from bfm import safe_int, int_to_bits_lsb, bits_to_int_lsb, LdpcTopBfm, TransactionRecorder

OUTBUFF_WRITE_BITS = 384


class CoreState(IntEnum):
    """Mirror of the state_t enum in rtl/ldpc_encoder_core.sv.

    SystemVerilog and Python IntEnum both number members 0, 1, 2, ... in
    declaration order, so KEEP THIS LIST IN THE SAME ORDER AS THE RTL ENUM.
    IDLE is pinned to 0 to match the RTL's default encoding; the trailing
    auto() members continue 1, 2, 3, ... When the RTL FSM gains/loses/reorders
    a state, mirror it here once and every monitor that compares core.state_q
    stays correct (instead of scattering magic numbers).
    """
    IDLE = 0
    LOAD = auto()         # 1
    CALC_LAMBDA = auto()  # 2
    CALC_PC = auto()      # 3
    CALC_PA = auto()      # 4

class LdpcInputBufferMonitor(uvm_monitor):
    """Monitors the aligned input segments being fed into the core."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.bfm = ConfigDB().get(self, "", "BFM")

    async def run_phase(self):
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core
        pending_kb_idx = None
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            
            # Data from previous cycle's address selection is now valid on info_group_i
            if pending_kb_idx is not None:
                data_in = safe_int(core.info_group_i)
                self.ap.write({'type': 'input', 'kb_idx': pending_kb_idx, 'data': data_in})
                pending_kb_idx = None

            if safe_int(core.state_q) == CoreState.CALC_LAMBDA and safe_int(core.inbuff_valid_i) == 1 and safe_int(core.inbuff_clear_o) == 0:
                pending_kb_idx = safe_int(core.info_group_sel_o)

class LdpcShifterMonitor(uvm_monitor):
    """Monitors data entering and exiting the cyclic shifter."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.bfm = ConfigDB().get(self, "", "BFM")

    async def run_phase(self):
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core
        metadata_queue = deque()
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            
            # Latch metadata when CSR valid is high (start of pipeline)
            if safe_int(core.csr_valid_q) == 1:
                col = safe_int(core.col_curr_q)
                act_rows = safe_int(core.actual_row_q)
                metadata_queue.append({
                    'col': col,
                    'rows': [(act_rows >> (i * 6)) & 0x3F for i in range(4)]
                })

            # Consume metadata when CSR valid delayed is high (end of pipeline)
            if safe_int(core.csr_valid_qdly) == 1:
                meta = metadata_queue.popleft()
                cs_in = safe_int(core.cs_data_in)
                cs_out = safe_int(core.cs_data_out)
                shift_val = safe_int(core.top_level_shifter.param_calc_inst.p_norm)
                self.ap.write({
                    'type': 'shifter', 
                    'in': cs_in, 
                    'out': cs_out, 
                    'shift': shift_val, 
                    'col': meta['col'], 
                    'rows': meta['rows']
                })

class LdpcGf2Monitor(uvm_monitor):
    """Monitors the accumulated GF(2) sums."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.bfm = ConfigDB().get(self, "", "BFM")

    async def run_phase(self):
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core
        metadata_queue = deque()
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            
            # Latch metadata when GF2 enable is high
            if safe_int(core.gf2_en_q) == 1:
                col = safe_int(core.col_curr_q)
                act_rows = safe_int(core.actual_row_q)
                metadata_queue.append({
                    'col': col,
                    'rows': [(act_rows >> (i * 6)) & 0x3F for i in range(4)]
                })

            # Consume metadata when GF2 enable delayed is high
            if safe_int(core.gf2_en_qdly) == 1:
                meta = metadata_queue.popleft()
                row_sum = safe_int(core.row_sum)
                self.ap.write({
                    'type': 'gf2_sum', 
                    'sum': row_sum, 
                    'col': meta['col'], 
                    'rows': meta['rows']
                })

class LdpcLambdaMonitor(uvm_monitor):
    """Monitors the finalized lambda calculation before core parity generation."""
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.bfm = ConfigDB().get(self, "", "BFM")

    async def run_phase(self):
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core

        # Lambda is produced incrementally across the CALC_LAMBDA state, one
        # row-group per merge_d_cycle step (e.g. ZC_MEDIUM yields rows 3,2 at
        # d_cycle=2, then 1,0 at d_cycle=1; ZC_LARGE yields one row per cycle).
        # Sampling only at the end of CALC_LAMBDA misses the earlier groups, so
        # instead capture each row the moment the RTL latches it into the core
        # parity calc: cpb_en pulses with exactly the lanes being completed, and
        # lane L always carries absolute row L. We assemble the 4 rows in their
        # absolute-row slots and emit one transaction per frame when the lambda
        # phase ends.
        lambda_acc = [0, 0, 0, 0]
        captured = False
        prev_in_lambda = False
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            in_lambda = safe_int(core.state_q) == CoreState.CALC_LAMBDA

            # Fresh frame: clear the accumulator on entry to CALC_LAMBDA.
            if in_lambda and not prev_in_lambda:
                lambda_acc = [0, 0, 0, 0]
                captured = False

            # cpb_en[L] high => lambda lane L holds the just-finished row L.
            cpb_en = safe_int(core.cpb_en)
            if in_lambda and cpb_en != 0:
                lam_val = safe_int(getattr(core, "lambda"))
                for L in range(4):
                    if (cpb_en >> L) & 1:
                        lambda_acc[L] = (lam_val >> (L * 384)) & ((1 << 384) - 1)
                        captured = True

            # Leaving CALC_LAMBDA: all groups have been latched; emit the set.
            if prev_in_lambda and not in_lambda and captured:
                self.ap.write({'type': 'lambda', 'lambdas': list(lambda_acc)})
                captured = False

            prev_in_lambda = in_lambda

class LdpcOutputMonitor(uvm_monitor):
    def build_phase(self) -> None:
        self.bfm: LdpcTopBfm = ConfigDB().get(self, "", "BFM")
        self.recorder: TransactionRecorder = ConfigDB().get(self, "", "RECORDER")
        self.actual_ap = uvm_analysis_port("actual_ap", self)

    async def capture_frame(self, ctx: dict[str, Any]) -> dict[str, Any]:
        dut = self.bfm.dut
        core = getattr(dut, "ldpc_encoder_core", None)
        cwgen = getattr(core, "codeword_generator", None) if core is not None else None

        rng = random.Random(ctx["seed"] ^ 0x5A5A)
        captured_bits: list[int] = []
        actual_words = []
        accepted_words = 0
        total_words = ctx["total_words"]
        timeout_cycles = max(30000, total_words * 128)
        
        actual_parity_chunks = []
        actual_internal_writes = []

        parity_core_events = 0
        parity_additional_events = 0
        tlast = 0

        for cycle in range(timeout_cycles):
            ready = 1 if rng.random() >= 0.30 else 0
            dut.m_axis_tready.value = ready
            await RisingEdge(dut.clk_i)

            if cwgen is not None:
                parity_core_valid = safe_int(getattr(cwgen, "parity_core_valid_i", None), 0)
                parity_additional_valid = safe_int(getattr(cwgen, "parity_additional_valid_i", None), 0)
                ext_valid = safe_int(getattr(cwgen, "ext_valid", None), 0)
                outbuff_full_i = safe_int(getattr(cwgen, "outbuff_full_i", None), 0)
                
                if ext_valid == 1 and outbuff_full_i == 0 and (parity_core_valid == 1 or parity_additional_valid == 1):
                    ext_len = safe_int(getattr(cwgen, "ext_len", None), 0)
                    ext_data = safe_int(getattr(cwgen, "ext_data", None), 0)
                    
                    if parity_core_valid == 1:
                        parity_core_events += 1
                    if parity_additional_valid == 1:
                        parity_additional_events += 1

                    actual_parity_chunks.append({
                        "len": ext_len,
                        "data": ext_data,
                        "src": "core" if parity_core_valid == 1 else "additional",
                        "cycle": cycle,
                        "time_ns": cocotb.utils.get_sim_time('ns')
                    })

            outbuff_wr_en = safe_int(getattr(dut, "outbuff_wr_en", None), 0)
            if outbuff_wr_en == 1:
                raw_wr = safe_int(getattr(dut, "outbuff_data", None), 0)
                actual_internal_writes.append({
                    "data": raw_wr & ((1 << OUTBUFF_WRITE_BITS) - 1),
                    "cycle": cycle,
                    "time_ns": cocotb.utils.get_sim_time('ns')
                })

            tvalid = safe_int(dut.m_axis_tvalid, 0)
            if tvalid == 1 and ready == 1:
                tlast = safe_int(dut.m_axis_tlast, 0)
                raw = safe_int(dut.m_axis_tdata, 0)
                accepted_words += 1
                
                actual_words.append({
                    "data": raw,
                    "time_ns": cocotb.utils.get_sim_time('ns')
                })
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

                if accepted_words == total_words:
                    break

        dut.m_axis_tready.value = 0

        return {
            "frame_id": ctx["frame_id"],
            "actual_bits": captured_bits[: ctx["output_bits"]],
            "actual_words": actual_words,
            "accepted_words": accepted_words,
            "parity_core_events": parity_core_events,
            "parity_additional_events": parity_additional_events,
            "actual_parity_chunks": actual_parity_chunks,
            "actual_internal_writes": actual_internal_writes,
            "tlast_on_last_word": tlast
        }

    async def run_phase(self) -> None:
        while True:
            ctx = await self.bfm.capture_queue.get()
            actual = await self.capture_frame(ctx)
            self.actual_ap.write(actual)
            done_evt = self.bfm.frame_done_events.get(ctx["frame_id"])
            if done_evt is not None:
                done_evt.set()
