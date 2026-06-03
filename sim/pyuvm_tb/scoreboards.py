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

    def check_input(self, tr):
        gm = self.golden_model
        if gm is None or tr['kb_idx'] >= len(gm.hooks.get('i_groups', [])):
            return
        expected_bits = gm.hooks['i_groups'][tr['kb_idx']]
        expected_int = bits_to_int_lsb(expected_bits)
        
        if tr['data'] != expected_int:
            import cocotb.utils
            sim_time = cocotb.utils.get_sim_time('ns')
            self.logger.error(f"[{sim_time} ns] INPUT MISMATCH at KB={tr['kb_idx']}. RTL: {hex(tr['data'])}, GM: {hex(expected_int)}")
        else:
            self.logger.debug(f"Input KB={tr['kb_idx']} aligned correctly.")

    def check_shifter(self, tr):
        gm = self.golden_model
        if gm is None:
            return
            
        col = tr['col']
        shift_val_packed = tr['shift']
        
        for i in range(4):
            row = tr['rows'][i]
            expected_shift = None
            for hook in gm.hooks.get('shifted_vectors', []):
                if hook['row'] == row and hook['col'] == col:
                    expected_shift = hook['shift']
                    break
            
            if expected_shift is not None:
                actual_shift = (shift_val_packed >> (i * 9)) & 0x1FF
                if actual_shift != expected_shift:
                    import cocotb.utils
                    sim_time = cocotb.utils.get_sim_time('ns')
                    self.logger.error(f"[{sim_time} ns] SHIFT MISMATCH at Row {row}, Col {col}. RTL: {actual_shift}, GM: {expected_shift}")
                else:
                    self.logger.debug(f"SHIFT OK at Row {row}, Col {col}: {actual_shift}")

    def check_gf2(self, tr):
        gm = self.golden_model
        if gm is None:
            return
            
        col = tr['col']
        sum_packed = tr['sum']
        
        for i in range(4):
            row = tr['rows'][i]
            expected_sum_bits = None
            for hook in gm.hooks.get('gf2_sums', []):
                if hook['row'] == row and hook['col'] == col:
                    expected_sum_bits = hook['sum']
                    break
            
            if expected_sum_bits is not None and len(expected_sum_bits) <= 96:
                actual_sum = (sum_packed >> (i * 96)) & ((1 << 96) - 1)
                expected_sum = bits_to_int_lsb(expected_sum_bits)
                if actual_sum != expected_sum:
                    import cocotb.utils
                    sim_time = cocotb.utils.get_sim_time('ns')
                    self.logger.error(f"[{sim_time} ns] GF2 MISMATCH at Row {row}, Col {col}. RTL: {hex(actual_sum)}, GM: {hex(expected_sum)}")
                else:
                    self.logger.debug(f"GF2 OK at Row {row}, Col {col}: {hex(actual_sum)}")

    def check_lambda(self, tr):
        gm = self.golden_model
        if gm is None:
            return
        expected_lambdas = gm.hooks.get('lambdas', [])
        if not expected_lambdas:
            return
        
        for i in range(4):
            Z = len(expected_lambdas[i])
            expected_int = bits_to_int_lsb(expected_lambdas[i])
            actual_int = (tr['lambdas'][i] >> (384 - Z)) & ((1 << Z) - 1)
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
        gm = self.golden_model
        if gm is None:
            return
        pg = gm.hooks.get('p_groups', [])
        if not pg:
            return
        Z = len(pg[0])
        t = cocotb.utils.get_sim_time('ns')

        if tr['type'] == 'parity_core':
            # parity_core lane -> p_groups index (core_parity_bit_calculator):
            #   lane3=p_c1->pg0, lane0=p_c2->pg1, lane1=p_c3->pg2, lane2=p_c4->pg3
            # Each lane is a full Z-bit value MSB-packed in 384b.
            for lane, pgi in ((3, 0), (0, 1), (1, 2), (2, 3)):
                rtl = (tr['lanes'][lane] >> (384 - Z)) & ((1 << Z) - 1)
                exp = bits_to_int_lsb(pg[pgi])
                if rtl != exp:
                    self.logger.error(f"[{t} ns] CORE PARITY MISMATCH at Row {pgi}. RTL: {hex(rtl)}, GM: {hex(exp)}")
                else:
                    self.logger.debug(f"CORE PARITY OK at Row {pgi}: {hex(rtl)}")

        elif tr['type'] == 'parity_add':
            lanes = tr['lanes']
            rows = tr['rows']
            mask = (1 << Z) - 1
            # Reconstruct each logical row by concatenating its 96b sub-lanes
            # (same MSB-first convention as merge_select_lambda / the output
            # banks), keyed by actual_row: SMALL 1 sub-lane/row, MEDIUM 2, LARGE 4.
            if Z <= 96:
                pairs = [(rows[k], lanes[k] & mask) for k in range(4)]
            elif Z <= 192:
                pairs = [(rows[0], (lanes[0] | (lanes[1] << 96)) & mask),
                         (rows[1], (lanes[2] | (lanes[3] << 96)) & mask)]
            else:
                val = lanes[0] | (lanes[1] << 96) | (lanes[2] << 192) | (lanes[3] << 288)
                pairs = [(rows[0], val & mask)]

            for row, rtl in pairs:
                if row < 4 or row >= len(pg):
                    continue  # rows 0-3 are core parity; skip padding/duplicate rows
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
    def zc_group_multiplier(zc: int) -> int:
        if zc > 192:
            return 1
        if zc > 96:
            return 2
        return 4

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

        # 2. Parity chunk comparison
        p_groups = expected["hooks"]["p_groups"]
        parity_expected = []
        for g in p_groups:
            parity_expected.extend(g)
            
        parity_mult = self.zc_group_multiplier(expected["zc"])
        expected_len = expected["zc"] * parity_mult
        
        parity_cursor = 0
        actual_chunks = actual.get("actual_parity_chunks", [])
        for idx, chunk in enumerate(actual_chunks):
            if chunk["len"] != expected_len:
                self.logger.error(f"[{chunk.get('time_ns', 'UNKNOWN')} ns] Parity group length mismatch frame={frame_id} chunk={idx} exp_len={expected_len} act_len={chunk['len']}")
                has_error = True
            
            if parity_cursor + chunk["len"] > len(parity_expected):
                self.logger.error(f"[{chunk.get('time_ns', 'UNKNOWN')} ns] Parity monitor overflow frame={frame_id} cursor={parity_cursor} ext_len={chunk['len']} parity_total={len(parity_expected)}")
                has_error = True
                break
                
            observed_bits = int_to_bits_lsb(chunk["data"], chunk["len"])
            expected_chunk = parity_expected[parity_cursor : parity_cursor + chunk["len"]]
            
            if observed_bits != expected_chunk:
                mismatch = next((i for i, (exp, act) in enumerate(zip(expected_chunk, observed_bits)) if exp != act), -1)
                exp_hex = hex(bits_to_int_lsb(expected_chunk))
                act_hex = hex(bits_to_int_lsb(observed_bits))
                self.logger.error(f"[{chunk.get('time_ns', 'UNKNOWN')} ns] Parity group mismatch frame={frame_id} src={chunk['src']} bit={mismatch}\nRTL:    {observed_bits} (hex: {act_hex})\nGolden: {expected_chunk} (hex: {exp_hex})")
                has_error = True
            
            parity_cursor += chunk["len"]

        if parity_cursor != len(parity_expected):
            self.logger.error(f"Parity consumption mismatch frame={frame_id} exp={len(parity_expected)} act={parity_cursor}")
            has_error = True

        if len(parity_expected) > 0 and actual["parity_core_events"] == 0:
            self.logger.error(f"No core parity groups observed frame={frame_id}")
            has_error = True
        if len(parity_expected) > 0 and actual["parity_additional_events"] == 0:
            self.logger.error(f"No additional parity groups observed frame={frame_id}")
            has_error = True

        # 3. Output buffer write comparison
        expected_internal_writes = []
        OUTBUFF_WRITE_BITS = 384
        write_count = (expected["output_bits"] + OUTBUFF_WRITE_BITS - 1) // OUTBUFF_WRITE_BITS
        for idx in range(write_count):
            lo = idx * OUTBUFF_WRITE_BITS
            hi = min((idx + 1) * OUTBUFF_WRITE_BITS, expected["output_bits"])
            row_bits = exp_bits[lo:hi] + [0] * (OUTBUFF_WRITE_BITS - (hi - lo))
            expected_internal_writes.append(bits_to_int_lsb(row_bits))
            
        actual_writes = actual.get("actual_internal_writes", [])
        if len(actual_writes) != len(expected_internal_writes):
            self.logger.error(f"Internal output_buffer write count mismatch frame={frame_id} exp={len(expected_internal_writes)} act={len(actual_writes)}")
            has_error = True
            
        for write_idx, (obs_wr_dict, exp_wr) in enumerate(zip(actual_writes, expected_internal_writes)):
            obs_wr = obs_wr_dict["data"]
            if obs_wr != exp_wr:
                observed_bits = int_to_bits_lsb(obs_wr, OUTBUFF_WRITE_BITS)
                expected_bits_row = int_to_bits_lsb(exp_wr, OUTBUFF_WRITE_BITS)
                mismatch = next((i for i, (exp, act) in enumerate(zip(expected_bits_row, observed_bits)) if exp != act), -1)
                lo = max(0, mismatch - 16)
                hi = min(OUTBUFF_WRITE_BITS, mismatch + 17)
                exp_hex = hex(bits_to_int_lsb(expected_bits_row[lo:hi]))
                act_hex = hex(bits_to_int_lsb(observed_bits[lo:hi]))
                self.logger.error(f"[{obs_wr_dict.get('time_ns', 'UNKNOWN')} ns] Output-buffer write mismatch frame={frame_id} row={write_idx} bit={mismatch}\nExp window: {expected_bits_row[lo:hi]} (hex: {exp_hex})\nAct window: {observed_bits[lo:hi]} (hex: {act_hex})")
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
