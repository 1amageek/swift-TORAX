# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-Gotenx is a Swift implementation of Google DeepMind's TORAX (https://github.com/google-deepmind/torax), a differentiable tokamak core transport simulator. It leverages Swift 6.2 and Apple's MLX framework to achieve high-performance fusion plasma simulations optimized for Apple Silicon.

### Key Technologies

- **Swift 6.2**: Strict concurrency, value semantics, protocol-oriented design
- **MLX-Swift**: GPU-accelerated array operations, automatic differentiation, JIT compilation
- **Swift Numerics**: Special functions (gamma, erfc), complex numbers, high-precision arithmetic
- **Swift Configuration**: Type-safe hierarchical configuration management
- **NetCDF-4**: Compressed output with DEFLATE level 6

---

## 📚 Documentation Structure

All detailed technical documentation is in `docs/` for easier maintenance:

| Topic | Document | Purpose |
|-------|----------|---------|
| **Architecture** | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | TORAX concepts, Swift patterns, future extensions |
| **Unit System** | [docs/UNIT_SYSTEM.md](docs/UNIT_SYSTEM.md) | SI-based units (eV, m⁻³), conversion guidelines |
| **Configuration** | [docs/CONFIGURATION_SYSTEM.md](docs/CONFIGURATION_SYSTEM.md) | Hierarchical config (CLI, env, JSON) |
| **Numerical Precision** | [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md) | Float32 policy, GPU constraints, stability |
| **Numerical Robustness** | [docs/NUMERICAL_ROBUSTNESS_DESIGN.md](docs/NUMERICAL_ROBUSTNESS_DESIGN.md) | 🔥 **NaN crash prevention, validation** |
| **MLX Best Practices** | [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md) | Lazy evaluation, eval() patterns |
| **Swift Concurrency** | [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md) | EvaluatedArray, actor isolation |
| **Transport Models** | [docs/TRANSPORT_MODELS.md](docs/TRANSPORT_MODELS.md) | Constant, Bohm-GyroBohm, QLKNN |
| **🔥 FVM Improvements** | [docs/FVM_NUMERICAL_IMPROVEMENTS_PLAN.md](docs/FVM_NUMERICAL_IMPROVEMENTS_PLAN.md) | **PRIORITY**: Power-law scheme, Sauter bootstrap |

**Complete documentation catalog**: [docs/README.md](docs/README.md)

---

## ⚠️ Critical Constraints for Development

### Apple Silicon GPU Limitations

**Float64 is NOT supported on Apple Silicon GPUs.** All MLXArray computations MUST use Float32.

```swift
// ❌ FAILS at runtime
let array = MLXArray([1.0, 2.0], dtype: .float64)

// ✅ WORKS
let array = MLXArray([1.0, 2.0], dtype: .float32)
```

**Mitigation**: Use algorithmic stability techniques (variable scaling, preconditioning, conservation enforcement) instead of higher precision.

**Full details**: [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md)

---

### MLXArray Initialization

**CRITICAL**: MLXArray initialization methods differ from standard Swift arrays. Using incorrect initializers will cause compilation errors.

#### Common Mistakes and Corrections

**❌ WRONG - `repeating:` does NOT exist**:
```swift
let Ti = MLXArray(repeating: 5000.0, [nCells])  // ❌ Compilation error
```

**✅ CORRECT - Use `MLXArray.full()`**:
```swift
let Ti = MLXArray.full([nCells], values: MLXArray(5000.0))
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

// 2. Zeros and ones
let zeros = MLXArray.zeros([nCells])
let ones = MLXArray.ones([nCells])

// 3. Linearly spaced values
let linspace = MLXArray.linspace(0.0, 1.0, count: 100)

// 4. From array literal
let array = MLXArray([Float(1.0), Float(2.0), Float(3.0)])

// 5. Scalar value
let scalar = MLXArray(Float(42.0))
```

**Key Rules**:
1. Always use `MLXArray.` static methods for array creation
2. Use `MLXArray(value)` to wrap scalar values for `values:` parameter
3. Prefer explicit `Float()` casts to avoid type ambiguity
4. Use `.float32` dtype for GPU operations

**Full details**: [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md)

---

### MLX Lazy Evaluation

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

---

### Swift 6 Concurrency

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
}
```

**Full details**: [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md)

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

## Project Status

**Current Capabilities** (October 2025):
- ✅ Core simulation infrastructure
- ✅ Transport models (Constant, Bohm-GyroBohm, QLKNN)
- ✅ Source models (Fusion, Ohmic, Ion-Electron, Bremsstrahlung)
- ✅ Solvers (Linear, Newton-Raphson)
- ✅ CLI integration (GotenxCLI)
- ✅ NetCDF output with compression
- ✅ Conservation enforcement

**Priority Improvements**:
- 🔥 FVM numerical enhancements (power-law scheme, Sauter bootstrap) - See [docs/FVM_NUMERICAL_IMPROVEMENTS_PLAN.md](docs/FVM_NUMERICAL_IMPROVEMENTS_PLAN.md)
- 🚧 Configuration system refactoring - See [docs/CONFIGURATION_ARCHITECTURE_REFACTORING.md](docs/CONFIGURATION_ARCHITECTURE_REFACTORING.md)

---

## Quick Reference for Common Tasks

### Starting a New Feature
1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design patterns
2. Check relevant technical docs in [docs/README.md](docs/README.md)
3. Follow Swift 6 concurrency patterns from [docs/SWIFT_CONCURRENCY.md](docs/SWIFT_CONCURRENCY.md)

### Working with MLX
1. Use correct initialization: `MLXArray.full()`, `MLXArray.linspace()`
2. Call `eval()` at computation chain ends
3. Wrap results in `EvaluatedArray` for Sendable compliance

### Handling Configuration
1. Use hierarchical priority: CLI > Env > JSON > Default
2. Validate with `ConfigurationValidator` - See [docs/CONFIGURATION_VALIDATION_SPEC.md](docs/CONFIGURATION_VALIDATION_SPEC.md)
3. Follow CFL-aware defaults pattern

### Debugging Numerical Issues
1. **Encountering NaN/Inf crashes?** 🔥 See [docs/NUMERICAL_ROBUSTNESS_DESIGN.md](docs/NUMERICAL_ROBUSTNESS_DESIGN.md) for validation and crash prevention
2. Check Float32 constraints: [docs/NUMERICAL_PRECISION.md](docs/NUMERICAL_PRECISION.md)
3. Verify unit consistency: [docs/UNIT_SYSTEM.md](docs/UNIT_SYSTEM.md)
4. Review MLX evaluation patterns: [docs/MLX_BEST_PRACTICES.md](docs/MLX_BEST_PRACTICES.md)

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

---

**For detailed information, see**: [docs/README.md](docs/README.md)

*Last updated: 2025-10-25* (Documentation reorganization)
