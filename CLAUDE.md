# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-Gotenx is a Swift implementation of Google DeepMind's TORAX (https://github.com/google-deepmind/torax), a differentiable tokamak core transport simulator. It leverages Swift 6.2 and Apple's MLX framework to achieve high-performance fusion plasma simulations optimized for Apple Silicon.

**For detailed architecture information**: See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

### Key Technologies

- **Swift 6.2**: Strict concurrency, value semantics, protocol-oriented design
- **MLX-Swift**: GPU-accelerated array operations, automatic differentiation, JIT compilation
- **Swift Numerics**: Special functions (gamma, erfc), complex numbers, high-precision arithmetic
- **Swift Configuration**: Type-safe hierarchical configuration management
- **NetCDF-4**: Compressed output with DEFLATE level 6

### Quick Library Selection Guide

| Operation | Library | Reason |
|-----------|---------|--------|
| Array operations on GPU | MLX | Auto-differentiable, GPU-accelerated |
| Scalar special functions | Swift Numerics | `gamma()`, `erfc()`, Complex numbers |
| High-precision accumulation | Swift Numerics | `Float.Augmented` for time stepping |

**Detailed guidelines**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

## Documentation Structure

All detailed technical documentation has been extracted to `docs/` for easier maintenance:

| Topic | Document | Description |
|-------|----------|-------------|
| Architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | TORAX concepts, Swift patterns, future extensions |
| Unit System | [docs/UNIT_SYSTEM.md](docs/UNIT_SYSTEM.md) | SI-based units (eV, m⁻³), conversion guidelines |
| Configuration | [docs/CONFIGURATION_SYSTEM.md](docs/CONFIGURATION_SYSTEM.md) | Hierarchical config (CLI, env, JSON) |
| Numerical Precision | [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md) | Float32 policy, GPU constraints, stability |
| MLX Best Practices | [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md) | Lazy evaluation, eval() patterns |
| Swift Concurrency | [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md) | EvaluatedArray, actor isolation |
| Transport Models | [docs/TRANSPORT_MODELS.md](docs/TRANSPORT_MODELS.md) | Constant, Bohm-GyroBohm, QLKNN |

**Navigation**: [docs/README.md](docs/README.md)

---

## Critical Constraints for Development

### ⚠️ Apple Silicon GPU Limitations

**Float64 is NOT supported on Apple Silicon GPUs.** All MLXArray computations MUST use Float32.

```swift
// ❌ FAILS at runtime
let array = MLXArray([1.0, 2.0], dtype: .float64)

// ✅ WORKS
let array = MLXArray([1.0, 2.0], dtype: .float32)
```

**Mitigation**: Use algorithmic stability techniques (variable scaling, preconditioning, conservation enforcement) instead of higher precision.

**Full details**: [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md)

### ⚠️ MLX Lazy Evaluation

**Operations are NOT executed immediately** - they queue until `eval()` is called.

```swift
// ❌ WRONG: Unevaluated graph returned
let result = exp(-1000.0 / temperature)
return result

// ✅ CORRECT: Force evaluation
let result = exp(-1000.0 / temperature)
eval(result)
return result
```

**When eval() is mandatory**:
- End of computation chains
- Before wrapping in `EvaluatedArray` (automatic)
- Before crossing actor boundaries
- End of each timestep in loops

**Full details**: [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md)

### ⚠️ Swift 6 Concurrency

MLXArray is NOT Sendable. Use `EvaluatedArray` wrapper for all data crossing actor boundaries:

```swift
// ✅ Type-safe wrapper
public struct EvaluatedArray: @unchecked Sendable {
    public init(evaluating array: MLXArray) {
        eval(array)  // Guaranteed evaluation
        self.array = array
    }
    public var value: MLXArray { array }
}

// ✅ Sendable data structures
public struct CoreProfiles: Sendable {
    public let ionTemperature: EvaluatedArray
    public let electronTemperature: EvaluatedArray
    // ...
}
```

**Full details**: [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md)

### ⚠️ MLXArray Initialization

**CRITICAL**: MLXArray initialization methods differ from standard Swift arrays. Using incorrect initializers will cause compilation errors.

#### Common Mistakes and Corrections

**❌ WRONG - `repeating:` does NOT exist**:
```swift
let Ti = MLXArray(repeating: 5000.0, [nCells])  // ❌ Compilation error
let Te = MLXArray(repeating: 5000.0, [nCells])  // ❌ Compilation error
```

**✅ CORRECT - Use `MLXArray.full()`**:
```swift
let Ti = MLXArray.full([nCells], values: MLXArray(5000.0))
let Te = MLXArray.full([nCells], values: MLXArray(Float(5000.0)))
```

**❌ WRONG - `linspace` is NOT a standalone function**:
```swift
let psi = MLXArray(linspace(0.0, 1.0, count: nCells))  // ❌ Compilation error
```

**✅ CORRECT - Use `MLXArray.linspace()`**:
```swift
let psi = MLXArray.linspace(0.0, 1.0, count: nCells)
```

#### Standard Initialization Methods

