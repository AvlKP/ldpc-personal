# UVM Framework Best Practices & Methodology

This document outlines the standard practices for building SystemVerilog-based Universal Verification Methodology (UVM) environments. It synthesizes the object-oriented methodologies from Chris Spear's *SystemVerilog for Verification* with the step-by-step architectural progression detailed in Ray Salemi's *The UVM Primer*.

---

## 1. Core Philosophy

* **Testbench as Software:** A modern SystemVerilog testbench is a complex software project. Leverage Object-Oriented Programming (OOP) concepts like inheritance, encapsulation, and polymorphism to maximize code reuse.
* **Separation of Structure and Data:** Clearly distinguish between structural components (which are created once and persist throughout the simulation) and data objects (which are continuously created, passed around, and destroyed).
* **Randomization and Coverage:** Unlike directed testing, UVM relies on Constrained Random Stimulus Generation to hit edge cases, paired with Functional Coverage to measure when verification is complete.

---

## 2. UVM Class Hierarchy

To build a reusable testbench, strictly adhere to the UVM base classes. Do not reinvent the wheel.

### Data Objects (`uvm_sequence_item`)
* **Purpose:** Represents the transactions, packets, or instructions flowing through the system.
* **Rules:** * Must inherit from `uvm_sequence_item`.
  * Use the ``` `uvm_object_utils() ``` macro to register it with the UVM Factory.
  * Define all fields using `rand` keywords and include `constraint` blocks to ensure generated data is valid for the DUT.

### Structural Components (`uvm_component`)
* **Purpose:** The static building blocks of the testbench (Drivers, Monitors, Scoreboards, Agents, Environments).
* **Rules:**
  * Must inherit from the appropriate base class (e.g., `uvm_driver`, `uvm_monitor`, `uvm_env`).
  * Use the ``` `uvm_component_utils() ``` macro.
  * Components must be instantiated during the UVM `build_phase`, never dynamically during the `run_phase`.

---

## 3. The UVM Factory

The Factory is central to UVM's reusability. It allows you to swap out objects or components at runtime without changing the original source code.

* **Registration:** Always register your classes using the appropriate `utils` macro. If you forget the macro, the factory cannot create the object.
* **Instantiation:** Never use the standard SystemVerilog `new()` constructor for UVM objects or components. 
  * **Instead of:** `my_txn = new("my_txn");`
  * **Use:** `my_txn = my_transaction::type_id::create("my_txn", this);`
* **Overrides:** Use factory overrides from the top-level test to inject error-injecting sequences or modified drivers without touching the base Environment code.

---

## 4. UVM Phasing

UVM execution is strictly divided into phases to ensure the testbench is fully built and connected before time starts advancing.

* **`build_phase(uvm_phase phase)`:** A top-down phase. Use this to extract configuration data from the `uvm_config_db` and instantiate child components using the factory.
* **`connect_phase(uvm_phase phase)`:** A bottom-up phase. Use this purely to connect TLM (Transaction Level Modeling) ports between instantiated components (e.g., connecting a Monitor's analysis port to a Scoreboard's export).
* **`run_phase(uvm_phase phase)`:** A time-consuming task (use `task` instead of `function`). This is where the simulation actually happens. Use `raise_objection()` at the start of stimulus generation and `drop_objection()` when done to prevent the simulator from exiting prematurely.

---

## 5. Configuration and Interfaces

Passing physical signals from the static Verilog module (`tb_top`) to the dynamic OOP testbench requires specific mechanisms.

* **Virtual Interfaces:** The DUT interfaces must be declared as `virtual interface` handles inside your UVM classes.
* **The `uvm_config_db`:** Use the configuration database to pass the virtual interface from the top-level module to the UVM Environment.
  * **In `tb_top`:** `uvm_config_db#(virtual my_if)::set(null, "uvm_test_top", "vif", physical_if);`
  * **In the UVM Test/Driver:** `uvm_config_db#(virtual my_if)::get(this, "", "vif", vif);`

---

## 6. Sequences and Stimulus

* **The Sequencer:** Acts as a router. Do not put stimulus generation logic inside the sequencer or the driver.
* **The Sequence:** Inherits from `uvm_sequence`. This is where all the algorithmic generation of `sequence_item`s belongs.
* **Handshake Protocol:** Use `start_item(req)` -> `req.randomize()` -> `finish_item(req)` to cleanly pass generated transactions down to the driver.

---

## 7. Contrast with Python Methods
*Unlike the methods detailed in *Python for RTL Verification* which leverage native Python queues and `async/await` for concurrency, UVM relies heavily on TLM FIFOs and the `run_phase` task for inter-process communication. When writing UVM, stay within the boundaries of SystemVerilog macros and TLM ports rather than attempting to implement software-style message passing.*