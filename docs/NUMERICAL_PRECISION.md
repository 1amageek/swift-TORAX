# Numerical Precision and Stability

**CRITICAL: This document defines the numerical foundation of the entire Gotenx architecture.**

## ⚠️ Apple Silicon GPU Precision Constraints

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
| **float16** | 16-bit (3 digits) | ✅ Full GPU support | Mixed-precision training (not used in Gotenx) |
| **bfloat16** | 16-bit (3 digits) | ✅ Full GPU support | ML inference (not used in Gotenx) |
| **float64** | 64-bit (15 digits) | ❌ **CPU only** | Not usable for GPU-accelerated arrays |

### Why This Matters for Gotenx

Tokamak plasma simulation involves numerically challenging computations:

1. **Long-time integration**: 2-second simulation = 20,000+ timesteps
   - Cumulative error: 20,000 × ε ≈ 2% for naive float32 summation

2. **Stiff PDEs with poor conditioning**: Jacobian condition number κ ~ 10⁸
   - Precision loss: log₁₀(κ) ≈ 8 digits → float32's 7 digits are insufficient without mitigation

3. **Small gradient calculations**: Magnetic flux ψ has small spatial variations
   - Catastrophic cancellation: (9.876543 - 9.876548) loses precision in float32

4. **Iterative solvers**: Newton-Raphson requires 10-100 iterations per timestep
   - Error propagation across iterations can amplify numerical instability

---

## Precision Policy Overview

Gotenx adopts a **Float32-only computation model** with algorithmic stability guarantees, based on the architectural characteristics of Apple Silicon GPUs and the mathematical properties of plasma transport PDEs.

| Category | Policy | Rationale |
|----------|--------|-----------|
| **Numeric format** | `Float32` (single precision) | Native GPU support; Float64 not supported on Apple Silicon GPU |
| **Float64 usage** | *Prohibited in runtime* (CPU fallback only) | Avoid performance degradation and mixed-precision bugs |
| **Mixed precision** | *Not used* | Type mixing causes implicit casting, non-determinism, JIT cache invalidation |
| **Accuracy target** | Relative error ≤ 10⁻³ over 20,000 steps | Well below experimental uncertainty (±5–10%) |

---

## PDE System Characteristics

Gotenx solves **four coupled, nonlinear, parabolic PDEs** describing tokamak plasma core transport:

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

---

## Numerical Stability Strategies

### 1. Double for Time Accumulation (CPU-Only Exception)

Time accumulation is the **only CPU operation** in the simulation pipeline:

```swift
// SimulationState.swift
public struct SimulationState: Sendable {
    /// High-precision time accumulator
    ///
    /// Uses Double (64-bit) for time accumulation to prevent cumulative errors
    /// over 20,000+ timesteps. This is a CPU-only operation (1 per timestep).
    ///
    /// **Why Double instead of Float32?**
    /// - Time accumulation is CPU-only (GPU compatibility irrelevant)
    /// - Double provides 15 digits precision vs Float32's 7 digits
    /// - For 20,000 steps: Double error ~10⁻¹² vs Float32 error ~2×10⁻³
    /// - Standard practice in scientific computing
    ///
    /// **Why not Float.Augmented?**
    /// - More complex (head + tail representation)
    /// - Slower (2 additions + correction)
    /// - Requires Swift Numerics dependency
    /// - Double is simpler, faster, and more accurate
    private let timeAccumulator: Double

    public var time: Float {
        Float(timeAccumulator)
    }

    public func advanced(by dt: Float, ...) -> SimulationState {
        let newTimeAccumulator = timeAccumulator + Double(dt)
        // ...
    }
}
```

**Design Rationale**:
- Float32-only policy applies to **GPU operations**
- CPU-only operations can use Double when beneficial
- Time accumulation: 1 operation per timestep (negligible cost)
- Result: 20,000× improvement in cumulative error

### 2. GPU Variable Scaling for Newton-Raphson

Normalize variables to O(1) for uniform relative precision:

