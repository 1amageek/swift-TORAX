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

## ⚠️ MLX Lazy Evaluation and eval() - CRITICAL

### The Lazy Evaluation System

**MLX-Swift uses lazy evaluation by design**. Operations on `MLXArray` are NOT executed immediately—they are deferred until explicitly materialized with `eval()` or `asyncEval()`.

```swift
// ❌ WRONG: Operations are queued, not executed!
let result = exp(-1000.0 / temperature)
return result  // Returns unevaluated computation graph ❌

// ✅ CORRECT: Force evaluation before returning
let result = exp(-1000.0 / temperature)
eval(result)  // Executes computation graph ✅
return result
```

### When eval() is MANDATORY

**YOU MUST call eval() in these situations:**

1. **At the END of a computation chain when values are actually needed**
   ```swift
   // ✅ CORRECT: Chain operations, eval at the end
   func computeTransport(Ti: MLXArray, Te: MLXArray) -> (MLXArray, MLXArray) {
       let chiIon = exp(-1000.0 / Ti)          // Lazy
       let chiElectron = exp(-1000.0 / Te)     // Lazy
       // Return lazy arrays - caller decides when to eval
       return (chiIon, chiElectron)
   }

   // Caller evaluates when needed
   let (chiIon, chiElectron) = computeTransport(Ti, Te)
   eval(chiIon, chiElectron)  // ✅ Eval when values are needed
   ```

2. **Before wrapping in EvaluatedArray** (automatic)
   ```swift
   // ✅ CORRECT: EvaluatedArray.init() calls eval() internally
   return TransportCoefficients(
       chiIon: EvaluatedArray(evaluating: chiIon),  // eval() called here
       chiElectron: EvaluatedArray(evaluating: chiElectron)
   )
   ```

3. **Before crossing actor boundaries**
   ```swift
   let profiles = computeProfiles(...)
   eval(profiles)  // ✅ Evaluate before sending to actor
   await actor.process(profiles)
   ```

4. **At the end of each time step in simulations**
   ```swift
   for step in 0..<nSteps {
       state = compiledStep(state)
       eval(state.coreProfiles)  // ✅ Evaluate per step
   }
   ```

5. **When accessing actual values** (often implicit)
   ```swift
   let result = compute(...)
   let value = result.item(Float.self)  // Implicit eval()
   let array = result.asArray(Float.self)  // Implicit eval()
   ```

### What Happens Without eval()

**Without eval(), you get:**
- ❌ **Unevaluated computation graphs** instead of actual values
- ❌ **Deferred memory allocation** - no storage for results
- ❌ **Unpredictable crashes** when graphs are accessed later
- ❌ **Incorrect numerical results** from stale or unexecuted operations
- ❌ **Memory leaks** from accumulating operation graphs

### Implicit Evaluation Triggers

These methods **automatically call eval() internally**:
- `array.item()` - Extracts scalar value
- `array.asArray(Type.self)` - Converts to Swift array
- `array.asData(noCopy:)` - Extracts raw data

**However**, relying on implicit evaluation is dangerous:

```swift
// ❌ BAD: Relying on implicit eval() in item()
func compute(...) -> MLXArray {
    let result = someOp(...)
    let _ = result.item()  // Triggers eval() as side effect
    return result  // But still feels hacky
}

// ✅ GOOD: Explicit eval() before return
func compute(...) -> MLXArray {
    let result = someOp(...)
    eval(result)  // Clear intent
    return result
}
```

### Best Practices

#### ✅ DO: Chain operations, eval at the end of computation
```swift
// ✅ GOOD: Let operations chain, eval when wrapping in EvaluatedArray
public func computeOhmicHeating(
    Te: MLXArray,
    jParallel: MLXArray,
    geometry: Geometry
) -> MLXArray {
    let eta = computeResistivity(Te, geometry)  // Lazy
    let Q_ohm = eta * jParallel * jParallel     // Lazy

    // Return lazy - caller will eval when wrapping in EvaluatedArray
    return Q_ohm
}

// Caller handles evaluation
let Q_ohm = ohmic.compute(Te, jParallel, geometry)
let source = SourceTerms(
    electronHeating: EvaluatedArray(evaluating: Q_ohm)  // eval() here
)
```

