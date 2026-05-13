# SystemVerilog RTL Best Practices

This document outlines the foundational methodologies for writing synthesizable SystemVerilog RTL, strictly adhering to Stuart Sutherland's guidelines. Apply these principles to guarantee synthesis-simulation equivalence, code conciseness, and robust hardware design.

## 1\. Intent-Specific Procedural Blocks

Traditional Verilog relied on the generic `always` block, which masked design intent and led to simulation-synthesis mismatches. You must use SystemVerilog's intent-specific blocks:

-   **`always_comb`**: Use for all combinational logic.
    
    -   _Why:_ It automatically infers a complete sensitivity list, evaluates at time zero (unlike `always @*`), and enforces a single-driver rule (tools will error if the same variable is driven in another block).
    -   _Rule:_ Ensure all variables are assigned in all branches of `if/else` and `case` statements within this block to prevent unintended latch inference.
-   **`always_ff @(posedge clk)`**: Use for all sequential flip-flop logic.
    
    -   _Why:_ It tells the synthesis tool and linter that the exact intent is a synchronous register. It will enforce that the sensitivity list only contains edge events.
-   **`always_latch`**: Use ONLY when a transparent latch is explicitly desired.
    
    -   _Why:_ It documents the intentional creation of a latch, preventing tools from flagging it as a missing-assignment error.

## 2\. Data Types and Variables

SystemVerilog simplifies data typing. Follow these rules for net and variable declarations:

-   **The `logic` Type:** Use `logic` for almost all signals (ports, internal variables, continuous assignments, and procedural assignments).
    
    -   _Why:_ It eliminates the confusion of choosing between `reg` and `wire`.
-   **When to use `wire`:** The ONLY time you should use `wire` (or `tri`) is when a net has multiple drivers (e.g., a bidirectional inout port or a tri-state bus). The `logic` type strictly forbids multiple continuous drivers to prevent accidental short circuits.
-   **Avoid 2-State Types in RTL:** Do not use `bit`, `byte`, `shortint`, or `int` for RTL variables unless strictly used as a loop iterator (e.g., `int i`).
    
    -   _Why:_ 2-state types hide uninitialized states ('X' and 'Z'). RTL must use 4-state types (`logic`) to accurately simulate reset behavior and detect uninitialized logic at simulation time.

## 3\. Decision Statements (Defeating the "Evil Twins")

Never use the traditional Verilog pragmas `// synopsys full_case parallel_case`. Sutherland refers to these as the "Evil Twins" because they provide instructions to the synthesizer that are hidden from the simulator, causing dangerous mismatches.

Instead, use SystemVerilog's built-in modifiers:

-   **`unique case`**: Use when you expect that one and only one case item will match the expression.
    
    -   _Effect:_ Tells the synthesizer to build parallel logic (no priority encoder) and instructs the simulator to issue a run-time warning if multiple conditions are true or if no conditions are true.
-   **`unique0 case`**: Similar to `unique`, but allows for no matches without throwing a simulation warning.
-   **`priority case`**: Use when multiple conditions might be true, but you want to enforce a priority order (like a long `if-else-if` chain).
    
    -   _Effect:_ Instructs the synthesizer to build a priority encoder and tells the simulator to issue a warning if no conditions match.

## 4\. User-Defined Types and Complex Data

Leverage SystemVerilog's abstraction capabilities to make RTL more readable and less error-prone.

-   **Enumerations for State Machines:** ALWAYS use strongly typed enums for FSM state variables.
    
    -   _Syntax:_ `typedef enum logic [2:0] {IDLE, READ, WRITE} state_t;`
    -   _Why:_ It abstracts the encoding, ensures type safety (you cannot accidentally assign a random integer to the state), and allows synthesis tools to easily extract and optimize the state machine.
-   **Packed Structs:** Use `struct packed` to group related signals that are assigned and passed around together.
    
    -   _Syntax:_ `typedef struct packed { logic valid; logic [31:0] data; } payload_t;`
    -   _Why:_ "Packed" guarantees that the synthesizer treats the struct as a contiguous vector of bits, making it perfectly synthesizable while maintaining field-level readability.

## 5\. Modules, Interfaces, and Packages

-   **ANSI-Style Ports:** Always declare ports with their direction, type, and size in a single concise list.
    
    -   _Example:_ `module adder (input logic [31:0] a, input logic [31:0] b, output logic [31:0] sum);`
-   **SystemVerilog Interfaces:** For complex buses (e.g., AXI, APB), group the signals into an `interface`. Pass the interface to the module port instead of dozens of individual wires. This drastically reduces connection errors. Use `modport` within the interface to define directional views (e.g., master vs. slave).
-   **Packages:** Place all shared `typedef`, `parameter`, `enum`, and `struct` definitions into a `package`.
    
    -   _Usage:_ Import the package inside the module header (e.g., `import my_pkg::*;`) rather than using `` `include ``. This prevents compilation order issues and global namespace pollution.

## 6\. Reset Strategies

-   Clearly separate reset logic from functional logic within the `always_ff` block.
-   Use asynchronous resets (`always_ff @(posedge clk or negedge rst_n)`) or synchronous resets (`always_ff @(posedge clk)`) consistently as dictated by the target architecture guidelines.
-   Avoid mixing reset styles within the same module unless specifically required by the architecture.