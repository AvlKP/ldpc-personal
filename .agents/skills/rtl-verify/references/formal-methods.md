# Formal Verification Best Practices & Methodology

This document outlines the standard practices for Formal Property Verification (FPV) using SystemVerilog Assertions (SVA). It draws heavily from the methodologies in *Formal Verification: An Essential Toolkit for Modern VLSI Design* by Erik Seligman et al., focusing on mathematical proofs of design intent rather than simulation-based test vectors.

---

## 1. Core Philosophy

* **Mathematical Proof vs. Test Vectors:** Unlike dynamic simulation (UVM/cocotb) which relies on generated stimulus to stumble upon bugs, formal verification uses mathematical solvers to prove that a property holds true across *all possible states* and inputs.
* **State-Space:** Formal tools explore the entire state-space. If a bug can happen, formal will find the shortest path to trigger it. Conversely, if the state-space is too large (state-space explosion), the tool will fail to converge.
* **Early Bug Finding:** Formal is best applied at the block level as soon as the RTL compiles, long before a full dynamic simulation testbench is ready.

---

## 2. The Formal Triad: Assert, Assume, Cover

Formal verification relies on three fundamental SVA directives. Misusing them—especially confusing `assert` and `assume`—is the most common cause of false proofs.

### `assert` (The Check)
* **Purpose:** Defines a rule that the Design Under Test (DUT) must never violate.
* **Formal Tool Action:** The tool tries to find a mathematical proof that the assertion can be broken. If it finds a break, it generates a counter-example (waveform).

### `assume` (The Environment)
* **Purpose:** Constrains the inputs to the DUT. It tells the tool what constitutes "legal" behavior from the outside world.
* **Formal Tool Action:** The tool restricts its state-space exploration to scenarios where the assumption is true.
* **Danger:** Over-constraining. If you accidentally write an `assume` that restricts legal inputs, you will "constrain away" valid state-space and hide real bugs. *Never use `assume` on an internal DUT signal or an output.*

### `cover` (The Sanity Check)
* **Purpose:** Proves that a specific state or sequence of events is reachable.
* **Formal Tool Action:** The tool searches for a path from reset to the covered condition.
* **Best Practice:** Always write a `cover` property for complex assumptions or assertions to ensure the scenario is actually possible and hasn't been accidentally constrained away (vacuous proofs).

---

## 3. Writing Effective SystemVerilog Assertions (SVA)

Do not write procedural testbench code for formal. Use concurrent assertions that evaluate continuously over time.

### Concurrent Assertions
Always use concurrent assertions (`assert property`) rather than immediate assertions (`assert()`) for formal tools, as they allow for temporal (time-based) expressions.

* **Syntax Pattern:**
    ```systemverilog
    property p_req_ack;
      @(posedge clk) disable iff (!rst_n)
      req |=> ack;
    endproperty
    a_req_ack: assert property(p_req_ack);
    ```

### Implication Operators
Use implications to define preconditions for your checks.
* **Overlapping Implication (`|->`):** If the left side is true, the right side must be true on the *same* clock cycle.
* **Non-Overlapping Implication (`|=>`):** If the left side is true, the right side must be true on the *next* clock cycle.

---

## 4. Separation of Concerns: The `bind` Construct

Never embed complex SVA directly inside the design RTL. This clutters the design code and creates synthesis risks.

* **The `bind` Statement:** Use SystemVerilog's `bind` feature to physically separate the design and the verification IP.
* **Methodology:** Write your assertions in a separate module or interface, and bind them to the DUT in your formal setup file.
    ```systemverilog
    // Binds the verification module 'v_fifo' to the RTL module 'dut_fifo'
    bind dut_fifo v_fifo v_fifo_inst (.*);
    ```

---

## 5. Managing Complexity (State-Space Explosion)

Formal tools can easily run out of memory or time if the mathematical complexity is too high. Use these techniques to help the tool converge:

* **Bounded Model Checking (BMC):** Instead of proving a property forever, prove that it holds for a specific number of clock cycles (e.g., 50 cycles after reset).
* **Abstraction:** * **Black-boxing:** Remove complex elements that aren't relevant to the control logic being verified (e.g., large SRAMs or DSP blocks).
    * **Cutpoints:** Sever internal signals and let the formal tool drive them freely to reduce logic depth.
* **Reduce Counters:** If a timer counts to 64,000, the formal tool will struggle. Temporarily reduce the counter threshold to 4 or 8 during formal runs to verify the wrap-around logic without exhausting memory.