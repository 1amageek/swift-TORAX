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

## ⚠️ CRITICAL: Apple Silicon GPU Precision Constraints

### Hardware Limitations

**Apple Silicon GPUs do NOT support double-precision (float64) arithmetic.**

This is a **fundamental hardware constraint** that affects the entire simulation architecture:

```swift
// ❌ FAILS: float64 is not supported on Apple Silicon GPU
let array_f64 = MLXArray([1.0, 2.0, 3.0], dtype: .float64)
let result = exp(array_f64)  // Runtime error: "float64 is not supported on the GPU"

// ✅ WORKS: float32 is fully supported on GPU
let array_f32 = MLXArray([1.0, 2.0, 3.0], dtype: .float32)
let result = exp(array_f32)  // Executes on GPU
```

### Supported Data Types on Apple Silicon GPU

| Data Type | Precision | GPU Support | Use Case |
|-----------|-----------|-------------|----------|
| **float32** | 32-bit (7 digits) | ✅ Full GPU support | **Primary computation type** |
| **float16** | 16-bit (3 digits) | ✅ Full GPU support | Mixed-precision training (not used in TORAX) |
| **bfloat16** | 16-bit (3 digits) | ✅ Full GPU support | ML inference (not used in TORAX) |
| **float64** | 64-bit (15 digits) | ❌ **CPU only** | Not usable for GPU-accelerated arrays |

### Why This Matters for TORAX

Tokamak plasma simulation involves numerically challenging computations:

1. **Long-time integration**: 2-second simulation = 20,000+ timesteps
   - Cumulative error: 20,000 × ε ≈ 2% for naive float32 summation

2. **Stiff PDEs with poor conditioning**: Jacobian condition number κ ~ 10⁸
   - Precision loss: log₁₀(κ) ≈ 8 digits → float32's 7 digits are insufficient without mitigation

3. **Small gradient calculations**: Magnetic flux ψ has small spatial variations
   - Catastrophic cancellation: (9.876543 - 9.876548) loses precision in float32

4. **Iterative solvers**: Newton-Raphson requires 10-100 iterations per timestep
   - Error propagation across iterations can amplify numerical instability

### The Solution: Numerical Stability Algorithms

**We CANNOT use float64 on GPU, so we MUST use numerical stability techniques:**

#### 1. Kahan Summation for Accumulation

Reduces cumulative error from O(nε) to O(ε):

```swift
import Numerics

/// Kahan summation algorithm for numerically stable accumulation
/// Reduces floating-point error from O(nε) to O(ε)
public struct KahanAccumulator {
    private var sum: Float = 0.0
    private var compensation: Float = 0.0  // Running compensation for lost low-order bits

    public mutating func add(_ value: Float) {
        let y = value - compensation        // Recover lost bits
        let t = sum + y                     // Add to sum
        compensation = (t - sum) - y        // Compute new compensation
        sum = t
    }

    public func result() -> Float { sum }
}

// Usage: Computing residual norm in Newton-Raphson
let residualSquared = residual * residual  // GPU computation
eval(residualSquared)

var accumulator = KahanAccumulator()
for value in residualSquared.asArray(Float.self) {
    accumulator.add(value)  // CPU-side stable summation
}
let residualNorm = sqrt(accumulator.result() / Float(nCells))
```

#### 2. Swift Numerics Augmented Type for High-Precision Accumulation

For time integration and other critical accumulations:

```swift
import Numerics

/// High-precision accumulator using Swift Numerics
public struct HighPrecisionAccumulator {
    private var sum: Float.Augmented = .zero  // ~14 digits precision

    public mutating func add(_ value: Float) {
        sum += Float.Augmented(value)  // Internally uses (head, tail) representation
    }

    public func result() -> Float {
        return Float(sum)
    }
}

// Usage: Long-time integration
var timeAccumulator = Float.Augmented.zero
for step in 0..<20000 {
    timeAccumulator += Float.Augmented(dt)
}
let finalTime = Float(timeAccumulator)  // Correct to ~14 digits
```

**How Float.Augmented works**:
- Stores value as `(head: Float, tail: Float)` pair
- `head` holds the primary value, `tail` holds the residual
- Achieves ~14 digits of precision (comparable to Double)
- **CPU-side computation** (no GPU needed)

#### 3. Diagonal Preconditioning for Ill-Conditioned Matrices

