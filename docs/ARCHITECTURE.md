# Architecture

## Project Overview

swift-Gotenx is a Swift implementation of Google DeepMind's TORAX (https://github.com/google-deepmind/torax), a differentiable tokamak core transport simulator. The goal is to leverage Swift 6.2 and Apple's MLX framework (instead of JAX) to achieve high-performance fusion plasma simulations optimized for Apple Silicon.

### Key Technologies

- **Swift 6.2**: Modern language features including strict concurrency, value semantics, and protocol-oriented design
- **MLX-Swift**: Apple's array framework for machine learning on Apple Silicon, providing:
  - Lazy evaluation and computation graph optimization
  - Unified memory architecture (CPU/GPU share memory)
  - Automatic differentiation via `grad()`, `valueAndGrad()`
  - JIT compilation via `compile()` for performance
  - Native Apple Silicon optimization
- **Swift Numerics**: Advanced numerical computing capabilities:
  - Special functions (gamma, erfc) for plasma physics calculations
  - Complex numbers for frequency domain analysis and eigenvalue problems
  - High-precision arithmetic (Augmented) for numerical stability
  - Integer utilities for grid calculations
- **Swift Configuration**: Type-safe configuration management for simulation parameters
- **NetCDF-4**: Output files compressed with DEFLATE and chunked along time for high compression ratios

### Mathematical Library Usage Strategy

Different mathematical operations use different libraries based on their characteristics:

**Use MLX for tensor/array operations** (runs on GPU, auto-differentiable):
- Basic math: `exp()`, `log()`, `sin()`, `cos()`, `sqrt()`, `pow()`
- Array operations: `matmul()`, `sum()`, `mean()`, reductions
- Error function: `erf()`, `erfInverse()`
- All operations on `MLXArray` that need gradients

**Use Swift Numerics for scalar/specialized operations**:
- Special functions not in MLX: `gamma()`, `logGamma()`, `erfc()`
- Complex number arithmetic: For eigenvalue solvers, frequency analysis
- High-precision calculations: Using `Augmented` types for critical numerical stability
- Scalar math on Swift native types (`Float`, `Double`)

**Example usage patterns**:
```swift
import MLX
import Numerics

// MLX for array operations (GPU-accelerated, differentiable)
let temperatures: MLXArray = ...
let rates = exp(-activationEnergy / temperatures)  // Element-wise on GPU

// Swift Numerics for scalar special functions
let coulombLog = Float.gamma(z) * Float.erfc(x)

// Complex eigenvalue analysis
let eigenvalues: [Complex<Double>] = computeEigenvalues(matrix)

// High-precision accumulation
var sum = Float.Augmented.zero
for value in criticalValues {
    sum += Float.Augmented(value)
}
```

**Key decision rule**: If the operation needs to be part of a computation graph for auto-differentiation or should run on GPU, use MLX. For scalar special functions or complex numbers, use Swift Numerics.

---

## TORAX Core Concepts

From the original Python/JAX implementation:

### 1. Static vs Dynamic Runtime Parameters

- `StaticRuntimeParams`: Parameters that trigger recompilation when changed (mesh config, solver type, which equations to evolve)
- `DynamicRuntimeParams`: Time-dependent parameters that don't trigger recompilation (boundary conditions, source parameters)
- Critical for MLX `compile()` optimization

### 2. State Separation

- `CoreProfiles`: Only variables evolved by PDEs (Ti, Te, ne, psi) as `CellVariable` instances
- `SimulationState`: Complete state including profiles + transport + sources + geometry + time
- **Do NOT conflate these two concepts**

### 3. FVM Data Structures

- `CellVariable`: Grid variables with boundary conditions (value, dr, face constraints)
- `Block1DCoeffs`: Complete FVM coefficients (transient_in, transient_out, d_face, v_face, source_mat, source)
- `CoeffsCallback`: Bridge between physics models and FVM solver, called iteratively during solving

### 4. Solver Flow

- Physics models (transport, sources, pedestal) → `CoeffsCallback` → `Block1DCoeffs` → FVM solver
- Solvers: Linear (Predictor-Corrector), Newton-Raphson (with auto-diff), Optimizer-based
- Theta method for time discretization (θ=0: explicit, θ=0.5: Crank-Nicolson, θ=1: implicit)

---

## Swift-Specific Design Patterns

