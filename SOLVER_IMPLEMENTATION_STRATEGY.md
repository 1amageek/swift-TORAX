# Solver Implementation Strategy

**Version**: 1.0
**Date**: 2025-10-17
**Purpose**: Efficient multi-variable PDE solver implementation for TORAX

---

## Executive Summary

This document outlines the strategy for implementing an efficient Newton-Raphson solver for the coupled transport equations in TORAX. The key challenge is handling **4 coupled variables** (Ti, Te, ne, psi) with **different transport coefficients** and **different source terms** while maximizing computational efficiency using MLX's parallel capabilities.

---

## Problem Statement

### Current Issues

1. **❌ Single coefficient set for 4 equations**: `Block1DCoeffs` treats all variables uniformly
2. **❌ FlattenedState loses variable identity**: Cannot apply different operators to Ti, Te, ne, psi
3. **❌ Index out of bounds**: `gradFace` loop doesn't set last element
4. **❌ Missing conversion**: `CoreProfiles.fromTuple()` doesn't exist
5. **❌ Wrong algorithm**: Gauss-Seidel is actually Jacobi
6. **❌ Unused coefficients**: `transientInCell`, `transientOutCell`, `sourceMatCell` not used

### Correct Physics

```
Ion temperature:        ∂Ti/∂t = (1/V)·∂/∂r(V·χ_i·∂Ti/∂r) + S_i
Electron temperature:   ∂Te/∂t = (1/V)·∂/∂r(V·χ_e·∂Te/∂r) + S_e + Q_ei
Electron density:       ∂ne/∂t = (1/V)·∂/∂r(V·D·∂ne/∂r) + (1/V)·∂/∂r(V·v·ne) + S_n
Poloidal flux:          ∂psi/∂t = η·∇²psi + S_psi
```

Each equation has:
- **Different diffusion coefficients**: χ_i, χ_e, D, η
- **Different source terms**: S_i, S_e, Q_ei, S_n, S_psi
- **Same geometric factors**: V(r), surface area A(r)

---

## Design Strategy

### Core Principle: Separation of Concerns

```
┌─────────────────────────────────────────────────────────────────┐
│ FlattenedState: [Ti₀, Ti₁, ..., Te₀, Te₁, ..., ne₀, ..., psi₀] │
│                  ↓                                                │
│ StateLayout: Track which indices belong to which variable       │
│                  ↓                                                │
│ Per-Variable Operators: Apply different physics to each slice   │
│                  ↓                                                │
│ Reassemble: Combine results back to FlattenedState              │
└─────────────────────────────────────────────────────────────────┘
```

### Strategy 1: Block-Structured Coefficients (RECOMMENDED)

**Idea**: Extend `Block1DCoeffs` to hold separate coefficient arrays for each variable.

```swift
public struct Block1DCoeffs: Sendable {
    // Separate coefficients for each equation
    public let ionCoeffs: EquationCoeffs       // For Ti equation
    public let electronCoeffs: EquationCoeffs  // For Te equation
    public let densityCoeffs: EquationCoeffs   // For ne equation
    public let fluxCoeffs: EquationCoeffs      // For psi equation
}

public struct EquationCoeffs: Sendable {
    public let dFace: EvaluatedArray           // Diffusion on faces [nFaces]
    public let vFace: EvaluatedArray           // Convection on faces [nFaces]
    public let sourceCell: EvaluatedArray      // Explicit sources [nCells]
    public let sourceMatCell: EvaluatedArray   // Implicit source matrix [nCells]
    public let transientCoeff: EvaluatedArray  // Time derivative coefficient [nCells]
}
```

**Advantages**:
- ✅ Clear separation of physics per equation
- ✅ Easy to apply different BCs per variable
- ✅ Straightforward debugging (inspect per-equation coefficients)
- ✅ Matches TORAX architecture

**Disadvantages**:
- ⚠️ Slightly more memory (4 × nCells × 5 arrays)
- ⚠️ More complex coefficient construction

### Strategy 2: Vectorized Batch Operations (ALTERNATIVE)

**Idea**: Stack all variables as `[4, nCells]` and process in batch.

```swift
// Stack variables: shape [4, nCells]
let stacked = MLX.stacked([Ti, Te, ne, psi], axis: 0)

// Stack diffusion coefficients: shape [4, nFaces]
let chiStacked = MLX.stacked([chiIon, chiElectron, D, eta], axis: 0)

// Apply operator to all variables at once (vectorized)
let result = batchApplySpatialOperator(stacked, chiStacked)
```

