# Vivado FPGA Synthesis Guidelines

When targeting Xilinx FPGAs using Vivado, generic RTL often maps poorly to the underlying silicon architecture. To achieve optimal Performance, Power, and Area (PPA), your SystemVerilog must be written to explicitly infer dedicated hardware blocks (DSP slices, BRAMs, URAMs, and SRLs).

This document outlines the coding techniques and synthesis attributes (pragmas) necessary for optimal Vivado synthesis.

## 1\. DSP48 Inference (Multipliers and MACs)

Xilinx DSP48 slices contain pre-adders, multipliers, and post-adders with dedicated internal pipeline registers.

-   **Pipelining for Performance:** To allow Vivado to pack operations into a DSP48 slice and run at high clock speeds, you must provide pipeline registers for the inputs, intermediate stages, and outputs.
-   **The Pre-Adder:** DSP slices have a dedicated pre-adder (e.g., `P = (A + D) * B`). To infer this, the addition and multiplication must occur in the same clock cycle, or have pipeline registers appropriately matching the DSP architecture.
-   **Synthesis Attribute:** Use the `use_dsp` attribute to force or prevent DSP inference.
    
    -   `(* use_dsp = "yes" *) logic [47:0] mac_result;`
    -   `(* use_dsp = "simd" *)` (For packing multiple small operations into one DSP).

## 2\. Memory Inference (BRAM and UltraRAM)

Vivado can automatically infer Block RAMs (BRAM) and UltraRAMs (URAM) from standard SystemVerilog arrays, provided the access patterns match the hardware.

-   **Synchronous Reads are Mandatory:** FPGAs do not have asynchronous read RAMs (except for tiny distributed RAM). Your array read address must be registered inside an `always_ff @(posedge clk)` block.
-   **Memory Initialization (The `initial` Exception):** While `initial` blocks are strictly forbidden in ASIC RTL, Vivado _requires_ them for initializing FPGA memory contents. You may use an `initial` block with `$readmemh` or `$readmemb` strictly for RAM initialization.
-   **Controlling Inference Style:** Vivado will guess the best memory type, but you should guide it:
    
    -   `(* ram_style = "block" *) logic [31:0] mem [0:1023];` (Forces BRAM)
    -   `(* ram_style = "ultra" *) logic [63:0] mem [0:4095];` (Forces UltraRAM)
    -   `(* ram_style = "distributed" *)` (Forces LUTRAM)

## 3\. Shift Register LUTs (SRLs)

Vivado can pack a shift register of up to 32 stages into a single Look-Up Table (LUT), saving dozens of flip-flops.

-   **The "No Reset" Rule:** Dedicated SRL hardware _does not possess a reset pin_. If you apply a reset (synchronous or asynchronous) to a shift register array in your RTL, Vivado is forced to use individual flip-flops instead of an SRL, destroying your area utilization.
-   **Coding Style:** Write your shift registers without resets whenever algorithmically possible.
-   **Synthesis Attribute:** `(* srl_style = "srl" *) logic [7:0] shift_reg [0:15];`

## 4\. Control Set Optimization

A "Control Set" is a unique combination of a clock, a reset, and a clock enable. FPGAs have a limited number of regional routing tracks for control signals.

-   **Limit Unique Control Signals:** Do not create localized, fine-grained resets or clock enables unless absolutely necessary. High numbers of control sets lead to routing congestion and timing failures.
-   **Prefer Synchronous Resets:** Xilinx DSP and BRAM primitives natively support synchronous resets. Using asynchronous resets often prevents the synthesizer from packing logic into these dedicated blocks.
-   **Active-High Control Signals:** Xilinx fabric registers natively use active-high resets and clock enables. While Vivado can invert active-low signals (`rst_n`), doing so at module boundaries can consume extra LUTs.

## 5\. Essential Vivado Attributes (Pragmas)

SystemVerilog allows synthesis attributes to be embedded directly in the RTL. Use these judiciously to guide Vivado:

-   **`(* keep = "true" *)`**: Prevents Vivado from optimizing away a signal, even if it appears unused. Useful for preserving signals for simulation or manual routing constraints.
-   **`(* mark_debug = "true" *)`**: Preserves the signal and marks it for inclusion in the Vivado Integrated Logic Analyzer (ILA) for hardware debugging.
-   **`(* max_fanout = "50" *)`**: Instructs the synthesis tool to automatically duplicate the driving register of a high fan-out net to meet timing.
-   **`(* async_reg = "true" *)`**: Apply to the first two flip-flops of a synchronizer chain. This tells Vivado to place them as close together as possible to increase MTBF (Mean Time Between Failures) and prevents it from optimizing the registers away.