# Specification: Golden Algorithmic Model for LDPC Encoder

## Overview
Develop a golden algorithmic model for the 5G NR LDPC Encoder based on the architecture described in Petrović et al. (2021). The model will incorporate the Compressed Sparse Row (CSR) storage novelty. It is not intended to be cycle-accurate, but rather functionally accurate to provide reference outputs step-by-step for RTL verification.

## Functional Requirements
- **Language**: Python 3.
- **Algorithm**: Implement the 5G NR LDPC encoding algorithm as defined in the Petrović paper, specifically handling the shift-network and base graph processing.
- **CSR Integration**: The model must parse and load the CSR data directly from the existing `rtl/mem/` files to ensure strict alignment with the RTL implementation.
- **Verification Interface**: The model will be structured as an importable Python module. This allows cocotb testbenches to instantiate the model, pass inputs, and retrieve intermediate and final encoded parity bits on the fly.
- **Accuracy**: The model must produce mathematically correct LDPC parity check bits corresponding to the 5G NR standard.

## Non-Functional Requirements
- **Modularity**: Provide hooks or methods to retrieve intermediate data at various encoding steps (e.g., intermediate matrix multiplication results, shifted values) to compare against RTL pipeline stages.
- **Code Quality**: Adhere to the project's Python code style guidelines.

## Acceptance Criteria
- A standalone Python module exists that can correctly encode a block of 5G NR data.
- The model successfully parses the `rtl/mem/` CSR files.
- The module can be successfully imported into a cocotb testbench and used to generate expected results that match a known-good test vector.

## Out of Scope
- Cycle-accurate representation of the RTL pipeline.
- High-performance/optimized software encoding (correctness is prioritized over software speed).