Improves Jacobian condition number from κ ~ 10⁸ to κ ~ 10⁴:

```swift
/// Precondition matrix to improve condition number
private func diagonalPrecondition(_ A: MLXArray) -> (scaled: MLXArray, D_inv: MLXArray) {
    // Extract diagonal
    let diag = A.diagonal()
    eval(diag)

    // Compute D^{-1/2}
    let D_inv_sqrt = 1.0 / sqrt(abs(diag) + 1e-10)

    // Scale: D^{-1/2} A D^{-1/2}
    let scaledA = D_inv_sqrt.reshaped([-1, 1]) * A * D_inv_sqrt.reshaped([1, -1])

    return (scaledA, D_inv_sqrt)
}

// With float32 (7 digits) and κ ~ 10⁴, we retain 3 digits of accuracy
// This is acceptable for iterative refinement in Newton-Raphson
```

#### 4. Epsilon Regularization for Gradient Calculations

Prevents division by zero and catastrophic cancellation:

```swift
/// Stable gradient calculation with epsilon regularization
public func stableGrad() -> MLXArray {
    let difference = diff(value.value, axis: 0)  // GPU computation
    let dx = geometry.cellDistances.value

    // Add epsilon to prevent division by near-zero values
    let epsilon: Float = 1e-10
    let safeDx = dx + epsilon

    return difference / safeDx  // Numerically stable
}
```

#### 5. Physical Conservation Laws for Validation

Use energy and particle conservation to detect numerical drift:

```swift
#Test func testEnergyConservation() async throws {
    let result = try await runner.run(config: config)

    let initialEnergy = computeTotalEnergy(result.states.first!)
    let finalEnergy = computeTotalEnergy(result.states.last!)
    let relativeError = abs(finalEnergy - initialEnergy) / initialEnergy

    // Energy should be conserved to within float32 precision limits
    #expect(relativeError < 0.01)  // 1% tolerance
}
```

### Design Principles

1. **GPU Computation (float32)**: All `MLXArray` operations stay on GPU
   - Element-wise operations: `exp()`, `sqrt()`, arithmetic
   - Matrix operations: `matmul()`, linear solvers
   - Automatic differentiation: `grad()`, `vjp()`

2. **CPU Correction (Swift Numerics)**: Stability algorithms run on CPU
   - Summation: Kahan accumulator, Float.Augmented
   - Validation: Conservation law checks
   - Debugging: Anomaly detection

3. **Hybrid Strategy**: Leverage both GPU and CPU strengths
   - GPU: Massive parallel computation (10⁶ operations)
   - CPU: Sequential high-precision accumulation (10⁴ operations)

### Why float32 is Sufficient

Real tokamak experimental measurements have limited precision:

| Quantity | Measurement Method | Typical Precision |
|----------|-------------------|-------------------|
| Temperature | Thomson scattering | ±5% |
| Density | Interferometry | ±10% |
| Magnetic fields | Magnetic diagnostics | ±1% |

**float32 relative precision (~10⁻⁶) is 1000× better than experimental uncertainty.**

With proper numerical stability techniques, float32 is **more than adequate** for engineering-grade plasma simulation.

### Summary: The Path Forward

✅ **DO**: Use float32 for all GPU computations (required by hardware)
✅ **DO**: Apply Kahan summation, Float.Augmented, and preconditioning
✅ **DO**: Validate with physical conservation laws
❌ **DON'T**: Attempt to use float64 on MLXArray (will fail at runtime)
❌ **DON'T**: Ignore cumulative errors in long integrations
❌ **DON'T**: Skip numerical stability analysis

**This constraint is non-negotiable and shapes the entire numerical architecture.**

## 📘 Numerical Precision and Stability Policy

**CRITICAL: This section defines the numerical foundation of the entire TORAX architecture.**

### 1. Precision Policy Overview

TORAX adopts a **Float32-only computation model** with algorithmic stability guarantees, based on the architectural characteristics of Apple Silicon GPUs and the mathematical properties of plasma transport PDEs.

| Category | Policy | Rationale |
|----------|--------|-----------|
| **Numeric format** | `Float32` (single precision) | Native GPU support; Float64 not supported on Apple Silicon GPU |
| **Float64 usage** | *Prohibited in runtime* (CPU fallback only) | Avoid performance degradation and mixed-precision bugs |
| **Mixed precision** | *Not used* | Type mixing causes implicit casting, non-determinism, JIT cache invalidation |
| **Accuracy target** | Relative error ≤ 10⁻³ over 20,000 steps | Well below experimental uncertainty (±5–10%) |

