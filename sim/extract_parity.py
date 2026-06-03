import os
import sys
import random

# Add sim directory to path to import golden_model
sys.path.append(os.path.dirname(__file__))
from golden_model import LdpcEncoderGoldenModel

def bits_to_int_lsb(bits):
    value = 0
    for idx, bit in enumerate(bits):
        if bit:
            value |= 1 << idx
    return value

def format_hex(value, width_bits):
    # Determine how many hex digits are needed
    num_chars = (width_bits + 3) // 4
    return f"0x{value:0{num_chars}X}"

def main():
    model = LdpcEncoderGoldenModel()
    mem_dir = os.path.join(os.path.dirname(__file__), "mem")
    model.load_csr_data(mem_dir)

    configs = [
        {"frame_id": 0, "base_graph": 0, "zc": 96, "seed": 0x1001, "bg_idx": 1, "kb": 22, "mb": 46},
        {"frame_id": 1, "base_graph": 0, "zc": 192, "seed": 0x2002, "bg_idx": 1, "kb": 22, "mb": 46},
        {"frame_id": 2, "base_graph": 1, "zc": 384, "seed": 0x3003, "bg_idx": 2, "kb": 10, "mb": 42},
    ]

    output_path = os.path.join(os.path.dirname(__file__), "golden_parity_bits.txt")
    
    with open(output_path, "w") as f:
        f.write("================================================================================\n")
        f.write("GOLDEN PARITY BITS FOR 5G NR LDPC ENCODER VERIFICATION\n")
        f.write("================================================================================\n\n")

        for cfg in configs:
            f.write(f"--------------------------------------------------------------------------------\n")
            f.write(f"Frame ID   : {cfg['frame_id']}\n")
            f.write(f"Base Graph : BG{cfg['bg_idx']} (base_graph={cfg['base_graph']})\n")
            f.write(f"Lifting (Z): {cfg['zc']}\n")
            f.write(f"Seed       : {format_hex(cfg['seed'], 16)}\n")
            f.write(f"--------------------------------------------------------------------------------\n\n")

            # Generate random info bits exactly like seq_items.py
            rng = random.Random(cfg["seed"])
            input_bits_len = cfg["kb"] * cfg["zc"]
            info_bits = [rng.randint(0, 1) for _ in range(input_bits_len)]

            # Encode using Golden Model
            parity_bits = model.encode(info_bits, cfg["zc"], bg_idx=cfg["bg_idx"], version='3gpp')
            p_groups = model.hooks['p_groups']

            f.write(f"PARITY GROUPS (each is Z = {cfg['zc']} bits long):\n")
            f.write(f"Format: [Group Index] | Hex Value (LSB first) | Binary string (first bit on the left)\n")
            f.write(f"--------------------------------------------------------------------------------\n")
            for idx, group in enumerate(p_groups):
                val = bits_to_int_lsb(group)
                hex_str = format_hex(val, cfg["zc"])
                bin_str = "".join(str(b) for b in group)
                # Show first 48 bits and last 48 bits if Z is large, or full if small
                if len(bin_str) > 96:
                    bin_disp = bin_str[:48] + "..." + bin_str[-48:]
                else:
                    bin_disp = bin_str
                f.write(f"Group {idx:2d} | {hex_str} | {bin_disp}\n")
            f.write("\n")

            # Print out AXIS words (32-bit packed, LSB first)
            f.write("AXI-STREAM PARITY WORDS (32-bit, LSB-first):\n")
            f.write("--------------------------------------------\n")
            num_words = (len(parity_bits) + 31) >> 5
            for word_idx in range(num_words):
                lo = word_idx * 32
                hi = min(len(parity_bits), lo + 32)
                chunk = parity_bits[lo:hi]
                val = bits_to_int_lsb(chunk)
                hex_str = format_hex(val, 32)
                f.write(f"Word {word_idx:3d} | {hex_str}\n")
            f.write("\n\n")

    print(f"Parity bits successfully written to {output_path}")

if __name__ == "__main__":
    main()