**Advantages**:
- ✅ Maximal GPU parallelism (process all 4 variables simultaneously)
- ✅ Fewer function calls
- ✅ Compact code

**Disadvantages**:
- ❌ Harder to handle different BC types per variable
- ❌ Coupling between variables (e.g., Q_ei term) requires special handling
- ❌ Less intuitive for debugging

---

## Chosen Strategy: Hybrid Approach

### Design Decision

Use **Strategy 1 (Block-Structured)** for coefficient representation, but implement **vectorized operations** where beneficial:

1. **Coefficients**: Store per-equation for clarity
2. **Residual computation**: Vectorize where possible
3. **Jacobian**: Use FlattenedState + vjp() (already optimal)

### Rationale

- TORAX uses per-equation coefficients → easier to port examples
- Debugging is critical → need per-variable inspection
- vjp() already handles vectorization automatically → no manual optimization needed
- Future extensions (e.g., multi-ion, impurities) easier with per-equation structure

---

## Implementation Plan

### Phase 1: Data Structure Redesign

#### 1.1 Create `EquationCoeffs`

```swift
// File: Sources/TORAX/Core/EquationCoeffs.swift
public struct EquationCoeffs: Sendable {
    public let dFace: EvaluatedArray           // [nFaces] diffusion
    public let vFace: EvaluatedArray           // [nFaces] convection
    public let sourceCell: EvaluatedArray      // [nCells] explicit source
    public let sourceMatCell: EvaluatedArray   // [nCells] implicit source matrix
    public let transientCoeff: EvaluatedArray  // [nCells] ∂/∂t coefficient
}
```

#### 1.2 Redesign `Block1DCoeffs`

```swift
// File: Sources/TORAX/Core/Block1DCoeffs.swift (modify)
public struct Block1DCoeffs: Sendable {
    public let ionCoeffs: EquationCoeffs
    public let electronCoeffs: EquationCoeffs
    public let densityCoeffs: EquationCoeffs
    public let fluxCoeffs: EquationCoeffs

    // Geometric factors (shared across all equations)
    public let g0Face: EvaluatedArray  // [nFaces] g0 = R²
    public let g1Face: EvaluatedArray  // [nFaces] g1 = R
    public let g2Face: EvaluatedArray  // [nFaces] g2 = 1
    public let g3Face: EvaluatedArray  // [nFaces] g3 = r
    public let volumeCell: EvaluatedArray  // [nCells] V = 2π²Ra²
}
```

#### 1.3 Add `CoreProfiles` Conversions

```swift
// File: Sources/TORAX/Extensions/CoreProfiles+Extensions.swift
extension CoreProfiles {
    /// Create from CellVariable tuple
    public static func fromTuple(
        _ tuple: (CellVariable, CellVariable, CellVariable, CellVariable)
    ) -> CoreProfiles {
        CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: tuple.0.value.value),
            electronTemperature: EvaluatedArray(evaluating: tuple.1.value.value),
            electronDensity: EvaluatedArray(evaluating: tuple.2.value.value),
            poloidalFlux: EvaluatedArray(evaluating: tuple.3.value.value)
        )
    }
}
```

### Phase 2: Coefficient Builder Redesign

#### 2.1 Build Per-Equation Coefficients

