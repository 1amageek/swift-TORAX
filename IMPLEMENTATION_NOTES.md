# Implementation Notes and Design Decisions

This document clarifies design decisions and apparent inconsistencies in the swift-Gotenx implementation.

## 1. Interpolation Methods: Coefficients vs Variables

### Issue
Different interpolation methods are used in different parts of the code:

**Block1DCoeffsBuilder.swift** (line 288-334):
- Uses **harmonic mean** for coefficients: `2/(1/a + 1/b)`
- Applied to: transport coefficients (χ_i, χ_e, D), electron density (n_e)

**LinearSolver.swift** (line 343-357):
- Uses **arithmetic mean** for variables: `(a + b)/2`
- Applied to: profile variables (T_i, T_e, n_e) when computing convection flux

### Explanation: This is **intentional** and physically correct

**Harmonic mean for coefficients**:
- Purpose: Ensures **flux continuity** across cell boundaries
- Rationale: For diffusion flux F = -D·∇T, using harmonic mean for D preserves flux conservation
- Example: If D₁=1 and D₂=1000, harmonic mean ≈ 2 (dominated by smaller value)
- Physics: Represents "series resistance" - flux is limited by the smaller diffusivity

**Arithmetic mean for variables**:
- Purpose: Standard **central differencing** for spatial discretization
- Rationale: For convection flux F = v·T, using arithmetic mean for T is the standard FVM approach
- Example: If T₁=100 and T₂=200, arithmetic mean = 150 (simple average)
- Physics: Represents physical average at cell face

### Code Location References
```swift
// Harmonic mean for coefficients (Block1DCoeffsBuilder.swift:302-307)
case .harmonic:
    let reciprocalSum = 1.0 / (leftCells + 1e-30) + 1.0 / (rightCells + 1e-30)
    interiorFaces = 2.0 / (reciprocalSum + 1e-30)

// Arithmetic mean for variables (LinearSolver.swift:350)
let interior = 0.5 * (left + right)
```

### Recommended Action
✅ **No change needed** - behavior is correct. This document serves as clarification.

---

## 2. Boundary Face Treatment in Harmonic Mean

### Issue
Boundary faces use single cell values instead of interpolation:

```swift
// Block1DCoeffsBuilder.swift:310-329
faceValues[0] = leftBoundaryValue              // Left boundary
faceValues[1...nCells-1] = interiorFaces      // Interior faces
faceValues[nFaces-1] = rightBoundaryValue     // Right boundary
```

### Explanation: This is **correct** FVM practice

**Face indexing convention**:
```
Cell:     |    0    |    1    |  ...  | nCells-1 |
Face:   [0]      [1]      [2]  ...  [nCells-1][nCells]
        ↑                                         ↑
    boundary                                  boundary
```

- `face[0]`: Left boundary (left of cell 0) → No neighboring cell, use cell 0 value
- `face[i]` (1 ≤ i ≤ nCells-1): Between cells → Use harmonic mean of neighbors
- `face[nCells]`: Right boundary (right of cell nCells-1) → No neighboring cell, use cell nCells-1 value

### Physical Interpretation
At physical boundaries, there is no "neighbor cell" to interpolate with. The boundary condition is applied to the face value directly.

### Recommended Action
✅ **No change needed** - boundary treatment is standard FVM practice.

---

## 3. Transient Coefficient Division Safety

### Issue
Division by `transientCoeff` in temperature equations may be unsafe for very low densities:

```swift
// LinearSolver.swift:340
return rhs / (transientCoeff + 1e-10)
```

For temperature equations: `transientCoeff = n_e` (electron density)

### Current Behavior (With SI Units)
**After unit standardization to SI (2025-01-18)**:
- Current density range: `n_e ~ 1e19 - 1e20 m⁻³` (realistic plasma values)
- Denominator: `1e20 + 1e-10 ≈ 1e20` (epsilon is negligible)
- **IMPORTANT**: Epsilon `1e-10` is **too small** relative to plasma densities

### Actual Issue in Current Implementation
The epsilon `1e-10` was designed for **normalized units** (where `n_e ~ 1.0`), not SI units:

```swift
// LinearSolver.swift:349 (CURRENT)
return rhs / (transientCoeff + 1e-10)
```

**With SI units**:
- For `n_e = 1e19 m⁻³`: `1e19 + 1e-10 ≈ 1e19` (epsilon has no effect)
- For `n_e = 1e10 m⁻³`: Division by small density → numerical instability
- **The epsilon does not provide meaningful protection at SI scales**

### Physical Context
**Temperature equation in non-conservation form**:
```
n_e ∂T/∂t = ∇·(n_e χ ∇T) + Q
→ ∂T/∂t = [∇·(n_e χ ∇T) + Q] / n_e
```

