# FVM Implementation Design for swift-Gotenx

**Date**: 2025-10-18
**Status**: Design Phase
**Priority**: P0 - Core Infrastructure

---

## Executive Summary

Analysis of existing FVM implementation reveals **80% completion**. Critical missing components:
1. **Power-law scheme** for Péclet number weighting (convection stability)
2. **Matrix assembler** for tridiagonal system construction
3. **Flux calculation** with proper upwinding
4. **Theta method integration** into solvers

---

## Current Implementation Status

### ✅ Completed Components (80%)

#### 1. CellVariable (100%)
**File**: `Sources/Gotenx/FVM/CellVariable.swift` (234 lines)

**Features**:
- ✅ Cell-centered values with EvaluatedArray
- ✅ Boundary conditions (Dirichlet, Neumann)
- ✅ Face value calculation (`faceValue()`)
- ✅ Face gradient calculation (`faceGrad()`)
- ✅ Validation and error handling

**Assessment**: **Complete and production-ready**

#### 2. Block1DCoeffs Structure (100%)
**File**: `Sources/Gotenx/Solver/Block1DCoeffs.swift` (208 lines)

**Features**:
- ✅ Per-equation coefficients (Ti, Te, ne, psi)
- ✅ Geometric factors (volumes, areas, distances)
- ✅ Shape validation
- ✅ EvaluatedArray integration

**Assessment**: **Complete and correct**

#### 3. Coefficient Builder (90%)
**File**: `Sources/Gotenx/Solver/Block1DCoeffsBuilder.swift` (313 lines)

**Features**:
- ✅ Per-equation coefficient construction
- ✅ Face interpolation (harmonic, arithmetic)
- ✅ Non-conservation form (matches Python TORAX)
- ✅ Density profile integration
- ⚠️ Missing: Power-law scheme for convection

**Assessment**: **Functional but needs power-law scheme**

#### 4. Equation Coefficients (100%)
**File**: `Sources/Gotenx/Solver/EquationCoeffs.swift`

**Features**:
- ✅ Diffusion coefficients (dFace)
- ✅ Convection coefficients (vFace)
- ✅ Source terms (sourceCell, sourceMatCell)
- ✅ Transient coefficients
- ✅ Validation

**Assessment**: **Complete**

---

## 🔴 Missing Components (P0 - Critical)

### 1. Power-Law Scheme for Péclet Weighting

**Problem**: Current implementation uses simple averaging for face values, which is **unstable for high convection** (high Péclet number).

**Required**: Power-law scheme that smoothly transitions between:
- **Low Péclet (|Pe| < 0.1)**: Central differencing (2nd order accurate)
- **Moderate Péclet (0.1 < |Pe| < 10)**: Power-law weighting
- **High Péclet (|Pe| > 10)**: Upwinding (1st order, but stable)

**Mathematics**:
```
Pe = V·Δx / D  (Péclet number)

Weighting factor α:
- Pe > 10:        α = 1 (full upwinding)
- 0 < Pe ≤ 10:   α = (1 + Pe/10) / (1 + Pe/5)
- -10 ≤ Pe < 0:  α = (1 - Pe/10) / (1 - Pe/5)
- Pe < -10:       α = 0 (reverse upwinding)

Face value: x_face = α·x_left + (1-α)·x_right
```

**MLX Implementation Strategy**:
```swift
func computePowerLawWeighting(
    peclet: MLXArray  // [nFaces]
) -> MLXArray {     // [nFaces] - weighting factors
    // Use where() for vectorized conditional logic
    let abs_pe = abs(peclet)

    // Case 1: |Pe| > 10 (full upwinding)
    let upwind = where(peclet > 0, MLXArray(1.0), MLXArray(0.0))

    // Case 2: 0 < Pe ≤ 10 (power-law)
    let power_law_pos = (1.0 + peclet / 10.0) / (1.0 + peclet / 5.0)

    // Case 3: -10 ≤ Pe < 0 (power-law)
    let power_law_neg = (1.0 - peclet / 10.0) / (1.0 - peclet / 5.0)

    // Combine with where() - fully vectorized!
    let alpha = where(
        abs_pe > 10.0,
        upwind,
        where(peclet >= 0, power_law_pos, power_law_neg)
    )

    return alpha
}
```

**File to Create**: `Sources/Gotenx/FVM/PowerLawScheme.swift`

---

### 2. Matrix Assembler for Tridiagonal Systems

**Problem**: Solvers need assembled matrix in form `A·x = b` for linear solve, but current implementation doesn't construct this matrix.