```swift
// File: Sources/TORAX/Solver/Block1DCoeffsBuilder.swift (rewrite)
public func buildBlock1DCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams
) -> Block1DCoeffs {
    let nCells = transport.chiIon.shape[0]
    let nFaces = nCells + 1

    // Geometric factors on faces
    let g0Face = geometry.g0.value  // Already [nFaces]
    let g1Face = geometry.g1.value
    let g2Face = geometry.g2.value
    let g3Face = geometry.g3.value
    let volumeCell = geometry.volume.value  // [nCells]

    // --- Ion Temperature Equation ---
    let chiIonFaces = interpolateToFaces(transport.chiIon.value)
    let dFaceIon = chiIonFaces * g1Face / g0Face
    let ionCoeffs = EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFaceIon),
        vFace: EvaluatedArray.zeros([nFaces]),  // No convection for heat
        sourceCell: EvaluatedArray(evaluating: sources.ionHeating.value / volumeCell),
        sourceMatCell: EvaluatedArray.zeros([nCells]),
        transientCoeff: EvaluatedArray(evaluating: volumeCell)
    )

    // --- Electron Temperature Equation ---
    let chiElectronFaces = interpolateToFaces(transport.chiElectron.value)
    let dFaceElectron = chiElectronFaces * g1Face / g0Face
    let electronCoeffs = EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFaceElectron),
        vFace: EvaluatedArray.zeros([nFaces]),
        sourceCell: EvaluatedArray(evaluating: sources.electronHeating.value / volumeCell),
        sourceMatCell: EvaluatedArray.zeros([nCells]),  // TODO: Q_ei implicit term
        transientCoeff: EvaluatedArray(evaluating: volumeCell)
    )

    // --- Electron Density Equation ---
    let dFaceDensity = interpolateToFaces(transport.particleDiffusivity.value) * g1Face / g0Face
    let vFaceDensity = interpolateToFaces(transport.convectionVelocity.value) * g1Face / g0Face
    let densityCoeffs = EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFaceDensity),
        vFace: EvaluatedArray(evaluating: vFaceDensity),
        sourceCell: EvaluatedArray(evaluating: sources.particleSource.value / volumeCell),
        sourceMatCell: EvaluatedArray.zeros([nCells]),
        transientCoeff: EvaluatedArray(evaluating: volumeCell)
    )

    // --- Poloidal Flux Equation ---
    // TODO: Compute resistivity η from profiles
    let etaFaces = MLXArray.full([nFaces], values: 1e-7)  // Placeholder
    let dFaceFlux = etaFaces
    let fluxCoeffs = EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFaceFlux),
        vFace: EvaluatedArray.zeros([nFaces]),
        sourceCell: EvaluatedArray(evaluating: sources.currentSource.value),
        sourceMatCell: EvaluatedArray.zeros([nCells]),
        transientCoeff: EvaluatedArray.ones([nCells])
    )

    return Block1DCoeffs(
        ionCoeffs: ionCoeffs,
        electronCoeffs: electronCoeffs,
        densityCoeffs: densityCoeffs,
        fluxCoeffs: fluxCoeffs,
        g0Face: EvaluatedArray(evaluating: g0Face),
        g1Face: EvaluatedArray(evaluating: g1Face),
        g2Face: EvaluatedArray(evaluating: g2Face),
        g3Face: EvaluatedArray(evaluating: g3Face),
        volumeCell: EvaluatedArray(evaluating: volumeCell)
    )
}
```

### Phase 3: Residual Computation Redesign

#### 3.1 Apply Spatial Operator Per Variable

```swift
// File: Sources/TORAX/Solver/NewtonRaphsonSolver.swift (modify)
private func computeThetaMethodResidual(
    xOld: MLXArray,
    xNew: MLXArray,
    coeffsOld: Block1DCoeffs,
    coeffsNew: Block1DCoeffs,
    dt: Float,
    theta: Float,
    layout: FlattenedState.StateLayout
) -> MLXArray {
    // Extract per-variable slices
    let tiOld = xOld[layout.tiRange]
    let teOld = xOld[layout.teRange]
    let neOld = xOld[layout.neRange]
    let psiOld = xOld[layout.psiRange]

    let tiNew = xNew[layout.tiRange]
    let teNew = xNew[layout.teRange]
    let neNew = xNew[layout.neRange]
    let psiNew = xNew[layout.psiRange]

    // Apply operator to each variable with its own coefficients
    let fTiOld = applySpatialOperator(tiOld, coeffs: coeffsOld.ionCoeffs)
    let fTiNew = applySpatialOperator(tiNew, coeffs: coeffsNew.ionCoeffs)
    let rTi = thetaMethodResidual(tiOld, tiNew, fTiOld, fTiNew, dt, theta, coeffsNew.ionCoeffs.transientCoeff.value)

    let fTeOld = applySpatialOperator(teOld, coeffs: coeffsOld.electronCoeffs)
    let fTeNew = applySpatialOperator(teNew, coeffs: coeffsNew.electronCoeffs)
    let rTe = thetaMethodResidual(teOld, teNew, fTeOld, fTeNew, dt, theta, coeffsNew.electronCoeffs.transientCoeff.value)

    let fNeOld = applySpatialOperator(neOld, coeffs: coeffsOld.densityCoeffs)
    let fNeNew = applySpatialOperator(neNew, coeffs: coeffsNew.densityCoeffs)
    let rNe = thetaMethodResidual(neOld, neNew, fNeOld, fNeNew, dt, theta, coeffsNew.densityCoeffs.transientCoeff.value)

    let fPsiOld = applySpatialOperator(psiOld, coeffs: coeffsOld.fluxCoeffs)
    let fPsiNew = applySpatialOperator(psiNew, coeffs: coeffsNew.fluxCoeffs)
    let rPsi = thetaMethodResidual(psiOld, psiNew, fPsiOld, fPsiNew, dt, theta, coeffsNew.fluxCoeffs.transientCoeff.value)

    // Concatenate residuals: [rTi; rTe; rNe; rPsi]
    return concatenated([rTi, rTe, rNe, rPsi], axis: 0)
}

private func thetaMethodResidual(
    _ xOld: MLXArray,
    _ xNew: MLXArray,
    _ fOld: MLXArray,
    _ fNew: MLXArray,
    _ dt: Float,
    _ theta: Float,
    _ transientCoeff: MLXArray
) -> MLXArray {
    // R = transient * (x^{n+1} - x^n) / dt - θ*f^{n+1} - (1-θ)*f^n
    let timeDeriv = transientCoeff * (xNew - xOld) / dt
    return timeDeriv - theta * fNew - (1.0 - theta) * fOld
}

private func applySpatialOperator(
    _ x: MLXArray,
    coeffs: EquationCoeffs
) -> MLXArray {
    let nCells = x.shape[0]

    // Extract coefficients
    let dFace = coeffs.dFace.value  // [nFaces]
    let vFace = coeffs.vFace.value
    let sourceCell = coeffs.sourceCell.value

    // Interpolate to faces
    let xFace = interpolateToFaces(x)  // [nFaces]

    // Compute gradients at faces: (x[i+1] - x[i]) / dr
    // FIXED: Use proper slicing
    let xLeft = x  // [nCells]
    let xRight = concatenated([x[1..<nCells], x[(nCells-1)..<nCells]], axis: 0)  // [nCells]

    // Pad for face gradient calculation
    let xPadded = concatenated([x[0..<1], x, x[(nCells-1)..<nCells]], axis: 0)  // [nCells+2]
    let gradFace = (xPadded[1..<(nCells+2)] - xPadded[0..<(nCells+1)]) / dr  // [nCells+1]

    // Diffusion flux: -D * ∇x
    let diffFlux = -dFace * gradFace

    // Convection flux: v * x
    let convFlux = vFace * xFace

    // Total flux
    let totalFlux = diffFlux + convFlux

    // Divergence: (flux[i+1] - flux[i]) / dr
    let divergence = (totalFlux[1..<(nCells+1)] - totalFlux[0..<nCells]) / dr

    // f(x) = divergence + source
    return divergence + sourceCell
}
```

