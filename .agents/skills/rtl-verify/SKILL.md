---
name: modern-verification-methodologies
description: Orchestrates and generates modern verification testbenches for SystemVerilog RTL. Use when the user asks to "write a testbench", "setup a UVM environment", "create a cocotb simulation", "run formal verification", or "configure Verilator".
---

# Modern Verification Methodologies

## 1. Core Principles
Before writing any testbench code, you must adhere to these strict constraints:
* **Separation of Concerns:** Never mix synthesizable RTL and non-synthesizable testbench constructs in the same file. 
* **Driven by Abstraction:** Prefer transactional or cycle-accurate BFMs (Bus Functional Models) over arbitrary signal toggling or hardcoded delays.
* **Coverage-Driven:** Always define what needs to be tested (the verification plan) before implementing the tests.

## 2. Verification Strategy Selection
Analyze the user's request to determine the appropriate framework. Use the following decision logic:
* **UVM (Universal Verification Methodology):** Select if the user requires a highly structured, scalable SystemVerilog environment with complex transaction randomization, factory overrides, and scoreboarding.
* **Cocotb:** Select if the user prefers Python-based verification, requires rapid test development, or wants to leverage standard Python libraries for data checking and stimulus generation.
* **Formal Verification:** Select if the user needs mathematical proof of RTL properties, asks to verify critical corner cases without test vectors, or explicitly mentions SVA (SystemVerilog Assertions).
* **Verilator:** Select if the user requires high-speed, cycle-accurate C++ simulation or co-simulation.

## 3. Core Workflow Checklist
When generating a testbench, follow this progressive step-by-step workflow:

**Step 1: Define Verification Plan**
* Ask the user for the DUT (Design Under Test) interface and specifications if not provided.
* Outline the core test scenarios and coverage goals.
* Consult `references/verification-plan-templates.md` for standard test plan structures.

**Step 2: Initialize Top-Level Interfaces**
* Generate the `tb_top.sv` module.
* Instantiate the DUT and declare virtual interfaces if required.
* Connect clock generation, reset logic, and physical interfaces.

**Step 3: Framework-Specific Implementation**
Execute the setup based on the selected framework:
* **UVM:** Build the sequence item, sequencer, driver, monitor, and agent hierarchy.
* **Cocotb:** Write the Python asynchronous coroutines, attach clock edge triggers, and define the simulation `Makefile`.
* **Formal:** Write the `assume`, `assert`, and `cover` properties and bind them appropriately to the DUT.

**Step 4: Execute and Validate**
* Confirm the directory structure is organized correctly.
* Validate that no non-synthesizable delays (e.g., `#5`) have accidentally been placed inside the RTL code being tested.

## 4. Methodology References
To implement the specific frameworks, you MUST consult the deep-dive guidelines in the `references/` directory:
* **For Python/cocotb:** Read `references/cocotb-best-practices.md` for asynchronous generator patterns and coroutine best practices.
* **For UVM/SystemVerilog:** Read `references/uvm-framework.md` for factory registration, phasing rules, and configuration databases.
* **For Formal/SVA:** Read `references/formal-methods.md` for property checking constraints and binding strategies.
* **For Verilator/C++:** Read `references/verilator-optimization.md` for wrapper generation and multi-threading flags.