**Required**: Function to assemble block-tridiagonal system from `Block1DCoeffs`.

**Mathematics**:

For each equation: `T(x_new)·x_new - T(x_old)·x_old = Δt·[θ·(C·x_new + c) + (1-θ)·(...)]`

Rearranged to standard form:
```
[T/Δt - θ·C] · x_new = [T/Δt · x_old + θ·c + (1-θ)·(C·x_old + c)]
     A              x           =                b
```

**Tridiagonal structure** (for single equation, nCells cells):
```
Matrix A (nCells × nCells):

[  d₀  u₀   0   0  ...   0  ]
[  l₁  d₁  u₁   0  ...   0  ]
[   0  l₂  d₂  u₂  ...   0  ]
[  ...              ...      ]
[   0  ...   0  lₙ₋₁  dₙ₋₁  ]

Diagonal   (dᵢ): (Tᵢ/Δt - θ·Cᵢᵢ)
Upper diag (uᵢ): -θ·Cᵢ,ᵢ₊₁  (diffusion + convection to right neighbor)
Lower diag (lᵢ): -θ·Cᵢ,ᵢ₋₁  (diffusion + convection from left neighbor)
```

**For diffusion + convection**:
```
Diffusion flux: Fᵢ₊₁/₂ᵈⁱᶠᶠ = -Dᵢ₊₁/₂ · (xᵢ₊₁ - xᵢ)/Δx
Convection flux: Fᵢ₊₁/₂ᶜᵒⁿᵛ = Vᵢ₊₁/₂ · x_face(α)

Discretized: (Fᵢ₊₁/₂ - Fᵢ₋₁/₂)/Δx contributes to:
- Diagonal: +(Dᵢ₊₁/₂ + Dᵢ₋₁/₂)/Δx² + convection contribution
- Upper: -Dᵢ₊₁/₂/Δx² - Vᵢ₊₁/₂·(1-α)/Δx
- Lower: -Dᵢ₋₁/₂/Δx² + Vᵢ₋₁/₂·α/Δx
```

**MLX Implementation Strategy**:
```swift
struct TridiagonalMatrix: Sendable {
    let diagonal: EvaluatedArray    // [nCells]
    let upperDiag: EvaluatedArray   // [nCells-1]
    let lowerDiag: EvaluatedArray   // [nCells-1]

    /// Solve tridiagonal system A·x = b using Thomas algorithm
    /// Vectorized implementation using MLX scan operations
    func solve(_ rhs: MLXArray) -> MLXArray {
        // Thomas algorithm (forward elimination + backward substitution)
        // Fully vectorized with MLX cumsum and reverse operations
    }
}

func assembleMatrix(
    coeffs: EquationCoeffs,
    geometry: GeometricFactors,
    dt: Float,
    theta: Float,
    transientOld: MLXArray  // T(x_old)
) -> (matrix: TridiagonalMatrix, rhs: MLXArray) {
    // Build tridiagonal matrix and RHS from coefficients
}
```

**File to Create**: `Sources/Gotenx/FVM/MatrixAssembler.swift`

---

### 3. Flux Calculation with Upwinding

**Problem**: Need explicit flux calculation for residual computation in Newton-Raphson solver.

**Required**: Compute total flux (diffusion + convection) at faces.

**Mathematics**:
```
Total flux: Γᵢ₊₁/₂ = -Dᵢ₊₁/₂ · (∂x/∂r)ᵢ₊₁/₂ + Vᵢ₊₁/₂ · xᵢ₊₁/₂

Where:
- Gradient: (∂x/∂r)ᵢ₊₁/₂ = (xᵢ₊₁ - xᵢ) / Δx
- Face value: xᵢ₊₁/₂ = α·xᵢ + (1-α)·xᵢ₊₁ (power-law weighted)
```

**MLX Implementation Strategy**:
```swift
func computeFluxes(
    cellValues: MLXArray,      // [nCells]
    dFace: MLXArray,           // [nFaces] - diffusion coefficients
    vFace: MLXArray,           // [nFaces] - convection velocities
    geometry: GeometricFactors
) -> MLXArray {                // [nFaces] - total fluxes
    // 1. Compute Péclet numbers at faces
    let peclet = vFace * geometry.cellDistances / (dFace + 1e-10)

    // 2. Compute power-law weighting
    let alpha = computePowerLawWeighting(peclet: peclet)

    // 3. Compute face gradients
    let gradient = diff(cellValues) / geometry.cellDistances

    // 4. Compute face values (power-law weighted)
    let leftCells = cellValues[0..<(nCells-1)]
    let rightCells = cellValues[1..<nCells]
    let faceValues = alpha * leftCells + (1.0 - alpha) * rightCells

    // 5. Total flux = diffusion + convection
    let diffusionFlux = -dFace * gradient
    let convectionFlux = vFace * faceValues

    return diffusionFlux + convectionFlux
}
```