#### 3.2 Vectorized Gradient Computation (Optimization)

```swift
/// Compute face gradients using MLX slicing (no loops!)
private func computeFaceGradients(_ cellValues: MLXArray, dr: Float) -> MLXArray {
    let nCells = cellValues.shape[0]

    // Pad with boundary values
    let padded = concatenated([
        cellValues[0..<1],         // Left BC: repeat first value
        cellValues,                // Interior
        cellValues[(nCells-1)..<nCells]  // Right BC: repeat last value
    ], axis: 0)

    // Forward difference: (x[i+1] - x[i]) / dr
    let gradients = (padded[1..<(nCells+2)] - padded[0..<(nCells+1)]) / dr

    return gradients  // Shape: [nCells+1]
}
```

### Phase 4: Linear Solver Fix

#### 4.1 Correct Gauss-Seidel Implementation

```swift
private func solveLinearSystem(_ A: MLXArray, _ b: MLXArray) -> MLXArray {
    let n = b.shape[0]
    var x = MLXArray.zeros([n])

    let maxIter = 100
    let tolerance: Float = 1e-8

    for iteration in 0..<maxIter {
        var maxChange: Float = 0.0

        // Gauss-Seidel: update x in-place (use latest values immediately)
        for i in 0..<n {
            var sum = b[i]

            // Use already-updated values for j < i (Gauss-Seidel)
            for j in 0..<i {
                sum = sum - A[i, j] * x[j]
            }

            // Use old values for j > i
            for j in (i+1)..<n {
                sum = sum - A[i, j] * x[j]
            }

            let xNew = sum / A[i, i]
            maxChange = max(maxChange, abs((xNew - x[i]).item(Float.self)))
            x[i] = xNew
        }

        // Check convergence
        if maxChange < tolerance {
            break
        }
    }

    return x
}
```

#### 4.2 Future: Use MLX.Linalg (When Available)

```swift
// TODO: Replace with MLX built-in when available
// let delta = MLX.Linalg.solve(jacobian, -residual)
```

---

## Performance Optimizations

### 1. Minimize eval() Calls

**Strategy**: Batch evaluations at outer loop boundaries only.

