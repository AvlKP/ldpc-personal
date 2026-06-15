from typing import Any
from cocotb.triggers import Event
from pyuvm import uvm_scoreboard, uvm_analysis_port, uvm_component, uvm_tlm_analysis_fifo, ConfigDB
from bfm import bits_to_int_lsb, int_to_bits_lsb, TransactionRecorder

class LdpcInternalScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.input_fifo = uvm_tlm_analysis_fifo("input_fifo", self)
        self.shifter_fifo = uvm_tlm_analysis_fifo("shifter_fifo", self)
        self.gf2_fifo = uvm_tlm_analysis_fifo("gf2_fifo", self)
        self.lambda_fifo = uvm_tlm_analysis_fifo("lambda_fifo", self)
        self.parity_fifo = uvm_tlm_analysis_fifo("parity_fifo", self)
        self.golden_model = ConfigDB().get(self, "", "GOLDEN_MODEL")

    async def run_phase(self):
        import cocotb
        cocotb.start_soon(self.process_input())
        cocotb.start_soon(self.process_shifter())
        cocotb.start_soon(self.process_gf2())
        cocotb.start_soon(self.process_lambda())
        cocotb.start_soon(self.process_parity())

    async def process_input(self):
        while True:
            tr = await self.input_fifo.get()
            self.check_input(tr)

    async def process_shifter(self):
        while True:
            tr = await self.shifter_fifo.get()
            self.check_shifter(tr)

    async def process_gf2(self):
        while True:
            tr = await self.gf2_fifo.get()
            self.check_gf2(tr)

    async def process_lambda(self):
        while True:
            tr = await self.lambda_fifo.get()
            self.check_lambda(tr)

    async def process_parity(self):
        while True:
            tr = await self.parity_fifo.get()
            self.check_parity(tr)

    def _frame_hooks(self, tr):
        """Return the golden hooks snapshot for THIS transaction's RTL frame.

        Each monitor tags transactions with the RTL frame index (counted from
        idle_o). The golden model keeps a per-frame snapshot list, so we never
        compare against a different frame's data even though the live
        golden_model.hooks is overwritten by later, already-encoded frames.
        """
        gm = self.golden_model
        if gm is None:
            return None
        fid = tr.get('frame_id', -1)
        if fid < 0 or fid >= len(gm.frame_hooks):
            return None
        return gm.frame_hooks[fid]

    def check_input(self, tr):
        hooks = self._frame_hooks(tr)
        if hooks is None or tr['kb_idx'] >= len(hooks.get('i_groups', [])):
            return
        expected_bits = hooks['i_groups'][tr['kb_idx']]
        expected_int = bits_to_int_lsb(expected_bits)

        import cocotb.utils
        sim_time = cocotb.utils.get_sim_time('ns')
        if tr['data'] != expected_int:
            self.logger.error(f"[{sim_time} ns] INPUT MISMATCH at KB={tr['kb_idx']}. RTL: {hex(tr['data'])}, GM: {hex(expected_int)}")
        else:
            self.logger.info(f"[{sim_time} ns] INPUT KB={tr['kb_idx']}. RTL: {hex(tr['data'])}, GM: {hex(expected_int)}")

    def _build_e_col_deques(self, hooks_dict, hook_key):
        """Build per-row ordered deques of E-column (col >= kb) hooks for one
        frame's hooks snapshot. The golden model and RTL iterate CSR entries in
        the same order, so popping these matches E-column events 1:1.
        """
        from collections import deque
        # kb = number of information groups; E columns have col >= kb
        kb = len(hooks_dict.get('i_groups', []))
        hooks = hooks_dict.get(hook_key, [])
        deques = {}
        for hook in hooks:
            if hook['col'] >= kb:
                row = hook['row']
                if row not in deques:
                    deques[row] = deque()
                deques[row].append(hook)
        return deques

    def check_shifter(self, tr):
        # Position-aware shifter check. A CSR entry holds 4 base-graph-row
        # POSITIONS; each output cycle processes a subset of them, folded onto
        # the four physical 96b lanes:
        #   SMALL  (Z<=96)    : positions 0..3 <-> lanes 0..3, one cycle
        #   MEDIUM (Z<=192)   : positions {mb, mb+1}, mb=2*(d_cycle-1), on
        #                       lane pairs {0,1} / {2,3}
        #   LARGE  (Z>192)    : position d_cycle on lanes {0,1,2,3}
        # Position p carries its own row (rows[p]), absolute column
        # (col_idx[p]) and normalized shift (p_norm[p]). The GM hook is the
        # unique base-graph entry at (row, col), so every check is a direct
        # idempotent lookup -- no ordering assumptions, no E-column deques.
        import cocotb.utils
        hooks = self._frame_hooks(tr)
        if hooks is None:
            return
        t = cocotb.utils.get_sim_time('ns')

        # (row, col) -> hook map, rebuilt when the RTL frame changes.
        fid = tr.get('frame_id', -1)
        if getattr(self, '_sv_frame', None) != fid:
            self._sv_frame = fid
            self._sv_by_rowcol = {(h['row'], h['col']): h
                                  for h in hooks.get('shifted_vectors', [])}

        Z = len(hooks['i_groups'][0]) if hooks.get('i_groups') else 96
        lanes_per_row = max(1, (Z + 95) // 96)
        d_cycle = tr.get('d_cycle', 0)
        if lanes_per_row == 1:
            pos_lanes = {p: (p,) for p in range(4)}
        elif lanes_per_row == 2:
            mb = 2 * (d_cycle - 1)
            if mb < 0:
                return
            pos_lanes = {mb: (0, 1), mb + 1: (2, 3)}
        else:
            pos_lanes = {d_cycle: (0, 1, 2, 3)}

        en_pos = tr.get('en_pos', 0xF)
        pc_sel = tr.get('pc_sel', [0, 0, 0, 0])
        col_idx = tr.get('col_idx', [tr['col']] * 4)
        mask96 = (1 << 96) - 1
        maskZ = (1 << Z) - 1
        out_lanes = [(tr['out'] >> (i * 96)) & mask96 for i in range(4)]
        in_lanes = [(tr['in'] >> (i * 96)) & mask96 for i in range(4)]

        for p, lanes in pos_lanes.items():
            if not ((en_pos >> p) & 1):
                continue
            row = tr['rows'][p]
            pcol = col_idx[p]
            shift = (tr['shift'] >> (p * 9)) & 0x1FF
            kind = "SHIFT(E)" if pc_sel[p] else "SHIFT"
            hook = self._sv_by_rowcol.get((row, pcol))
            if hook is None:
                self.logger.error(f"[{t} ns] {kind} NO GM HOOK at Row {row}, Col {pcol} (col_curr {tr['col']})")
                continue
            if shift != hook['shift']:
                self.logger.error(f"[{t} ns] {kind} VAL MISMATCH at Row {row}, Col {pcol}: RTL {shift}, GM {hook['shift']}")
            else:
                self.logger.info(f"[{t} ns] {kind} VAL at Row {row}, Col {pcol}: RTL {shift}, GM {hook['shift']}")
            # Reassemble this position's fold-group (concat layout: lane k of
            # the group holds bits [96k +: 96] of the Z-bit vector).
            rv = 0
            riv = 0
            for k, l in enumerate(lanes):
                rv |= out_lanes[l] << (k * 96)
                riv |= in_lanes[l] << (k * 96)
            rv &= maskZ
            riv &= maskZ
            gm_in = bits_to_int_lsb(hook['in_vec'])
            gm_vec = bits_to_int_lsb(hook['vec'])
            if riv == gm_in:
                self.logger.info(f"[{t} ns] {kind} UNSHIFTED at Row {row}, Col {pcol}: RTL {hex(riv)}, GM {hex(gm_in)}")
            else:
                self.logger.error(f"[{t} ns] {kind} UNSHIFTED MISMATCH at Row {row}, Col {pcol}: RTL {hex(riv)}, GM {hex(gm_in)}")
            if rv == gm_vec:
                self.logger.info(f"[{t} ns] {kind} VEC at Row {row}, Col {pcol}: RTL {hex(rv)}, GM {hex(gm_vec)}")
            else:
                self.logger.error(f"[{t} ns] {kind} VEC MISMATCH at Row {row}, Col {pcol}: shift={shift}, RTL {hex(rv)}, GM {hex(gm_vec)}")

    def check_gf2(self, tr):
        # Disabled as requested by user - comparison is currently incorrect
        return

        import cocotb.utils

        col = tr['col']
        sum_packed = tr['sum']
        pc_sel = tr.get('pc_sel', [0, 0, 0, 0])

        # Lazily build E-column hook deques for gf2_sums
        if not hasattr(self, '_gf2_e_deques') or self._gf2_e_hooks_id != id(gm.hooks.get('gf2_sums', [])):
            gs_hooks = gm.hooks.get('gf2_sums', [])
            self._gf2_e_hooks_id = id(gs_hooks)
            self._gf2_e_deques = self._build_e_col_deques('gf2_sums')

        for i in range(4):
            row = tr['rows'][i]
            actual_sum = (sum_packed >> (i * 96)) & ((1 << 96) - 1)

            if pc_sel[i] == 1:
                # E column lane: pop next E-column hook for this row
                expected_sum_bits = None
                e_col = None
                row_deque = self._gf2_e_deques.get(row)
                if row_deque:
                    hook = row_deque.popleft()
                    expected_sum_bits = hook['sum']
                    e_col = hook['col']

                if expected_sum_bits is not None and len(expected_sum_bits) <= 96:
                    expected_sum = bits_to_int_lsb(expected_sum_bits)
                    if actual_sum != expected_sum:
                        sim_time = cocotb.utils.get_sim_time('ns')
                        self.logger.error(
                            f"[{sim_time} ns] GF2(E) MISMATCH at Row {row}, Col {e_col} (pc_sel).\n"
                            f"  RTL gf2_acc[{i}]: {hex(actual_sum)}\n"
                            f"  GM  gf2_acc:      {hex(expected_sum)}")
                    else:
                        self.logger.debug(
                            f"GF2(E) OK at Row {row}, Col {e_col} (pc_sel):\n"
                            f"  RTL gf2_acc[{i}]: {hex(actual_sum)}\n"
                            f"  GM  gf2_acc:      {hex(expected_sum)}")
                else:
                    self.logger.debug(
                        f"GF2(E) RTL-ONLY at Row {row}, lane {i} (pc_sel, no GM hook):\n"
                        f"  RTL gf2_acc[{i}]: {hex(actual_sum)}")
            else:
                # D column lane: match by (row, col) as before
                expected_sum_bits = None
                for hook in gm.hooks.get('gf2_sums', []):
                    if hook['row'] == row and hook['col'] == col:
                        expected_sum_bits = hook['sum']
                        break

                if expected_sum_bits is not None and len(expected_sum_bits) <= 96:
                    expected_sum = bits_to_int_lsb(expected_sum_bits)
                    if actual_sum != expected_sum:
                        sim_time = cocotb.utils.get_sim_time('ns')
                        self.logger.error(
                            f"[{sim_time} ns] GF2 MISMATCH at Row {row}, Col {col}.\n"
                            f"  RTL gf2_acc[{i}]: {hex(actual_sum)}\n"
                            f"  GM  gf2_acc:      {hex(expected_sum)}")
                    else:
                        self.logger.debug(
                            f"GF2 OK at Row {row}, Col {col}:\n"
                            f"  RTL gf2_acc[{i}]: {hex(actual_sum)}\n"
                            f"  GM  gf2_acc:      {hex(expected_sum)}")

    def check_lambda(self, tr):
        hooks = self._frame_hooks(tr)
        if hooks is None:
            return
        expected_lambdas = hooks.get('lambdas', [])
        if not expected_lambdas:
            return
        
        for i in range(4):
            Z = len(expected_lambdas[i])
            expected_int = bits_to_int_lsb(expected_lambdas[i])
            actual_int = tr['lambdas'][i] & ((1 << Z) - 1)
            if actual_int != expected_int:
                import cocotb.utils
                sim_time = cocotb.utils.get_sim_time('ns')
                self.logger.error(f"[{sim_time} ns] LAMBDA MISMATCH at Row {i}. RTL: {hex(actual_int)}, GM: {hex(expected_int)}")
            else:
                self.logger.debug(f"LAMBDA OK at Row {i}: {hex(actual_int)}")

    def check_parity(self, tr):
        # Compares the parity the core produces (at the codeword_generator
        # boundary) against the golden model's p_groups, per row, in the same
        # RTL/GM style as the lambda check. p_groups[0..3] are core parity
        # (p_c1..p_c4); p_groups[4..] are additional parity.
        import cocotb.utils
        hooks = self._frame_hooks(tr)
        if hooks is None:
            return
        pg = hooks.get('p_groups', [])
        if not pg:
            return
        Z = len(pg[0])
        t = cocotb.utils.get_sim_time('ns')

        if tr['type'] == 'parity_core':
            # parity_core lane -> p_groups index (core_parity_bit_calculator):
            #   lane3=p_c1->pg0, lane0=p_c2->pg1, lane1=p_c3->pg2, lane2=p_c4->pg3
            # Each lane is a full Z-bit value LSB-packed in 384b.
            for lane, pgi in ((3, 0), (0, 1), (1, 2), (2, 3)):
                rtl = tr['lanes'][lane] & ((1 << Z) - 1)
                exp = bits_to_int_lsb(pg[pgi])
                if rtl != exp:
                    self.logger.error(f"[{t} ns] CORE PARITY MISMATCH at Row {pgi}. RTL: {hex(rtl)}, GM: {hex(exp)}")
                else:
                    self.logger.debug(f"CORE PARITY OK at Row {pgi}: {hex(rtl)}")

        elif tr['type'] == 'parity_add':
            lanes = tr['lanes']
            rows = tr['rows']
            mdc = tr.get('d_cycle', 0)
            mask = (1 << Z) - 1
            # Reconstruct each logical row by concatenating its 96b sub-lanes
            # (LSB-packed, same convention as merge_sel_lambda / the output
            # banks), keyed by the ACTIVE actual_row for this merge_d_cycle step
            # (same lane->row mapping as the gf2_en remap in the core):
            #   SMALL : 4 rows, lane k -> actual_row[k]
            #   MEDIUM: 2 rows, lanes {0,1}->actual_row[2*(d_cycle-1)],
            #                   lanes {2,3}->actual_row[2*(d_cycle-1)+1]
            #   LARGE : 1 row,  all lanes -> actual_row[merge_d_cycle]
            if Z <= 96:
                # Each sub-lane is LSB-packed in 96b ([Z-1:0]); mask bottom Z.
                cand = [(rows[k], lanes[k] & mask) for k in range(4)]
            elif Z <= 192:
                base = 2 * (mdc - 1)
                cand = [(rows[base],     (lanes[0] | (lanes[1] << 96)) & mask),
                        (rows[base + 1], (lanes[2] | (lanes[3] << 96)) & mask)]
            else:
                val = lanes[0] | (lanes[1] << 96) | (lanes[2] << 192) | (lanes[3] << 288)
                cand = [(rows[mdc], val & mask)]

            seen = set()
            for row, rtl in cand:
                # rows 0-3 are core parity; the last row-group duplicates rows
                # to pad to 4, so skip out-of-range and already-seen indices.
                if row < 4 or row >= len(pg) or row in seen:
                    continue
                seen.add(row)
                exp = bits_to_int_lsb(pg[row])
                if rtl != exp:
                    self.logger.error(f"[{t} ns] ADD PARITY MISMATCH at Row {row}. RTL: {hex(rtl)}, GM: {hex(exp)}")
                else:
                    self.logger.debug(f"ADD PARITY OK at Row {row}: {hex(rtl)}")


class LdpcScoreboard(uvm_scoreboard):
    def build_phase(self) -> None:
        self.expected_fifo = uvm_tlm_analysis_fifo("expected_fifo", self)
        self.actual_fifo = uvm_tlm_analysis_fifo("actual_fifo", self)
        self.frame_count: int = ConfigDB().get(self, "", "FRAME_COUNT")
        self.done_event: Event = ConfigDB().get(self, "", "SB_DONE_EVENT")
        self.recorder: TransactionRecorder = ConfigDB().get(self, "", "RECORDER")

    @staticmethod
    def rows_per_pa_event(zc: int) -> int:
        """Base-graph rows completed per additional-parity hand-off pulse."""
        if zc > 192:
            return 1
        if zc > 96:
            return 2
        return 4

    @staticmethod
    def expected_ram_rows(exp_bits: list[int], zc: int, kb: int, nb: int):
        """Expected codeword RAM image: {bank row: (value, used-bit mask)}.

        Mirrors the codeword_generator layout / output_buffer address
        generator: pf = 4/2/1 columns per 384b bank row; info rows from 0,
        core parity from cp_base = ceil(KB/pf), additional parity from
        ap_base = cp_base + 4/pf. Boundary padding sub-banks (and bits above
        Zc inside a slot) are excluded via the mask -- they are never written
        nor read.
        """
        pf = 4 if zc <= 96 else (2 if zc <= 192 else 1)
        slot_bits = 384 // pf
        cp_base = (kb + pf - 1) // pf
        ap_base = cp_base + 4 // pf
        rows: dict[int, int] = {}
        masks: dict[int, int] = {}
        col_mask = (1 << zc) - 1
        for c in range(nb):
            if c < kb:
                addr, slot = c // pf, c % pf
            elif c < kb + 4:
                rel = c - kb
                addr, slot = cp_base + rel // pf, rel % pf
            else:
                rel = c - kb - 4
                addr, slot = ap_base + rel // pf, rel % pf
            val = bits_to_int_lsb(exp_bits[c * zc:(c + 1) * zc])
            rows[addr] = rows.get(addr, 0) | (val << (slot * slot_bits))
            masks[addr] = masks.get(addr, 0) | (col_mask << (slot * slot_bits))
        return rows, masks

    async def run_phase(self) -> None:
        for _ in range(self.frame_count):
            expected = await self.expected_fifo.get()
            actual = await self.actual_fifo.get()
            self.compare(expected, actual)
        self.done_event.set()

    def compare(self, expected: dict[str, Any], actual: dict[str, Any]) -> None:
        frame_id = expected["frame_id"]
        has_error = False
        
        if frame_id != actual["frame_id"]:
            self.logger.error(f"Frame ordering mismatch. expected={frame_id} actual={actual['frame_id']}")
            has_error = True
            return

        # 1. Output bit comparison
        exp_bits = expected["expected_bits"]
        act_bits = actual["actual_bits"]
        act_words = actual.get("actual_words", [])
        
        if len(exp_bits) != len(act_bits):
            self.logger.error(f"Frame {frame_id} bit length mismatch. exp={len(exp_bits)} act={len(act_bits)}")
            has_error = True
        else:
            mismatch = next((idx for idx, (exp, act) in enumerate(zip(exp_bits, act_bits)) if exp != act), -1)
            if mismatch >= 0:
                word_idx = mismatch // 32
                time_ns = act_words[word_idx]["time_ns"] if word_idx < len(act_words) else "UNKNOWN"
                lo = word_idx * 32
                hi = min(len(exp_bits), (word_idx + 1) * 32)
                exp_hex = hex(bits_to_int_lsb(exp_bits[lo:hi]))
                act_hex = hex(bits_to_int_lsb(act_bits[lo:hi]))
                self.logger.error(f"[{time_ns} ns] Frame {frame_id} mismatch at bit {mismatch} (word {word_idx}).\nExp window: {exp_bits[lo:hi]} (hex: {exp_hex})\nAct window: {act_bits[lo:hi]} (hex: {act_hex})")
                has_error = True

        # 2. Parity hand-off comparison (row-keyed: the CSR row schedule
        #    completes rows out of order, so there is no linear stream)
        zc = expected["zc"]
        kb = expected["input_bits"] // zc
        nb = expected["output_bits"] // zc
        mb = nb - kb
        p_groups = expected["hooks"]["p_groups"]
        rtl_rows = actual.get("actual_parity_rows", {})
        for row_idx, grp in enumerate(p_groups):
            exp_val = bits_to_int_lsb(grp)
            if row_idx not in rtl_rows:
                self.logger.error(f"Frame {frame_id} parity row {row_idx} never handed to codeword_generator")
                has_error = True
            elif rtl_rows[row_idx] != exp_val:
                self.logger.error(f"Frame {frame_id} parity row {row_idx} mismatch at hand-off.\nRTL:    {hex(rtl_rows[row_idx])}\nGolden: {hex(exp_val)}")
                has_error = True

        if actual["parity_core_events"] != 1:
            self.logger.error(f"Frame {frame_id} expected 1 core-parity hand-off, saw {actual['parity_core_events']}")
            has_error = True
        exp_pa_events = -(-(mb - 4) // self.rows_per_pa_event(zc))
        if actual["parity_additional_events"] != exp_pa_events:
            self.logger.error(f"Frame {frame_id} additional-parity hand-off count mismatch exp={exp_pa_events} act={actual['parity_additional_events']}")
            has_error = True

        # 3. Codeword RAM image (rows as fetched back by the output buffer),
        #    masked to the sub-bank slots the layout actually uses
        exp_rows, exp_masks = self.expected_ram_rows(exp_bits, zc, kb, nb)
        ram_rows = actual.get("actual_ram_rows", [])
        if len(ram_rows) != len(exp_rows):
            self.logger.error(f"Codeword RAM row count mismatch frame={frame_id} exp={len(exp_rows)} act={len(ram_rows)}")
            has_error = True
        for rec in ram_rows:
            addr = rec["addr"]
            if addr not in exp_rows:
                self.logger.error(f"[{rec.get('time_ns', 'UNKNOWN')} ns] Output buffer fetched unexpected codeword RAM row frame={frame_id} addr={addr}")
                has_error = True
                continue
            got = rec["data"] & exp_masks[addr]
            if got != exp_rows[addr]:
                self.logger.error(f"[{rec.get('time_ns', 'UNKNOWN')} ns] Codeword RAM row mismatch frame={frame_id} addr={addr}\nRTL:    {hex(got)}\nGolden: {hex(exp_rows[addr])}")
                has_error = True
        missing = sorted(set(exp_rows) - {rec["addr"] for rec in ram_rows})
        if missing:
            self.logger.error(f"Codeword RAM rows never fetched frame={frame_id} addrs={missing}")
            has_error = True

        # 4. TLAST check
        if actual.get("tlast_on_last_word", 0) != 1:
            self.logger.error(f"TLAST missing on final output word frame={frame_id} word={actual['accepted_words']-1}")
            has_error = True

        self.recorder.record_frame(
            {
                "frame_id": frame_id,
                "base_graph": expected["base_graph"],
                "zc": expected["zc"],
                "input_bits": expected["input_bits"],
                "output_bits": expected["output_bits"],
                "accepted_words": actual["accepted_words"],
                "parity_core_events": actual["parity_core_events"],
                "parity_additional_events": actual["parity_additional_events"],
                "status": "FAIL" if has_error else "PASS", 
            }
        )
