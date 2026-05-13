# Cocotb Best Practices & Methodology

This document outlines the standard practices for building Python-based verification environments using cocotb. It draws heavily from the object-oriented and software-driven methodologies advocated in Ray Salemi's *Python for RTL Verification*, focusing on utilizing standard Python features to replace complex SystemVerilog/UVM constructs.

---

## 1. Core Philosophy

* **Software Engineering Approach:** Treat your testbench as a standard Python software project. Leverage Object-Oriented Programming (OOP) to encapsulate behavior, promote reuse, and maintain clean namespaces.
* **Keep RTL and Testbench Separate:** The DUT (Design Under Test) should only contain synthesizable Verilog/SystemVerilog. All delays, checking logic, and stimulus generation must reside in the Python testbench.
* **Leverage Python Standard Libraries:** Instead of relying on complex, domain-specific hardware verification libraries (like UVM's TLM), use standard Python modules such as `queue`, `logging`, and built-in data structures (`list`, `dict`, `tuple`).

---

## 2. Object-Oriented Testbench Architecture

Do not write monolithic, procedural tests. Break the test environment down into modular classes.

### The Bus Functional Model (BFM)
Create a class to abstract the pin-level toggling away from the test logic. 
* **Encapsulation:** Pass the `dut` object into the BFM class during initialization so the BFM can access the signals.
* **Methods as Transactions:** Create methods like `send_op(a, b, op)` that handle the bit-level wiggling, allowing the main test to simply call these high-level functions.

### Drivers and Monitors
Separate the logic that drives the bus from the logic that observes the bus.
* **Drivers:** Coroutines that take high-level transactions and pass them to the BFM to drive onto the DUT.
* **Monitors:** Passive coroutines that continuously sample the DUT's outputs on a clock edge and report the observed transactions. 

### Scoreboards
* Use standard Python data structures to build your scoreboard.
* A common pattern is to use a Python `list` to store expected results calculated by a Python reference model, and then `.pop(0)` or compare against that list when the Monitor reports an actual result from the RTL.

---

## 3. Concurrency and Communication

Cocotb is asynchronous. Managing concurrent tasks (like running a driver, a monitor, and a clock generator simultaneously) is critical.

### Coroutines and Awaitables
* Always use `async def` to define your test and structural coroutines.
* Use `await` to yield control back to the simulator until a specific trigger occurs.

### Spawning Background Tasks
* Monitors and continuous checkers need to run in the background. Use `cocotb.start_soon()` to fork these processes so they run concurrently with the main test stimulus.
* **Example Pattern:**
    ```python
    # Start the monitor in the background
    cocotb.start_soon(my_monitor.observe_bus())
    ```

### Inter-Process Communication (The TLM Alternative)
* Do not reinvent complex Transaction Level Modeling (TLM) FIFOs.
* Use Python's built-in `queue.Queue` or `cocotb.queue.Queue` to pass transactions safely between your Monitors and your Scoreboard.
* A Monitor puts observed data into the queue; the Scoreboard awaits data from the queue and evaluates it.

---

## 4. Trigger Management

Triggers are how Python synchronizes with the hardware simulator. 

* **Clock Edges:** Use `await RisingEdge(dut.clk)` or `await FallingEdge(dut.clk)` for synchronous logic. Avoid arbitrary `#` time delays.
* **Timers:** If you must wait for a specific duration (e.g., waiting for a reset to settle), use `await Timer(10, units='ns')`.
* **Combining Triggers:** Use `First()` or `Combine()` if a coroutine needs to wake up on multiple potential events (e.g., waiting for a `ready` signal OR a `timeout` Timer).

---

## 5. Coding Standards & Best Practices

* **Logging:** Use cocotb's built-in logging (`dut._log.info()`, `dut._log.error()`) instead of standard `print()` statements. This ensures test output is formatted uniformly and timestamped by the simulator.
* **Assertions:** Liberally use standard Python `assert` statements within your scoreboards and test logic. If an `assert` fails, cocotb will automatically catch the exception and mark the test as a failure.
* **Factory Patterns for Tests:** Use parameterized testing or test factories (like `cocotb.regression.TestFactory`) to run the same sequence over multiple configurations or randomized inputs, maximizing coverage without duplicating code.