**File to Create**: `Sources/Gotenx/FVM/FluxCalculation.swift`

---

### 4. Theta Method Integration

**Problem**: Solvers (Linear, Newton-Raphson) need explicit theta method discretization.

**Required**: Integrate theta parameter into time discretization.

**Mathematics**:

General theta method:
```
x_new - x_old = Δt · [θ·f(x_new) + (1-θ)·f(x_old)]

Where f(x) = C·x + c (spatial operator + sources)

Rearranged:
[I - θ·Δt·C]·x_new = [I + (1-θ)·Δt·C]·x_old + Δt·[θ·c_new + (1-θ)·c_old]
```

**Special cases**:
- θ = 0: Explicit Euler (CFL restriction, simple)
- θ = 0.5: Crank-Nicolson (2nd order, A-stable)
- θ = 1: Implicit Euler (L-stable, unconditionally stable, **default**)

**Current solver integration**:
- ✅ LinearSolver: Has predictor-corrector structure (can integrate theta)
- ✅ NewtonRaphsonSolver: Has theta parameter (needs theta-aware residual)
- ❌ Residual function: Needs explicit theta discretization

**File to Modify**: `Sources/Gotenx/Solver/LinearSolver.swift`, `NewtonRaphsonSolver.swift`

---

## Implementation Plan

### Phase 1: Power-Law Scheme (P0 - Highest Priority)

**Why First**: Critical for convection stability, affects all transport equations.

**Tasks**:
1. Create `PowerLawScheme.swift`
2. Implement `computePowerLawWeighting()`
3. Add vectorized Péclet number calculation
4. Add tests with known Pe values
5. Integrate into `Block1DCoeffsBuilder`

**Estimated Effort**: 4-6 hours

**Files**:
- NEW: `Sources/Gotenx/FVM/PowerLawScheme.swift`
- MODIFY: `Sources/Gotenx/Solver/Block1DCoeffsBuilder.swift`
- NEW: `Tests/GotenxTests/FVM/PowerLawSchemeTests.swift`

---

### Phase 2: Matrix Assembler (P0)

**Why Second**: Required for all solvers to construct linear systems.

**Tasks**:
1. Create `MatrixAssembler.swift`
2. Implement `TridiagonalMatrix` struct
3. Implement Thomas algorithm solver (vectorized)
4. Implement `assembleMatrix()` from EquationCoeffs
5. Add boundary condition handling
6. Add tests with known solutions

**Estimated Effort**: 6-8 hours

**Files**:
- NEW: `Sources/Gotenx/FVM/MatrixAssembler.swift`
- NEW: `Tests/GotenxTests/FVM/MatrixAssemblerTests.swift`

---

### Phase 3: Flux Calculation (P0)

**Why Third**: Needed for Newton-Raphson residual computation.

**Tasks**:
1. Create `FluxCalculation.swift`
2. Implement `computeFluxes()` with power-law
3. Add divergence calculation
4. Add conservative flux formulation
5. Add tests with known fluxes

**Estimated Effort**: 3-4 hours

**Files**:
- NEW: `Sources/Gotenx/FVM/FluxCalculation.swift`
- NEW: `Tests/GotenxTests/FVM/FluxCalculationTests.swift`

---

### Phase 4: Theta Method Integration (P0)

**Why Fourth**: Completes time discretization for stable time stepping.

**Tasks**:
1. Modify LinearSolver to use theta
2. Modify NewtonRaphsonSolver residual for theta
3. Add theta-aware matrix assembly
4. Add tests comparing theta=0, 0.5, 1

**Estimated Effort**: 4-5 hours

**Files**:
- MODIFY: `Sources/Gotenx/Solver/LinearSolver.swift`
- MODIFY: `Sources/Gotenx/Solver/NewtonRaphsonSolver.swift`
- MODIFY: `Sources/Gotenx/FVM/MatrixAssembler.swift`
- NEW: `Tests/GotenxTests/Solver/ThetaMethodTests.swift`

---

### Phase 5: Integration Testing (P0)

**Why Last**: Validate complete FVM pipeline end-to-end.

**Tasks**:
1. Create simple 1D diffusion test (analytical solution)
2. Create convection-diffusion test (varying Péclet)
3. Create coupled system test (all 4 equations)
4. Benchmark against Python TORAX
5. Profile MLX performance