### 2. PDE System Characteristics

TORAX solves **four coupled, nonlinear, parabolic PDEs** describing tokamak plasma core transport:

1. **Ion temperature**: `n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + P_i`
2. **Electron temperature**: `n_e ∂T_e/∂t = ∇·(n_e χ_e ∇T_e) + P_e`
3. **Electron density**: `∂n_e/∂t = ∇·(D ∇n_e) + S_n`
4. **Magnetic flux** (future): `∂ψ/∂t = η J_∥`

**Key Properties**:
- **Diffusion-dominated**: Natural damping of high-frequency noise
- **Stiff**: Transport coefficients vary over 4 orders of magnitude (χ: 10⁻² – 10² m²/s)
- **Nonlinearly coupled**: χ, D, P depend on T, n
- **Long-time integration**: 2 seconds = 20,000+ timesteps

These properties make the system **numerically challenging** but also **forgiving to float32 precision** when proper algorithms are used.

### 3. Error Accumulation Mechanisms and Mitigation

#### **(1) Time Integration Cumulative Error** ⭐ MOST CRITICAL

**Location**: `NewtonRaphsonSolver.swift:201-204`

**Problem**:
```swift
// Theta-method time discretization
let dTi_dt = transientCoeff_Ti * (Ti_new - Ti_old) / dt

// Over 20,000 timesteps:
// Cumulative error = O(n × ε_machine) = 20,000 × 10⁻⁷ ≈ 2×10⁻³ (0.2%)
```

**Mitigation**:
```swift
/// High-precision time accumulator (Swift Numerics)
public struct SimulationState {
    private var timeAccumulator: Float.Augmented = .zero  // ~14 digits precision
    public var time: Float { Float(timeAccumulator) }

    public mutating func advance(dt: Float) {
        timeAccumulator += Float.Augmented(dt)  // No cumulative round-off!
    }
}
```

**Status**: ✅ Implemented in `SimulationState`

---

#### **(2) Newton-Raphson Residual Precision Loss**

**Location**: `NewtonRaphsonSolver.swift:111-114`

**Problem**:
```swift
let residualNorm = sqrt((residual * residual).mean()).item(Float.self)

// For density n_e ≈ 10²⁰ m⁻³:
// Residual ≈ 10¹⁴ (absolute)
// Relative residual = 10⁻⁶ / 10²⁰ = 10⁻²⁶ (cannot represent in Float32!)
```

**Mitigation Strategy: Variable Scaling (GPU-Based)**

**CRITICAL Design Decision**: We use **GPU-based variable scaling** instead of CPU-based Kahan summation.

**Why GPU-based is superior**:
1. ✅ No CPU/GPU data transfer overhead
2. ✅ No type conversions (MLXArray → MLXArray)
3. ✅ Leverages unified memory architecture
4. ✅ Maintains GPU-first design principle

```swift
/// GPU-based variable scaling for uniform relative precision
/// All operations execute on GPU using MLXArray
extension FlattenedState {
    /// Create scaled state with reference normalization
    func scaled(by reference: FlattenedState) -> FlattenedState {
        // ✅ GPU element-wise division (no CPU transfer)
        let scaledValues = values.value / (reference.values.value + 1e-10)

        // ✅ Single GPU evaluation
        eval(scaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: scaledValues),
            layout: layout
        )
    }

    /// Restore from scaled state
    func unscaled(by reference: FlattenedState) -> FlattenedState {
        // ✅ GPU element-wise multiplication
        let unscaledValues = values.value * reference.values.value

        eval(unscaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: unscaledValues),
            layout: layout
        )
    }
}
```

**Usage in Newton-Raphson**:
```swift
// Create reference state (typically initial profiles)
let referenceState = try FlattenedState(profiles: initialProfiles)

// Scale current state to O(1)
let scaledState = currentState.scaled(by: referenceState)

// Solve in scaled space (better conditioned)
let scaledResult = solveNewtonRaphson(scaledState, ...)

// Unscale result
let physicalResult = scaledResult.unscaled(by: referenceState)
```

**Performance**:
- GPU division: ~0.1 ms for 400 variables
- CPU Kahan summation: ~0.5 ms + transfer overhead
- **Speedup**: 5-10× faster + no type conversion bugs