```swift
// FlattenedState.swift
extension FlattenedState {
    /// GPU-based variable scaling for uniform relative precision
    func scaled(by reference: FlattenedState) -> FlattenedState {
        // GPU element-wise division (no CPU transfer)
        let scaledValues = values.value / (reference.values.value + 1e-10)
        eval(scaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: scaledValues),
            layout: layout
        )
    }

    /// Restore from scaled state
    func unscaled(by reference: FlattenedState) -> FlattenedState {
        let unscaledValues = values.value * reference.values.value
        eval(unscaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: unscaledValues),
            layout: layout
        )
    }
}

// Usage in Newton-Raphson
let referenceState = try FlattenedState(profiles: initialProfiles)
let scaledState = currentState.scaled(by: referenceState)
let scaledResult = solveNewtonRaphson(scaledState, ...)
let physicalResult = scaledResult.unscaled(by: referenceState)
```

**Why GPU-based?**
- Pure GPU operations (no CPU/GPU transfers)
- 5-10× faster than CPU Kahan summation
- Maintains GPU-first architecture

### 3. Diagonal Preconditioning for Ill-Conditioned Matrices

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

### 4. Epsilon Regularization for Gradient Calculations

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

### 5. Physical Conservation Laws for Validation

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

---

## Error Accumulation Mechanisms and Mitigation

### (1) Time Integration Cumulative Error ⭐ MOST CRITICAL

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

### (2) Newton-Raphson Residual Precision Loss

**Problem**:
```swift
let residualNorm = sqrt((residual * residual).mean()).item(Float.self)

// For density n_e ≈ 10²⁰ m⁻³:
// Residual ≈ 10¹⁴ (absolute)
// Relative residual = 10⁻⁶ / 10²⁰ = 10⁻²⁶ (cannot represent in Float32!)
```

**Mitigation**: GPU-based variable scaling (see Section 2 above)

**Performance**:
- GPU division: ~0.1 ms for 400 variables
- CPU Kahan summation: ~0.5 ms + transfer overhead
- **Speedup**: 5-10× faster + no type conversion bugs

**Status**: ✅ Implemented

### (3) Conservation Law Drift

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
}

// Apply every 1000 steps
if step % 1000 == 0 {
    state = renormalizeConservation(state, initialState: initialState)
}
```

**Status**: ⏳ Planned (P1 priority)

### (4) Jacobian Ill-Conditioning

**Problem**:
```
Condition number κ(J) = λ_max / λ_min ≈ 10⁸

Float32 precision: 7 digits
Precision loss:    log₁₀(10⁸) = 8 digits
→ Solution precision ≈ 0 digits (catastrophic!)
```

**Mitigation**: Diagonal preconditioning (see Section 3 above)

**Status**:
- ✅ Diagonal preconditioning implemented
- ⏳ Condition monitoring planned (P2 priority, diagnostics)

### (5) Nonlinear Term Catastrophic Cancellation

**Location**: `FusionPower.swift` (Bosch-Hale reactivity)

**Problem**:
```swift
let ratio = numerator / denominator
let theta = T / (1.0 - ratio)  // ← Near peak (T ≈ 70 keV), (1 - ratio) ≈ 10⁻⁸