When `n_e → 0` or becomes very small:
- Temperature evolution becomes **ill-defined** physically
- Division by near-zero density causes numerical instability

### Current Status
**P0 configuration** uses fixed density profile with `n_e ~ 1e20 m⁻³`, so:
- Division is well-conditioned: `rhs / 1e20`
- Epsilon `1e-10` has no practical effect (1e20 >> 1e-10)
- **Issue is latent** - will manifest if density evolution is enabled or edge density drops

### Recommended Action
✅ **Implemented** (2025-10-18) - Density floor added:

**Implementation locations**:
1. **Block1DCoeffsBuilder.swift** (lines ~113, ~165):
```swift
// In buildIonEquationCoeffs / buildElectronEquationCoeffs
let ne_floor: Float = 1e18  // [m⁻³]
let ne_cell = maximum(profiles.electronDensity.value, MLXArray(ne_floor))
```

2. **LinearSolver.swift** (line ~351):
```swift
// In applyOperatorToVariable
let safetyFloor: Float = 1e18  // [m⁻³]
return rhs / maximum(transientCoeff, MLXArray(safetyFloor))
```

**Rationale**: Density floor at 1e18 m⁻³ prevents numerical instability while being physically reasonable:
- Below 1e18 m⁻³, plasma physics breaks down (Debye length exceeds system size)
- Typical tokamak densities: 1e19 - 1e20 m⁻³
- Floor is 10× - 100× below typical values, providing safety without affecting physics

**Alternative** (not implemented): Conservation form
```swift
// Change equation from n_e ∂T/∂t to ∂(n_e T)/∂t
// Requires additional ∂n_e/∂t term in RHS
// More complex, but better energy conservation for rapid density changes
```

---

## 4. Float32 Overflow in Harmonic Mean (CURRENT IMPLEMENTATION STATUS)

### Current Implementation
**As of 2025-01-18**, the code uses reciprocal form to avoid overflow:

```swift
// Block1DCoeffsBuilder.swift:325-326 (CURRENT)
let reciprocalSum = 1.0 / (leftCells + 1e-30) + 1.0 / (rightCells + 1e-30)
interiorFaces = 2.0 / (reciprocalSum + 1e-30)
```

### Original Issue
The reciprocal form was implemented to fix Float32 overflow with large density values:

```swift
// ❌ PROBLEMATIC: Direct multiplication form (not in current code)
interiorFaces = 2.0 * leftCells * rightCells / (leftCells + rightCells)
// With n_e ~ 1e20: 2 * 1e20 * 1e20 = 2e40 > Float32.max (3.4e38) → inf
```

### Root Cause
- Electron density: `n_e ~ 1e20 m⁻³` (SI units after unit standardization)
- Direct multiplication: `a * b = 1e40` exceeds Float32 range (max 3.4e38)
- This causes `inf` in coefficients, which propagates to `NaN` in solver

### Mathematical Equivalence
```
Harmonic mean: 2ab/(a+b) = 2/(1/a + 1/b)
```

Both are mathematically equivalent, but the reciprocal form avoids overflow by working with small numbers (`1/1e20 = 1e-20`).

### Verification
The current implementation (reciprocal form) prevents overflow for typical plasma densities (`n_e ~ 1e20 m⁻³`).

### Recommended Action
✅ **Current implementation is correct** - uses reciprocal form to avoid Float32 overflow.

---

## 5. Conservation Form vs Non-Conservation Form

### Current Implementation
**Non-conservation form** (following Python TORAX):

```
Ion temperature:      n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
Electron temperature: n_e ∂T_e/∂t = ∇·(n_e χ_e ∇T_e) + Q_e
Electron density:     ∂n_e/∂t = ∇·(D ∇n_e) + S_n
```

### Alternative: Conservation Form
```
Ion temperature:      ∂(n_e T_i)/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
Electron temperature: ∂(n_e T_e)/∂t = ∇·(n_e χ_e ∇T_e) + Q_e
```

### Trade-offs

**Non-conservation form** (current):
- ✅ Simpler implementation
- ✅ Matches Python TORAX exactly
- ✅ Adequate for slow density evolution
- ❌ May have energy conservation errors when density changes rapidly (pellets, gas puff)

**Conservation form**:
- ✅ Better energy conservation
- ✅ Handles rapid density changes correctly
- ❌ More complex implementation (requires ∂n_e/∂t term)
- ❌ Harder to validate against Python TORAX

### When Conservation Form Matters
- **Pellet injection**: Density increases rapidly → large ∂n_e/∂t
- **Gas puff**: Sudden edge fueling
- **ELMs**: Fast edge density/temperature changes