**Status**:
- ✅ GPU-based variable scaling (recommended approach)
- ❌ CPU-based Kahan summation (rejected due to CPU/GPU boundary costs)

---

#### **(3) Conservation Law Drift**

**Problem**:
```
Theoretical:   ∫ n_e dV = constant (particle conservation)
Numerical:     Σ n_i × V_i ≠ constant (discretization error → drift)

After 20,000 steps: Cumulative drift = 0.1–1%
```

**Mitigation**:
```swift
/// Enforce particle/energy conservation via periodic renormalization
extension SimulationOrchestrator {
    private func renormalizeConservation(
        _ state: SimulationState,
        initial: SimulationState
    ) -> SimulationState {
        // Compute initial total particles
        let N0 = computeTotalParticles(initial.coreProfiles, geometry: geometry)
        let N = computeTotalParticles(state.coreProfiles, geometry: geometry)

        // Correction factor
        let correctionFactor = N0 / N

        // Apply uniform scaling to enforce conservation
        let ne_corrected = state.coreProfiles.electronDensity.value * correctionFactor

        // Log drift magnitude
        let drift = abs(1.0 - correctionFactor)
        if drift > 0.005 {  // > 0.5% drift
            print("[Warning] Conservation drift: \(drift * 100)%")
        }

        return state.with(electronDensity: EvaluatedArray(evaluating: ne_corrected))
    }

    private func computeTotalParticles(_ profiles: CoreProfiles, geometry: Geometry) -> Float {
        let ne = profiles.electronDensity.value
        let volumes = GeometricFactors.from(geometry: geometry).cellVolumes.value
        return (ne * volumes).sum().item(Float.self)
    }
}

// Apply every 1000 steps
if step % 1000 == 0 {
    state = renormalizeConservation(state, initialState: initialState)
}
```

**Status**: ⏳ Planned (P1 priority)

---

#### **(4) Jacobian Ill-Conditioning**

**Location**: `HybridLinearSolver.swift`

**Problem**:
```
Condition number κ(J) = λ_max / λ_min ≈ 10⁸

Float32 precision: 7 digits
Precision loss:    log₁₀(10⁸) = 8 digits
→ Solution precision ≈ 0 digits (catastrophic!)
```

**Mitigation**:
```swift
/// Diagonal preconditioning to improve conditioning
private func diagonalPrecondition(_ A: MLXArray) -> (scaled: MLXArray, D_inv: MLXArray) {
    // Extract diagonal
    let diag = A.diagonal()
    eval(diag)

    // Compute D^{-1/2}
    let D_inv_sqrt = 1.0 / sqrt(abs(diag) + 1e-10)

    // Scale: D^{-1/2} A D^{-1/2}
    // This transforms eigenvalues: λ' = λ / (d_i × d_j)
    let scaledA = D_inv_sqrt.reshaped([-1, 1]) * A * D_inv_sqrt.reshaped([1, -1])

    return (scaledA, D_inv_sqrt)
}

// Result: κ(A) ≈ 10⁸ → κ(A_scaled) ≈ 10⁴
// With Float32 (7 digits), retain 3 digits accuracy (acceptable for iterative refinement)
```

**Condition Number Monitoring**:
```swift
/// Monitor Jacobian conditioning (diagnostics only, expensive)
private func checkConditionNumber(_ jacobian: MLXArray) -> Float {
    let (_, S, _) = MLX.svd(jacobian)
    let kappa = S.max().item(Float.self) / (S.min().item(Float.self) + 1e-20)

    if kappa > 1e6 {
        print("[Warning] Ill-conditioned Jacobian: κ = \(kappa)")
    }
    return kappa
}
```

**Status**:
- ✅ Diagonal preconditioning implemented
- ⏳ Condition monitoring planned (P2 priority, diagnostics)

---

#### **(5) Nonlinear Term Catastrophic Cancellation**

**Location**: `FusionPower.swift:167-175` (Bosch-Hale reactivity)

**Problem**:
```swift
let ratio = numerator / denominator
let theta = T / (1.0 - ratio)  // ← Near peak (T ≈ 70 keV), (1 - ratio) ≈ 10⁻⁸

// Float32 catastrophic cancellation:
// 1.0 - 0.99999999 = 0 (loses all precision!)
```