```swift
// ❌ BAD: Evaluate every iteration
for i in 0..<maxIter {
    let residual = computeResidual(...)
    eval(residual)  // Expensive!
    let jacobian = computeJacobian(...)
    eval(jacobian)  // Expensive!
}

// ✅ GOOD: Evaluate only when needed
for i in 0..<maxIter {
    let residual = computeResidual(...)
    let jacobian = computeJacobian(...)
    let delta = solve(jacobian, residual)

    // Only evaluate for convergence check (every 5 iterations)
    if i % 5 == 0 {
        eval(residual)
        if norm(residual) < tol { break }
    }
}
eval(xFinal)  // Ensure final result is evaluated
```

### 2. Avoid Loops with MLX Slicing

**Strategy**: Use array slicing instead of element-wise loops.

```swift
// ❌ BAD: Element-wise loop
for i in 0..<nCells {
    divergence[i] = (flux[i+1] - flux[i]) / dr
}

// ✅ GOOD: Vectorized slicing
let divergence = (flux[1..<(nCells+1)] - flux[0..<nCells]) / dr
```

### 3. Reuse Interpolated Values

```swift
// Compute once, use multiple times
let xFace = interpolateToFaces(x)
let diffFlux = -dFace * computeGradients(xFace)
let convFlux = vFace * xFace  // Reuse xFace
```

---

## Testing Strategy

### Unit Tests

1. **Test per-variable operators**:
   ```swift
   @Test("Apply spatial operator to single variable")
   func testApplySpatialOperator() {
       let x = MLXArray([1.0, 2.0, 3.0, 4.0, 5.0])
       let coeffs = EquationCoeffs(...)
       let result = applySpatialOperator(x, coeffs: coeffs)
       #expect(result.shape == [5])
   }
   ```

2. **Test residual assembly**:
   ```swift
   @Test("Assemble 4-variable residual correctly")
   func testResidualAssembly() {
       // Create FlattenedState with known values
       // Compute residual
       // Verify each slice independently
   }
   ```

3. **Test gradient computation**:
   ```swift
   @Test("Face gradients computed correctly")
   func testFaceGradients() {
       let x = MLXArray([1.0, 2.0, 3.0])  // Linear profile
       let grad = computeFaceGradients(x, dr: 0.1)
       #expect(grad.shape == [4])  // nCells + 1
       // All gradients should be 10.0 for linear profile
   }
   ```

### Integration Tests

1. **1D heat diffusion**:
   ```swift
   @Test("1D heat equation converges")
   func test1DHeatDiffusion() {
       // Set up simple diffusion problem
       // χ = 1.0, no sources, boundary conditions T(0)=1, T(1)=0
       // Run solver
       // Check steady-state solution matches analytical
   }
   ```

2. **Multi-variable coupling**:
   ```swift
   @Test("4-variable system solves without crash")
   func testMultiVariableSystem() {
       // Set up realistic plasma profiles
       // Run one timestep
       // Verify all variables updated, no NaN/Inf
   }
   ```

---

## Migration Plan

### Step 1: Create New Data Structures (Non-Breaking)

- Add `EquationCoeffs.swift`
- Add `CoreProfiles.fromTuple()` extension
- Keep old `Block1DCoeffs` temporarily

### Step 2: Rewrite `buildBlock1DCoeffs` (Breaking)

- Create new version with per-equation output
- Update call sites in `SimulationOrchestrator`

### Step 3: Rewrite `NewtonRaphsonSolver` (Breaking)

- Implement per-variable residual computation
- Fix index bugs
- Fix Gauss-Seidel

### Step 4: Update Tests

- Add new unit tests for per-variable operations
- Update existing tests to use new Block1DCoeffs structure

### Step 5: Deprecate Old API

- Mark old `Block1DCoeffs` as deprecated
- Provide migration guide

---

## Success Criteria

✅ **Correctness**:
- All 4 variables have independent coefficients
- Boundary conditions applied correctly per variable
- No index out-of-bounds errors
- Gauss-Seidel converges correctly

✅ **Performance**:
- Residual computation uses vectorized operations (no element loops)
- Jacobian via vjp() (already optimal)
- eval() called ≤ once per Newton iteration

✅ **Maintainability**:
- Clear separation: 1 file per concern
- Per-equation physics easy to inspect
- Tests cover each component independently

---

## References

- **TORAX Paper**: arXiv:2406.06718v2 (Section 2.2: Equations)
- **ARCHITECTURE.md**: Lines 1050-1220 (Performance optimizations)
- **FlattenedState Design**: Sources/TORAX/Solver/FlattenedState.swift

---

## Next Steps

1. Review this strategy document
2. Get approval from team
3. Implement Phase 1 (data structures)
4. Implement Phase 2 (coefficient builder)
5. Implement Phase 3 (residual computation)
6. Implement Phase 4 (linear solver fix)
7. Run tests and benchmarks
