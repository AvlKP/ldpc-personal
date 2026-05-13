# SystemVerilog Timing Closure and Optimization

This document outlines best practices for writing SystemVerilog RTL that easily meets Static Timing Analysis (STA) requirements, specifically setup and hold times. The focus is on structuring your code to minimize combinational logic depth and manage signal routing delays before synthesis.

## 1\. Minimizing Logic Depth (Setup Time Optimization)

Setup time violations occur when the combinational logic path between two registers (flip-flops) is too long. To resolve this at the RTL level:

-   **Break Complex Expressions:** Do not chain multiple arithmetic operations (e.g., addition, multiplication) and multiplexers in a single clock cycle.
-   **Flatten Logic with `unique case`:** This is a critical Sutherland methodology for timing.
    
    -   Using a long `if-else-if` chain or a `priority case` forces the synthesis tool to build a priority encoder. This creates a deep, serial logic chain that heavily impacts setup time.
    -   Whenever conditions are mutually exclusive, ALWAYS use `unique case`. This instructs the synthesizer to build a flat, parallel multiplexer structure, significantly reducing logic depth and delay.
-   **Pre-compute Late Arriving Signals:** If a control signal arrives very late in the clock cycle, avoid using it at the beginning of a deep logic cone. Rearrange the logic equation to use the late-arriving signal at the very end of the combinational path (e.g., at the final multiplexer select pin).

## 2\. Pipeline Staging

When logic depth cannot be flattened further, you must insert pipeline registers to break the critical path into multiple clock cycles.

-   **Clean Pipeline Structures:** Use packed structs to group datapath signals and pass them through pipeline stages. This prevents mismatched pipeline delays among related signals.
    
    -   _Example:_ Define `typedef struct packed { logic valid; logic [31:0] data; } pipe_data_t;` and instantiate an array of these structs for the pipeline stages.
-   **Retiming Boundaries:** Modern synthesizers (like Vivado) can automatically move registers across combinational logic to balance delays (Register Retiming). To facilitate this:
    
    -   Provide dedicated pipeline registers at the output of complex modules.
    -   Avoid mixing reset types (synchronous vs. asynchronous) in a pipeline chain, as this prevents the synthesis tool from moving the registers.

## 3\. Separation of Datapath and Control Path

Mixing complex state machine logic with heavy datapath routing in the same procedural block leads to poor synthesis mapping and timing violations.

-   **Rule of Thumb:** Calculate next-state logic and control signals in one `always_comb` block, and perform heavy arithmetic/data routing in a separate `always_comb` block or directly inside an `always_ff` block.
-   _Why it helps:_ It allows the synthesizer to optimize the FSM independently from the datapath, often resulting in faster state decoding and shorter critical paths.

## 4\. Managing High Fan-Out Nets

High fan-out nets (a single register driving hundreds or thousands of endpoints) suffer from severe routing delays, leading to timing failures.

-   **Register Duplication (Cloning):** If a control signal (like a global enable, clear, or state machine output) has a massive fan-out, manually replicate the driving flip-flop in the RTL.
    
    -   Instead of `logic global_en;`, use `logic [3:0] global_en_dup;` and assign each duplicate to a specific sub-module or logic region.
-   **Avoid Over-Resetting:** Do not reset datapath registers unless strictly necessary for algorithm correctness. Resetting every single pipeline register creates a massive high fan-out net on the reset line. Usually, only the control path (e.g., the `valid` signals) requires a reset.

## 5\. Arithmetic Optimization

Arithmetic operators (`+`, `-`, `*`) are the most common source of timing failures.

-   **Operand Isolation:** If the output of an adder or multiplier is only used when a specific condition is met, use control logic to freeze the inputs to the arithmetic block when it is not needed. This prevents unnecessary toggling and can sometimes shorten the effective timing path.
-   **Targeted DSP Inference:** When targeting FPGAs, standard arithmetic might map to slow LUTs if not coded correctly. Ensure that pre-adders, multipliers, and post-adders have matching pipeline registers immediately before and after them to allow the tool to pack the entire operation into a dedicated, high-speed DSP slice.