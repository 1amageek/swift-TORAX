# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-TORAX is a Swift implementation of Google DeepMind's TORAX (https://github.com/google-deepmind/torax), a differentiable tokamak core transport simulator. The goal is to leverage Swift 6.2 and Apple's MLX framework (instead of JAX) to achieve high-performance fusion plasma simulations optimized for Apple Silicon.

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

## Swift 6 Concurrency and MLXArray

### The Challenge

MLXArray is **not Sendable** by design - it's a reference type (class) that wraps a C++ `mlx_array` with reference counting. However, Swift 6's strict concurrency requires all data crossing actor boundaries or async contexts to be Sendable.

### Why We MUST Keep MLXArray Throughout Computation

**Critical requirement**: The entire computation chain must remain as MLXArray for:

1. **Automatic Differentiation**: `grad()` requires an unbroken computation graph
   ```swift
   // Newton-Raphson needs this:
   let jacobian = grad(computeResidual)(profiles)  // Must be MLXArray chain
   ```

2. **compile() Optimization**: Graph must be continuous for fusion and optimization
   ```swift
   let step = compile { state in
       // All operations on MLXArray - optimized as single kernel
       let coeffs = calculateCoeffs(state.profiles)  // MLXArray
       let residual = computeResidual(state.profiles, coeffs)  // MLXArray
       return solveNewton(residual)  // MLXArray
   }
   ```

3. **Iterative Solvers**: 10-100 iterations per timestep
   - Converting to Swift arrays would break the computation graph
   - 30 Newton iterations × conversion overhead = unacceptable
   - Need continuous MLXArray chain for grad() at each iteration

### The Solution: Type-Safe EvaluatedArray Wrapper

**KEY DESIGN DECISION**: We use a type-safe wrapper to enforce evaluation at compile time, not runtime comments.

```swift
/// Type-safe wrapper ensuring MLXArray has been evaluated
/// This is the ONLY type marked @unchecked Sendable
public struct EvaluatedArray: @unchecked Sendable {
    private let array: MLXArray

    /// Only way to create: forces evaluation
    public init(evaluating array: MLXArray) {
        eval(array)  // Guaranteed evaluation
        self.array = array
    }

    /// Batch evaluation for efficiency
    public static func evaluatingBatch(_ arrays: [MLXArray]) -> [EvaluatedArray] {
        // Force evaluation of all arrays
        arrays.forEach { eval($0) }
        return arrays.map { EvaluatedArray(preEvaluated: $0) }
    }

    private init(preEvaluated: MLXArray) {
        self.array = preEvaluated
    }

    /// Read-only access to evaluated array
    public var value: MLXArray { array }

    // MARK: - Convenience accessors

    /// Shape of the evaluated array
    public var shape: [Int] { array.shape }

    /// Number of dimensions
    public var ndim: Int { array.ndim }

    /// Data type
    public var dtype: DType { array.dtype }
}

/// Core data structures are now truly Sendable
public struct CoreProfiles: Sendable {
    public let ionTemperature: EvaluatedArray
    public let electronTemperature: EvaluatedArray
    public let electronDensity: EvaluatedArray
    public let poloidalFlux: EvaluatedArray
}

public struct TransportCoefficients: Sendable {
    public let chiIon: EvaluatedArray
    public let chiElectron: EvaluatedArray
    public let particleDiffusivity: EvaluatedArray
    public let convectionVelocity: EvaluatedArray
}
```

### Why This Design is Superior

1. **Type-Level Safety**: Cannot create unevaluated arrays that cross actor boundaries
2. **No Comment Dependencies**: Compiler enforces evaluation, not developer discipline
3. **Minimal @unchecked Sendable**: Only `EvaluatedArray` needs it, not every data structure
4. **Clear Intent**: `EvaluatedArray` vs `MLXArray` clearly communicates evaluation state
5. **Batch Optimization**: `evaluatingBatch()` enables efficient multi-array evaluation

### Data Flow Pattern

