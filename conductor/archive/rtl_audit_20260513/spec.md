# Specification - RTL Audit and Evaluation

## Goal
Map current RTL implementation to Petrović et al. (2021) architecture. Create initial understanding baseline for future development. Identify incomplete modules.

## Scope
- RTL files in `rtl/`.
- Petrović 2021 paper in `doc/`.
- Mapping RTL components to paper sections/figures.
- High-level module connectivity.
- Identify missing or skeleton-only modules.

## Deliverables
- `doc/architecture_mapping.md`: Table/Map linking RTL modules to paper concepts (e.g., Circular Shifter, λ-vector calculation).
- `doc/module_status.md`: Inventory of all modules with completion status (Complete / Incomplete / Skeleton).
- Interconnection map in `doc/`.

## Constraints
- **No Simulation:** Static analysis only.
- **Read-Only:** Do not modify RTL.
- **Assumptions:** Do not assume code works or is finished.