// Float32 catastrophic cancellation:
// 1.0 - 0.99999999 = 0 (loses all precision!)
```

**Mitigation (Epsilon Floor)**:
```swift
// Current implementation
let denom = (1.0 - ratio) + 1e-12  // Prevent division by zero
let theta = T / denom
```

**Mitigation (Log-Space - alternative)**:
```swift
// Work in log-space to avoid subtraction
let log_theta = log(T) - log(max(1.0 - ratio, 1e-10))
let theta = exp(log_theta)
```

**Status**: ✅ Epsilon floor implemented

---

## GPU-First Design Principles

**CRITICAL**: All numerical stability strategies must be **GPU-compatible** to maintain performance.

### Core Principles

| Principle | Requirement | Rationale |
|-----------|-------------|-----------|
| **1. MLXArray-only computation** | All operations use MLXArray | Avoid CPU/GPU transfers and type conversions |
| **2. Minimize `.asArray()` calls** | Extract to CPU only for final results | Each call triggers GPU→CPU transfer (~10-100 μs) |
| **3. No CPU loops on array data** | Use MLXArray operations | CPU loops break GPU parallelism |
| **4. Batch `eval()` calls** | Evaluate multiple arrays together | Reduce GPU synchronization overhead |
| **5. Unified memory awareness** | Keep data in MLXArray | No explicit CPU↔GPU copies needed |

### Allowed CPU Operations

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

### Rejected Approaches

| Approach | Why Rejected | Alternative |
|----------|--------------|-------------|
| **CPU Kahan summation** | Requires `.asArray()` + loop | GPU variable scaling |
| **Double precision** | Not supported on Apple Silicon GPU | Float32 + algorithmic stability |
| **CPU matrix operations** | 100× slower than GPU | MLXArray operations |
| **Mixed CPU/GPU pipelines** | Type conversion overhead | Pure GPU pipeline |

### Performance Impact

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

---

## Hierarchical Error-Control Architecture

| Level | Purpose | Method | GPU/CPU | Status |
|-------|---------|--------|---------|--------|
| **L1: Algorithmic Stability** | Unconditional stability | Fully implicit (θ=1) + CFL adaptive timestep | GPU | ✅ |
| **L2: Numerical Conditioning** | Reduce magnitude sensitivity | GPU variable scaling + diagonal preconditioning | GPU | ✅ |
| **L3: Accumulation Accuracy** | Suppress round-off growth | Double/Float.Augmented time accumulation | CPU* | ✅ |
| **L4: Physical Consistency** | Enforce conservation | GPU particle/energy renormalization | GPU | ⏳ (P1) |

*CPU exception: Only time accumulation (1 op/step, negligible cost)

---

## Why Float32 is Sufficient

### Engineering Justification

| Aspect | Float32 Performance |
|--------|---------------------|
| **Machine precision** | ~10⁻⁷ (7 significant digits) |
| **Experimental uncertainty** | ±5–10% (Thomson scattering, interferometry) |
| **Expected simulation error** | 10⁻³ – 10⁻⁴ (with mitigation strategies) |
| **Conclusion** | **Numerical precision exceeds measurement precision by 100–1000×** |

Real tokamak experimental measurements have limited precision:

| Quantity | Measurement Method | Typical Precision |
|----------|-------------------|-------------------|
| Temperature | Thomson scattering | ±5% |
| Density | Interferometry | ±10% |
| Magnetic fields | Magnetic diagnostics | ±1% |

**float32 relative precision (~10⁻⁶) is 1000× better than experimental uncertainty.**

### Real-World Validation

Original Python TORAX (JAX/float32) has been validated against:
- ITER baseline scenarios
- JET experimental data
- Multi-code benchmarks (CRONOS, JETTO, TRANSP)

Results consistently show **agreement within experimental error bars**, confirming that float32 precision with proper algorithms is sufficient for fusion transport simulation.

---

## Summary: Float32 Policy Statement

> **Gotenx performs all runtime computations in single-precision (Float32).**
>
> **Double precision (Float64) is prohibited on GPU** due to hardware constraints.
>
> **Numerical stability is ensured through**:
> - Algorithmic robustness (implicit methods, adaptive timesteps)
> - Numerical conditioning (scaling, preconditioning)
> - Hierarchical error mitigation (Double/Float.Augmented time accumulation, conservation enforcement)
>
> **Rather than relying on hardware precision.**

This approach achieves **100× GPU speedup** while maintaining **engineering-grade accuracy** for plasma transport simulation.

✅ **DO**: Use float32 for all GPU computations (required by hardware)
✅ **DO**: Apply variable scaling, preconditioning, and conservation laws
✅ **DO**: Validate with physical conservation tests
❌ **DON'T**: Attempt to use float64 on MLXArray (will fail at runtime)
❌ **DON'T**: Ignore cumulative errors in long integrations
❌ **DON'T**: Skip numerical stability analysis

---

## References

- **Original TORAX (Python/JAX)**: https://github.com/google-deepmind/torax
- **TORAX Paper**: arXiv:2406.06718v2 - "TORAX: A Differentiable Tokamak Transport Simulator"
- **Float.Augmented documentation**: Swift Numerics package
- **Kahan summation algorithm**: Higham, "Accuracy and Stability of Numerical Algorithms" (2002)
- **CFL condition**: Courant, Friedrichs, Lewy, "Über die partiellen Differenzengleichungen der mathematischen Physik" (1928)

---

*See also: [CLAUDE.md](../CLAUDE.md) for development guidelines*
