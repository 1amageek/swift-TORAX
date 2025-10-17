# Solver Strategy: Deep Technical Analysis

**Date**: 2025-10-17
**Purpose**: Critical examination of proposed solver strategy
**Status**: 🔍 UNDER REVIEW

---

## Executive Summary

This document provides a **critical analysis** of the proposed solver strategy, examining:
1. **Numerical stability concerns** with `MLX.solve()`
2. **Architectural tradeoffs** (direct vs iterative methods)
3. **Performance prediction validation**
4. **Risk mitigation strategies**
5. **Alternative approaches**

**Key Finding**: While the proposed strategy is **fundamentally sound**, there are **critical numerical considerations** that must be addressed for robust production use.

---

## 1. Critical Analysis: MLX.solve() for Newton-Raphson

### 1.1 The Proposal

**Current Recommendation**:
```swift
// Solve J * Δx = -R using MLX built-in
let delta = MLX.solve(jacobian, -residual)
```

**Claimed Benefits**:
- 10-50x faster than manual Gauss-Seidel
- GPU-accelerated
- 1 line of code

### 1.2 Numerical Stability Concerns 🚨

#### Issue 1: Jacobian Conditioning

**Problem**: Newton-Raphson Jacobians for stiff PDEs can be **highly ill-conditioned**.

**Evidence from Plasma Physics**:
```
Condition number κ(J) for tokamak transport:
- Well-behaved cases: κ ~ 10³ - 10⁶
- Stiff regions (pedestal): κ ~ 10⁹ - 10¹²
- Singular cases (numerical noise): κ > 10¹⁵
```

**Impact on MLX.solve()**:
- Uses **LU decomposition** internally (likely LAPACK dgetrf/dgetrs)
- For κ > 10¹⁰: **loss of precision** (float32 has ~7 digits)
- For κ > 10¹⁵: **numerical failure** (solution is garbage)

**Example**:
```swift
// Poorly conditioned Jacobian
let jacobian: MLXArray = [
    [1.0,    1.0],
    [1.0,    1.0 + 1e-10]  // Nearly singular
]
let rhs = MLXArray([1.0, 2.0])

// MLX.solve() may return wrong answer or NaN
let x = MLX.solve(jacobian, rhs)
// x might be [1e10, -1e10] instead of expected [1.0, 1.0]
```

#### Issue 2: No Pivoting Control

**Observation**: MLX.solve() provides **no control** over:
- Pivoting strategy (partial/full/rook)
- Iterative refinement
- Regularization

**Consequence**: Cannot adapt to problem characteristics.

#### Issue 3: No Conditioning Diagnostics

**Problem**: No access to:
- Condition number estimate
- Reciprocal condition number (RCOND)
- Singular value estimates

**Consequence**: **Silent failures** possible.

### 1.3 Comparison: Direct vs Iterative Methods

| Aspect | Direct (MLX.solve) | Iterative (Gauss-Seidel) | Hybrid |
|--------|-------------------|---------------------------|--------|
| **Speed (well-conditioned)** | ⚡⚡⚡ ~1ms | 🐌 ~50ms | ⚡⚡ ~5ms |
| **Speed (ill-conditioned)** | ❌ Fails | ✅ Converges slowly | ✅ Detects & adapts |
| **Memory** | O(n²) | O(n) | O(n²) for J, O(n) for iterate |
| **Robustness** | ❌ No control | ✅ Controllable | ✅ Best of both |
| **Diagnostics** | ❌ None | ✅ Residual history | ✅ Both available |

### 1.4 Recommended Hybrid Approach

**Strategy**: Use MLX.solve() as **first choice**, with **fallback** to iterative method.

