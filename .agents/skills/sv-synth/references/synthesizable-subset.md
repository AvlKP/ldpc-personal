# Synthesizable Subset of SystemVerilog

SystemVerilog is a unified design and verification language. However, synthesis tools (like Design Compiler or Vivado) only support a specific subset of the language that can be mapped to physical hardware gates.

When writing RTL, you must strictly adhere to this subset. If a construct is not on the "Allowed" list, do not use it.

## 1\. Strictly Forbidden Constructs (Simulation Only)

The following constructs have no hardware equivalent and will cause synthesis failures. NEVER use these in RTL modules:

-   **Timing Controls:** `#` (delay), `wait`, and asynchronous `@` events (except in testbenches).
-   **Dynamic Data Types:** `class`, `string`, `real`, `time`, `shortreal`, `event`.
-   **Dynamic Arrays and Data Structures:** Queues (`[$]`), associative arrays (`[type]`), and dynamic arrays (`[]`). All RTL arrays must have statically defined, fixed boundaries.
-   **Testbench Procedural Blocks:** `program`, `initial` (exception: FPGA BRAM/URAM initialization), and `final`.
-   **Object-Oriented Programming:** Inheritance, polymorphism, mailboxes, semaphores, and randomization (`rand`, `randc`, `std::randomize()`).
-   **Concurrency Controls:** `fork...join`, `fork...join_any`, `fork...join_none`.

## 2\. Allowed and Recommended Data Types

RTL requires deterministic, fixed-width 4-state types.

-   **`logic`:** The default type for all vectors, scalars, and arrays.
-   **`enum`:** Must be used for state machine encoding. Define the underlying type explicitly (e.g., `typedef enum logic [3:0] {...}`).
-   **`struct packed` and `union packed`:** Only _packed_ structures and unions are synthesizable. Unpacked structs are generally not supported for hardware mapping because their memory layout is arbitrary.
-   **Fixed-Size Arrays:** Multidimensional arrays are fully synthesizable if bounds are statically declared (e.g., `logic [31:0] mem [0:255]`).

## 3\. Functions vs. Tasks

A major source of synthesis errors in traditional Verilog was the use of `task` constructs that accidentally included timing controls.

-   **Use `void` Functions Instead of Tasks:** As per Stuart Sutherland's guidelines, ALWAYS use `void function` instead of a `task` for modeling combinational logic blocks or repetitive RTL operations. Functions guarantee execution in zero time, matching combinational hardware behavior, whereas tasks permit delays that break synthesis.
-   **Function Syntax:** `function void do_math(input logic a, output logic b); ... endfunction`

## 4\. Module Instantiation and Connectivity

SystemVerilog introduced shortcuts to reduce verbose and error-prone netlists.

-   **Implicit Port Connections:** Use the `.name` or `.*` shortcuts for module instantiations when the port name and the connected signal name perfectly match. This prevents manual connection errors and reduces code size.
-   **Interfaces:** Use SystemVerilog `interface` constructs to group related bus signals (e.g., AXI, APB). Interfaces are fully synthesizable and drastically reduce port-list clutter.

## 5\. Decision Statements and Loops

-   **Case Modifiers:** Use `unique case`, `unique0 case`, or `priority case` to explicitly define the synthesis architecture (parallel multiplexer vs. priority encoder). Completely avoid the `// synopsys full_case parallel_case` pragmas.
-   **Loops (`for`):** `for` loops are fully synthesizable ONLY if the synthesis tool can statically unroll them.
    
    -   The loop boundary must be a constant or a parameter.
    -   Always declare the loop iterator locally within the loop statement to prevent variable scope leakage (e.g., `for (int i = 0; i < DATA_WIDTH; i++)`).
-   **Generate Blocks:** Use `generate...endgenerate` combined with `for` loops or `if/else` statements for structural instantiation of modules or procedural blocks based on parameters.

## 6\. Procedural Blocks

As detailed in other references, restrict procedural assignments to:

-   `always_comb` (Combinational logic)
-   `always_ff @(posedge clk)` (Sequential logic)
-   `always_latch` (Intentional latches only)