```swift
// 1. Computation layer: Use MLXArray for chained operations
func computeTransport(_ profiles: CoreProfiles) -> TransportCoefficients {
    // Extract lazy MLXArrays for computation
    let ti = profiles.ionTemperature.value
    let te = profiles.electronTemperature.value

    // Chain operations (lazy)
    let chiIon = exp(-1000.0 / ti)
    let chiElectron = exp(-1000.0 / te)

    // Force evaluation before wrapping
    return TransportCoefficients(
        chiIon: EvaluatedArray(evaluating: chiIon),
        chiElectron: EvaluatedArray(evaluating: chiElectron),
        particleDiffusivity: EvaluatedArray(evaluating: chiElectron * 0.5),
        convectionVelocity: EvaluatedArray.zeros([profiles.ionTemperature.shape[0]])
    )
}

// 2. Batch evaluation for efficiency
func computeStep(_ profiles: CoreProfiles) -> CoreProfiles {
    let ti = profiles.ionTemperature.value
    let te = profiles.electronTemperature.value
    let ne = profiles.electronDensity.value
    let psi = profiles.poloidalFlux.value

    // All operations are lazy
    let newTi = ti + computeDeltaTi(ti, te)
    let newTe = te + computeDeltaTe(ti, te, ne)
    let newNe = ne + computeDeltaNe(ne, psi)
    let newPsi = psi + computeDeltaPsi(psi)

    // Single batch evaluation (efficient)
    let evaluated = EvaluatedArray.evaluatingBatch([newTi, newTe, newNe, newPsi])

    return CoreProfiles(
        ionTemperature: evaluated[0],
        electronTemperature: evaluated[1],
        electronDensity: evaluated[2],
        poloidalFlux: evaluated[3]
    )
}

// 3. I/O boundary: Convert for serialization
struct SerializableProfiles: Sendable, Codable {
    let ionTemperature: [Float]
    let electronTemperature: [Float]
    let electronDensity: [Float]
    let poloidalFlux: [Float]
}

extension CoreProfiles {
    func toSerializable() -> SerializableProfiles {
        SerializableProfiles(
            ionTemperature: ionTemperature.value.asArray(Float.self),
            electronTemperature: electronTemperature.value.asArray(Float.self),
            electronDensity: electronDensity.value.asArray(Float.self),
            poloidalFlux: poloidalFlux.value.asArray(Float.self)
        )
    }
}

// 4. Safe usage across actors
let profiles = computeStep(initialProfiles)
// Safe: EvaluatedArray guarantees evaluation
await actor1.process(profiles)
await actor2.analyze(profiles)
// Convert only for output
try profiles.toSerializable().saveToFile("output.json")
```

### Actor Isolation and compile()

**CRITICAL**: Swift 6 forbids capturing actor `self` in `compile()` closures.

#### ❌ WRONG: Actor Self Capture
```swift
public actor SimulationOrchestrator {
    private let transport: any TransportModel

    init(...) {
        // ❌ Undefined behavior: captures actor self
        self.compiledStep = compile { state in
            self.transport.compute(...)  // Actor self escapes!
        }
    }
}
```

#### ✅ CORRECT: Pure Function Compilation
```swift
public actor SimulationOrchestrator {
    private let staticParams: StaticRuntimeParams
    private let transport: any TransportModel
    private let sources: any SourceModel

    // Compiled pure function (no actor dependency)
    private let compiledStep: (CoreProfiles, DynamicRuntimeParams) -> CoreProfiles

    public init(
        staticParams: StaticRuntimeParams,
        transport: any TransportModel,
        sources: any SourceModel
    ) {
        self.staticParams = staticParams
        self.transport = transport
        self.sources = sources

        // Compile a pure function with all dependencies captured
        self.compiledStep = compile(
            Self.makeStepFunction(
                staticParams: staticParams,
                transport: transport,
                sources: sources
            )
        )
    }

    /// Create pure function (not actor-isolated)
    private static func makeStepFunction(
        staticParams: StaticRuntimeParams,
        transport: any TransportModel,
        sources: any SourceModel
    ) -> (CoreProfiles, DynamicRuntimeParams) -> CoreProfiles {
        return { profiles, dynamicParams in
            // Pure computation - all dependencies captured
            let geometry = Geometry(config: staticParams.mesh)
            let transportCoeffs = transport.computeCoefficients(
                profiles: profiles,
                geometry: geometry,
                params: dynamicParams.transportParams
            )
            let sourceTerms = sources.computeTerms(
                profiles: profiles,
                geometry: geometry,
                params: dynamicParams.sourceParams
            )
            // ... Newton-Raphson solver
            return updatedProfiles
        }
    }

    public func step(
        _ profiles: CoreProfiles,
        dynamicParams: DynamicRuntimeParams
    ) async -> CoreProfiles {
        // Call compiled function (no actor isolation issues)
        return compiledStep(profiles, dynamicParams)
    }
}
```

