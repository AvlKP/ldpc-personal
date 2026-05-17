from typing import Any
from cocotb.triggers import Event
from pyuvm import uvm_scoreboard, uvm_analysis_port, uvm_component, uvm_tlm_analysis_fifo, ConfigDB
from bfm import bits_to_int_lsb, int_to_bits_lsb, TransactionRecorder

class LdpcInternalScoreboard(uvm_scoreboard):
    def build_phase(self):
        self.input_export = uvm_analysis_port("input_export", self)
        self.shifter_export = uvm_analysis_port("shifter_export", self)
        self.gf2_export = uvm_analysis_port("gf2_export", self)
        self.lambda_export = uvm_analysis_port("lambda_export", self)
        
        # FIFOs to hold transactions
        self.input_fifo = []
        self.shifter_fifo = []
        self.gf2_fifo = []
        self.golden_model = ConfigDB().get(self, "", "GOLDEN_MODEL")
        
    def write_input_export(self, tr):
        gm = self.golden_model
        if gm is None or tr['kb_idx'] >= len(gm.hooks.get('i_groups', [])):
            return
        expected_bits = gm.hooks['i_groups'][tr['kb_idx']]
        expected_int = bits_to_int_lsb(expected_bits)
        
        if tr['data'] != expected_int:
            self.logger.error(f"INPUT MISMATCH at KB={tr['kb_idx']}. RTL: {hex(tr['data'])}, GM: {hex(expected_int)}")
        else:
            self.logger.debug(f"Input KB={tr['kb_idx']} aligned correctly.")

    def write_shifter_export(self, tr):
        self.shifter_fifo.append(tr)
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
                    self.logger.error(f"SHIFT MISMATCH at Row {row}, Col {col}. RTL: {actual_shift}, GM: {expected_shift}")

    def write_gf2_export(self, tr):
        self.gf2_fifo.append(tr)
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
                    self.logger.error(f"GF2 MISMATCH at Row {row}, Col {col}. RTL: {hex(actual_sum)}, GM: {hex(expected_sum)}")

    def write_lambda_export(self, tr):
        gm = self.golden_model
        if gm is None:
            return
        expected_lambdas = gm.hooks.get('lambdas', [])
        if not expected_lambdas:
            return
        
        for i in range(4):
            expected_int = bits_to_int_lsb(expected_lambdas[i])
            if tr['lambdas'][i] != expected_int:
                self.logger.error(f"LAMBDA MISMATCH at Row {i}. RTL: {hex(tr['lambdas'][i])}, GM: {hex(expected_int)}")


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
        if len(exp_bits) != len(act_bits):
            self.logger.error(f"Frame {frame_id} bit length mismatch. exp={len(exp_bits)} act={len(act_bits)}")
            has_error = True
        else:
            mismatch = next((idx for idx, (exp, act) in enumerate(zip(exp_bits, act_bits)) if exp != act), -1)
            if mismatch >= 0:
                lo = max(0, mismatch - 32)
                hi = min(len(exp_bits), mismatch + 33)
                exp_hex = hex(bits_to_int_lsb(exp_bits[lo:hi]))
                act_hex = hex(bits_to_int_lsb(act_bits[lo:hi]))
                self.logger.error(f"Frame {frame_id} mismatch at bit {mismatch}.\nExp window: {exp_bits[lo:hi]} (hex: {exp_hex})\nAct window: {act_bits[lo:hi]} (hex: {act_hex})")
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
                self.logger.error(f"Parity group length mismatch frame={frame_id} chunk={idx} exp_len={expected_len} act_len={chunk['len']}")
                has_error = True
            
            if parity_cursor + chunk["len"] > len(parity_expected):
                self.logger.error(f"Parity monitor overflow frame={frame_id} cursor={parity_cursor} ext_len={chunk['len']} parity_total={len(parity_expected)}")
                has_error = True
                break
                
            observed_bits = int_to_bits_lsb(chunk["data"], chunk["len"])
            expected_chunk = parity_expected[parity_cursor : parity_cursor + chunk["len"]]
            
            if observed_bits != expected_chunk:
                mismatch = next((i for i, (exp, act) in enumerate(zip(expected_chunk, observed_bits)) if exp != act), -1)
                exp_hex = hex(bits_to_int_lsb(expected_chunk))
                act_hex = hex(bits_to_int_lsb(observed_bits))
                self.logger.error(f"Parity group mismatch frame={frame_id} src={chunk['src']} bit={mismatch}\nRTL:    {observed_bits} (hex: {act_hex})\nGolden: {expected_chunk} (hex: {exp_hex})")
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
            
        for write_idx, (obs_wr, exp_wr) in enumerate(zip(actual_writes, expected_internal_writes)):
            if obs_wr != exp_wr:
                observed_bits = int_to_bits_lsb(obs_wr, OUTBUFF_WRITE_BITS)
                expected_bits_row = int_to_bits_lsb(exp_wr, OUTBUFF_WRITE_BITS)
                mismatch = next((i for i, (exp, act) in enumerate(zip(expected_bits_row, observed_bits)) if exp != act), -1)
                lo = max(0, mismatch - 16)
                hi = min(OUTBUFF_WRITE_BITS, mismatch + 17)
                exp_hex = hex(bits_to_int_lsb(expected_bits_row[lo:hi]))
                act_hex = hex(bits_to_int_lsb(observed_bits[lo:hi]))
                self.logger.error(f"Output-buffer write mismatch frame={frame_id} row={write_idx} bit={mismatch}\nExp window: {expected_bits_row[lo:hi]} (hex: {exp_hex})\nAct window: {observed_bits[lo:hi]} (hex: {act_hex})")
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
