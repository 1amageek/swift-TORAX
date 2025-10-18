# swift-TORAX

Swift-based, differentiable implementation of the TORAX tokamak core transport simulator. The code targets Apple Silicon and builds on MLX-Swift to deliver high-performance, GPU-accelerated, auto-diff capable plasma transport simulations.

## Highlights

- Differentiable 1D transport solver covering ion/electron heat, particle density, and poloidal flux.
- MLX-backed compute kernels with lazy execution, compilation support, and GPU acceleration on Apple Silicon.
- Modular physics stack (`TransportModel`, `SourceModel`, `PedestalModel`) for rapid experimentation.
- Protocol-oriented solver layer with Newton–Raphson and linearized predictor/corrector paths.
- Strong typing around evaluated MLX tensors (`EvaluatedArray`) to preserve Sendable safety across actors.
- Detailed architecture and solver strategy documents (`ARCHITECTURE.md`, `SOLVER_IMPLEMENTATION_STRATEGY.md`, …).

## Project Status

Work in progress. The solver is actively being refactored toward per-equation coefficient handling, hybrid linear solves, and full alignment with the documented architecture. Expect API adjustments until a tagged release lands.

## Prerequisites

- macOS on Apple Silicon with Xcode 16 toolchain.
- Swift 6.2 (or current Trunk snapshot matching `Package.swift`).
- MLX-Swift 0.18+ (pulled automatically via SwiftPM).
- Python 3.11+ if you plan to mirror TORAX reference workflows (optional).

## Getting Started

Clone the repository and resolve dependencies:

```bash
git clone https://github.com/your-org/swift-TORAX.git
cd swift-TORAX
swift package resolve
```

### Build

```bash
swift build
```

### Run Example (stub)

```bash
swift run torax-cli --help
```

> A full CLI and sample configuration loader are planned; for now, integrate through unit/integration tests or embed the library in your own app.

### Test

```bash
swift test
```

Current test suites cover core data structures, FVM utilities, and flattening helpers. Broader solver/orchestrator integration tests are on the roadmap.

## Repository Layout

- `Sources/TORAX/Core/` – Immutable simulation data (profiles, coefficients, geometry).
- `Sources/TORAX/Solver/` – PDE solvers, coefficient builders, hybrid linear solve utilities.
- `Sources/TORAX/Transport/` – Transport model implementations.
- `Sources/TORAX/Orchestration/` – Actor-based simulation driver and state tracking.
- `Sources/TORAX/Configuration/` – Mesh/runtime configuration structures.
- `Tests/TORAXTests/` – Swift Testing suites.
- `ARCHITECTURE.md` – System-level design guide.
- `SOLVER_IMPLEMENTATION_STRATEGY.md` / `SOLVER_STRATEGY_*` – Solver refactor roadmap and analysis.

## Documentation

- `ARCHITECTURE.md`: Big picture overview and performance best practices.
- `SOLVER_IMPLEMENTATION_STRATEGY.md`: Current solver redesign plan.
- `SOLVER_STRATEGY_DEEP_ANALYSIS.md`, `SOLVER_STRATEGY_REVIEW.md`: Investigation notes and recommendations.
- `IMPLEMENTATION_NOTES.md`: Design decisions, apparent inconsistencies, and their rationale (interpolation methods, Float32 overflow fixes, etc.).

## Roadmap

- Finalize per-equation coefficient wiring and geometry helpers.
- Restore/expand orchestrator integration tests.
- Add surrogate transport models (e.g., QLKNN).
- Expose CLI tools and configuration loaders.
- Benchmark suite and profiling harness.

See `CLAUDE.md` for a more granular backlog aligned with the TORAX paper (arXiv:2406.06718v2).

## Contributing

1. Fork the repository and create a feature branch.
2. Run `swift test` before opening a PR.
3. Include updates to documentation/tests for user-facing changes.
4. Follow Swift formatting conventions and keep comments concise but informative.

## License

MIT License. See `LICENSE` for full text.

---

Questions or suggestions? Open an issue or reach out to the maintainers—feedback on the solver refactor is especially welcome.