### CoeffsCallback Design: Synchronous API

**CRITICAL**: MLX operations are synchronous. Do NOT use async unnecessarily.

```swift
/// Synchronous callback for coefficient computation
public typealias CoeffsCallback = @Sendable (CoreProfiles, Geometry) -> Block1DCoeffs

/// Design Pattern: Closure Capture for Additional Context
///
/// The callback accepts only (CoreProfiles, Geometry) to keep the signature simple.
/// Additional context (dynamicParams, staticParams, transport models, etc.) is
/// provided via closure capture from the enclosing scope.
///
/// Example:
/// let coeffsCallback: CoeffsCallback = { profiles, geometry in
///     // Capture transport, sources, dynamicParams from outer scope
///     let transportCoeffs = transport.computeCoefficients(
///         profiles: profiles,
///         geometry: geometry,
///         params: dynamicParams.transportParams  // Captured
///     )
///     return buildBlock1DCoeffs(transport: transportCoeffs, ...)
/// }
///
/// This allows the solver to remain agnostic about parameter sources while
/// maintaining access to all necessary context through closure capture.

/// Thread-safe synchronous cache
public final class CoeffsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [CacheKey: Block1DCoeffs] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    /// Synchronous cache lookup and computation
    public func getOrCompute(
        profiles: CoreProfiles,
        geometry: Geometry,
        compute: CoeffsCallback
    ) -> Block1DCoeffs {
        let key = CacheKey(profiles: profiles, geometry: geometry)

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] {
            return cached
        }

        // Compute while holding lock (prevents duplicate work)
        let result = compute(profiles, geometry)

        if cache.count >= maxEntries {
            cache.removeFirst()
        }
        cache[key] = result

        return result
    }
}

// Usage in solver
let coeffs = cache.getOrCompute(
    profiles: currentProfiles,
    geometry: geometry
) { profiles, geo in
    // Synchronous computation
    combineCoefficients(
        transport: transportModel.computeCoefficients(profiles, geo, params),
        sources: sourceModel.computeTerms(profiles, geo, params)
    )
}
```

### When to Use Each Approach

| Type | Sendable Status | Use Case | Example |
|------|----------------|----------|---------|
| `EvaluatedArray` | `@unchecked Sendable` | Evaluated MLXArray wrapper | Core infrastructure |
| Structs with `EvaluatedArray` | Pure `Sendable` | Data structures | CoreProfiles, TransportCoefficients |
| Pure `Sendable` | Pure `Sendable` | Configuration, I/O | SimulationConfig, SerializableProfiles |
| Actor | Thread-safe reference | Mutable state management | SimulationOrchestrator |
| Synchronous cache | `@unchecked Sendable` with locks | CoeffsCache | CoeffsCache |

## Architecture Philosophy

### TORAX Core Concepts (from original Python/JAX implementation)

1. **Static vs Dynamic Runtime Parameters**
   - `StaticRuntimeParams`: Parameters that trigger recompilation when changed (mesh config, solver type, which equations to evolve)
   - `DynamicRuntimeParams`: Time-dependent parameters that don't trigger recompilation (boundary conditions, source parameters)
   - Critical for MLX `compile()` optimization

