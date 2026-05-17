from pyuvm import uvm_driver, uvm_analysis_port, ConfigDB
from bfm import LdpcTopBfm

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
