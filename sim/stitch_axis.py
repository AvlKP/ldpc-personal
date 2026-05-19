import json
import sys

def stitch(jsonl_path, frame_id=0):
    records = []
    with open(jsonl_path) as f:
        for line in f:
            rec = json.loads(line)
            if rec["frame_id"] == frame_id:
                records.append(rec)

    records.sort(key=lambda r: r["word_idx"])

    # Place word 0 at the MSB, last word at the LSB
    num_words = len(records)
    value = 0
    for rec in records:
        value |= int(rec["data_hex"], 16) << ((num_words - 1 - rec["word_idx"]) * 32)

    num_bits  = len(records) * 32
    hex_chars = num_bits // 4
    hex_str   = f"{value:0{hex_chars}x}"

    print(f"frame_id={frame_id}  words={len(records)}  bits={num_bits}")
    print(hex_str)

if __name__ == "__main__":
    path     = sys.argv[1] if len(sys.argv) > 1 else "sim_build/ldpc_encoder_pyuvm/txn/axis_in_trace.jsonl"
    frame_id = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    stitch(path, frame_id)