#### ✅ DO: Batch evaluation for efficiency
```swift
// Compute multiple results
let chiIon = exp(-1000.0 / Ti)
let chiElectron = exp(-1000.0 / Te)
let diffusivity = chiElectron * 0.5

// Batch evaluate (more efficient than 3 separate eval() calls)
eval(chiIon, chiElectron, diffusivity)

return TransportCoefficients(
    chiIon: EvaluatedArray(evaluating: chiIon),
    chiElectron: EvaluatedArray(evaluating: chiElectron),
    particleDiffusivity: EvaluatedArray(evaluating: diffusivity),
    convectionVelocity: .zeros([nCells])
)
```

#### ✅ DO: Use EvaluatedArray for type safety
```swift
// EvaluatedArray enforces evaluation at construction
public struct EvaluatedArray: @unchecked Sendable {
    private let array: MLXArray

    public init(evaluating array: MLXArray) {
        eval(array)  // ✅ Guaranteed evaluation
        self.array = array
    }
}
```

#### ❌ DON'T: Return unevaluated arrays
```swift
// ❌ WRONG: Unevaluated computation graph returned
func computeTransport(...) -> MLXArray {
    let chi = exp(-activation / temperature)
    return chi  // ❌ NO eval() - BUG!
}
```

#### ❌ DON'T: Evaluate too frequently in loops
```swift
// ❌ WRONG: eval() in tight loop (inefficient)
for i in 0..<nSteps {
    let x = operation1(...)
    eval(x)  // ❌ Too frequent
    let y = operation2(x)
    eval(y)  // ❌ Too frequent
}

// ✅ CORRECT: Accumulate operations, eval once per step
for i in 0..<nSteps {
    let x = operation1(...)
    let y = operation2(x)
    eval(y)  // ✅ Once per iteration
}
```

### Common Bug Patterns

#### Bug Pattern #1: Accessing values without ensuring evaluation
```swift
// ❌ BUG: Using result without eval() when not wrapped in EvaluatedArray
public func process(array: MLXArray) -> Float {
    let result = transform(array)
    // If result is never evaluated and we try to use it later...
    return someOtherFunction(result)  // ❌ May use unevaluated graph
}

// ✅ FIX 1: Wrap in EvaluatedArray (auto eval)
public func process(array: MLXArray) -> EvaluatedArray {
    let result = transform(array)
    return EvaluatedArray(evaluating: result)  // ✅ Auto eval
}

// ✅ FIX 2: Explicit eval when needed
public func process(array: MLXArray) -> Float {
    let result = transform(array)
    eval(result)  // ✅ Ensure evaluation
    return result.item(Float.self)
}
```

#### Bug Pattern #2: Forgetting eval() in iterative solvers
```swift
// ❌ BUG: Newton-Raphson without eval()
for iteration in 0..<maxIter {
    let residual = computeResidual(x)
    let jacobian = computeJacobian(x)
    let delta = solve(jacobian, residual)
    x = x - delta
    // ❌ Missing eval(x) here
}
return x  // Returns unevaluated graph

// ✅ FIX: Evaluate in each iteration
for iteration in 0..<maxIter {
    let residual = computeResidual(x)
    let jacobian = computeJacobian(x)
    let delta = solve(jacobian, residual)
    x = x - delta
    eval(x)  // ✅ Evaluate per iteration
}
return x
```

#### Bug Pattern #3: Conditional eval()
```swift
// ❌ BUG: Only evaluating sometimes
func process(array: MLXArray, shouldEval: Bool) -> MLXArray {
    let result = transform(array)
    if shouldEval {
        eval(result)
    }
    return result  // ❌ Might be unevaluated
}

// ✅ FIX: Always evaluate before return
func process(array: MLXArray) -> MLXArray {
    let result = transform(array)
    eval(result)  // ✅ Always evaluate
    return result
}
```

### Testing for eval() bugs

Use these techniques to catch missing eval() calls:

1. **Check shapes immediately**
   ```swift
   let result = compute(...)
   #expect(result.shape == expectedShape)  // Will fail if unevaluated
   ```

2. **Extract values in tests**
   ```swift
   let result = compute(...)
   let value = result.item(Float.self)  // Forces eval, catches bugs
   #expect(abs(value - expected) < 1e-6)
   ```

3. **Use eval() explicitly in all tests**
   ```swift
   let result = compute(...)
   eval(result)  // Make it explicit
   #expect(allClose(result, expected).item(Bool.self))
   ```

### Summary: eval() Checklist

✅ **ALWAYS eval() when:**
- Values are actually needed (end of computation chain)
- Wrapping in EvaluatedArray (done automatically by init)
- Crossing actor boundaries
- End of time steps in loops
- Before accessing with item() or asArray() (often implicit)