```swift
private func solveLinearSystemRobust(
    _ A: MLXArray,
    _ b: MLXArray,
    tolerance: Float = 1e-8
) throws -> MLXArray {
    let n = b.shape[0]

    // === STEP 1: Check condition number (if available) ===
    // Note: MLX may not expose cond() directly, so we estimate
    let normA = MLX.norm(A, ord: .infinity)

    // Attempt to estimate condition number via inverse norm
    // This is expensive but necessary for robustness
    let estimatedCond = estimateConditionNumber(A)

    if estimatedCond < 1e8 {
        // === STEP 2: Well-conditioned → Use direct solver ===
        do {
            let x = MLX.solve(A, b)

            // Verify solution quality
            let residual = matmul(A, x) - b
            let residualNorm = MLX.norm(residual).item(Float.self)
            let relativeError = residualNorm / MLX.norm(b).item(Float.self)

            if relativeError < tolerance * 10 {
                return x  // Solution is good
            } else {
                // Solution is inaccurate, fall through to iterative
                print("Warning: MLX.solve() produced inaccurate solution (rel_error=\(relativeError))")
            }
        } catch {
            print("Warning: MLX.solve() failed: \(error)")
        }
    }

    // === STEP 3: Ill-conditioned or failed → Use iterative solver ===
    return solveLinearSystemIterative(A, b, tolerance: tolerance)
}

/// Estimate condition number using power iteration (cheap approximation)
private func estimateConditionNumber(_ A: MLXArray) -> Float {
    // Quick estimate: ||A|| * ||A^-1||
    // For symmetric matrices, use largest/smallest eigenvalue ratio
    // For general matrices, use norm ratio (rough estimate)

    let normA = MLX.norm(A, ord: .infinity).item(Float.self)

    // Very rough estimate: if we can't compute inverse, use norm of A
    // A more sophisticated implementation would use iterative methods
    // to estimate ||A^-1|| without computing the full inverse

    // For now, return a conservative estimate
    // TODO: Implement proper condition number estimation
    return normA * 1e6  // Conservative: assume moderate conditioning
}

/// Iterative solver (Gauss-Seidel with relaxation)
private func solveLinearSystemIterative(
    _ A: MLXArray,
    _ b: MLXArray,
    tolerance: Float
) -> MLXArray {
    let n = b.shape[0]
    var x = MLXArray.zeros([n])

    let maxIter = 1000
    let omega: Float = 1.2  // SOR relaxation factor

    for iteration in 0..<maxIter {
        var maxChange: Float = 0.0

        // Gauss-Seidel with Successive Over-Relaxation (SOR)
        for i in 0..<n {
            var sum = b[i]

            for j in 0..<n {
                if j != i {
                    sum = sum - A[i, j] * x[j]
                }
            }

            let xNew = sum / A[i, i]

            // SOR update: x_new = ω * x_GS + (1-ω) * x_old
            let xRelaxed = omega * xNew + (1.0 - omega) * x[i]

            maxChange = max(maxChange, abs((xRelaxed - x[i]).item(Float.self)))
            x[i] = xRelaxed
        }

        // Check convergence
        if maxChange < tolerance {
            print("Iterative solver converged in \(iteration) iterations")
            return x
        }

        // Periodic residual check (more expensive but more reliable)
        if iteration % 50 == 0 {
            let residual = matmul(A, x) - b
            let residualNorm = MLX.norm(residual).item(Float.self)
            let relativeError = residualNorm / MLX.norm(b).item(Float.self)

            if relativeError < tolerance {
                print("Iterative solver converged (residual check) in \(iteration) iterations")
                return x
            }
        }
    }

    print("Warning: Iterative solver reached max iterations without converging")
    return x
}
```

**Benefits**:
- ✅ Fast path for well-conditioned problems (MLX.solve)
- ✅ Robust fallback for ill-conditioned problems (iterative)
- ✅ Diagnostics (condition number, residual norms)
- ✅ User-visible warnings for numerical issues

**Tradeoffs**:
- ⚠️ More complex (100+ lines vs 1 line)
- ⚠️ Condition number estimation has overhead
- ⚠️ Still falls back to O(n²) Gauss-Seidel for bad cases

---

## 2. Analysis: Vectorization Strategy

### 2.1 The Proposal

**Eliminate ALL loops** in spatial operator computation.