### 1. Protocol-Oriented Design

- Use protocols for extensibility: `TransportModel`, `SourceModel`, `PDESolver`, `GeometryProvider`
- Keep physics models as value types where possible

### 2. Value Semantics

- Immutable structs for data: `CoreProfiles`, `Block1DCoeffs`, `Geometry`, `TransportCoefficients`
- Reference types (`class`/`actor`) only for stateful orchestration

### 3. MLX Module Integration

- Use `Module` protocol from MLX for components with mutable state
- Leverage `Updatable` protocol for `compile()` to track state changes
- Use `compile(inputs:outputs:shapeless:)` for stateful functions

### 4. Actor-Based Concurrency

- `SimulationOrchestrator` as actor for thread-safe simulation management
- Async/await for progress reporting and I/O

---

## Critical Implementation Guidelines

### MLX Optimization Best Practices

#### 1. Compilation Strategy

```swift
// Compile entire step function with shapeless=true
let compiledStep = compile(
    inputs: [state],
    outputs: [state],
    shapeless: true  // Prevents recompilation on grid size changes
)(stepFunction)
```

#### 2. Evaluation Timing

```swift
// Evaluate at end of each time step, not more frequently
for step in 0..<nSteps {
    state = compiledStep(state)
    eval(state.coreProfiles)  // Explicit evaluation
}
```

#### 3. Memory Management

```swift
// Monitor GPU memory
let snapshot = MLX.GPU.snapshot()

// Set cache limits if needed
MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024)  // 1GB
```

#### 4. Efficient Jacobian Computation

Newton-Raphson requires Jacobian computation at each iteration. Computing gradients for each variable separately is inefficient.

**❌ Inefficient: 4 separate grad() calls**
```swift
// 4n function evaluations for n×n Jacobian
let dR_dTi = grad { Ti in residualFn(Ti, Te, ne, psi) }(Ti)
let dR_dTe = grad { Te in residualFn(Ti, Te, ne, psi) }(Te)
let dR_dNe = grad { ne in residualFn(Ti, Te, ne, psi) }(ne)
let dR_dPsi = grad { psi in residualFn(Ti, Te, ne, psi) }(psi)
```

**✅ Efficient: Flattened state with vjp()**
```swift
/// Flattened state vector for efficient Jacobian computation
public struct FlattenedState: Sendable {
    public let values: EvaluatedArray
    public let layout: StateLayout

    public init(profiles: CoreProfiles) throws {
        // Flatten: [Ti; Te; ne; psi]
        let flattened = concatenated([
            profiles.ionTemperature.value,
            profiles.electronTemperature.value,
            profiles.electronDensity.value,
            profiles.poloidalFlux.value
        ], axis: 0)

        self.values = EvaluatedArray(evaluating: flattened)
        // ...
    }
}

/// Compute Jacobian via vector-Jacobian product (efficient)
func computeJacobianViaVJP(_ residualFn: (MLXArray) -> MLXArray, _ x: MLXArray) -> MLXArray {
    let n = x.shape[0]
    var jacobianTranspose: [MLXArray] = []

    for i in 0..<n {
        var cotangent = MLXArray.zeros([n])
        cotangent[i] = 1.0

        // vjp computes: J^T · cotangent
        let (_, vjp_result) = vjp(residualFn, primals: [x], cotangents: [cotangent])
        jacobianTranspose.append(vjp_result[0])
    }

    return MLX.stacked(jacobianTranspose, axis: 0).transposed()
}
```

**Performance**: For 100-cell grid (400 variables), vjp approach is 3-4× faster than separate grad() calls.

### Solver Implementation Requirements

When implementing any solver, ensure it accepts all required arguments matching Gotenx interface:
- `dt`, `staticParams`, `dynamicParamsT`, `dynamicParamsTplusDt`
- `geometryT`, `geometryTplusDt`
- `xOld` (tuple of CellVariables), `coreProfilesT`, `coreProfilesTplusDt`
- `coeffsCallback` for iterative coefficient calculation

### FVM Discretization Details

- Use power-law scheme for Péclet weighting (transitions between central differencing and upwinding)
- Handle boundary conditions via ghost cells
- Flux decomposition: diffusion + convection terms
- Theta method for time discretization

---

## Future Extensions