### Current Status (SI Units)
**P0 configuration** (fixed density):
- Non-conservation form is exact since `∂n_e/∂t = 0`
- Density: `n_e ~ 1e20 m⁻³` (realistic SI value)
- No rapid density changes, so conservation errors are negligible

**Future density evolution scenarios**:
- Pellet injection, gas puff: Rapid `∂n_e/∂t` → non-conservation form may show energy errors
- Edge density variations: Need to validate energy conservation

### Recommended Action
📋 **Document as known limitation** - consider conservation form for future density evolution scenarios.

See: Block1DCoeffsBuilder.swift:15-28 for detailed explanation in code comments.

---

## 6. Solver Convergence Criteria

### Issue
LinearSolver uses hardcoded convergence threshold:

```swift
// LinearSolver.swift:97
if residualNorm < 1e-6 {
    break
}
```

### Current Behavior
- Convergence criterion: L2 norm of profile changes < `1e-6`
- Units: eV for temperature, m⁻³ for density
- Not dimensionless → depends on physical scale

### Recommended Improvement
Use **relative** convergence criterion:

```swift
let relativeTolerance = 1e-6
let referenceNorm = computeReferenceNorm(xOld)
if residualNorm / referenceNorm < relativeTolerance {
    break
}
```

### Why This Matters
- Current: `ΔT < 1e-6 eV` is very tight for `T ~ 10000 eV` (relative error ~ 1e-10)
- Relative: `ΔT/T < 1e-6` adapts to problem scale

### Recommended Action
🔧 **Future improvement** - implement relative convergence criterion.

---

## 7. Grid Uniformity Assumption

### Issue
Several parts of the code assume **uniform grid spacing**:

```swift
// LinearSolver.swift:308
let dr = cellDist[0].item(Float.self)  // Assumes all cells have same Δr
```

### Current Behavior
- Geometry supports non-uniform grids via `cellDistances` array
- But solver extracts only first element and uses it everywhere

### Impact
For **non-uniform grids** (e.g., refined edge grid):
- Gradient calculation `(x_right - x_left)/dr` is incorrect
- Should use local `dr[i]` for each cell

### Current Justification
P0 configuration uses circular geometry with uniform grid (MeshConfig with `nCells=25`).

### Recommended Action
🔧 **Future improvement** - support non-uniform grids properly:

```swift
// Vectorized gradient with per-cell spacing
let drFaces = geometry.faceDistances.value  // [nFaces]
let gradFace = (x_right - x_left) / drFaces[1..<nCells]
```

---

## Summary Table

| Issue | Status | Priority | Action Required |
|-------|--------|----------|----------------|
| Different interpolation methods | ✅ Correct | - | Document only |
| Boundary face treatment | ✅ Correct | - | Document only |
| Transient coeff division safety | ✅ Implemented | - | Density floor `1e18 m⁻³` added (2025-10-18) |
| Float32 overflow in harmonic mean | ✅ Implemented | - | Current code uses reciprocal form (correct) |
| Non-conservation form | 📋 Documented | Medium | Consider for density evolution; currently exact for P0 (fixed density) |
| Convergence criterion | 🔧 Improve | Low | Use relative tolerance instead of absolute `1e-6` |
| Grid uniformity assumption | 🔧 Improve | Medium | Support non-uniform grids for edge refinement |

Legend:
- ✅ Correct/Implemented: Current implementation is correct
- ⚠️ Works now: Adequate for P0 but needs improvement for general use (SI units exposed latent issues)
- 📋 Documented: Known limitation, acceptable trade-off for current use case
- 🔧 Improve: Recommended future enhancement

**Key Changes After SI Unit Standardization (2025-01-18)**:
- Density values now realistic: `n_e ~ 1e20 m⁻³` instead of normalized `~1.0`
- Epsilon values designed for normalized units are now inadequate (Priority: High → needs density floor)
- Float32 overflow risk is real with large density products (reciprocal form prevents this)

---

## References

### Related Files
- `Sources/Gotenx/Solver/Block1DCoeffsBuilder.swift` - Coefficient construction
- `Sources/Gotenx/Solver/LinearSolver.swift` - Time stepping and spatial operators
- `Tests/GotenxTests/Integration/P0IntegrationTest.swift` - Integration test
- `CLAUDE.md` - High-level architecture and design philosophy

### External References
- [TORAX Paper (arXiv:2406.06718v2)](https://arxiv.org/abs/2406.06718v2)
- [Python TORAX Repository](https://github.com/google-deepmind/torax)
- Finite Volume Method: Versteeg & Malalasekera, "An Introduction to Computational Fluid Dynamics"
- Plasma Transport: Wesson, "Tokamaks" (4th Edition)

---

*Document Version: 1.0*
*Last Updated: 2025-01-18*
*Maintainer: Claude Code Analysis*