2. **State Separation**
   - `CoreProfiles`: Only variables evolved by PDEs (Ti, Te, ne, psi) as `CellVariable` instances
   - `SimulationState`: Complete state including profiles + transport + sources + geometry + time
   - Do NOT conflate these two concepts

3. **FVM Data Structures**
   - `CellVariable`: Grid variables with boundary conditions (value, dr, face constraints)
   - `Block1DCoeffs`: Complete FVM coefficients (transient_in, transient_out, d_face, v_face, source_mat, source)
   - `CoeffsCallback`: Bridge between physics models and FVM solver, called iteratively during solving

4. **Solver Flow**
   - Physics models (transport, sources, pedestal) → `CoeffsCallback` → `Block1DCoeffs` → FVM solver
   - Solvers: Linear (Predictor-Corrector), Newton-Raphson (with auto-diff), Optimizer-based
   - Theta method for time discretization (θ=0: explicit, θ=0.5: Crank-Nicolson, θ=1: implicit)

### Swift-Specific Design Patterns

1. **Protocol-Oriented Design**
   - Use protocols for extensibility: `TransportModel`, `SourceModel`, `PDESolver`, `GeometryProvider`
   - Keep physics models as value types where possible

2. **Value Semantics**
   - Immutable structs for data: `CoreProfiles`, `Block1DCoeffs`, `Geometry`, `TransportCoefficients`
   - Reference types (`class`/`actor`) only for stateful orchestration

3. **MLX Module Integration**
   - Use `Module` protocol from MLX for components with mutable state
   - Leverage `Updatable` protocol for `compile()` to track state changes
   - Use `compile(inputs:outputs:shapeless:)` for stateful functions

4. **Actor-Based Concurrency**
   - `SimulationOrchestrator` as actor for thread-safe simulation management
   - Async/await for progress reporting and I/O

## Common Development Commands

### Build and Test
```bash
# Build the package
swift build

# Run all tests
swift test

# Run specific test
swift test --filter <TestName>

# Build in release mode (optimized)
swift build -c release
```

### Package Management
```bash
# Update dependencies
swift package update

# Resolve dependencies
swift package resolve

# Generate Xcode project (if needed)
swift package generate-xcodeproj
```

## Critical Implementation Guidelines

### MLX Optimization Best Practices

1. **Compilation Strategy**
   ```swift
   // Compile entire step function with shapeless=true
   let compiledStep = compile(
       inputs: [state],
       outputs: [state],
       shapeless: true  // Prevents recompilation on grid size changes
   )(stepFunction)
   ```

2. **Evaluation Timing**
   ```swift
   // Evaluate at end of each time step, not more frequently
   for step in 0..<nSteps {
       state = compiledStep(state)
       eval(state.coreProfiles)  // Explicit evaluation
   }
   ```

3. **Memory Management**
   ```swift
   // Monitor GPU memory
   let snapshot = MLX.GPU.snapshot()

   // Set cache limits if needed
   MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024)  // 1GB
   ```

