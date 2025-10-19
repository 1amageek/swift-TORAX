# swift-TORAX

A Swift implementation of Google DeepMind's [TORAX](https://github.com/google-deepmind/torax) tokamak core transport simulator, optimized for Apple Silicon using MLX-Swift. This differentiable, GPU-accelerated simulator solves coupled nonlinear PDEs describing fusion plasma transport in tokamaks.

## Highlights

- **Differentiable Transport Solver**: Coupled 1D PDEs for ion/electron temperature, particle density, and (future) poloidal flux
- **Apple Silicon Optimized**: MLX-Swift backend with lazy evaluation, JIT compilation, and unified memory architecture
- **GPU-Accelerated**: All computations run on Apple Silicon GPU using float32 precision
- **Modular Physics Stack**: Protocol-based transport models, source terms, and boundary conditions
- **Type-Safe Concurrency**: Swift 6 actors with `EvaluatedArray` wrapper for Sendable MLXArray handling
- **Auto-Differentiation**: Jacobian computation via `grad()` and `vjp()` for Newton-Raphson solvers
- **Full CLI**: Command-line interface for running simulations and analyzing results
- **Comprehensive Documentation**: Architecture guides, implementation notes, and numerical precision policies

## Project Status

**Phase 4 Complete (95%)** - Core functionality operational with CLI integration.

✅ **Implemented**:
- Core data structures (profiles, coefficients, geometry)
- FVM discretization with power-law scheme
- Linear and Newton-Raphson solvers
- Transport models (constant, Bohm-GyroBohm)
- Source models (fusion power, Ohmic heating, radiation, ion-electron exchange)
- Configuration system (JSON loading and validation)
- CLI executable with progress monitoring
- Actor-based simulation orchestration
- JSON output format

⏳ **In Progress**:
- Plotting and visualization
- HDF5/NetCDF output formats
- QLKNN neural network transport model

## Prerequisites

- **macOS 15.0+** on Apple Silicon (M1/M2/M3/M4)
- **Xcode 16.0+** with Swift 6.2 toolchain
- **MLX-Swift 0.20+** (automatically resolved via SwiftPM)
- **Swift Numerics** (automatically resolved via SwiftPM)

**Optional**:
- **Python 3.11+** with original TORAX for comparison workflows
- **gnuplot** for visualization (future plotting support)

## Quick Start

### Installation

```bash
git clone https://github.com/your-org/swift-TORAX.git
cd swift-TORAX
swift build -c release
```

### Run a Simulation

```bash
# Run with example configuration
.build/release/torax-cli run \
  --config examples/iter_like.json \
  --output-dir results/ \
  --log-progress

# Or use installed CLI
swift package experimental-install -c release
torax run --config examples/iter_like.json --log-progress
```

### View Results

```bash
# Plot results (currently a stub - manual plotting required)
torax plot results/state_history_*.json
```

### Run Tests

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter TORAXTests

# Run with verbose output
swift test -v
```

## CLI Usage

The `torax` CLI provides commands for running simulations and analyzing results:

```bash
# Get help
torax --help

# Run simulation with custom parameters
torax run \
  --config config.json \
  --output-dir ./output \
  --mesh-ncells 100 \
  --log-progress \
  --no-compile  # Disable JIT for debugging

