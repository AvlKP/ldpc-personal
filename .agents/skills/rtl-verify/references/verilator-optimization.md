# Verilator Optimization & C++ Integration

This document outlines the standard practices for configuring, optimizing, and building testbenches using Verilator. Verilator is uniquely different from event-driven simulators (like ModelSim or VCS); it translates synthesizable SystemVerilog into highly optimized C++ or SystemC code, functioning as a cycle-accurate, 2-state simulator.

## 1. Core Philosophy

* **Cycle-Accurate & 2-State:** Verilator evaluates the design synchronously. By default, it simulates only two states (0 and 1), ignoring `X` (unknown) and `Z` (high-impedance). This constraint makes it blazingly fast but requires your RTL to be clean and purely synthesizable.
* **C++ Driven:** The testbench stimulus, clock generation, and result checking are written in C++ (or SystemC) rather than SystemVerilog.
* **Strict Linting First:** Verilator is a rigorous linter before it is a simulator. Passing Verilator's `-Wall` warnings is one of the best ways to guarantee your RTL is ready for ASIC/FPGA synthesis.

## 2. The C++ Testbench Wrapper

Because Verilator compiles the SystemVerilog design into a C++ class, you must write a C++ `main.cpp` wrapper to instantiate and drive the model.

### Structure of the Simulation Loop
* **Initialization:** Instantiate the compiled Verilated model (e.g., `Vtop* dut = new Vtop;`).
* **Clock Generation:** You must manually toggle the clock signal in the C++ `while` loop.
* **Evaluation:** You must explicitly call `dut->eval()` after every signal change to propagate the combinatorial logic and update registers.

```cpp
#include "Vtop.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtop* dut = new Vtop;

    // Simulation Loop
    while (!Verilated::gotFinish()) {
        // Toggle Clock
        dut->clk = !dut->clk; 
        
        // Drive Inputs on falling edge, sample on rising edge
        if (!dut->clk) {
            dut->reset = 0; // Deassert reset
            // Drive other stimuli here
        }

        // Evaluate the model
        dut->eval(); 
    }

    delete dut;
    return 0;
}
```


## 3. High-Performance Compilation Flags

Verilator's speed is largely dependent on how you configure the compilation flags during the Verilation process. Always optimize your `Makefile` or build script using these flags:

* **`-O3`:** Applies the highest level of C++ compiler optimizations. This increases build time but drastically reduces simulation execution time.
* **`--x-assign fast`:** Optimizes handling of two-state variables, pushing the simulator to assign deterministic values rather than modeling `X` states accurately, leading to performance gains.
* **`--x-initial fast`:** Forces uninitialized variables to 0, mimicking typical FPGA power-on states and removing overhead.
* **`--threads <N>`:** Enables multi-threading. Use this for large designs. Verilator will automatically partition your RTL across `N` CPU cores. *Note: For small designs, the threading overhead may actually slow down simulation.*

## 4. Tracing and Debugging

Generating waveform traces is the most resource-intensive operation in Verilator.

* **Use FST instead of VCD:** Always use `--trace-fst` instead of standard VCD tracing. FST files are significantly smaller and faster to write to disk. You will need a viewer like GTKWave to read them.
* **Conditional Tracing:** Do not leave tracing on by default for regression testing. Wrap your C++ tracing logic (`VerilatedFstC`) in a command-line flag or `#ifdef` block so you only pay the performance penalty when actively debugging a failure.


## 5. SystemVerilog Limitations & Linting Rules

Because Verilator models hardware mathematically rather than dynamically, certain traditional SV testbench constructs will fail to compile.

* **No Time Delays:** You cannot use `#10` or `wait(signal)` anywhere in the SystemVerilog code compiled by Verilator. All delays must be modeled via cycle counting in the C++ wrapper or within synchronous RTL.
* **Address Linter Warnings:** Do not ignore Verilator warnings. Fix `UNOPTFLAT` (combinatorial loops), `WIDTH` (mismatched bit widths), and `LATCH` (unintentional latches) at the source. If a warning is a known false positive, use inline pragmas to disable it locally rather than globally:
```systemverilog
/* verilator lint_off WIDTH */
assign narrow_bus = wide_bus;
/* verilator lint_on WIDTH */
```