```swift
// 1. Fill with constant value
let ones = MLXArray.full([nCells], values: MLXArray(1.0))
let constants = MLXArray.full([10, 20], values: MLXArray(Float(42.0)))

// 2. Zeros
let zeros = MLXArray.zeros([nCells])
let zerosMatrix = MLXArray.zeros([10, 20])

// 3. Ones
let ones = MLXArray.ones([nCells])
let onesMatrix = MLXArray.ones([10, 20])

// 4. Linearly spaced values
let linspace = MLXArray.linspace(0.0, 1.0, count: 100)  // [0.0, 0.01, 0.02, ..., 1.0]

// 5. From array literal
let array = MLXArray([Float(1.0), Float(2.0), Float(3.0)])
let array2D = MLXArray([[1.0, 2.0], [3.0, 4.0]])

// 6. Scalar value
let scalar = MLXArray(Float(42.0))
let scalar2 = MLXArray(3.14)
```

#### Data Type Specifications

```swift
// Explicit dtype (use .float32 for GPU compatibility)
let array = MLXArray.zeros([100], dtype: .float32)
let full = MLXArray.full([50], values: MLXArray(1.0), dtype: .float32)

// ⚠️ Remember: Float64 is NOT supported on Apple Silicon GPUs
let badArray = MLXArray.zeros([100], dtype: .float64)  // ❌ Will fail at runtime on GPU
```

#### Creating Arrays Like Another

```swift
let template = MLXArray.zeros([100])

// Create zeros with same shape
let zeros = MLXArray.zeros(like: template)

// Create ones with same shape
let ones = MLXArray.ones(like: template)
```

**Key Rules**:
1. Always use `MLXArray.` static methods for array creation
2. Use `MLXArray(value)` to wrap scalar values for `values:` parameter
3. Prefer explicit `Float()` casts to avoid type ambiguity
4. Use `.float32` dtype for GPU operations (default is usually fine)

---

## NetCDF Compression Guidelines

NetCDF profiles use DEFLATE level 6 with shuffle, chunked as `[min(256, nTime), nRho]`:
- Achieves 51× compression (verified in `NetCDFCompressionTests.swift`)
- CLI path expects 20-25× compression (`OutputWriterTests.swift`)
- Test `testChunkingStrategies` validates different access patterns

---

## Unit System Standard

**Critical**: Consistent SI-based units throughout to prevent 1000× errors.

| Quantity | Unit | Symbol | Notes |
|----------|------|--------|-------|
| Temperature | electron volt | **eV** | NOT keV |
| Density | particles/m³ | **m⁻³** | NOT 10²⁰ m⁻³ |
| Power | megawatts/m³ | **MW/m³** | Source terms only |

**Conversion point**: `Block1DCoeffsBuilder` converts MW/m³ → eV/(m³·s) via `UnitConversions.megawattsToEvDensity()`.

**Display units** (output only): Temperature in keV (`/1000`), density in 10²⁰ m⁻³ (`/1e20`).

**Full details**: [docs/UNIT_SYSTEM.md](docs/UNIT_SYSTEM.md)

---

## Configuration System

Hierarchical priority (highest to lowest):
1. CLI arguments (`--mesh-ncells 200`)
2. Environment variables (`GOTENX_MESH_NCELLS=150`)
3. JSON file
4. Default values

```swift
let configReader = try await GotenxConfigReader.create(
    jsonPath: "config.json",
    cliOverrides: ["runtime.static.mesh.nCells": "200"]
)
let config = try await configReader.fetchConfiguration()
```

**Full details**: [docs/CONFIGURATION_SYSTEM.md](docs/CONFIGURATION_SYSTEM.md)

---

## Transport Models

| Model | Use Case | Performance | Platform |
|-------|----------|-------------|----------|
| Constant | Testing/debugging | ~1μs | All |
| Bohm-GyroBohm | Fast empirical | ~10μs | All |
| QLKNN | High-fidelity physics | ~1ms | macOS only |

**Example**: See `Examples/Configurations/iter_like_qlknn.json` and `README_QLKNN.md`

**Full details**: [docs/TRANSPORT_MODELS.md](docs/TRANSPORT_MODELS.md)

---

## Common Development Commands

### Build and Test

```bash
# Build package
swift build

# Run tests
swift test

# Run specific test
swift test --filter <TestName>

# Release build
swift build -c release
```

### CLI Usage

```bash
# Run simulation
.build/release/GotenxCLI run --config Examples/Configurations/iter_like.json

# Install CLI
swift package experimental-install -c release
```

### Package Management

```bash
swift package update
swift package resolve
swift package show-dependencies
```

---

## Critical Implementation Guidelines

### MLX Optimization

**Compilation**:
```swift
let compiledStep = compile(
    inputs: [state],
    outputs: [state],
    shapeless: true  // Prevents recompilation on grid changes
)(stepFunction)
```

**Evaluation timing**:
```swift
for step in 0..<nSteps {
    state = compiledStep(state)
    eval(state.coreProfiles)  // Once per step
}
```