4. **Efficient Jacobian Computation**

   Newton-Raphson requires Jacobian computation at each iteration. Computing gradients for each variable separately is inefficient.

   **❌ Inefficient: 4 separate grad() calls**
   ```swift
   // 4n function evaluations for n×n Jacobian
   let dR_dTi = grad { Ti in residualFn(Ti, Te, ne, psi) }(Ti)
   let dR_dTe = grad { Te in residualFn(Ti, Te, ne, psi) }(Te)
   let dR_dNe = grad { ne in residualFn(Ti, Te, ne, psi) }(ne)
   let dR_dPsi = grad { psi in residualFn(Ti, Te, ne, psi) }(psi)
   // Jacobian assembly from 4 blocks...
   ```

   **✅ Efficient: Flattened state with vjp()**
   ```swift
   /// Flattened state vector for efficient Jacobian computation
   public struct FlattenedState: Sendable {
       public let values: EvaluatedArray
       public let layout: StateLayout

       /// Memory layout for state variables
       public struct StateLayout: Sendable, Equatable {
           public let nCells: Int
           public let tiRange: Range<Int>   // [0, nCells)
           public let teRange: Range<Int>   // [nCells, 2*nCells)
           public let neRange: Range<Int>   // [2*nCells, 3*nCells)
           public let psiRange: Range<Int>  // [3*nCells, 4*nCells)

           public init(nCells: Int) throws {
               guard nCells > 0 else {
                   throw FlattenedStateError.invalidCellCount(nCells)
               }
               self.nCells = nCells
               self.tiRange = 0..<nCells
               self.teRange = nCells..<(2*nCells)
               self.neRange = (2*nCells)..<(3*nCells)
               self.psiRange = (3*nCells)..<(4*nCells)
           }

           public var totalSize: Int { 4 * nCells }

           /// Validate layout consistency
           public func validate() throws {
               guard tiRange.count == nCells,
                     teRange.count == nCells,
                     neRange.count == nCells,
                     psiRange.count == nCells else {
                   throw FlattenedStateError.inconsistentLayout
               }
               guard psiRange.upperBound == totalSize else {
                   throw FlattenedStateError.layoutMismatch
               }
           }
       }

       public init(profiles: CoreProfiles) throws {
           let nCells = profiles.ionTemperature.shape[0]
           let layout = try StateLayout(nCells: nCells)
           try layout.validate()

           // Extract MLXArrays from EvaluatedArrays and flatten: [Ti; Te; ne; psi]
           let flattened = concatenated([
               profiles.ionTemperature.value,
               profiles.electronTemperature.value,
               profiles.electronDensity.value,
               profiles.poloidalFlux.value
           ], axis: 0)

           // Wrap flattened result in EvaluatedArray
           self.values = EvaluatedArray(evaluating: flattened)
           self.layout = layout
       }

       /// Restore to CoreProfiles
       public func toCoreProfiles() -> CoreProfiles {
           // Extract MLXArray from EvaluatedArray
           let array = values.value

           // Slice array and wrap each slice in EvaluatedArray
           let extracted = EvaluatedArray.evaluatingBatch([
               array[layout.tiRange],
               array[layout.teRange],
               array[layout.neRange],
               array[layout.psiRange]
           ])

           return CoreProfiles(
               ionTemperature: extracted[0],
               electronTemperature: extracted[1],
               electronDensity: extracted[2],
               poloidalFlux: extracted[3]
           )
       }
   }

   /// Compute Jacobian via vector-Jacobian product (efficient)
   func computeJacobianViaVJP(
       _ residualFn: (MLXArray) -> MLXArray,
       _ x: MLXArray
   ) -> MLXArray {
       let n = x.shape[0]
       var jacobianTranspose: [MLXArray] = []

       for i in 0..<n {
           // Standard basis vector
           var cotangent = MLXArray.zeros([n])
           cotangent[i] = 1.0

           // vjp computes: J^T · cotangent
           let (_, vjp_result) = vjp(residualFn, primals: [x], cotangents: [cotangent])
           jacobianTranspose.append(vjp_result[0])
       }

       // Transpose to get Jacobian
       return MLX.stacked(jacobianTranspose, axis: 0).transposed()
   }

   // Usage in Newton-Raphson
   let flatState = try FlattenedState(profiles: currentProfiles)
   let jacobian = computeJacobianViaVJP(
       { stateVec in computeResidualFlat(stateVec, geometry, dt) },
       flatState.values.value
   )
   // Only n function evaluations instead of 4n!
   ```

   **Performance**: For 100-cell grid (400 variables), vjp approach is 3-4× faster than separate grad() calls.

### Solver Implementation Requirements

When implementing any solver, ensure it accepts all required arguments matching TORAX interface:
- `dt`, `staticParams`, `dynamicParamsT`, `dynamicParamsTplusDt`
- `geometryT`, `geometryTplusDt`
- `xOld` (tuple of CellVariables), `coreProfilesT`, `coreProfilesTplusDt`
- `coeffsCallback` for iterative coefficient calculation