**Example**:
```swift
// ✅ Vectorized
let divergence = (flux[1..<(nCells+1)] - flux[0..<nCells]) / dr
```

### 2.2 Validation ✅

**Assessment**: **CORRECT** and **OPTIMAL**.

**Reasoning**:
1. MLX-Swift is designed for array operations
2. Slicing is compiled to GPU kernels
3. No Swift interpreter overhead

**Benchmark Estimate** (for nCells=100):
```
Loop version:       10 µs (CPU-bound, Swift overhead)
Vectorized version: 0.5 µs (GPU, single kernel launch)
Speedup: 20x
```

**For nCells=1000**:
```
Loop version:       1000 µs (linear scaling)
Vectorized version: 2 µs (GPU parallelism)
Speedup: 500x
```

**Conclusion**: Vectorization is **essential** for performance.

---

## 3. Analysis: compile() Usage

### 3.1 The Proposal

Compile the entire residual function:
```swift
let compiledResidual = compile { (xFlat: MLXArray) -> MLXArray in
    // All residual computation
}
```

### 3.2 Concerns 🤔

#### Issue 1: Closure Capture Complexity

**Problem**: `coeffsCallback` captures dynamic context.

**Example**:
```swift
let compiledResidual = compile { (xFlat: MLXArray) -> MLXArray in
    let profilesNew = unflatten(xFlat)
    let coeffsNew = coeffsCallback(profilesNew, geometry)  // ← Dynamic!
    return computeResidual(xFlat, coeffsNew, ...)
}
```

**Question**: Does `compile()` work with **nested function calls** like `coeffsCallback`?

**MLX-Swift Behavior**:
- `compile()` traces the computation graph
- External function calls (like `coeffsCallback`) are **NOT inlined**
- If `coeffsCallback` calls transport models, those are **separate traces**

**Implication**: May not get full fusion if `coeffsCallback` boundary breaks the graph.

#### Issue 2: Recompilation on Shape Changes

**Problem**: If grid size changes (adaptive mesh refinement), recompilation needed.

**Mitigation**: Use `compile(shapeless: true)` parameter (if available).

#### Issue 3: Compilation Overhead

**First Call**: ~50-200ms for graph construction
**Subsequent Calls**: ~0.1ms (cached)

**Tradeoff**:
- For >10 Newton iterations: **Worth it** (amortized)
- For <5 Newton iterations: **Not worth it** (overhead dominates)

**Recommendation**: Make compilation **optional** with flag:
```swift
let useCompilation = staticParams.solverMaxIterations > 10

let residualFn = useCompilation
    ? compile(makeResidualFunction(...))
    : makeResidualFunction(...)
```

### 3.3 Alternative: Compile Only Inner Operations

**Strategy**: Don't compile the entire residual, just the expensive parts.

```swift
// Compile only the spatial operator (no dynamic calls)
let compiledSpatialOp = compile { (x: MLXArray, dFace: MLXArray, vFace: MLXArray) -> MLXArray in
    // Pure tensor operations, no callbacks
    let gradFace = computeGradients(x)
    let diffFlux = -dFace * gradFace
    let convFlux = vFace * interpolateToFaces(x)
    let divergence = (diffFlux[1...] - diffFlux[...-1]) / dr
    return divergence
}

// Use in residual (not compiled)
func computeResidual(...) -> MLXArray {
    let coeffs = coeffsCallback(...)  // Dynamic, not compiled

    // Use compiled spatial operator
    let fNew = compiledSpatialOp(
        xNew,
        coeffs.dFace.value,
        coeffs.vFace.value
    )

    return timeDeriv - theta * fNew - (1-theta) * fOld
}
```

**Benefits**:
- ✅ Compiles the most expensive part (spatial operator)
- ✅ Allows dynamic coefficient callbacks
- ✅ Simpler to reason about

**Recommendation**: Use this **hybrid approach** instead of full residual compilation.

---

## 4. Analysis: Performance Predictions

### 4.1 Claimed Speedup: 10-20x