**Efficient Jacobian computation**: Use flattened state with `vjp()` instead of separate `grad()` calls.

**Full details**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md)

### Numerical Stability

Key strategies (all GPU-based):
1. **Variable scaling**: Normalize to O(1) for uniform precision
2. **Diagonal preconditioning**: Improve condition number κ ~ 10⁸ → 10⁴
3. **Epsilon regularization**: Prevent division by zero
4. **Conservation enforcement**: Periodic particle/energy renormalization
5. **Double for time**: CPU-only time accumulation (negligible cost)

**Full details**: [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md)

### Actor Isolation

**❌ DON'T** capture actor self in `compile()`:
```swift
// ❌ WRONG
self.compiledStep = compile { state in
    self.transport.compute(...)  // Actor self escapes!
}
```

**✅ DO** use pure functions:
```swift
// ✅ CORRECT
self.compiledStep = compile(
    Self.makeStepFunction(
        staticParams: staticParams,
        transport: transport,
        sources: sources
    )
)
```

**Full details**: [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md)

---

## SwiftUI Preview Best Practices

**CRITICAL**: `@Previewable` declarations MUST appear first in `#Preview` body:

```swift
#Preview("Example") {
    // ✅ CORRECT: @Previewable first
    @Previewable @State var value = 0
    @Previewable @State var isOn = false

    // ✅ Other declarations after
    let config = PlotConfiguration.default

    // ✅ View construction last
    MyView(value: $value, isOn: $isOn)
}
```

**Minimum**: iOS 17.0+, macOS 14.0+

---

## TORAX Core Concepts

Key architecture patterns from original Python/JAX implementation:

1. **Static vs Dynamic Parameters**
   - Static: Trigger recompilation (mesh, solver type, equations)
   - Dynamic: Hot-reloadable (boundaries, sources, transport)

2. **State Separation**
   - `CoreProfiles`: Variables evolved by PDEs (Ti, Te, ne, psi)
   - `SimulationState`: Complete state (profiles + transport + sources + geometry + time)

3. **FVM Data Structures**
   - `CellVariable`: Grid variables with boundary conditions
   - `Block1DCoeffs`: FVM coefficients (transient, diffusion, convection, source)
   - `CoeffsCallback`: Bridge between physics models and solver

4. **Solver Flow**
   - Physics models → `CoeffsCallback` → `Block1DCoeffs` → FVM solver
   - Theta method for time discretization (θ=1: implicit)

**Full details**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

## Future Extensions

Planned enhancements (from TORAX roadmap arXiv:2406.06718v2):

**High Priority**:
- Forward sensitivity analysis (gradient-based optimization)
- Time-dependent geometry (evolving equilibrium)
- Stationary state solver (∂/∂t = 0)
- Compilation caching

**Medium Priority**:
- Multi-ion species
- Impurity transport
- MHD models (sawteeth, NTMs)
- Core-edge coupling

**Full details**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/PHASE5_7_IMPLEMENTATION_PLAN.md](docs/PHASE5_7_IMPLEMENTATION_PLAN.md)

---

## Project Status

**Phase 4 Complete** (October 2025):
- ✅ Core simulation infrastructure
- ✅ Transport models (Constant, Bohm-GyroBohm, QLKNN)
- ✅ Source models (Fusion, Ohmic, Ion-Electron, Bremsstrahlung)
- ✅ Solvers (Linear, Newton-Raphson)
- ✅ CLI integration (GotenxCLI)
- ✅ NetCDF output with compression
- ✅ Conservation enforcement

**Current Capabilities**:
- Run time-stepping simulations with adaptive timesteps
- Compute transport coefficients (3 models)
- Apply source terms (4 types)
- Solve transport PDEs
- Save results to JSON/NetCDF
- Validate conservation laws

---

## References

### Original TORAX
- **GitHub**: https://github.com/google-deepmind/torax
- **Paper**: arXiv:2406.06718v2 - "TORAX: A Differentiable Tokamak Transport Simulator"
- **DeepWiki**: https://deepwiki.com/google-deepmind/torax

### MLX Framework
- **GitHub**: https://github.com/ml-explore/mlx-swift
- **DeepWiki**: https://deepwiki.com/ml-explore/mlx-swift

### Swift Packages
- **Swift Numerics**: https://github.com/apple/swift-numerics (https://deepwiki.com/apple/swift-numerics)
- **Swift Configuration**: https://github.com/apple/swift-configuration (https://deepwiki.com/apple/swift-configuration)
- **Swift Argument Parser**: https://github.com/apple/swift-argument-parser

### Fusion Science
- **QLKNN Paper**: van de Plassche et al., Physics of Plasmas 27, 022310 (2020)
- **QuaLiKiz**: Bourdelle et al., Physics of Plasmas 14, 112501 (2007)
- **Numerical Methods**: Higham, "Accuracy and Stability of Numerical Algorithms" (2002)

---

**For detailed information, see**: [docs/README.md](docs/README.md)

*Last updated: 2025-10-21* (Added MLXArray initialization guidelines)