### FVM Discretization Details

- Use power-law scheme for Péclet weighting (transitions between central differencing and upwinding)
- Handle boundary conditions via ghost cells
- Flux decomposition: diffusion + convection terms
- Theta method for time discretization

## Future Extensions (Based on TORAX Paper arXiv:2406.06718v2)

The architecture is designed for extensibility to support planned enhancements from the original TORAX roadmap:

### High Priority Extensions

1. **Forward Sensitivity Analysis**
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

2. **Time-Dependent Geometry**
   - Support evolving magnetic equilibrium
   - Implement time derivatives for moving boundaries
   - Use spline interpolation for smooth geometry evolution

   ```swift
   protocol GeometryProvider {
       func geometry(at time: Float) -> Geometry
       func geometryTimeDerivative(at time: Float) -> GeometryDerivative
   }
   ```

3. **Flexible Configuration System**
   - Use Swift Configuration for hierarchical configs
   - Support environment variables and command-line overrides
   - Time-series and functional parameter specifications

   ```swift
   struct DynamicRuntimeParamsConfig: Codable {
       var constant: [String: Float]?
       var timeSeries: [String: TimeSeries]?
       var predefinedFunctions: [String: PredefinedFunction]?
   }
   ```

4. **Stationary State Solver**
   - Solve steady-state equations directly (∂/∂t = 0)
   - Use Newton-Raphson on residual function
   - Note: Must convert CoreProfiles to MLXArray tuple for grad()

   ```swift
   // Correct approach: differentiate w.r.t. individual arrays
   let dR_dTi = grad { Ti_var in residualFn(Ti_var, Te, ne, psi) }(Ti)
   let dR_dTe = grad { Te_var in residualFn(Ti, Te_var, ne, psi) }(Te)
   // ... construct Jacobian from partial derivatives
   ```

5. **Compilation Cache Strategy**
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

6. **Modular Physics Model Registry**
   - Dynamically load transport/source/pedestal models
   - Register custom models at runtime
   - Configuration-driven model selection

7. **Multi-Ion Species and Impurity Transport**
   - Extend CoreProfiles to handle multiple ion species
   - Implement impurity radiation models

8. **MHD Models** (sawteeth, neoclassical tearing modes)

9. **Core-Edge Coupling**

### Important Design Constraints

**MLX Gradient Limitations:**
- `grad()` works on MLXArray or explicit tuples, NOT structs
- To differentiate w.r.t. CoreProfiles, must:
  1. Convert to tuple: `(Ti, Te, ne, psi) = profiles.asTuple()`
  2. Apply grad to each field separately
  3. Reconstruct full Jacobian

**Sendable Constraints:**
- No closures in enum cases (use protocols instead)
- All configuration types must be Codable and Sendable
- Custom interpolation via protocol, not function pointers

## Project Status

This is an early-stage project. The architecture has been designed to align with:
1. TORAX's proven simulation methodology (including paper roadmap)
2. MLX-Swift's performance characteristics and gradient semantics
3. Swift's language idioms and safety features (Swift 6 concurrency)

The immediate implementation priorities are:
1. Core data structures (CellVariable, Block1DCoeffs, CoreProfiles)
2. FVM foundation (discretization, flux calculation, boundary conditions)
3. Basic solvers (Linear, Newton-Raphson)
4. Geometry system with time-dependence support
5. Transport models (starting with simple constant model, then QLKNN)
6. Configuration system with Swift Configuration

## References

- Original TORAX: https://github.com/google-deepmind/torax
- TORAX Documentation: https://deepwiki.com/google-deepmind/torax
- MLX-Swift: https://github.com/ml-explore/mlx-swift
- MLX-Swift Documentation: https://deepwiki.com/ml-explore/mlx-swift
- swift-numerics : https://github.com/apple/swift-numerics
- swift-numerics Documentation: https://deepwiki.com/apple/swift-numerics