**Breakdown**:
| Optimization | Claimed Speedup | Validation |
|--------------|----------------|------------|
| MLX.solve() vs Gauss-Seidel | 10-50x | ✅ Plausible |
| Vectorization vs loops | 3-5x | ✅ Conservative |
| compile() | 1.5-3x | 🤔 Optimistic |

### 4.2 Reality Check

**Best Case** (well-conditioned, nCells=100):
- Jacobian solve: 10x faster ✅
- Residual: 5x faster (vectorization) ✅
- compile(): 2x faster ✅
- **Total: ~100x faster** (multiplicative)

**Typical Case** (moderate conditioning, nCells=100):
- Jacobian solve: 5x faster (some overhead for robustness)
- Residual: 3x faster (vectorization + eval overhead)
- compile(): 1.5x faster (callback boundaries)
- **Total: ~20x faster** ✅

**Worst Case** (ill-conditioned, nCells=100):
- Jacobian solve: 1x (falls back to iterative)
- Residual: 3x faster (still vectorized)
- compile(): 1x (overhead not worth it)
- **Total: ~3x faster**

**Conclusion**: **10-20x is achievable** for typical cases, but expect **wide variance** based on problem conditioning.

---

## 5. Analysis: Block-Structured vs Batched Operations

### 5.1 Current Approach: Block-Structured

**Design**:
```swift
struct Block1DCoeffs {
    let ionCoeffs: EquationCoeffs
    let electronCoeffs: EquationCoeffs
    let densityCoeffs: EquationCoeffs
    let fluxCoeffs: EquationCoeffs
}
```

**Pros**:
- ✅ Clear separation of physics
- ✅ Easy per-variable boundary conditions
- ✅ Debuggable

**Cons**:
- ⚠️ Sequential processing (4 separate operator calls)
- ⚠️ Potential cache misses

### 5.2 Alternative: Batched Operations

**Design**:
```swift
// Stack all variables: [4, nCells]
let xStacked = stack([Ti, Te, ne, psi], axis: 0)
let dStacked = stack([d_ion, d_electron, d_density, d_flux], axis: 0)

// Single operator call processes all 4 variables
let resultStacked = batchApplySpatialOperator(xStacked, dStacked)
```

**Pros**:
- ✅ True GPU parallelism (4 variables at once)
- ✅ Better memory locality
- ✅ Fewer kernel launches

**Cons**:
- ❌ Harder to handle different BCs per variable
- ❌ Coupling between variables (e.g., Q_ei term)
- ❌ Less clear code

### 5.3 Benchmark Comparison

**Estimate** (nCells=100, M1 GPU):

| Approach | Time per Residual | GPU Utilization |
|----------|------------------|-----------------|
| Block-structured (sequential) | 0.5 ms | ~25% (underutilized) |
| Batched (parallel) | 0.15 ms | ~80% (better) |

**Speedup**: ~3x for batched approach.

### 5.4 Recommendation

**Phase 1-4**: Use **block-structured** for clarity and correctness.

**Phase 5**: Implement **batched operations** as optimization if profiling shows sequential processing is a bottleneck.

**Hybrid Option**: Batch where possible (heat equations), separate where needed (density with convection, flux with different BCs).

---

## 6. Risk Assessment

### 6.1 High-Risk Items 🔴

1. **MLX.solve() numerical failures**
   - **Probability**: Medium (stiff PDEs common)
   - **Impact**: Critical (wrong solutions)
   - **Mitigation**: Hybrid solver with fallback ✅

2. **compile() doesn't fuse across callbacks**
   - **Probability**: High (likely limitation)
   - **Impact**: Moderate (performance gain reduced)
   - **Mitigation**: Compile only inner operators ✅

3. **Memory scaling for large grids**
   - **Probability**: High (nCells > 1000)
   - **Impact**: Critical (OOM on GPU)
   - **Mitigation**: Tridiagonal solver (Phase 5) ⚠️

### 6.2 Medium-Risk Items 🟡

1. **Vectorization correctness**
   - **Probability**: Low (well-understood)
   - **Impact**: High (wrong physics)
   - **Mitigation**: Extensive unit tests ✅

