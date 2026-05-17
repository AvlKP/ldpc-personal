from pyuvm import uvm_agent, uvm_sequencer, uvm_env
from driver import LdpcDriver
from monitors import LdpcOutputMonitor, LdpcInputBufferMonitor, LdpcShifterMonitor, LdpcGf2Monitor, LdpcLambdaMonitor
from scoreboards import LdpcScoreboard, LdpcInternalScoreboard

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

        # internal monitoring
        self.inbuff_monitor = LdpcInputBufferMonitor("input_buffer_monitor", self)
        self.shifter_monitor = LdpcShifterMonitor("cyclic_shifter_monitor", self)
        self.gf2_monitor = LdpcGf2Monitor("gf2_sum_monitor", self)
        self.lambda_monitor = LdpcLambdaMonitor("lambda_monitor", self)
        self.internal_scoreboard = LdpcInternalScoreboard("internal_scoreboard", self)

    def connect_phase(self) -> None:
        self.agent.driver.expected_ap.connect(self.scoreboard.expected_fifo.analysis_export)
        self.output_monitor.actual_ap.connect(self.scoreboard.actual_fifo.analysis_export)
        self.inbuff_monitor.ap.connect(self.internal_scoreboard.input_fifo.analysis_export)
        self.shifter_monitor.ap.connect(self.internal_scoreboard.shifter_fifo.analysis_export)
        self.gf2_monitor.ap.connect(self.internal_scoreboard.gf2_fifo.analysis_export)
        self.lambda_monitor.ap.connect(self.internal_scoreboard.lambda_fifo.analysis_export)
