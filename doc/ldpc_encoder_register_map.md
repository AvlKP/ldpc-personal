# LDPC Encoder Register Map (Draft)


## Register Summary
| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x0000 | STATUS | RO | 0x00000000 | Runtime state and error flags |
| 0x0004 | CFG | RW | 0x00000000 | Core LDPC mode config (BG, Zc, code rate profile) |
| 0x0008 | INPUT_BITS | RW | 0x00000000 | Number of valid input bits for current code block |
| 0x000C | OUTPUT_BITS | RW | 0x00000000 | Expected number of encoded output bits |

## Register Bitfields

### 0x0000 - STATUS (RO)
- `[0] READY`: encoder ready to receive input. -> from input buffer
- `[1] BUSY`: encoder processing active block. -> from core
- `[2] DONE`: last encode operation completed. -> from output buffer
- `[31:3] RESERVED`

### 0x0004 - CFG (RW)
- `[0] BASE_GRAPH`: `0=BG1`, `1=BG2`.
- `[9:1] ZC_VALUE`: lifting size `Zc` value.
- `[31:10] RESERVED`

### 0x0008 - INPUT_BITS (RW)
- `[15:0] K_BITS`: number of valid input bits for current code block.
- `[31:16] RESERVED`

### 0x000C - OUTPUT_BITS (RW)
- `[15:0] N_BITS`: number of encoded bits expected on output.
- `[31:16] RESERVED`