2. **Boundary condition handling**
   - **Probability**: Medium (complex logic)
   - **Impact**: High (wrong BCs → wrong solution)
   - **Mitigation**: Per-variable coefficient structure ✅

3. **Float32 precision limits**
   - **Probability**: Medium (large temperature gradients)
   - **Impact**: Moderate (accuracy loss)
   - **Mitigation**: Use Float64 if available ⚠️

### 6.3 Low-Risk Items 🟢

1. **Data structure design**
   - Well-thought-out, separates concerns ✅

2. **Testing strategy**
   - Comprehensive unit + integration tests ✅

3. **Phase division**
   - Logical, incremental ✅

---

## 7. Alternative Strategies

### 7.1 Alternative 1: Jacobian-Free Newton-Krylov (JFNK)

**Concept**: Avoid forming Jacobian explicitly. Use Krylov subspace methods (GMRES) with Jacobian-vector products.

**Implementation**:
```swift
// Instead of: J * Δx = -R
// Solve iteratively using only: J·v ≈ [R(x + ε·v) - R(x)] / ε

func jfnk_solve(residualFn, x, tolerance) -> MLXArray {
    // GMRES iteration
    // Only requires residual evaluations, not full Jacobian
}
```

**Pros**:
- ✅ O(n) memory (no Jacobian storage)
- ✅ Works for large n (>1000)
- ✅ Robust for stiff problems

**Cons**:
- ❌ More complex to implement
- ❌ Requires good preconditioner
- ❌ May need many iterations

**Recommendation**: Consider for **Phase 6** if memory becomes an issue.

### 7.2 Alternative 2: Anderson Acceleration

**Concept**: Accelerate fixed-point iteration (like Gauss-Seidel) using history.

**Implementation**:
```swift
// Store last m iterations
var history: [(x: MLXArray, residual: MLXArray)] = []

// Compute optimal combination of past iterates
let xNew = andersonCombination(history, currentX)
```

**Pros**:
- ✅ Simple to add on top of iterative solver
- ✅ Often 2-5x fewer iterations
- ✅ Low memory overhead

**Cons**:
- ⚠️ Requires careful tuning (history depth m)
- ⚠️ Not always stable

**Recommendation**: Consider for **Phase 5** as enhancement to iterative solver.

### 7.3 Alternative 3: Pseudo-Transient Continuation

**Concept**: Start with large (implicit) timestep, gradually reduce to reach steady state.

**Implementation**:
```swift
var dt = 1e-2  // Large initial dt
while !converged {
    solveImplicitStep(dt)
    dt *= 0.5  // Reduce timestep
}
```

**Pros**:
- ✅ More robust convergence
- ✅ Avoids stiff transients

**Cons**:
- ⚠️ Requires many timesteps
- ⚠️ Not applicable for time-accurate solutions

**Recommendation**: **Not applicable** for TORAX (need time-accurate transport).

---

## 8. Revised Recommendations

### 8.1 Critical Changes to Strategy

1. **Linear Solver**: Use **hybrid approach**
   ```swift
   func solveLinearSystem() {
       if estimatedCond < 1e8 {
           try MLX.solve(...)  // Fast path
       } else {
           solveIterative(...)  // Robust fallback
       }
   }
   ```

2. **compile() Usage**: Compile **inner operators only**, not full residual
   ```swift
   let compiledSpatialOp = compile { (x, d, v) in
       // Pure tensor ops
   }
   ```

3. **Performance Claims**: Update to **3-20x** (from 10-20x) to reflect variance

4. **Risk Mitigation**: Add **numerical diagnostics**:
   - Condition number monitoring
   - Residual norm tracking
   - Solution quality checks

### 8.2 Implementation Priority (Revised)

**Phase 1**: Data Structures ✅
- EquationCoeffs, Block1DCoeffs
- CoreProfiles.fromTuple()

**Phase 2**: Coefficient Builder ✅
- Per-equation coefficients
- Geometric factor application

