---
name: sv-synth
description: Generates, refines, and optimizes synthesizable SystemVerilog RTL code for ASIC and FPGA targets. Use when a user asks for "RTL coding", "timing closure", "Vivado optimization", "hardware design", or mentions writing/generating ".sv" files for synthesis. Do not use for writing UVM verification testbenches.
---

# Synthesizable SystemVerilog RTL Modeling

This skill guides the generation of high-quality, fully synthesizable SystemVerilog RTL. All generated code must strictly adhere to Stuart Sutherland's methodologies for safe, concise, and highly optimized hardware modeling.

## Critical Constraints (Non-Negotiables)

Before writing any code, you must enforce the following rules:

1.  **Synthesizable Subset ONLY:** NEVER use testbench constructs in RTL. Strictly forbid `initial` blocks (unless explicitly targeted for FPGA BRAM/URAM initialization), `#` delays, `wait`, `fork...join`, `class`, `program`, or `string` data types.
2.  **Intent-Specific Procedural Blocks:** ALWAYS use SystemVerilog-specific blocks to prevent simulation-synthesis mismatches:
    
    -   Use `always_comb` for combinational logic (never `always @*`).
    -   Use `always_ff @(posedge clk)` for sequential logic.
    -   Use `always_latch` only if a latch is explicitly requested; otherwise, prevent unintended latches in `always_comb` by assigning all variables in all branches.
3.  **Data Types:** Use `logic` instead of `reg` or `wire` for all signals, except when a signal has multiple drivers (where `wire` or `tri` is strictly required).
4.  **State Machines:** ALWAYS use enumerated types (`typedef enum logic [W-1:0]`) for state machine encoding to ensure type safety and clear synthesis inference.
5.  **Port Declarations:** ALWAYS use ANSI-style port declarations with explicit directions (`input`, `output`, `inout`) and types.

## Workflow: RTL Generation & Optimization

Follow these steps sequentially when asked to create or optimize RTL:

### Step 1: Analyze Architecture and Constraints

-   Determine the target technology (ASIC vs. FPGA/Vivado).
-   Identify PPA (Power, Performance, Area) goals and clocking constraints.
-   _Reference:_ Consult `references/rtl-best-practices.md` to establish the foundational rules for the target architecture.
-   _Reference:_ If the target is a Xilinx FPGA, consult `references/vivado-fpga.md` for specific macro inference (DSP48, UltraRAM, SRLs).

### Step 2: Draft Interface and Module Definition

-   Define the module using standard parameter declarations and ANSI-style port lists.
-   Parameterize data widths and depths (`#(parameter DATA_WIDTH = 32)`).
-   Bundle highly related interface signals using SystemVerilog `interface` constructs if requested, ensuring they are synthesizable.

### Step 3: Implement Core Logic (Sutherland Method)

-   Write the core logic keeping data paths and control paths clearly separated.
-   Use `unique case` or `priority case` modifiers to explicitly guide the synthesis tool on parallel versus priority evaluation, reducing area and avoiding unintended latches.
-   Keep logic depth shallow between registers to assist with timing closure.
-   _Reference:_ Consult `references/timing-closure.md` for pipeline staging and fan-out management.
-   _Reference:_ Consult `references/ppa-optimization.md` for operand isolation and clock-gating strategies.

### Step 4: Validate Synthesizability

-   Review the generated `.sv` code against `references/synthesizable-subset.md`.
-   Ensure there are no asynchronous resets mixed with synchronous logic in the same `always_ff` block without proper syntax.
-   Perform a careful manual review of the generated code to verify no simulation-only constructs have leaked into the RTL.

## Examples

**Example 1: Basic Module Generation** _User says:_ "Write a parameterized APB timer module in SystemVerilog." _Actions:_

1.  Define APB interface ports using `logic` and standard ANSI module headers.
2.  Implement the down-counter inside an `always_ff` block with a synchronous reset.
3.  Implement APB read/write decode logic in an `always_comb` block.
4.  Present the clean, commented code to the user.

**Example 2: Vivado Optimization** _User says:_ "Optimize this multiply-accumulate block for Vivado." _Actions:_

1.  Consult `references/vivado-fpga.md`.
2.  Restructure the code to ensure it perfectly maps to DSP48E2 slices.
3.  Add appropriate `(* use_dsp = "yes" *)` synthesis pragmas.
4.  Ensure the pre-adder, multiplier, and post-adder pipeline registers are correctly aligned to allow register retiming by the Vivado synthesizer.

## References

Do not guess domain-specific optimizations. If the user requests advanced tuning, explicitly load and read the corresponding reference files:

-   For foundational RTL patterns and standards: Read `references/rtl-best-practices.md`
-   For setup/hold violations or high-frequency targets: Read `references/timing-closure.md`
-   For Xilinx-specific pragmas and RAM/DSP inference: Read `references/vivado-fpga.md`
-   For reducing gate count or dynamic power: Read `references/ppa-optimization.md`
-   If unsure about a language feature: Read `references/synthesizable-subset.md`