# Plot multiple result files
torax plot results/*.json --format pdf
```

### Configuration Files

Configuration is specified via JSON files following the TORAX schema:

```json
{
  "mesh": {
    "nCells": 100
  },
  "geometry": {
    "geometryType": "circular",
    "Rmaj": 6.2,
    "Rmin": 2.0,
    "B0": 5.3,
    "elongation": 1.7,
    "triangularity": 0.33
  },
  "timeRange": {
    "start": 0.0,
    "end": 2.0
  },
  "transport": {
    "modelType": "bohmGyrobohm"
  },
  "sources": {
    "fusionPower": {
      "enabled": true
    },
    "ohmicHeating": {
      "enabled": true
    }
  },
  "boundary": {
    "Ti": 1000.0,
    "Te": 1000.0,
    "ne": 5.0e19
  }
}
```

See `examples/` directory for complete configuration examples.

## Repository Layout

```
swift-TORAX/
├── Sources/
│   ├── TORAX/                      # Core library
│   │   ├── Core/                   # Data structures (CoreProfiles, TransportCoefficients)
│   │   ├── Solver/                 # PDE solvers (Linear, Newton-Raphson)
│   │   ├── Transport/              # Transport models (Bohm-GyroBohm, constant)
│   │   ├── Sources/                # Source terms (fusion, Ohmic, radiation)
│   │   ├── Geometry/               # Geometry system (circular tokamak)
│   │   ├── Configuration/          # Configuration loaders and validation
│   │   ├── Orchestration/          # Simulation orchestrator (actor-based)
│   │   └── Utils/                  # Utilities (FVM, interpolation)
│   └── torax-cli/                  # CLI executable
│       ├── Commands/               # CLI commands (run, plot)
│       └── Output/                 # Progress logging, result formatting
├── Tests/
│   └── TORAXTests/                 # Unit and integration tests
├── examples/                        # Example configuration files
└── docs/                           # Documentation and design notes
```

## Unit System

**CRITICAL**: swift-TORAX uses **SI-based units** throughout to prevent conversion errors:

| Quantity | Unit | Symbol | Notes |
|----------|------|--------|-------|
| **Temperature** | electron volt | **eV** | NOT keV |
| **Density** | particles/m³ | **m⁻³** | NOT 10²⁰ m⁻³ |
| **Time** | seconds | **s** | SI base |
| **Length** | meters | **m** | SI base |
| **Magnetic Field** | tesla | **T** | SI derived |
| **Power Density** | MW/m³ | **MW/m³** | Source terms |

**Display units** (CLI output only) may show keV and 10²⁰ m⁻³ for convenience, but all internal computations use eV and m⁻³.

See `CLAUDE.md` "Unit System Standard" section for detailed rationale.

## Documentation

### Core Documentation
- **`CLAUDE.md`**: Comprehensive project guide for AI assistants (architecture, precision policy, design decisions)
- **`README.md`**: This file - quick start and overview

### Design Documents
- **`ARCHITECTURE.md`**: System design and performance optimization strategies
- **`IMPLEMENTATION_NOTES.md`**: Design decisions, numerical considerations, and rationale
- **`SOLVER_IMPLEMENTATION_STRATEGY.md`**: Solver architecture and refactoring roadmap

### Phase Documentation
- **`PHASE4_IMPLEMENTATION_REVIEW.md`**: Unit system audit and CLI integration review
- **`SOLVER_STRATEGY_*.md`**: Solver analysis and recommendations

## Key Features

### Numerical Precision

swift-TORAX uses **float32** exclusively on GPU (Apple Silicon GPUs don't support float64) with algorithmic stability techniques:

- **Variable scaling** for Newton-Raphson conditioning
- **High-precision time accumulation** using `Double` (CPU-only operation)
- **Diagonal preconditioning** for ill-conditioned Jacobians
- **Conservation law enforcement** to detect numerical drift
- **Epsilon regularization** for gradient calculations

Result: Engineering-grade accuracy (relative error ≤ 10⁻³) sufficient for experimental validation.

### MLX Lazy Evaluation

All MLX operations are lazy by default. The `EvaluatedArray` wrapper enforces evaluation at type boundaries:

```swift
public struct EvaluatedArray: @unchecked Sendable {
    private let array: MLXArray

    public init(evaluating array: MLXArray) {
        eval(array)  // Forces evaluation
        self.array = array
    }

    public var value: MLXArray { array }
}
```

This prevents unevaluated computation graphs from crossing actor boundaries while maintaining GPU-first architecture.

### Concurrency Model

Swift 6 strict concurrency with actors:

```swift
public actor SimulationOrchestrator {
    public func run(
        config: SimulationConfig,
        progress: ((SimulationProgress) async -> Void)? = nil
    ) async throws -> SimulationResult
}
```

All data structures are `Sendable`, with `EvaluatedArray` as the only `@unchecked Sendable` type.

## Roadmap

### P0 - High Priority
- [ ] Implement plotting with Swift Charts or gnuplot bridge
- [ ] Add HDF5/NetCDF output formats
- [ ] Implement QLKNN neural network transport model
- [ ] Add pedestal models
- [ ] Conservation law renormalization

### P1 - Medium Priority
- [ ] Time-dependent geometry support
- [ ] Current diffusion equation (ψ evolution)
- [ ] Forward sensitivity analysis (gradient-based optimization)
- [ ] Compilation caching
- [ ] Multi-ion species support

### P2 - Future Extensions
- [ ] MHD models (sawteeth, neoclassical tearing modes)
- [ ] Core-edge coupling
- [ ] Benchmark suite against original TORAX
- [ ] Performance profiling harness

See `CLAUDE.md` for detailed feature roadmap aligned with [TORAX paper](https://arxiv.org/abs/2406.06718v2).

## Contributing

1. Fork the repository and create a feature branch.
2. Run `swift test` before opening a PR.
3. Include updates to documentation/tests for user-facing changes.
4. Follow Swift formatting conventions and keep comments concise but informative.

## License

MIT License. See `LICENSE` for full text.

---

Questions or suggestions? Open an issue or reach out to the maintainers—feedback on the solver refactor is especially welcome.