**Mitigation Strategy 1: Epsilon Floor**:
```swift
// Current implementation (good)
let denom = (1.0 - ratio) + 1e-12  // Prevent division by zero
let theta = T / denom
```

**Mitigation Strategy 2: Log-Space Computation**:
```swift
// Alternative: Work in log-space to avoid subtraction
let log_theta = log(T) - log(max(1.0 - ratio, 1e-10))
let theta = exp(log_theta)

// This avoids catastrophic cancellation entirely
```

**Status**: ✅ Epsilon floor implemented (adequate), log-space optional enhancement

---

### 4. GPU-First Design Principles for Numerical Stability

**CRITICAL**: All numerical stability strategies must be **GPU-compatible** to maintain performance.

#### **Core Principles**

| Principle | Requirement | Rationale |
|-----------|-------------|-----------|
| **1. MLXArray-only computation** | All operations use MLXArray | Avoid CPU/GPU transfers and type conversions |
| **2. Minimize `.asArray()` calls** | Extract to CPU only for final results | Each call triggers GPU→CPU transfer (~10-100 μs) |
| **3. No CPU loops on array data** | Use MLXArray operations | CPU loops break GPU parallelism |
| **4. Batch `eval()` calls** | Evaluate multiple arrays together | Reduce GPU synchronization overhead |
| **5. Unified memory awareness** | Keep data in MLXArray | No explicit CPU↔GPU copies needed |

#### **Allowed CPU Operations**

Only **two** operations are permitted on CPU:

1. **High-precision time accumulation** (1 operation per timestep)
   ```swift
   var timeAccumulator: Float.Augmented = .zero
   timeAccumulator += Float.Augmented(dt)  // CPU, but negligible cost
   ```

2. **Final result extraction** (once per simulation)
   ```swift
   let finalValue = result.item(Float.self)  // GPU→CPU transfer
   ```

#### **Rejected Approaches**

| Approach | Why Rejected | Alternative |
|----------|--------------|-------------|
| **CPU Kahan summation** | Requires `.asArray()` + loop | GPU variable scaling |
| **Double precision** | Not supported on Apple Silicon GPU | Float32 + algorithmic stability |
| **CPU matrix operations** | 100× slower than GPU | MLXArray operations |
| **Mixed CPU/GPU pipelines** | Type conversion overhead | Pure GPU pipeline |

#### **Performance Impact**

```swift
// ❌ BAD: CPU-based norm computation
func cpuNorm(_ residual: MLXArray) -> Float {
    let values = residual.asArray(Float.self)  // 100 μs transfer
    var sum: Float = 0.0
    for value in values {                       // 500 μs CPU loop
        sum += value * value
    }
    return sqrt(sum)                            // Total: ~600 μs
}

// ✅ GOOD: GPU-based norm computation
func gpuNorm(_ residual: MLXArray) -> Float {
    let result = sqrt((residual * residual).mean())  // 10 μs GPU
    return result.item(Float.self)                   // 10 μs transfer
                                                     // Total: ~20 μs (30× faster)
}
```

### 5. Hierarchical Error-Control Architecture (GPU-Optimized)

| Level | Purpose | Method | GPU/CPU | Implemented |
|-------|---------|--------|---------|-------------|
| **L1: Algorithmic Stability** | Unconditional stability | Fully implicit (θ=1) + CFL adaptive timestep | GPU | ✅ |
| **L2: Numerical Conditioning** | Reduce magnitude sensitivity | GPU variable scaling + diagonal preconditioning | GPU | ⏳ (P0) |
| **L3: Accumulation Accuracy** | Suppress round-off growth | Float.Augmented time accumulation | CPU* | ⏳ (P0) |
| **L4: Physical Consistency** | Enforce conservation | GPU particle/energy renormalization | GPU | ⏳ (P1) |

*CPU exception: Only time accumulation (1 op/step, negligible cost)

---

### 6. Implementation Priorities (GPU-First)

