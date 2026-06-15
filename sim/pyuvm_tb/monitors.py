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
        frame_id = -1
        prev_idle = 1
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            # Count RTL frames: each starts when the core leaves IDLE.
            idle = safe_int(core.idle_o)
            if prev_idle and not idle:
                frame_id += 1
            prev_idle = idle

            # Data from previous cycle's address selection is now valid on info_group_i
            if pending_kb_idx is not None:
                data_in = safe_int(core.info_group_i)
                self.ap.write({'type': 'input', 'kb_idx': pending_kb_idx, 'data': data_in, 'frame_id': frame_id})
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
        frame_id = -1
        prev_idle = 1
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            idle = safe_int(core.idle_o)
            if prev_idle and not idle:
                frame_id += 1
            prev_idle = idle

            # Latch metadata when CSR valid is high (start of pipeline)
            if safe_int(core.csr_valid_q) == 1:
                col = safe_int(core.col_curr_q)
                act_rows = safe_int(core.actual_row_q)
                pc_sel = safe_int(core.cs_pc_sel_q)
                metadata_queue.append({
                    'col': col,
                    'rows': [(act_rows >> (i * 6)) & 0x3F for i in range(4)],
                    'pc_sel': [(pc_sel >> i) & 1 for i in range(4)],
                    'frame_id': frame_id
                })

            # Consume metadata when CSR valid delayed is high (end of pipeline)
            if safe_int(core.csr_valid_qdly) == 1:
                meta = metadata_queue.popleft()
                cs_in = safe_int(core.cs_data_in)
                cs_out = safe_int(core.cs_data_out)
                shift_val = safe_int(core.top_level_shifter.param_calc_inst.p_norm)
                # Position-domain context for this output cycle. A CSR entry
                # holds 4 base-graph-row POSITIONS; the folded modes process a
                # subset per cycle (merge_d_cycle says which), gf2_en_qdly is
                # the per-POSITION accumulate enable, and col_idx_qdly is each
                # position's absolute base-graph column (col_curr for D
                # entries, the E column for parity-feedback entries).
                d_cycle = safe_int(core.merge_d_cycle)
                en_pos = safe_int(core.gf2_en_qdly)
                col_idx_packed = safe_int(core.col_idx_qdly)
                self.ap.write({
                    'type': 'shifter',
                    'in': cs_in,
                    'out': cs_out,
                    'shift': shift_val,
                    'col': meta['col'],
                    'rows': meta['rows'],
                    'pc_sel': meta['pc_sel'],
                    'd_cycle': d_cycle,
                    'en_pos': en_pos,
                    'col_idx': [(col_idx_packed >> (i * 7)) & 0x7F for i in range(4)],
                    'frame_id': meta['frame_id']
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
            
            # Latch metadata when any GF2 enable lane is high (4-bit vector)
            if safe_int(core.gf2_en_q) != 0:
                col = safe_int(core.col_curr_q)
                act_rows = safe_int(core.actual_row_q)
                pc_sel = safe_int(core.cs_pc_sel_q)
                metadata_queue.append({
                    'col': col,
                    'rows': [(act_rows >> (i * 6)) & 0x3F for i in range(4)],
                    'pc_sel': [(pc_sel >> i) & 1 for i in range(4)]
                })

            # Consume metadata when any GF2 enable delayed lane is high
            if safe_int(core.gf2_en_qdly) != 0:
                meta = metadata_queue.popleft()
                row_sum = safe_int(core.row_sum)
                self.ap.write({
                    'type': 'gf2_sum', 
                    'sum': row_sum, 
                    'col': meta['col'], 
                    'rows': meta['rows'],
                    'pc_sel': meta['pc_sel']
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
        frame_id = -1
        prev_idle = 1
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            idle = safe_int(core.idle_o)
            if prev_idle and not idle:
                frame_id += 1
            prev_idle = idle
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
                self.ap.write({'type': 'lambda', 'lambdas': list(lambda_acc), 'frame_id': frame_id})
                captured = False

            prev_in_lambda = in_lambda

class LdpcParityMonitor(uvm_monitor):
    """Taps the core/additional parity the encoder hands to codeword_generator.

    Core parity (core.parity_core, 4 lanes x 384b, each a full Z-bit p_c value
    LSB-packed). core_parity_bit_calculator's output mapping is:
        lane3 -> p_c1 = p_groups[0]    lane0 -> p_c2 = p_groups[1]
        lane1 -> p_c3 = p_groups[2]    lane2 -> p_c4 = p_groups[3]
    It is stable throughout CALC_PC, so snapshot every cycle and emit on exit.

    Additional parity (core.parity_additional = row_sum, 4 sub-lanes x 96b)
    holds the rows just finished when parity_additional_valid pulses, keyed by
    core.actual_row_qdly. Captured once per rising edge of the pulse; the
    scoreboard merges sub-lanes per Z and compares each row to p_groups[row].
    """
    def build_phase(self):
        self.ap = uvm_analysis_port("ap", self)
        self.bfm = ConfigDB().get(self, "", "BFM")

    async def run_phase(self):
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core
        prev_core_valid = False
        prev_add_valid = False
        core_lanes = [0, 0, 0, 0]
        frame_id = -1
        prev_idle = 1
        while True:
            await RisingEdge(core.clk_i)
            await ReadOnly()
            idle = safe_int(core.idle_o)
            if prev_idle and not idle:
                frame_id += 1
            prev_idle = idle
            core_valid = safe_int(getattr(core, "parity_core_valid", None), 0) == 1
            add_valid = safe_int(getattr(core, "parity_additional_valid", None), 0) == 1

            # Core parity: snapshot while in CALC_PC, emit the settled set on exit.
            if core_valid:
                pc = safe_int(getattr(core, "parity_core"), 0)
                core_lanes = [(pc >> (k * 384)) & ((1 << 384) - 1) for k in range(4)]
            if prev_core_valid and not core_valid:
                self.ap.write({'type': 'parity_core', 'lanes': list(core_lanes), 'frame_id': frame_id})

            # Additional parity: capture once per pulse (the pulse can be >1 cyc).
            # merge_d_cycle selects which actual_row(s) the lanes carry this
            # sub-step (MEDIUM/LARGE process a row-group over several sub-steps).
            if add_valid and not prev_add_valid:
                pa = safe_int(getattr(core, "parity_additional"), 0)
                ar = safe_int(getattr(core, "actual_row_qdly"), 0)
                mdc = safe_int(getattr(core, "merge_d_cycle"), 0)
                lanes = [(pa >> (k * 96)) & ((1 << 96) - 1) for k in range(4)]
                rows = [(ar >> (k * 6)) & 0x3F for k in range(4)]
                self.ap.write({'type': 'parity_add', 'lanes': lanes, 'rows': rows, 'd_cycle': mdc, 'frame_id': frame_id})

            prev_core_valid = core_valid
            prev_add_valid = add_valid

class LdpcOutputMonitor(uvm_monitor):
    """Captures the AXIS output per frame, plus two white-box views collected
    by a free-running task: the parity values handed to the codeword
    generator and the codeword RAM rows the output buffer fetches back.

    The collector CANNOT live inside the per-frame AXIS capture loop: with the
    double-banked codeword RAM, frame N+1's ENTIRE encode overlaps frame N's
    readout, so events must be attributed by hardware frame counters (encode
    frames = idle_o falling edges, readout frames = codeword_done pulses),
    not by which capture window happens to observe them.
    """
    # Mirrors the output_buffer state_t encoding (declaration order)
    OB_STREAM = 3

    def build_phase(self) -> None:
        self.bfm: LdpcTopBfm = ConfigDB().get(self, "", "BFM")
        self.recorder: TransactionRecorder = ConfigDB().get(self, "", "RECORDER")
        self.actual_ap = uvm_analysis_port("actual_ap", self)
        # encode-frame keyed: base-graph row -> Zc-bit parity value
        self.parity_rows_by_frame: dict[int, dict[int, int]] = {}
        self.pc_events_by_frame: dict[int, int] = {}
        self.pa_events_by_frame: dict[int, int] = {}
        # readout-frame keyed: [{"addr", "data", "time_ns"}, ...]
        self.ram_rows_by_frame: dict[int, list] = {}
        self._seen_addrs_by_frame: dict[int, set] = {}

    async def _collect_internal(self) -> None:
        dut = self.bfm.dut
        core = dut.ldpc_encoder_core
        outbuff = dut.output_buffer

        enc_frame = -1
        rd_frame = 0
        prev_idle = 1
        prev_core_valid = False
        prev_add_valid = False
        core_lanes = [0, 0, 0, 0]
        prev_ob_state = None
        mask96 = (1 << 96) - 1

        while True:
            await RisingEdge(dut.clk_i)
            await ReadOnly()

            idle = safe_int(core.idle_o)
            if prev_idle and not idle:
                enc_frame += 1
            prev_idle = idle

            # Frame-stable config from the core's registered copies (the
            # ctx is not available here; the values pin the lane layout)
            zc = safe_int(core.lifting_size_q, 0)
            mb = 42 if safe_int(core.base_graph_q, 0) else 46
            mask_z = (1 << zc) - 1 if zc else 0

            # --- parity hand-off at the core/codeword_generator boundary ---
            core_valid = safe_int(getattr(core, "parity_core_valid", None), 0) == 1
            add_valid = safe_int(getattr(core, "parity_additional_valid", None), 0) == 1

            if core_valid:
                pc = safe_int(getattr(core, "parity_core", None), 0)
                core_lanes = [(pc >> (k * 384)) & ((1 << 384) - 1) for k in range(4)]
            if prev_core_valid and not core_valid:
                rows_acc = self.parity_rows_by_frame.setdefault(enc_frame, {})
                self.pc_events_by_frame[enc_frame] = self.pc_events_by_frame.get(enc_frame, 0) + 1
                # core_parity_bit_calculator lane map: p_c1=lane3, p_c2=lane0,
                # p_c3=lane1, p_c4=lane2 -> p_groups rows 0..3
                for lane, row in ((3, 0), (0, 1), (1, 2), (2, 3)):
                    rows_acc[row] = core_lanes[lane] & mask_z

            if add_valid and not prev_add_valid:
                rows_acc = self.parity_rows_by_frame.setdefault(enc_frame, {})
                self.pa_events_by_frame[enc_frame] = self.pa_events_by_frame.get(enc_frame, 0) + 1
                pa = safe_int(getattr(core, "parity_additional", None), 0)
                ar = safe_int(getattr(core, "actual_row_qdly", None), 0)
                mdc = safe_int(getattr(core, "merge_d_cycle", None), 0)
                lanes = [(pa >> (k * 96)) & mask96 for k in range(4)]
                rows = [(ar >> (k * 6)) & 0x3F for k in range(4)]
                # Reassemble rows by zc group, same lane->row mapping as the
                # core's gf2_en remap (see internal scoreboard check_parity)
                if zc <= 96:
                    cand = [(rows[k], lanes[k] & mask_z) for k in range(4)]
                elif zc <= 192:
                    base = 2 * (mdc - 1)
                    cand = [] if base < 0 else [
                        (rows[base], (lanes[0] | (lanes[1] << 96)) & mask_z),
                        (rows[base + 1], (lanes[2] | (lanes[3] << 96)) & mask_z),
                    ]
                else:
                    val = lanes[0] | (lanes[1] << 96) | (lanes[2] << 192) | (lanes[3] << 288)
                    cand = [(rows[mdc], val & mask_z)]
                for row, val in cand:
                    # skip the partial last group's duplicate padding labels
                    if 4 <= row < mb and row not in rows_acc:
                        rows_acc[row] = val

            prev_core_valid = core_valid
            prev_add_valid = add_valid

            # --- codeword RAM rows, sampled when the output buffer enters
            #     STREAM with a freshly fetched word ---
            ob_state = safe_int(getattr(outbuff, "state_q", None), None)
            if ob_state == self.OB_STREAM and prev_ob_state != self.OB_STREAM:
                addr = safe_int(getattr(dut, "cw_r_addr", None), 0)
                seen = self._seen_addrs_by_frame.setdefault(rd_frame, set())
                if addr not in seen:
                    seen.add(addr)
                    self.ram_rows_by_frame.setdefault(rd_frame, []).append({
                        "addr": addr,
                        "data": safe_int(getattr(dut, "cw_r_data", None), 0),
                        "time_ns": cocotb.utils.get_sim_time('ns'),
                    })
            prev_ob_state = ob_state

            # Readout-frame boundary: codeword_done is a 1-cycle pulse fired
            # after the frame's last RAM fetch, before its last AXIS beat.
            if safe_int(getattr(dut, "outbuff_done", None), 0) == 1:
                rd_frame += 1

    async def capture_frame(self, ctx: dict[str, Any]) -> dict[str, Any]:
        dut = self.bfm.dut

        rng = random.Random(ctx["seed"] ^ 0x5A5A)
        captured_bits: list[int] = []
        actual_words = []
        accepted_words = 0
        total_words = ctx["total_words"]
        timeout_cycles = max(30000, total_words * 128)
        tlast = 0

        for cycle in range(timeout_cycles):
            ready = 1 if rng.random() >= 0.30 else 0
            dut.m_axis_tready.value = ready
            await RisingEdge(dut.clk_i)

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

        # By the time the frame's last AXIS word is accepted, its encode
        # finished long ago and its codeword_done already pulsed, so the
        # collector's per-frame views are complete.
        fid = ctx["frame_id"]
        return {
            "frame_id": fid,
            "actual_bits": captured_bits[: ctx["output_bits"]],
            "actual_words": actual_words,
            "accepted_words": accepted_words,
            "parity_core_events": self.pc_events_by_frame.get(fid, 0),
            "parity_additional_events": self.pa_events_by_frame.get(fid, 0),
            "actual_parity_rows": self.parity_rows_by_frame.get(fid, {}),
            "actual_ram_rows": self.ram_rows_by_frame.get(fid, []),
            "tlast_on_last_word": tlast
        }

    async def run_phase(self) -> None:
        import cocotb
        cocotb.start_soon(self._collect_internal())
        while True:
            ctx = await self.bfm.capture_queue.get()
            actual = await self.capture_frame(ctx)
            self.actual_ap.write(actual)
            done_evt = self.bfm.frame_done_events.get(ctx["frame_id"])
            if done_evt is not None:
                done_evt.set()
