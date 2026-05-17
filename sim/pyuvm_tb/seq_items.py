from dataclasses import dataclass
from pyuvm import uvm_sequence_item, uvm_sequence
import random

BG1_KB = 22
BG2_KB = 10
BG1_NB = 68
BG2_NB = 52

@dataclass
class FrameCfg:
    frame_id: int
    base_graph: int
    zc: int
    seed: int

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