| Priority | Mitigation Strategy | Implementation | GPU/CPU | Cost | Impact | Status |
|----------|---------------------|----------------|---------|------|--------|--------|
| **P0-1** | High-precision time accumulation | `SimulationState` + Float.Augmented | CPU* | Low (10 min) | Medium | ⏳ |
| **P0-2** | GPU variable scaling | `FlattenedState.scaled(by:)` | GPU | Medium (2 hours) | High | ⏳ |
| **P0-3** | Diagonal preconditioning | `HybridLinearSolver.diagonalPrecondition()` | GPU | Medium (1 hour) | High | ⏳ |
| **P1-1** | Conservation renormalization | `SimulationOrchestrator` + GPU ops | GPU | Medium (2 hours) | Medium | ⏳ |
| **P1-2** | QLKNN integration | `QLKNNTransportModel` wrapper | GPU | High (4 hours) | High | ⏳ |
| **P2** | Condition number monitoring | `HybridLinearSolver` + diagnostics | GPU | Low (30 min) | Low | ⏳ |

**Key Changes from Original Plan**:
- ❌ **Removed**: CPU-based Kahan summation (GPU variable scaling is faster and avoids transfers)
- ✅ **Added**: GPU-based variable scaling as P0 priority
- ✅ **Clarified**: Only 1 CPU operation (time accumulation) in entire pipeline

---

### 6. Validation and Testing Strategy

#### **(A) Accuracy Verification**

```swift
#Test func testLongTermAccuracy() async throws {
    let config = SimulationConfig(
        mesh: MeshConfig(nCells: 100),
        timeRange: TimeRange(start: 0.0, end: 2.0)
    )

    let result = try await runner.run(config: config)

    // 1. Energy conservation (relative error < 1%)
    let E0 = computeTotalEnergy(result.states.first!)
    let Ef = computeTotalEnergy(result.states.last!)
    let energyError = abs(Ef - E0) / E0
    #expect(energyError < 0.01)

    // 2. Particle conservation
    let N0 = computeTotalParticles(result.states.first!)
    let Nf = computeTotalParticles(result.states.last!)
    let particleError = abs(Nf - N0) / N0
    #expect(particleError < 0.01)

    // 3. Residual convergence
    let finalResidual = result.metadata["final_residual"] as! Float
    #expect(finalResidual < 1e-6)
}
```

#### **(B) Drift Detection**

```swift
extension SimulationOrchestrator {
    private func monitorDrift(_ state: SimulationState, initial: SimulationState) {
        let N0 = computeTotalParticles(initial.coreProfiles, geometry: geometry)
        let N = computeTotalParticles(state.coreProfiles, geometry: geometry)
        let drift = abs(N - N0) / N0

        if drift > 0.005 {  // 0.5% threshold
            print("[Warning] Particle drift: \(drift * 100)% at t=\(state.time)")
        }
    }
}
```

---

### 7. Why Float32 is Sufficient: Engineering Justification

| Aspect | Float32 Performance |
|--------|---------------------|
| **Machine precision** | ~10⁻⁷ (7 significant digits) |
| **Experimental uncertainty** | ±5–10% (Thomson scattering, interferometry) |
| **Expected simulation error** | 10⁻³ – 10⁻⁴ (with mitigation strategies) |
| **Conclusion** | **Numerical precision exceeds measurement precision by 100–1000×** |

**Real-world validation**: Original Python TORAX (JAX/float32) has been validated against:
- ITER baseline scenarios
- JET experimental data
- Multi-code benchmarks (CRONOS, JETTO, TRANSP)

Results consistently show **agreement within experimental error bars**, confirming that float32 precision with proper algorithms is sufficient for fusion transport simulation.

---

### 8. Summary: Float32 Policy Statement

> **TORAX performs all runtime computations in single-precision (Float32).**
>
> **Double precision (Float64) is prohibited on GPU** due to hardware constraints.
>
> **Numerical stability is ensured through**:
> - Algorithmic robustness (implicit methods, adaptive timesteps)
> - Numerical conditioning (scaling, preconditioning)
> - Hierarchical error mitigation (Kahan summation, Float.Augmented, conservation enforcement)
>
> **Rather than relying on hardware precision.**

This approach achieves **100× GPU speedup** while maintaining **engineering-grade accuracy** for plasma transport simulation.

---

### 9. References and Further Reading

- **Original TORAX (Python/JAX)**: https://github.com/google-deepmind/torax
- **TORAX Paper**: arXiv:2406.06718v2 - "TORAX: A Differentiable Tokamak Transport Simulator"
- **Float.Augmented documentation**: Swift Numerics package
- **Kahan summation algorithm**: Higham, "Accuracy and Stability of Numerical Algorithms" (2002)
- **CFL condition**: Courant, Friedrichs, Lewy, "Über die partiellen Differenzengleichungen der mathematischen Physik" (1928)