**Estimated Effort**: 6-8 hours

**Files**:
- NEW: `Tests/GotenxTests/Integration/FVMIntegrationTests.swift`
- NEW: `Benchmarks/FVMBenchmarks.swift`

---

## Total Estimated Effort

**Phase 1-4**: 17-23 hours (P0 implementation)
**Phase 5**: 6-8 hours (Testing & validation)
**Total**: 23-31 hours (~3-4 days)

---

## MLX Optimization Strategy

### Key Optimizations

1. **Vectorized Conditionals**: Use `where()` instead of loops
   ```swift
   // ❌ Slow: element-wise loop
   for i in 0..<n {
       alpha[i] = peclet[i] > 10 ? 1.0 : power_law(peclet[i])
   }

   // ✅ Fast: vectorized where()
   let alpha = where(abs(peclet) > 10.0, upwind, power_law)
   ```

2. **Lazy Evaluation**: Build computation graph, evaluate once
   ```swift
   // All operations are lazy
   let fluxDiff = -dFace * gradient
   let fluxConv = vFace * faceValues
   let totalFlux = fluxDiff + fluxConv

   // Single evaluation at end
   eval(totalFlux)
   ```

3. **Batched Operations**: Compute all faces simultaneously
   ```swift
   // ❌ Slow: per-face loop
   for i in 0..<nFaces {
       flux[i] = computeFlux(i, ...)
   }

   // ✅ Fast: vectorized for all faces
   let fluxes = computeFluxes(cellValues, dFace, vFace)  // Single MLXArray op
   ```

4. **compile() Placement**: Compile entire timestep, not individual functions
   ```swift
   // ✅ Optimal: compile full step including FVM
   let compiledStep = compile { (profiles, params) in
       let coeffs = buildBlock1DCoeffs(...)
       let matrix = assembleMatrix(coeffs, ...)
       let xNew = solveSystem(matrix, ...)
       return xNew
   }
   ```

5. **Avoid Premature Conversion**: Keep MLXArray until absolutely necessary
   ```swift
   // ❌ Slow: convert to Swift array mid-computation
   let swiftArray = mlxArray.asArray(Float.self)
   // ... more computation ...

   // ✅ Fast: stay in MLX
   let result = mlxArray.operation1().operation2()  // Lazy chain
   ```

### Performance Targets

| Operation | Target Time (nCells=100) | MLX Strategy |
|-----------|--------------------------|--------------|
| Coefficient building | < 1 ms | Vectorized interpolation |
| Matrix assembly | < 2 ms | Vectorized tridiagonal construction |
| Flux calculation | < 1 ms | Vectorized power-law + flux |
| Linear solve | < 3 ms | Thomas algorithm (vectorized) |
| **Full timestep** | **< 10 ms** | **compile() entire step** |

---

## References

1. **TORAX Paper**: arXiv:2406.06718v2 (Section 2.2 - FVM discretization)
2. **TORAX DeepWiki**: https://deepwiki.com/google-deepmind/torax
3. **Power-Law Scheme**: Patankar, S. V. (1980). Numerical Heat Transfer and Fluid Flow
4. **Theta Method**: Hairer, E., & Wanner, G. (1996). Solving Ordinary Differential Equations II
5. **MLX Documentation**: https://ml-explore.github.io/mlx-swift/MLX/

---

## Next Steps

1. **Review this design** with team/user
2. **Start Phase 1**: Power-Law Scheme implementation
3. **Iterate**: Test → Profile → Optimize
4. **Validate**: Compare with Python TORAX results

---

## Appendix: Existing Implementation Quality

### Strengths

✅ **Type Safety**: EvaluatedArray pattern ensures evaluation at boundaries
✅ **Clean Architecture**: Separation of CellVariable, coefficients, solvers
✅ **Boundary Conditions**: Comprehensive Dirichlet/Neumann handling
✅ **Documentation**: Well-commented with physics equations
✅ **Testing**: Existing tests for CellVariable, geomet ric factors

### Improvements Needed

⚠️ **Power-Law Scheme**: Critical for convection stability (currently missing)
⚠️ **Matrix Assembly**: Need explicit tridiagonal matrix construction
⚠️ **Flux Calculation**: Need explicit flux computation for residuals
⚠️ **Theta Integration**: Need theta-aware time discretization

---

**Conclusion**: The existing FVM implementation is **80% complete** with a solid foundation. The remaining 20% (power-law scheme, matrix assembler, flux calculation, theta integration) are **well-defined, implementable tasks** with clear mathematics and MLX optimization strategies.
