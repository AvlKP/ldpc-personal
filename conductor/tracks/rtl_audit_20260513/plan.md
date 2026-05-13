# Implementation Plan - RTL Audit and Evaluation

## Phase 1: Paper to RTL Mapping
- [x] Task: Review Petrović paper architecture (Figures 10, 11).
- [x] Task: Associate `rtl/*.sv` files with paper components (e.g., CS network, Parity bit calculators).
- [~] Task: Create `doc/architecture_mapping.md` with initial findings.
- [ ] Task: Conductor - User Manual Verification 'Paper to RTL Mapping' (Protocol in workflow.md)

## Phase 2: Structural Inventory & Connectivity
- [ ] Task: Map top-level module hierarchy.
- [ ] Task: Document module interconnections in `doc/interconnect_map.md`.
- [ ] Task: Identify and document data flow through the encoder stages.
- [ ] Task: Conductor - User Manual Verification 'Structural Inventory & Connectivity' (Protocol in workflow.md)

## Phase 3: Completeness & Evaluation Baseline
- [ ] Task: Analyze each module for placeholder logic or "TODO" markers.
- [ ] Task: Create `doc/module_status.md` flagging incomplete/skeleton modules.
- [ ] Task: Perform baseline evaluation (resource/timing estimates) for "complete" modules.
- [ ] Task: Conductor - User Manual Verification 'Completeness & Evaluation Baseline' (Protocol in workflow.md)