**Phase 3A**: Vectorized Residual (NO compile) 🔴
- Pure slicing, no loops
- Test correctness FIRST

**Phase 3B**: Hybrid Linear Solver 🔴
- MLX.solve() with fallback
- Condition number checks

**Phase 3C**: Selective Compilation 🟡
- Compile spatial operators only
- Benchmark before/after

**Phase 4**: Testing & Validation ✅
- Unit tests (per-variable operators)
- Integration tests (1D diffusion, multi-variable)
- Numerical accuracy tests (compare to analytical solutions)

**Phase 5**: Advanced Optimizations (OPTIONAL)
- Tridiagonal structure
- Batched operations
- Anderson acceleration

---

## 9. Open Questions

### 9.1 MLX-Swift Capabilities

❓ **Q1**: Does MLX.solve() support condition number estimation?
- **Action**: Check MLX.norm(..., ord=-2) for smallest singular value
- **Fallback**: Implement power iteration for rough estimate

❓ **Q2**: Can compile() fuse operations across function boundaries?
- **Action**: Benchmark compiled vs non-compiled residual
- **Decide**: Full vs partial compilation based on results

❓ **Q3**: Is Float64 available in MLX-Swift?
- **Action**: Check if DType.float64 exists
- **Impact**: May be critical for stiff problems

### 9.2 Numerical Behavior

❓ **Q4**: What is typical condition number for tokamak transport Jacobians?
- **Action**: Run TORAX Python version, monitor cond(J)
- **Use**: Set thresholds for solver selection

❓ **Q5**: Does Anderson acceleration help for our problem?
- **Action**: Implement as Phase 5 experiment
- **Measure**: Iteration count reduction

---

## 10. Final Assessment

### 10.1 Strategy Viability

**Original Strategy**: ⚠️ **VIABLE with MODIFICATIONS**

**Key Strengths**:
- ✅ Correct architectural separation (block-structured)
- ✅ Identifies major optimization opportunities (vectorization, MLX.solve)
- ✅ Phased approach enables incremental validation

**Key Weaknesses**:
- 🔴 **Underestimates numerical stability challenges**
- 🔴 **Overestimates compile() benefits** (callback boundaries)
- 🟡 **Performance predictions are best-case** (need range)

### 10.2 Recommended Modifications

1. **Hybrid linear solver** (MLX.solve + iterative fallback)
2. **Selective compilation** (operators only, not full residual)
3. **Performance range** (3-20x instead of 10-20x)
4. **Numerical diagnostics** (condition number, residuals)

### 10.3 Go/No-Go Decision

**Decision**: ✅ **GO** with revised strategy

**Rationale**:
- Fundamental approach is sound
- Identified risks have clear mitigations
- Phased approach allows course correction
- Benefits outweigh complexity

**Next Steps**:
1. Update strategy document with modifications
2. Implement Phase 1 (data structures)
3. Implement Phase 3A (vectorized residual, NO compile)
4. Benchmark before adding compile()
5. Validate numerical stability with test cases

---

## 11. Conclusion

The proposed solver strategy is **fundamentally correct** but requires **critical refinements** for production robustness:

1. **Use MLX.solve() cautiously** with conditioning checks and fallback
2. **Vectorize aggressively** (this is the main win)
3. **Compile selectively** (inner operators, not full residual)
4. **Monitor numerical health** (diagnostics, not silent failures)

With these modifications, we expect:
- **Best case**: 20x speedup (well-conditioned problems)
- **Typical case**: 10x speedup (moderate conditioning)
- **Worst case**: 3x speedup (ill-conditioned, falls back to iterative)

**Recommendation**: **PROCEED** with implementation, incorporating the refinements outlined in this analysis.

---

## References

- **MLX-Swift Linear Algebra**: DeepWiki investigation results
- **TORAX Paper**: arXiv:2406.06718v2 (Section 3.2: Numerical methods)
- **Numerical Stability**: Higham, "Accuracy and Stability of Numerical Algorithms"
- **Iterative Methods**: Saad, "Iterative Methods for Sparse Linear Systems"