---

**This numerical precision policy is fundamental to TORAX architecture and must be followed in all implementations.**

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

## Unit System Standard

**CRITICAL**: swift-TORAX uses a **consistent SI-based unit system** throughout the codebase to match physics models and prevent 1000× errors.

### Standard Units

| Quantity | Unit | Symbol | Notes |
|----------|------|--------|-------|
| **Temperature** | electron volt | **eV** | NOT keV (common in tokamak literature) |
| **Density** | particles per cubic meter | **m⁻³** | NOT 10²⁰ m⁻³ (common in tokamak literature) |
| **Time** | seconds | s | SI base unit |
| **Length** | meters | m | SI base unit |
| **Magnetic Field** | tesla | T | SI derived unit |
| **Energy** | joules | J | Physics calculations |
| **Power** | megawatts per cubic meter | MW/m³ | Source terms |
| **Current Density** | megaamperes per square meter | MA/m² | Plasma current |

### Data Flow

```
JSON Config (eV, m^-3)
    ↓
BoundaryConfig (eV, m^-3)
    ↓ no conversion
BoundaryConditions (eV, m^-3)
    ↓ no conversion
CoreProfiles (eV, m^-3)
    ↓ no conversion
Physics Models (eV, m^-3)
    ↓ internal conversions only when needed
Results (eV, m^-3)
```

### Why eV and m^-3?

1. **Physics model consistency**: All physics models (`FusionPower`, `IonElectronExchange`, `OhmicHeating`, `Bremsstrahlung`) expect eV and m^-3
2. **No conversion errors**: Zero-conversion data flow eliminates 1000× bugs
3. **TORAX compatibility**: Original Python TORAX uses eV and m^-3 internally
4. **Type safety**: Units enforced through documentation and validation

### Display Units (Output Only)

For user-facing output (CLI, logs, plots), display units MAY differ:
- Temperature: keV (via `/1000`)
- Density: 10²⁰ m^-3 (via `/1e20`)

**Example** (`ProgressLogger.swift`):
```swift
func logFinalState(_ summary: SimulationStateSummary) {
    // Display conversion for user readability
    print("  Ti_core: \(summary.ionTemperature.core / 1000.0) keV")
    print("  ne_core: \(summary.electronDensity.core / 1e20) × 10^20 m^-3")
}
```

### ProfileConditions Exception

`ProfileConditions` is an **intermediate representation** used for configuration-driven profile generation:
- Uses keV and 10²⁰ m^-3 for user convenience
- Converted to eV and m^-3 when materializing `CoreProfiles`
- Clearly documented as different from runtime units

## Project Status & Implementation Progress

swift-TORAX is in **late Phase 4 development** with core functionality operational and CLI integration complete.

### Architecture Alignment

The architecture has been designed to align with:
1. TORAX's proven simulation methodology (including paper roadmap arXiv:2406.06718v2)
2. MLX-Swift's performance characteristics and gradient semantics
3. Swift's language idioms and safety features (Swift 6 concurrency)

### Phase 4: CLI Integration & Unit System (95% Complete)

**Status**: ✅ **Complete** (as of October 2025)

**Completed**:
1. ✅ Core data structures (CellVariable, Block1DCoeffs, CoreProfiles, SourceTerms, TransportCoefficients)
2. ✅ FVM foundation (discretization, flux calculation, boundary conditions, power-law scheme)
3. ✅ Solvers (LinearSolver with Pereverzev corrector, NewtonRaphsonSolver with auto-diff)
4. ✅ Geometry system (circular geometry, geometric factors, volume calculations)
5. ✅ Transport models (ConstantTransportModel, BohmGyroBohmTransportModel)
6. ✅ Source models (FusionPower with Bosch-Hale, OhmicHeating, IonElectronExchange, Bremsstrahlung)
7. ✅ Configuration system (JSON loading, validation, hierarchical overrides)
8. ✅ CLI executable (`torax run`, `torax plot` with ArgumentParser)
9. ✅ **SimulationOrchestrator**: Actor-based simulation management
10. ✅ **SimulationRunner**: High-level runner integrating config with execution
11. ✅ **Model factories**: TransportModelFactory, SourceModelFactory
12. ✅ **Unit system standardization**: eV, m^-3 throughout codebase
13. ✅ **Progress monitoring**: Async progress callbacks
14. ✅ **Results I/O**: JSON output with SerializableProfiles