The architecture is designed for extensibility to support planned enhancements from the original TORAX roadmap (arXiv:2406.06718v2):

### High Priority Extensions

#### 1. Forward Sensitivity Analysis

- Enable gradient-based optimization and control
- Use `valueAndGrad()` to compute ∂output/∂parameters
- Requires flattening parameters into `DifferentiableParameters` struct

```swift
struct DifferentiableParameters: @unchecked Sendable {
    let values: MLXArray  // Flattened parameter vector
    let parameterMap: [String: Int]
}

protocol SensitivityComputable {
    func computeSensitivity(
        _ input: Input,
        parameters: DifferentiableParameters
    ) -> (output: Output, sensitivity: MLXArray)
}
```

#### 2. Time-Dependent Geometry

- Support evolving magnetic equilibrium
- Implement time derivatives for moving boundaries
- Use spline interpolation for smooth geometry evolution

```swift
protocol GeometryProvider {
    func geometry(at time: Float) -> Geometry
    func geometryTimeDerivative(at time: Float) -> GeometryDerivative
}
```

#### 3. Flexible Configuration System

- Use Swift Configuration for hierarchical configs
- Support environment variables and command-line overrides
- Time-series and functional parameter specifications

#### 4. Stationary State Solver

- Solve steady-state equations directly (∂/∂t = 0)
- Use Newton-Raphson on residual function
- Must convert CoreProfiles to MLXArray tuple for grad()

#### 5. Compilation Cache Strategy

- Cache compiled functions with type safety
- Use per-signature caches or generic wrappers
- Future: persistent disk cache (requires MLX support)

```swift
actor CompilationCacheManager {
    private var stepFunctionCache: [CacheKey: (SimulationState) -> SimulationState]

    func getOrCompileStepFunction(...) -> (SimulationState) -> SimulationState
}
```

### Medium Priority Extensions

- **Modular Physics Model Registry**: Dynamically load transport/source/pedestal models
- **Multi-Ion Species**: Extend CoreProfiles to handle multiple ion species
- **Impurity Transport**: Implement impurity radiation models
- **MHD Models**: Sawteeth, neoclassical tearing modes
- **Core-Edge Coupling**: Interface with edge plasma codes

---

## Important Design Constraints

### MLX Gradient Limitations

- `grad()` works on MLXArray or explicit tuples, NOT structs
- To differentiate w.r.t. CoreProfiles, must:
  1. Convert to tuple: `(Ti, Te, ne, psi) = profiles.asTuple()`
  2. Apply grad to each field separately
  3. Reconstruct full Jacobian

### Sendable Constraints

- No closures in enum cases (use protocols instead)
- All configuration types must be Codable and Sendable
- Custom interpolation via protocol, not function pointers

---

## NetCDF Compression Guidelines

- NetCDF profiles are written with DEFLATE level 6 (shuffle enabled), chunked along time with max 256 steps (`[min(256, nTime), nRho]`)
- This configuration achieves 51× compression ratio (verified in `Tests/GotenxTests/IO/NetCDF/NetCDFCompressionTests.swift`)
- CLI path compression ratio is measured in `Tests/GotenxCLITests/OutputWriterTests.swift` with expected 20-25× compression
- Validation tests `testChunkingStrategies` compare full-time chunking vs default chunking for different access patterns

---

## References

- **Original TORAX**: https://github.com/google-deepmind/torax
- **TORAX Paper**: arXiv:2406.06718v2 - "TORAX: A Differentiable Tokamak Transport Simulator"
- **MLX-Swift**: https://github.com/ml-explore/mlx-swift
- **Swift Numerics**: https://github.com/apple/swift-numerics
- **Swift Configuration**: https://github.com/apple/swift-configuration

---

*See also:*
- [NUMERICAL_PRECISION.md](NUMERICAL_PRECISION.md) for precision policies
- [MLX_BEST_PRACTICES.md](MLX_BEST_PRACTICES.md) for lazy evaluation patterns
- [SWIFT_CONCURRENCY.md](SWIFT_CONCURRENCY.md) for concurrency patterns
- [CONFIGURATION_SYSTEM.md](CONFIGURATION_SYSTEM.md) for configuration details
- [TRANSPORT_MODELS.md](TRANSPORT_MODELS.md) for transport model comparison
- [CLAUDE.md](../CLAUDE.md) for development guidelines
