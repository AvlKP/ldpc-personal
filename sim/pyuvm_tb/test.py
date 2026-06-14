import os
import sys
import logging
from pyuvm import uvm_root

# Add the parent directory and the pyuvm directory to sys.path so modules can find each other
sys.path.append(os.path.dirname(__file__))
sys.path.append(os.path.dirname(os.path.dirname(__file__)))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Event, ClockCycles
from pyuvm import uvm_test, test, ConfigDB
from golden_model import LdpcEncoderGoldenModel
from bfm import TransactionRecorder, LdpcTopBfm
from seq_items import FrameCfg, LdpcFrameSequence
from agent_env import LdpcEnv

CLK_PERIOD_NS = 10

def setup_file_logger():
    sim_build = os.environ.get("SIM_BUILD", "sim_build/ldpc_encoder_pyuvm")
    log_file = os.path.join(sim_build, "pyuvm_test.log")
    
    fh = logging.FileHandler(log_file, mode='w')
    fh.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(levelname)s %(name)s %(message)s')
    fh.setFormatter(formatter)
    
    # Add handler to root logger
    logging.getLogger().addHandler(fh)
    # Add handler to cocotb logger
    logging.getLogger("cocotb").addHandler(fh)
    # Add handler to pyuvm root
    uvm_root().logger.addHandler(fh)
    
    # In pyuvm, component loggers are named by their hierarchical path (e.g. uvm_test_top.env.scoreboard)
    # They might not propagate to root or cocotb. Let's attach it to 'uvm_test_top' as well.
    logging.getLogger("uvm_test_top").addHandler(fh)
    
    return log_file

@test()
class LdpcCorePyuvmTest(uvm_test):
    def build_phase(self) -> None:
        self.recorder = TransactionRecorder()
        
        # Instantiate and load the Golden Model
        self.golden_model = LdpcEncoderGoldenModel()
        mem_dir = os.environ.get("CSR_MEM_DIR", os.path.join(os.path.dirname(os.path.dirname(__file__)), "mem"))
        self.golden_model.load_csr_data(mem_dir)
        
        # Pass golden model to BFM
        self.bfm = LdpcTopBfm(cocotb.top, self.recorder, self.golden_model)
        self.sb_done_event = Event()

        # ZC_SMALL: zc <= 96
        # zc_values = [
        #     2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        #     18, 20, 22, 24, 26, 28, 30, 32, 36, 40, 44, 48, 52, 56,
        #     60, 64, 72, 80, 88, 96,
        # ]
        # frame_cfgs = [
        #     FrameCfg(frame_id=i, base_graph=0, zc=zc, seed=0x1000 + i)
        #     for i, zc in enumerate(zc_values)
        # ]

        # ZC_MEDIUM: 96 < zc <= 192
        # zc_values = [104, 112, 120, 128, 144, 160, 176, 192]
        # frame_cfgs = [
        #     FrameCfg(frame_id=i, base_graph=0, zc=zc, seed=0x2000 + i)
        #     for i, zc in enumerate(zc_values)
        # ]

        # ZC_LARGE: zc > 192
        zc_values = [208, 224, 240, 256, 288, 320, 352, 384]
        frame_cfgs = [
            FrameCfg(frame_id=i, base_graph=1, zc=zc, seed=0x3000 + i)
            for i, zc in enumerate(zc_values)
        ]

        self.frame_cfgs = frame_cfgs

        ConfigDB().set(self, "*", "BFM", self.bfm)
        ConfigDB().set(self, "*", "RECORDER", self.recorder)
        ConfigDB().set(self, "*", "FRAME_CONFIGS", frame_cfgs)
        ConfigDB().set(self, "*", "FRAME_COUNT", len(frame_cfgs))
        ConfigDB().set(self, "*", "SB_DONE_EVENT", self.sb_done_event)
        ConfigDB().set(self, "*", "GOLDEN_MODEL", self.golden_model)

        self.env = LdpcEnv("env", self)
        
    def end_of_elaboration_phase(self) -> None:
        # Setup file logger directly on the scoreboard logger
        sim_build = os.environ.get("SIM_BUILD", "sim_build/ldpc_encoder_pyuvm")
        log_file = os.path.join(sim_build, "pyuvm_test.log")
        fh = logging.FileHandler(log_file, mode='w')
        fh.setLevel(logging.DEBUG)
        
        class SimTimeFormatter(logging.Formatter):
            def format(self, record):
                try:
                    import cocotb.utils
                    sim_time = f"{cocotb.utils.get_sim_time('ns'):8.2f}ns"
                except Exception:
                    sim_time = "   -.--ns"
                return f"{sim_time} {record.levelname:8} [{record.name}] {record.getMessage()}"

        fh.setFormatter(SimTimeFormatter())
        
        self.env.scoreboard.logger.addHandler(fh)
        self.env.internal_scoreboard.logger.addHandler(fh)
        self.logger.addHandler(fh)

        self.env.scoreboard.logger.setLevel(logging.DEBUG)
        self.env.internal_scoreboard.logger.setLevel(logging.DEBUG)

        self.logger.info(f"Logging pyuvm output to {log_file}")

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
