# Product Guidelines - 5G NR LDPC Encoder IP

## Documentation Style
- **Tone:** Technical and Concise.
- **Audience:** Senior hardware engineers and physical layer researchers.
- **Directives:** Use direct language. Focus on technical substance and rationale. Avoid conversational filler.

## Design Principles
- **Timing-First Design:** Prioritize timing closure and ease of routing. Ensure the architecture supports high-speed operation without complex logic paths that hinder timing at target frequencies.
- **Functionality First:** Focus on achieving architectural correctness and HUE (Hardware Usage Efficiency) optimization as described in the reference paper. Interface details (AXI, register mapping) are secondary to core functional performance.
- **Synthesizability:** All RTL must be strictly synthesizable for Xilinx Vivado. Use platform-specific primitives (DSP48, BRAM) when they provide clear timing or resource benefits.

## Branding and Naming
- **Naming Convention:** Unified snake_case (e.g., `ldpc_encoder_core`, `input_buffer_ctrl`).
- **Consistency:** Apply snake_case naming consistently across RTL filenames, module names, and technical documentation.
