# RTL Evaluation Report: Combinational & Simple Sequential Logic

## Target Architecture
- **Device:** Xilinx XC7Z020 (Zynq-7000)
- **EDA:** Vivado
- **Optimization Goal:** Timing closure and Hardware Usage Efficiency (HUE)

## Modules Evaluated

### 1. `set_index_decoder.sv` & `zc_decoder.sv`
- **Function:** Decodes the lifting size `$Z$` (or `$Z_c$`) into the set index (`i_LS` / `rom_sel`).
- **Structure:** Large `unique case` block assigning combinatorial values, followed by a pipeline register.
- **Synthesis/PPA:** 
  - The `unique case` construct is excellent for Vivado. It flattens the priority routing, allowing synthesis to pack the decode logic tightly into 6-input LUTs. 
  - The pipeline register isolates the combinatorial cone from downstream routing, aiding timing closure.
  - **Best Practices:** Adheres to Sutherland rules (default assignments prevent latches, ANSI ports, distinct `always_comb` / `always_ff` blocks). 
- **Bug Analysis:** Clean. Default assignments are correctly placed before the case statement.
- **Evaluation:** Complete and high quality.

### 2. `parameter_calculation.sv`
- **Function:** Calculates shifter parameters ($D$, $P \bmod D$, $Z/D$, etc.) based on base graph parameters.
- **Structure:** Purely combinational. Uses a `case(d)` statement to multiplex parameters.
- **Synthesis/PPA:** 
  - Logic is shallow and mostly consists of bit-slicing and small additions (`+ 7'd1`).
  - No DSP48 inference required or beneficial here (too small).
  - Will map directly to a small number of LUTs.
- **Bug Analysis:** Clean. Default assignments strictly prevent latch inference. 
- **Evaluation:** Complete.

### 3. `gf2_sum.sv`
- **Function:** Calculates XOR sums of shifted vectors (the $\lambda$ vectors).
- **Structure:** Combinational XOR network with a synchronous accumulation register.
- **Synthesis/PPA:**
  - Standard accumulator structure (`data_out_internal[i] <= comb_sum[i]`).
  - The XOR logic is extremely fast and will map to LUTs efficiently.
  - The `clr` and `en` signals act as synchronous reset and clock enable, mapping perfectly to the `SR` and `CE` pins of Xilinx FDRE primitives.
- **Bug Analysis:** Clean. 
- **Evaluation:** Complete.

### 4. `merge_sel_lambda.sv`
- **Function:** Rearranges the $\lambda$ vectors into the correct format for core parity calculation based on $D$.
- **Structure:** Purely combinational multiplexing based on `case(d)`.
- **Synthesis/PPA:**
  - Broad bit-slicing and assignment. 
  - Vivado will implement this as a wide multiplexer network. Depending on the size of `ZC_MAX`, this could become a routing bottleneck if not pipelined.
- **Bug Analysis:** 
  - **Risk:** In the `2'b01` and `2'b11` cases, the output index depends on `d_cycle`. Because `d_cycle` is an input, the assignments to `data_out[2*d_cycle]` only write to *some* elements of `data_out`. 
  - **Latch Warning:** While there is a default `for` loop setting `data_out[i] = '0'` at the top of the `always_comb` block, the dynamic indexing (`data_out[2*d_cycle] = ...`) might cause Vivado to infer complex priority logic or struggle with constant propagation. However, since the default assignment covers all indices, no latches will be inferred.
- **Evaluation:** Functionally complete, but the multiplexing scheme could put pressure on routing resources.

---
*Note: Complex sequential modules (Shifters, CSR Decoder, Buffers) require further analysis.*