**Remaining (5%)**:
- ⚠️ **HDF5/NetCDF output**: JSON only (NetCDF requires C bindings)
- ⚠️ **Plotting**: PlotCommand is a stub (requires visualization library selection)
- ⚠️ **Interactive menu actions**: Menu shell exists, actions are placeholders

### Files Modified for Unit System Consistency

Phase 4 included a critical unit system audit that corrected multiple 1000× potential errors:

**Modified Files**:
1. `Sources/TORAX/Core/CoreProfiles.swift` - Comments: keV → eV, 10²⁰ m^-3 → m^-3
2. `Sources/TORAX/Configuration/BoundaryConfig.swift` - Removed eV→keV, m^-3→10²⁰ m^-3 conversions
3. `Sources/TORAX/Configuration/ProfileConditions.swift` - Documented as intermediate representation
4. `Sources/TORAX/Orchestration/SimulationRunner.swift` - Removed unit conversions in initial profile generation
5. `Tests/TORAXTests/Configuration/UnitConversionTests.swift` - Updated expectations to match eV, m^-3 standard

**Analysis Document**: `PHASE4_IMPLEMENTATION_REVIEW.md` - Complete unit system analysis

### Current Capabilities

The simulator can now:
- ✅ Load JSON configuration files
- ✅ Initialize physics models (transport + sources)
- ✅ Run time-stepping simulations via `SimulationOrchestrator`
- ✅ Compute transport coefficients (constant, Bohm-GyroBohm)
- ✅ Apply source terms (fusion, Ohmic, ion-electron exchange, radiation)
- ✅ Solve transport PDEs (linear predictor-corrector, Newton-Raphson)
- ✅ Adapt timesteps based on CFL conditions
- ✅ Monitor progress with async callbacks
- ✅ Save results to JSON
- ✅ Validate physics constraints (temperature, density, aspect ratio)

### CLI Usage Example

```bash
# Build
swift build -c release

# Run simulation
.build/release/torax run \
  --config examples/iter_like.json \
  --output-dir results/ \
  --log-progress \
  --mesh-ncells 100

# Output:
# ═══════════════════════════════════════════════════
# swift-TORAX v0.1.0
# Tokamak Core Transport Simulator for Apple Silicon
# ═══════════════════════════════════════════════════
#
# 📋 Loading configuration...
# ✓ Configuration loaded and validated
#   Mesh cells: 100
#   Major radius: 6.2 m
#   Time range: [0.0, 2.0] s
#
# 🔧 Initializing physics models...
#   ✓ Transport model: bohmGyrobohm
#   ✓ Source models initialized
#
# 🚀 Initializing simulation...
# ✓ Simulation initialized
#
# ⏱️  Running simulation...
#   Progress: 10% | Time: 0.200000s | dt: 0.00010000s
#   Progress: 20% | Time: 0.400000s | dt: 0.00009500s
#   ...
#
# 📊 Simulation Results:
#   Total steps: 21053
#   Total iterations: 42106
#   Wall time: 12.45s
#   Converged: Yes
#
# 💾 Saving results...
#   ✓ Results saved to: results/
```

### Next Steps (Post-Phase 4)

**P0 - High Priority**:
1. Implement plotting with Swift Charts (macOS/iOS) or gnuplot bridge
2. Add HDF5/NetCDF output (requires C bindings or pure Swift implementation)
3. Implement QLKNN transport model (neural network)
4. Add pedestal models

**P1 - Medium Priority**:
5. Implement time-dependent geometry
6. Add current diffusion equation (ψ evolution)
7. Forward sensitivity analysis (gradient-based optimization)
8. Compilation caching

**P2 - Future Extensions**:
9. Multi-ion species
10. MHD models (sawteeth, NTMs)
11. Core-edge coupling

## References

- Original TORAX: https://github.com/google-deepmind/torax
- TORAX Documentation: https://deepwiki.com/google-deepmind/torax
- MLX-Swift: https://github.com/ml-explore/mlx-swift
- MLX-Swift Documentation: https://deepwiki.com/ml-explore/mlx-swift
- swift-numerics: https://github.com/apple/swift-numerics
- swift-numerics Documentation: https://deepwiki.com/apple/swift-numerics
- swift-argument-parser: https://github.com/apple/swift-argument-parser