✅ **NEVER:**
- Eval too early in computation chains (breaks optimization)
- Forget eval() in iterative loops
- Rely solely on implicit evaluation without understanding it

✅ **REMEMBER:**
- MLX is lazy by default - operations queue, don't execute
- Let computations chain for better optimization
- EvaluatedArray wrapper enforces evaluation at type level
- eval() is cheap - it's a no-op if already evaluated
- When in doubt, use EvaluatedArray for type safety

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
# Build the package (library + CLI)
swift build

# Build only the library
swift build --product TORAX

# Build only the CLI
swift build --product torax-cli

# Run all tests
swift test

# Run specific test
swift test --filter <TestName>

# Build in release mode (optimized)
swift build -c release
```

### CLI Development and Testing
```bash
# Run CLI during development
.build/debug/torax-cli run --config examples/test.json

# Install CLI locally for testing
swift build -c release
sudo cp .build/release/torax-cli /usr/local/bin/torax

# Or use Swift Package Manager experimental install
swift package experimental-install -c release

# Test CLI commands
torax run --config examples/basic_config.json --quit
torax plot test_results/*.json
```

### Package Management
```bash
# Update dependencies
swift package update

# Resolve dependencies
swift package resolve

# Show dependency tree
swift package show-dependencies

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

## Command-Line Interface

swift-TORAX provides a comprehensive CLI built with [swift-argument-parser](https://github.com/apple/swift-argument-parser). See [CLI.md](CLI.md) for complete documentation.

### Architecture

The CLI is implemented as a separate executable target (`torax-cli`) that depends on the core TORAX library:

```
Sources/
├── TORAX/           # Core library (reusable)
└── torax-cli/       # CLI executable
    ├── main.swift
    ├── Commands/
    │   ├── RunCommand.swift
    │   ├── PlotCommand.swift
    │   └── InteractiveMenu.swift
    └── Output/
        ├── OutputWriter.swift
        └── ProgressLogger.swift
```

This separation allows the core library to be used independently in other Swift projects.

### Main Commands

**`torax run`** - Execute simulations
```bash
torax run --config examples/basic_config.json --log-progress
```

**`torax plot`** - Visualize results
```bash
torax plot results/state_history_*.json
```

### Key Features

1. **Interactive Menu**: Post-simulation actions without recompilation
   - Rerun with modified parameters
   - Plot results
   - Compare with reference runs

2. **Type-Safe Configuration**: JSON/TOML configs with full validation

3. **Progress Logging**: Real-time monitoring of simulation progress
   ```
   t=1.2345s, dt=0.001s, iter=12
   ```

4. **Debug Support**:
   - `--no-compile`: Disable MLX JIT compilation
   - `--enable-errors`: Additional error checking
   - `--log-output`: Detailed state logging

5. **Batch Processing**: `--quit` flag for scripts and automation

### Environment Variables

- `TORAX_COMPILATION_ENABLED`: Enable/disable MLX JIT (default: `true`)
- `TORAX_ERRORS_ENABLED`: Additional error checking (default: `false`)
- `TORAX_GPU_CACHE_LIMIT`: MLX GPU cache limit in bytes

### Output Formats

- **JSON** (current): Human-readable, universal support
- **HDF5** (planned): Binary format, fast I/O, compression
- **NetCDF** (planned): Self-describing, CF conventions, wide adoption

### Example Workflow

```bash
# 1. Run simulation with progress logging
torax run \
  --config iter_hybrid.json \
  --output-dir ~/simulations/run_001 \
  --log-progress

# 2. Plot results
torax plot ~/simulations/run_001/state_history_*.json

# 3. Compare with reference
torax plot \
  ~/simulations/run_001/state_history_*.json \
  reference_data/iter_baseline.json \
  --format pdf
```

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
7. **CLI executable with ArgumentParser** (designed, ready for implementation)

## References

- Original TORAX: https://github.com/google-deepmind/torax
- TORAX Documentation: https://deepwiki.com/google-deepmind/torax
- MLX-Swift: https://github.com/ml-explore/mlx-swift
- MLX-Swift Documentation: https://deepwiki.com/ml-explore/mlx-swift
- swift-numerics: https://github.com/apple/swift-numerics
- swift-numerics Documentation: https://deepwiki.com/apple/swift-numerics
- swift-argument-parser: https://github.com/apple/swift-argument-parser
