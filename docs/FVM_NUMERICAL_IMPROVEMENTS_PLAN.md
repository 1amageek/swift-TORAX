# FVM Numerical Improvements Plan

**Date**: 2025-10-21
**Status**: Design & Implementation Roadmap
**Priority**: P0 - Critical for Physics Accuracy
**Target**: TORAX-equivalent numerical fidelity

---

## Executive Summary

This document consolidates two critical reviews:
1. **FVM Implementation Gaps**: Missing power-law scheme, simplified bootstrap current, uniform-grid assumptions
2. **Hardcoded Tolerances**: Magic number `1e-6` used inconsistently across 15+ locations

**Key Goals**:
- ✅ Implement TORAX-compliant power-law scheme for convection stability
- ✅ Upgrade bootstrap current to Sauter formula with collisionality dependence
- ✅ Support non-uniform grids with proper metric tensors
- ✅ Centralize all numerical tolerances in configuration system
- ✅ Establish comprehensive integration tests

**Total Effort Estimate**: 40-50 hours (~1 week)

---

## Part A: FVM Implementation Gaps

### Review Summary

**Current Status**: 80% complete with solid foundation, but critical physics components missing.

#### ✅ Strengths (Completed)
- `CellVariable`: Boundary conditions, face values/gradients (234 lines, 100% complete)
- `Block1DCoeffs`: Per-equation coefficients, geometric factors (208 lines, 100% complete)
- `Block1DCoeffsBuilder`: Non-conservation form, density floor, unit conversions (556 lines, 90% complete)
- `NewtonRaphsonSolver`: Theta-method residuals, vectorized spatial operators (468 lines, 95% complete)

#### ⚠️ Critical Gaps

| Gap | Impact | Priority | Effort |
|-----|--------|----------|--------|
| Power-law scheme | Numerical oscillations at high Péclet (Pe > 10) | **P0** | 6-8h |
| Sauter bootstrap formula | 20-50% error in edge/high-collisionality regions | **P0** | 8-10h |
| Non-uniform grid support | 10-30% geometric error for shaped plasmas (δ > 0.3) | **P1** | 6-8h |
| Energy coupling (Ti-Te) | Missing explicit ion-electron exchange term | **P1** | 4-6h |
| Integration tests | No end-to-end validation of flux assembly | **P2** | 6-8h |

---

## Part B: Hardcoded Tolerance Analysis

### Review Summary

**Magic Number `1e-6` Used in 15+ Locations**:

#### Solver Tolerances (5 locations)
| File | Line | Usage | Current Value | Issue |
|------|------|-------|---------------|-------|
| `NewtonRaphsonSolver.swift` | 37 | Residual convergence | `1e-6` | Not configurable per equation |
| `RuntimeParams.swift` | 51 | Default solver tolerance | `1e-6` | Single value for all 4 equations |
| `SolverConfig.swift` | 19 | Config default | `1e-6` | No distinction for Ti/Te/ne/psi |
| `TimeStepCalculator.swift` | 31 | Minimum timestep | `1e-6` | Too aggressive for stiff systems |
| `SimulationOrchestrator.swift` | 79 | Explicit minTimestep | `1e-6` | Hardcoded, should use config |

**Problem**: Newton-Raphson using same tolerance for all equations ignores scale differences:
- Temperature: O(10⁴) eV → relative error O(10⁻²)
- Density: O(10²⁰) m⁻³ → relative error O(10⁻²⁶) (meaningless precision)
- Flux: O(10) Wb → relative error O(10⁻⁷)

#### Physical Thresholds (6 locations)
| File | Line | Usage | Current Value | Issue |
|------|------|-------|---------------|-------|
| `OhmicHeating.swift` | 307 | Poloidal flux variation threshold | `1e-6` | Should be `flux_range * rtol` |
| `FusionPower.swift` | 99 | Fuel fraction sum check | `1e-6` | Should be `1e-4` (physical tolerance) |
| `ConfigurationValidator.swift` | 124 | Fusion fuel fraction sum | `1e-6` | Should be `1e-4` (too strict) |
| `DerivedQuantitiesComputer.swift` | 167 | Joule→MJ conversion floor | `1e-6` | Context-specific (energy scale) |
| `DerivedQuantitiesComputer.swift` | 337 | Energy confinement time | `1e-6` | Should use power threshold (MW) |
| `DerivedQuantitiesComputer.swift` | 579 | Fusion gain Q threshold | `1e-6` | Should be `1e-3` (Q < 0.001 is negligible) |

**Problem**: Physical thresholds should scale with problem size, not use fixed absolute values.

#### Time Configuration (4 locations)
| File | Line | Usage | Current Value | Issue |
|------|------|-------|---------------|-------|
| `TimeConfiguration.swift` | 45 | Adaptive timestep minDt | `1e-6` | Default for all scenarios |
| `GotenxConfigReader.swift` | 185 | Config default minDt | `1e-6` | Should depend on `maxDt` |
| `GotenxConfigReader.swift` | 408 | Fallback minDt | `1e-6` | Hardcoded magic number |

**Problem**: Minimum timestep should be `maxDt / max_refinement_factor` (e.g., `maxDt / 1000`), not absolute.

---

## Design Goals

### Numerical Accuracy Goals
1. **Convection Stability**: Support Péclet numbers Pe ∈ [0.01, 100] without oscillations
2. **Bootstrap Current**: ≤ 10% error vs. Sauter formula reference (all collisionality regimes)
3. **Geometric Fidelity**: ≤ 5% error for shaped plasmas (triangularity δ ≤ 0.5, elongation κ ≤ 2.0)
4. **Energy Coupling**: Explicit Ti-Te exchange with ≤ 5% conservation error

### Configuration System Goals
1. **Per-Equation Tolerances**: Separate absolute/relative tolerances for Ti, Te, ne, psi
2. **Scaled Thresholds**: All physical thresholds scale with problem characteristics
3. **Adaptive Defaults**: Minimum timestep = `maxDt * config.minTimestepFraction` (default: 0.001)
4. **Validation**: Configuration validator checks tolerance consistency

### Testing Goals
1. **Unit Tests**: Power-law scheme, Sauter formula, metric tensor calculations
2. **Integration Tests**: 1D diffusion (analytical solution), convection-diffusion (Pe sweep)
3. **Conservation Tests**: Particle, energy, current conservation within 1% over 100 timesteps
4. **Regression Tests**: ITER-like scenario matches Python TORAX within 5%

---

## Architecture Changes

### 1. New Configuration Structure

**File**: `Sources/Gotenx/Configuration/NumericalTolerances.swift` (NEW)

```swift
/// Per-equation numerical tolerances
public struct EquationTolerances: Codable, Sendable {
    /// Absolute tolerance for residual norm [physical units]
    public let absoluteTolerance: Float

    /// Relative tolerance for residual norm [dimensionless]
    public let relativeTolerance: Float

    /// Minimum value threshold (below this, use absolute tolerance only)
    public let minValueThreshold: Float

    /// Compute combined tolerance for state value x
    /// tol = max(absoluteTolerance, relativeTolerance * |x|)
    public func combinedTolerance(for value: Float) -> Float {
        if abs(value) < minValueThreshold {
            return absoluteTolerance
        }
        return max(absoluteTolerance, relativeTolerance * abs(value))
    }
}

/// Numerical tolerance configuration for all equations
public struct NumericalTolerances: Codable, Sendable {
    /// Ion temperature equation tolerances
    public let ionTemperature: EquationTolerances

    /// Electron temperature equation tolerances
    public let electronTemperature: EquationTolerances

    /// Electron density equation tolerances
    public let electronDensity: EquationTolerances

    /// Poloidal flux equation tolerances
    public let poloidalFlux: EquationTolerances

    /// Default ITER-scale tolerances
    public static let iterScale = NumericalTolerances(
        ionTemperature: EquationTolerances(
            absoluteTolerance: 10.0,        // 10 eV absolute
            relativeTolerance: 1e-4,        // 0.01% relative
            minValueThreshold: 100.0        // Below 100 eV, use absolute only
        ),
        electronTemperature: EquationTolerances(
            absoluteTolerance: 10.0,        // 10 eV absolute
            relativeTolerance: 1e-4,        // 0.01% relative
            minValueThreshold: 100.0        // Below 100 eV, use absolute only
        ),
        electronDensity: EquationTolerances(
            absoluteTolerance: 1e17,        // 1e17 m⁻³ absolute
            relativeTolerance: 1e-4,        // 0.01% relative
            minValueThreshold: 1e18         // Below 1e18 m⁻³, use absolute only
        ),
        poloidalFlux: EquationTolerances(
            absoluteTolerance: 1e-3,        // 1 mWb absolute
            relativeTolerance: 1e-5,        // 0.001% relative (flux is smooth)
            minValueThreshold: 0.1          // Below 0.1 Wb, use absolute only
        )
    )
}
```

### 2. Time Configuration Enhancement

**File**: `Sources/Gotenx/Configuration/TimeConfiguration.swift` (MODIFY)

```swift
public struct TimeConfiguration: Codable, Sendable {
    // ... existing fields ...

    /// Minimum timestep fraction of maxDt (default: 0.001)
    /// Actual minDt = maxDt * minTimestepFraction
    public let minTimestepFraction: Float

    /// CFL safety factor (default: 0.9)
    public let cflSafetyFactor: Float

    /// Maximum timestep growth rate per step (default: 1.2)
    public let maxTimestepGrowth: Float

    public static let `default` = TimeConfiguration(
        // ... existing defaults ...
        minTimestepFraction: 0.001,      // minDt = maxDt / 1000
        cflSafetyFactor: 0.9,            // 10% margin below CFL limit
        maxTimestepGrowth: 1.2           // Max 20% increase per step
    )

    /// Computed minimum timestep (adaptive)
    public var computedMinDt: Float {
        return maxDt * minTimestepFraction
    }
}
```

### 3. Physical Thresholds Configuration

**File**: `Sources/Gotenx/Configuration/PhysicalThresholds.swift` (NEW)

```swift
/// Physical quantity thresholds (scaled to problem)
public struct PhysicalThresholds: Codable, Sendable {
    /// Fusion fuel fraction sum tolerance (default: 1e-4)
    /// Physical tolerance: 0.01% is reasonable for fraction sums
    public let fuelFractionTolerance: Float

    /// Minimum fusion power for Q calculation [MW] (default: 1e-3)
    /// Below 1 kW, fusion gain Q is meaningless
    public let minFusionPowerForQ: Float

    /// Minimum heating power for τE calculation [MW] (default: 1e-2)
    /// Below 10 kW, energy confinement time is unreliable
    public let minHeatingPowerForTauE: Float

    /// Poloidal flux relative variation threshold (default: 1e-5)
    /// Skip Ohmic heating if dψ/ψ < threshold
    public let fluxVariationThreshold: Float

    /// Minimum stored energy for diagnostics [MJ] (default: 1e-3)
    /// Below 1 kJ, plasma is negligible
    public let minStoredEnergy: Float

    public static let `default` = PhysicalThresholds(
        fuelFractionTolerance: 1e-4,      // 0.01% (was 1e-6, too strict)
        minFusionPowerForQ: 1e-3,         // 1 kW (was 1e-6 MW, unrealistic)
        minHeatingPowerForTauE: 1e-2,     // 10 kW (was implicit 1e-6)
        fluxVariationThreshold: 1e-5,     // 0.001% flux change (was 1e-6)
        minStoredEnergy: 1e-3             // 1 kJ (was 1e-6 MJ, too small)
    )
}
```

### 4. Solver Configuration Update

**File**: `Sources/Gotenx/Configuration/SolverConfig.swift` (MODIFY)

```swift
public struct SolverConfig: Codable, Sendable {
    // ... existing fields ...

    /// Per-equation tolerances
    public let tolerances: NumericalTolerances

    /// Physical thresholds for diagnostics
    public let physicalThresholds: PhysicalThresholds

    /// Maximum Newton-Raphson iterations (default: 30)
    public let maxIterations: Int

    /// Line search parameters
    public let lineSearchEnabled: Bool
    public let lineSearchMaxAlpha: Float

    public static let `default` = SolverConfig(
        tolerances: .iterScale,
        physicalThresholds: .default,
        maxIterations: 30,
        lineSearchEnabled: true,
        lineSearchMaxAlpha: 1.0
    )
}
```

---

## Implementation Plan

### Phase 1: Configuration System Refactor (P0, 8-10 hours)

**Goal**: Eliminate all hardcoded `1e-6` values, introduce per-equation tolerances.

#### Tasks

**1.1 Create New Configuration Files** (2 hours)
- ✅ `Sources/Gotenx/Configuration/NumericalTolerances.swift`
- ✅ `Sources/Gotenx/Configuration/PhysicalThresholds.swift`
- ✅ Add to `RuntimeParams` and `GotenxConfigReader`

**1.2 Update Solver to Use Per-Equation Tolerances** (3 hours)

**File**: `Sources/Gotenx/Solver/NewtonRaphsonSolver.swift`

Changes:
```swift
public struct NewtonRaphsonSolver: PDESolver {
    /// Per-equation tolerances (replaces single tolerance: Float)
    public let tolerances: NumericalTolerances

    public func solve(...) -> SolverResult {
        // ...

        // Compute per-equation residual norms
        let layout = StateLayout(nCells: nCells)
        let R_Ti_norm = computeNorm(residualScaled[layout.tiRange])
        let R_Te_norm = computeNorm(residualScaled[layout.teRange])
        let R_ne_norm = computeNorm(residualScaled[layout.neRange])
        let R_psi_norm = computeNorm(residualScaled[layout.psiRange])

        // Check convergence for each equation
        let Ti_converged = R_Ti_norm < tolerances.ionTemperature.absoluteTolerance
        let Te_converged = R_Te_norm < tolerances.electronTemperature.absoluteTolerance
        let ne_converged = R_ne_norm < tolerances.electronDensity.absoluteTolerance
        let psi_converged = R_psi_norm < tolerances.poloidalFlux.absoluteTolerance

        let converged = Ti_converged && Te_converged && ne_converged && psi_converged

        // Store per-equation convergence info in metadata
        metadata["Ti_residual"] = R_Ti_norm
        metadata["Te_residual"] = R_Te_norm
        metadata["ne_residual"] = R_ne_norm
        metadata["psi_residual"] = R_psi_norm
    }
}
```

**1.3 Update Time Step Calculator** (2 hours)

**File**: `Sources/Gotenx/Orchestration/TimeStepCalculator.swift`

Changes:
```swift
public struct TimeStepCalculator {
    // Remove hardcoded minTimestep: Float = 1e-6

    public func computeTimestep(
        timeConfig: TimeConfiguration,  // Now contains minTimestepFraction
        // ...
    ) -> Float {
        // ...
        let cflDt = minCFLDt * timeConfig.cflSafetyFactor

        // Adaptive minimum timestep
        let minDt = timeConfig.computedMinDt  // = maxDt * fraction

        // Clamp with growth limit
        let proposedDt = min(cflDt, previousDt * timeConfig.maxTimestepGrowth)
        return max(proposedDt, minDt)
    }
}
```

**1.4 Update Physical Modules** (3 hours)

Replace all hardcoded thresholds:

**File**: `Sources/GotenxPhysics/Heating/OhmicHeating.swift` (Line 307)
```swift
// OLD: if fluxVariation < 1e-6 { return zero }
// NEW:
if fluxVariation < (fluxRange * thresholds.fluxVariationThreshold) {
    return zero
}
```

**File**: `Sources/GotenxPhysics/Heating/FusionPower.swift` (Line 99)
```swift
// OLD: guard sum > 1e-6 else { throw error }
// NEW:
guard abs(sum - 1.0) < thresholds.fuelFractionTolerance else {
    throw FusionPowerError.invalidFuelFractionSum(
        sum: sum,
        tolerance: thresholds.fuelFractionTolerance
    )
}
```

**File**: `Sources/Gotenx/Diagnostics/DerivedQuantitiesComputer.swift`
```swift
// Line 337 - Energy confinement time
// OLD: if totalHeatingPower < 1e-6 { return 0 }
// NEW:
if totalHeatingPower < thresholds.minHeatingPowerForTauE {
    return 0.0
}

// Line 579 - Fusion gain Q
// OLD: if heatingPower < 1e-6 { return 0 }
// NEW:
if fusionPower < thresholds.minFusionPowerForQ {
    return 0.0
}
```

#### Deliverables
- ✅ 2 new configuration files
- ✅ Updated `NewtonRaphsonSolver` with per-equation convergence
- ✅ Updated `TimeStepCalculator` with adaptive minDt
- ✅ Updated 5 physics modules to use `PhysicalThresholds`
- ✅ JSON schema update for new config fields
- ✅ CLI help text update

---

### Phase 2: Power-Law Scheme Implementation (P0, 6-8 hours)

**Goal**: TORAX-compliant Patankar scheme for convection stability.

#### 2.1 Create Power-Law Module (3 hours)

**File**: `Sources/Gotenx/FVM/PowerLawScheme.swift` (NEW)

```swift
import MLX

/// Patankar power-law scheme for convection-diffusion face weighting
///
/// **Physics**: High Péclet number (Pe = V·Δx/D >> 1) causes numerical oscillations
/// with central differencing. Power-law scheme provides smooth transition:
///
/// - Pe < 0.1: Central differencing (2nd order accurate)
/// - 0.1 ≤ Pe ≤ 10: Power-law interpolation
/// - Pe > 10: First-order upwinding (stable but diffusive)
///
/// **References**:
/// - Patankar, S.V. (1980). "Numerical Heat Transfer and Fluid Flow"
/// - TORAX: arXiv:2406.06718v2, Section 2.2.3
public struct PowerLawScheme {

    /// Compute Péclet number at faces
    ///
    /// Pe = V·Δx / D
    ///
    /// - Parameters:
    ///   - vFace: Convection velocity at faces [m/s], shape [nFaces]
    ///   - dFace: Diffusion coefficient at faces [m²/s], shape [nFaces]
    ///   - dx: Cell spacing [m], shape [nFaces-1] or scalar
    /// - Returns: Péclet number [dimensionless], shape [nFaces]
    public static func computePecletNumber(
        vFace: MLXArray,
        dFace: MLXArray,
        dx: MLXArray
    ) -> MLXArray {
        // Regularization to prevent division by zero
        let dFace_safe = dFace + 1e-30

        // Broadcast dx to [nFaces] if needed (interior faces + boundaries)
        let dx_broadcast: MLXArray
        if dx.ndim == 0 {
            // Scalar dx: create [nFaces] array
            dx_broadcast = MLXArray.full([vFace.shape[0]], values: dx)
        } else {
            // dx is [nFaces-1]: pad with boundary values
            let dx_left = dx[0..<1]
            let dx_right = dx[(dx.shape[0]-1)..<dx.shape[0]]
            dx_broadcast = concatenated([dx_left, dx, dx_right], axis: 0)
        }

        return vFace * dx_broadcast / dFace_safe
    }

    /// Compute power-law weighting factor α for face interpolation
    ///
    /// Face value: x_face = α·x_upwind + (1-α)·x_downwind
    ///
    /// **Patankar formula**:
    /// ```
    /// α(Pe) = max(0, (1 - 0.1·|Pe|)^5)  for |Pe| ≤ 10
    /// α(Pe) = 0 (full upwinding)        for |Pe| > 10
    /// ```
    ///
    /// Sign convention:
    /// - Pe > 0: flow left→right, upwind is left cell
    /// - Pe < 0: flow right→left, upwind is right cell
    ///
    /// - Parameter peclet: Péclet number [dimensionless], shape [nFaces]
    /// - Returns: Weighting factor α ∈ [0,1], shape [nFaces]
    public static func computeWeightingFactor(peclet: MLXArray) -> MLXArray {
        let absPe = abs(peclet)

        // Power-law formula: (1 - 0.1*|Pe|)^5
        // Only valid for |Pe| ≤ 10
        let powerLaw = pow(maximum(0.0, 1.0 - 0.1 * absPe), 5.0)

        // For |Pe| > 10: use full upwinding (α = 0 for central diff, 1 for upwind)
        // TORAX uses (1 - α) formulation, so α=0 means full upwind
        let alpha = expandedDimensions(where(absPe > 10.0, MLXArray(0.0), powerLaw), axis: -1)

        return alpha.squeezed()
    }

    /// Compute face values using power-law weighting
    ///
    /// - Parameters:
    ///   - cellValues: Values at cell centers [nCells]
    ///   - peclet: Péclet number at faces [nFaces]
    /// - Returns: Weighted face values [nFaces]
    public static func interpolateToFaces(
        cellValues: MLXArray,
        peclet: MLXArray
    ) -> MLXArray {
        let nCells = cellValues.shape[0]

        // Interior faces: power-law weighted
        let leftCells = cellValues[0..<(nCells-1)]   // [nFaces-1]
        let rightCells = cellValues[1..<nCells]      // [nFaces-1]
        let pecletInterior = peclet[1..<(peclet.shape[0]-1)]  // [nFaces-1]

        let alpha = computeWeightingFactor(peclet: pecletInterior)

        // Upwind selection based on flow direction
        // Pe > 0: use left cell (α=1), Pe < 0: use right cell (α=0)
        let upwindValues = expandedDimensions(
            where(pecletInterior > 0, leftCells, rightCells),
            axis: -1
        ).squeezed()
        let downwindValues = expandedDimensions(
            where(pecletInterior > 0, rightCells, leftCells),
            axis: -1
        ).squeezed()

        let faceInterior = alpha * upwindValues + (1.0 - alpha) * downwindValues

        // Boundary faces: use adjacent cell value
        let faceLeft = cellValues[0..<1]
        let faceRight = cellValues[(nCells-1)..<nCells]

        return concatenated([faceLeft, faceInterior, faceRight], axis: 0)
    }
}
```

#### 2.2 Integrate into NewtonRaphsonSolver (2 hours)

**File**: `Sources/Gotenx/Solver/NewtonRaphsonSolver.swift`

Modify `interpolateToFacesVectorized`:
```swift
/// Interpolate cell values to faces using power-law scheme
///
/// - Parameters:
///   - u: Cell values [nCells]
///   - vFace: Convection velocity at faces [nFaces]
///   - dFace: Diffusion coefficient at faces [nFaces]
///   - dx: Cell spacing [nCells-1] or scalar
/// - Returns: Face values [nFaces]
private func interpolateToFacesVectorized(
    _ u: MLXArray,
    vFace: MLXArray,
    dFace: MLXArray,
    dx: MLXArray
) -> MLXArray {
    // Compute Péclet number
    let peclet = PowerLawScheme.computePecletNumber(
        vFace: vFace,
        dFace: dFace,
        dx: dx
    )

    // Use power-law interpolation
    return PowerLawScheme.interpolateToFaces(
        cellValues: u,
        peclet: peclet
    )
}
```

Update `applySpatialOperatorVectorized` call site (Line 368):
```swift
// OLD: let u_face = interpolateToFacesVectorized(u)
// NEW:
let u_face = interpolateToFacesVectorized(
    u,
    vFace: vFace,
    dFace: dFace,
    dx: geometry.cellDistances.value
)
```

#### 2.3 Add Tests (3 hours)

**File**: `Tests/GotenxTests/FVM/PowerLawSchemeTests.swift` (NEW)

```swift
import XCTest
import MLX
@testable import Gotenx

final class PowerLawSchemeTests: XCTestCase {

    /// Test Péclet number calculation
    func testPecletNumber() {
        let vFace = MLXArray([0.0, 1.0, 10.0, 100.0])  // [m/s]
        let dFace = MLXArray([1.0, 1.0, 1.0, 1.0])     // [m²/s]
        let dx = MLXArray(1.0)                         // [m]

        let peclet = PowerLawScheme.computePecletNumber(
            vFace: vFace,
            dFace: dFace,
            dx: dx
        )
        eval(peclet)

        let expected = [0.0, 1.0, 10.0, 100.0]
        XCTAssertEqual(peclet.asArray(Float.self), expected, accuracy: 1e-6)
    }

    /// Test power-law weighting for different Péclet numbers
    func testWeightingFactor() {
        let peclet = MLXArray([0.0, 1.0, 5.0, 10.0, 50.0, -10.0])
        let alpha = PowerLawScheme.computeWeightingFactor(peclet: peclet)
        eval(alpha)

        let result = alpha.asArray(Float.self)

        // Pe = 0: central differencing → α ≈ 1 (max power-law)
        XCTAssertEqual(result[0], 1.0, accuracy: 1e-5)

        // Pe = 1: α = (1 - 0.1)^5 = 0.59049
        XCTAssertEqual(result[1], 0.59049, accuracy: 1e-4)

        // Pe = 5: α = (1 - 0.5)^5 = 0.03125
        XCTAssertEqual(result[2], 0.03125, accuracy: 1e-4)

        // Pe = 10: α = (1 - 1.0)^5 = 0
        XCTAssertEqual(result[3], 0.0, accuracy: 1e-5)

        // |Pe| > 10: full upwinding → α = 0
        XCTAssertEqual(result[4], 0.0, accuracy: 1e-5)
        XCTAssertEqual(result[5], 0.0, accuracy: 1e-5)
    }

    /// Test convection-diffusion with varying Péclet (1D analytical solution)
    func testConvectionDiffusion1D() {
        // Problem: ∂u/∂t + V·∂u/∂x = D·∂²u/∂x²
        // Steady-state analytical: u(x) = (exp(Pe·x) - 1) / (exp(Pe) - 1)

        let nCells = 100
        let L: Float = 1.0  // Domain length
        let V: Float = 1.0  // Velocity
        let D: Float = 0.1  // Diffusion
        let Pe = V * L / D  // Péclet = 10

        // Create grid
        let x = MLXArray.linspace(0.0, L, count: nCells)
        let dx = L / Float(nCells - 1)

        // Analytical solution
        let u_exact = (exp(Pe * x) - 1.0) / (exp(Pe) - 1.0)

        // TODO: Solve using power-law scheme and compare
        // (Requires full FVM solver integration)
    }
}
```

#### Deliverables
- ✅ `PowerLawScheme.swift` with Patankar formula
- ✅ Integration into `NewtonRaphsonSolver`
- ✅ Unit tests for Pe = [0.1, 1, 5, 10, 50]
- ✅ Documentation with physics background

---

### Phase 3: Sauter Bootstrap Current (P0, 8-10 hours)

**Goal**: Replace simplified `C_BS = 1 - ε` with collisionality-dependent Sauter formula.

#### 3.1 Implement Collisionality Calculation (3 hours)

**File**: `Sources/Gotenx/Solver/CollisionalityHelpers.swift` (NEW)

```swift
import MLX
import Numerics  // For physical constants

/// Collisionality and neoclassical transport helpers
///
/// **References**:
/// - Sauter et al., "Neoclassical conductivity and bootstrap current", PoP 6, 2834 (1999)
/// - Wesson, "Tokamak Physics" (2nd ed.), Chapter 7
public struct CollisionalityHelpers {

    /// Compute electron-ion collision time τₑ
    ///
    /// Formula: τₑ = (12π^(3/2) ε₀² mₑ^(1/2) Tₑ^(3/2)) / (nₑ e⁴ ln(Λ))
    ///
    /// Simplified: τₑ ≈ 3.44e5 * Tₑ^(3/2) / (nₑ * ln(Λ))  [seconds]
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV], shape [nCells]
    ///   - ne: Electron density [m⁻³], shape [nCells]
    ///   - coulombLog: Coulomb logarithm (default: 17.0)
    /// - Returns: Collision time [s], shape [nCells]
    public static func computeCollisionTime(
        Te: MLXArray,
        ne: MLXArray,
        coulombLog: Float = 17.0
    ) -> MLXArray {
        // τₑ = 3.44e5 * Tₑ^(3/2) / (nₑ * ln(Λ))
        let tau_e = 3.44e5 * pow(Te, 1.5) / (ne * coulombLog)
        return tau_e
    }

    /// Compute normalized collisionality ν*
    ///
    /// Formula: ν* = (R₀ q) / (ε^(3/2) vₜₕ τₑ)
    ///           = (R₀ q) / (ε^(3/2) √(2Tₑ/mₑ) τₑ)
    ///
    /// Where:
    /// - ε = r/R₀ (inverse aspect ratio)
    /// - q: safety factor
    /// - vₜₕ = √(2Tₑ/mₑ): thermal velocity
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV], shape [nCells]
    ///   - ne: Electron density [m⁻³], shape [nCells]
    ///   - geometry: Tokamak geometry
    /// - Returns: Normalized collisionality ν* [dimensionless], shape [nCells]
    public static func computeNormalizedCollisionality(
        Te: MLXArray,
        ne: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        let tau_e = computeCollisionTime(Te: Te, ne: ne)

        // Inverse aspect ratio: ε = r/R₀
        let epsilon = geometry.radii.value / geometry.majorRadius

        // Safety factor q (from geometry or approximation)
        // For now, use cylindrical approximation: q ≈ r·Bφ/(R₀·Bp)
        let q = geometry.safetyFactor ?? approximateSafetyFactor(geometry: geometry)

        // Thermal velocity: vₜₕ = √(2Tₑ/mₑ)
        // With Tₑ in eV: vₜₕ = √(2 * Tₑ[eV] * 1.602e-19 / 9.109e-31)
        //                    = √(3.514e11 * Tₑ)  [m/s]
        let vth = sqrt(3.514e11 * Te)

        // ν* = (R₀ q) / (ε^(3/2) vₜₕ τₑ)
        let nu_star = (geometry.majorRadius * q) / (pow(epsilon, 1.5) * vth * tau_e)

        return nu_star
    }

    /// Approximate safety factor q from geometry
    ///
    /// Cylindrical approximation: q ≈ (r Bφ) / (R₀ Bp)
    ///
    /// - Parameter geometry: Tokamak geometry
    /// - Returns: Safety factor [dimensionless], shape [nCells]
    private static func approximateSafetyFactor(geometry: Geometry) -> MLXArray {
        // q ≈ (r * Bφ) / (R₀ * Bp)
        // Bp ≈ ψ' / (2π r) (from flux definition)

        // Simplified: q ≈ 1 + (r/a)²  (parabolic profile)
        let r_norm = geometry.radii.value / geometry.minorRadius
        return 1.0 + r_norm * r_norm
    }
}
```

#### 3.2 Implement Sauter Formula (4 hours)

**File**: `Sources/Gotenx/Solver/Block1DCoeffsBuilder.swift`

Replace `computeBootstrapCurrent` (Line 474-507):

```swift
/// Compute bootstrap current using Sauter neoclassical formula
///
/// **Full Sauter Formula**:
/// ```
/// J_BS = -C_BS(ν*, ft, ε) · (∇P / B_φ)
/// where C_BS = L₃₁·fₜ + L₃₂·fₜ·α + L₃₄·fₜ·α²
/// ```
///
/// - L₃ᵢ: Collisionality-dependent coefficients (Sauter Table I)
/// - fₜ: Trapped particle fraction = 1 - √(1-ε)
/// - α: Pressure anisotropy parameter (≈ 0 for isotropic)
///
/// **References**:
/// - Sauter et al., PoP 6, 2834 (1999), Eqs. 13-14, Table I
///
/// - Parameters:
///   - profiles: Current core profiles
///   - geometry: Tokamak geometry
/// - Returns: Bootstrap current density [A/m²], shape [nCells]
private func computeBootstrapCurrent(
    profiles: CoreProfiles,
    geometry: Geometry
) -> MLXArray {
    let Ti = profiles.ionTemperature.value
    let Te = profiles.electronTemperature.value
    let ne = profiles.electronDensity.value

    // 1. Compute total pressure: P = n_e (T_i + T_e) * e
    let P = ne * (Ti + Te) * UnitConversions.eV  // [Pa]

    // 2. Compute pressure gradient: ∇P [Pa/m]
    let geoFactors = GeometricFactors.from(geometry: geometry)
    let gradP = computeGradient(P, cellDistances: geoFactors.cellDistances.value)

    // 3. Compute normalized collisionality ν*
    let nu_star = CollisionalityHelpers.computeNormalizedCollisionality(
        Te: Te,
        ne: ne,
        geometry: geometry
    )

    // 4. Compute trapped particle fraction
    let epsilon = geometry.radii.value / geometry.majorRadius
    let ft = 1.0 - sqrt(1.0 - epsilon)

    // 5. Compute Sauter coefficients L₃₁, L₃₂, L₃₄
    // Using Sauter et al. (1999) Table I fitting formulas
    let L31 = computeSauterL31(nu_star: nu_star, ft: ft)
    let L32 = computeSauterL32(nu_star: nu_star, ft: ft)
    let L34 = computeSauterL34(nu_star: nu_star, ft: ft)

    // 6. Pressure anisotropy parameter α (assume isotropic: α = 0)
    // For anisotropic distributions, α = (P_∥ - P_⊥) / P
    let alpha = MLXArray.zeros(like: Te)

    // 7. Bootstrap coefficient: C_BS = L₃₁·ft + L₃₂·ft·α + L₃₄·ft·α²
    let C_BS = L31 * ft + L32 * ft * alpha + L34 * ft * alpha * alpha

    // 8. Bootstrap current: J_BS = -C_BS · (∇P / B_φ)
    // Note: Negative sign because ∇P points inward (toward axis) in tokamak
    let J_BS = -C_BS * gradP / geometry.toroidalField

    // 9. Clamp to physical range [0, 10 MA/m²]
    // (Negative values can occur at plasma edge, clamp to zero)
    let J_BS_clamped = minimum(maximum(J_BS, MLXArray(0.0)), MLXArray(1e7))

    return J_BS_clamped
}

/// Compute Sauter L₃₁ coefficient (bootstrap current, main term)
///
/// **Formula** (Sauter Table I, simplified):
/// ```
/// L₃₁(ν*, ft) = ((1 + 0.15/ft) - 0.22/(1 + 0.01·ν*)) / (1 + 0.5·√ν*)
/// ```
///
/// - Parameters:
///   - nu_star: Normalized collisionality [dimensionless]
///   - ft: Trapped fraction [dimensionless]
/// - Returns: L₃₁ coefficient [dimensionless]
private func computeSauterL31(nu_star: MLXArray, ft: MLXArray) -> MLXArray {
    // Regularization to prevent division by zero
    let ft_safe = ft + 1e-10
    let nu_safe = nu_star + 1e-10

    // L₃₁ = ((1 + 0.15/ft) - 0.22/(1 + 0.01·ν*)) / (1 + 0.5·√ν*)
    let numerator = (1.0 + 0.15 / ft_safe) - 0.22 / (1.0 + 0.01 * nu_safe)
    let denominator = 1.0 + 0.5 * sqrt(nu_safe)

    return numerator / denominator
}

/// Compute Sauter L₃₂ coefficient (pressure anisotropy correction)
private func computeSauterL32(nu_star: MLXArray, ft: MLXArray) -> MLXArray {
    // Simplified: L₃₂ ≈ 0.05 (small correction for α term)
    return MLXArray.full(nu_star.shape, values: MLXArray(0.05))
}

/// Compute Sauter L₃₄ coefficient (second-order pressure anisotropy)
private func computeSauterL34(nu_star: MLXArray, ft: MLXArray) -> MLXArray {
    // Simplified: L₃₄ ≈ 0.01 (very small correction for α² term)
    return MLXArray.full(nu_star.shape, values: MLXArray(0.01))
}
```

#### 3.3 Add Tests (3 hours)

**File**: `Tests/GotenxTests/Solver/BootstrapCurrentTests.swift` (NEW)

```swift
final class BootstrapCurrentTests: XCTestCase {

    /// Test collisionality calculation against reference values
    func testCollisionality() {
        // ITER typical core: Te = 10 keV, ne = 1e20 m⁻³
        let Te = MLXArray([10000.0])  // [eV]
        let ne = MLXArray([1e20])     // [m⁻³]

        let tau_e = CollisionalityHelpers.computeCollisionTime(
            Te: Te,
            ne: ne,
            coulombLog: 17.0
        )
        eval(tau_e)

        // Expected: τₑ ≈ 3.44e5 * (1e4)^1.5 / (1e20 * 17) ≈ 2.02e-6 s
        let expected: Float = 2.02e-6
        XCTAssertEqual(tau_e.item(Float.self), expected, accuracy: expected * 0.1)
    }

    /// Test Sauter coefficients for banana regime (low ν*)
    func testSauterCoefficients_BananaRegime() {
        // Low collisionality: ν* = 0.01, ft = 0.3
        let nu_star = MLXArray([0.01])
        let ft = MLXArray([0.3])

        let L31 = computeSauterL31(nu_star: nu_star, ft: ft)
        eval(L31)

        // Banana regime: L₃₁ ≈ 1.5 (from Sauter Table I)
        XCTAssertEqual(L31.item(Float.self), 1.5, accuracy: 0.2)
    }

    /// Test Sauter coefficients for plateau regime (moderate ν*)
    func testSauterCoefficients_PlateauRegime() {
        // Moderate collisionality: ν* = 1.0, ft = 0.3
        let nu_star = MLXArray([1.0])
        let ft = MLXArray([0.3])

        let L31 = computeSauterL31(nu_star: nu_star, ft: ft)
        eval(L31)

        // Plateau regime: L₃₁ ≈ 0.8
        XCTAssertEqual(L31.item(Float.self), 0.8, accuracy: 0.2)
    }

    /// Compare simplified vs. Sauter bootstrap current for ITER-like profile
    func testBootstrapCurrent_ITERComparison() {
        // TODO: Set up ITER-like profiles and compare
        // Expected: Sauter gives 20-30% higher bootstrap fraction at edge
    }
}
```

#### Deliverables
- ✅ `CollisionalityHelpers.swift` with ν* calculation
- ✅ Sauter formula implementation in `computeBootstrapCurrent`
- ✅ Unit tests for banana/plateau/Pfirsch-Schlüter regimes
- ✅ Integration test comparing simplified vs. Sauter for ITER

---

### Phase 4: Non-Uniform Grid Support (P1, 6-8 hours)

**Goal**: Use full metric tensors from `Geometry` for shaped plasmas.

#### 4.1 Enhance GeometricFactors (4 hours)

**File**: `Sources/Gotenx/Core/GeometricFactors.swift` (MODIFY)

Add metric tensor support:
```swift
public struct GeometricFactors: Sendable {
    // ... existing fields ...

    /// Metric tensor component g₀ = √g (Jacobian of flux coordinates)
    /// Shape: [nCells]
    public let jacobian: EvaluatedArray

    /// Metric tensor component g₁ (related to ∂R/∂ψ)
    /// Shape: [nCells]
    public let g1: EvaluatedArray

    /// Metric tensor component g₂ (related to pressure gradient)
    /// Shape: [nCells]
    public let g2: EvaluatedArray

    /// Create from full geometry (NEW: use g0, g1, g2)
    public static func from(geometry: Geometry) -> GeometricFactors {
        let nCells = geometry.nCells

        // Use actual metric tensors from Geometry
        let jacobian = geometry.g0  // √g = F/B_p
        let g1 = geometry.g1
        let g2 = geometry.g2

        // Cell volumes: V = ∫ √g dr dθ dζ = 2π ∫ g₀ dr
        let dr = geometry.radii.value[1] - geometry.radii.value[0]  // Assume uniform for now
        let cellVolumes = jacobian.value * dr * Float(2 * .pi)

        // Face areas: A = 2π g₀(r_face)
        let jacobianFaces = interpolateToFaces(jacobian.value, mode: .arithmetic)
        let faceAreas = jacobianFaces * Float(2 * .pi)

        // ... rest of implementation ...

        return GeometricFactors(
            cellVolumes: EvaluatedArray(evaluating: cellVolumes),
            faceAreas: EvaluatedArray(evaluating: faceAreas),
            cellDistances: ...,
            jacobian: jacobian,
            g1: g1,
            g2: g2
        )
    }
}
```

#### 4.2 Update Spatial Operators (2 hours)

Modify `applySpatialOperatorVectorized` to use metric tensors:
```swift
private func applySpatialOperatorVectorized(
    u: MLXArray,
    coeffs: EquationCoeffs,
    geometry: GeometricFactors,
    boundaryCondition: BoundaryCondition
) -> MLXArray {
    // ... existing gradient calculation ...

    // Flux divergence with metric tensors:
    // ∇·F = (1/√g) ∂(√g·F)/∂ψ
    let flux_right = totalFlux[1..<(nCells + 1)]
    let flux_left = totalFlux[0..<nCells]

    // Metric-weighted flux difference
    let jacobianCells = geometry.jacobian.value
    let jacobianFaces = interpolateToFaces(jacobianCells, mode: .arithmetic)
    let jacobian_right = jacobianFaces[1..<(nCells + 1)]
    let jacobian_left = jacobianFaces[0..<nCells]

    let weightedFlux_right = jacobian_right * flux_right
    let weightedFlux_left = jacobian_left * flux_left

    let fluxDivergence = (weightedFlux_right - weightedFlux_left) /
                         (jacobianCells * geometry.cellDistances.value + 1e-10)

    // ... rest of implementation ...
}
```

#### 4.3 Add Non-Uniform Grid Tests (2 hours)

**File**: `Tests/GotenxTests/FVM/NonUniformGridTests.swift` (NEW)

```swift
final class NonUniformGridTests: XCTestCase {

    /// Test convergence on exponentially refined grid
    func testExponentialGrid() {
        // Create exponentially spaced grid (fine near edge)
        let nCells = 100
        let a: Float = 0.5  // Minor radius
        let stretch: Float = 2.0

        // r(i) = a * (exp(stretch * i/N) - 1) / (exp(stretch) - 1)
        let i_norm = MLXArray.linspace(0.0, 1.0, count: nCells)
        let r = a * (exp(stretch * i_norm) - 1.0) / (exp(stretch) - 1.0)

        // TODO: Create geometry with non-uniform spacing
        // Verify conservation and convergence rate
    }

    /// Test shaped plasma (D-shape with δ = 0.4, κ = 1.8)
    func testShapedPlasma() {
        // TODO: Create ITER-like shaped geometry
        // Compare flux-surface-averaged quantities with/without metrics
    }
}
```

#### Deliverables
- ✅ Enhanced `GeometricFactors` with metric tensors
- ✅ Updated spatial operators to use metrics
- ✅ Tests for exponential grid and shaped plasma
- ✅ Documentation on metric tensor usage

---

### Phase 5: Integration Testing (P2, 6-8 hours)

**Goal**: End-to-end validation of complete FVM pipeline.

#### 5.1 Analytical Solution Tests (3 hours)

**File**: `Tests/GotenxTests/Integration/FVMAnalyticalTests.swift` (NEW)

```swift
final class FVMAnalyticalTests: XCTestCase {

    /// Test 1D diffusion against analytical solution
    ///
    /// PDE: ∂T/∂t = χ ∂²T/∂r²
    /// Analytical: T(r,t) = T₀ exp(-r²/(4χt)) / √(1 + 4χt/r₀²)
    func testDiffusionAnalytical() {
        let chi: Float = 1.0    // [m²/s]
        let T0: Float = 1000.0  // [eV]
        let r0: Float = 0.5     // [m]
        let tFinal: Float = 1.0 // [s]

        // TODO: Set up simulation with D=χ, V=0, source=0
        // Run to t=tFinal, compare with analytical solution
        // Expected error < 5% for nCells=100
    }

    /// Test steady-state convection-diffusion (Péclet sweep)
    ///
    /// PDE: V ∂T/∂r = χ ∂²T/∂r²
    /// Analytical: T(r) = (exp(Pe·r/L) - 1) / (exp(Pe) - 1)
    func testConvectionDiffusionSteadyState() {
        let pecletNumbers: [Float] = [0.1, 1.0, 5.0, 10.0, 50.0]

        for Pe in pecletNumbers {
            // TODO: Set up V and χ to achieve target Pe
            // Run to steady state, compare with analytical
            // Verify power-law scheme prevents oscillations for Pe > 10
        }
    }
}
```

#### 5.2 Conservation Tests (2 hours)

**File**: `Tests/GotenxTests/Integration/ConservationTests.swift` (NEW)

```swift
final class ConservationTests: XCTestCase {

    /// Test particle conservation over 100 timesteps
    func testParticleConservation() {
        // Initial particles: N₀ = ∫ n_e dV
        // After 100 steps with no source: |N - N₀| / N₀ < 1%

        // TODO: Run simulation with particle source = 0
        // Compute integrated particle number at each step
        // Verify drift < 1% over 100 steps
    }

    /// Test energy conservation (no heating/loss)
    func testEnergyConservation() {
        // Total energy: E = ∫ (3/2)nT dV
        // With Q_heat = 0, Q_loss = 0: dE/dt ≈ 0

        // TODO: Run simulation with all sources = 0
        // Verify |E(t=100Δt) - E(t=0)| / E(t=0) < 1%
    }

    /// Test current conservation (bootstrap + Ohmic)
    func testCurrentConservation() {
        // Total current: I_p = ∫ J dA
        // Verify I_p matches specified boundary condition

        // TODO: Set fixed current drive, run to steady state
        // Compare integrated current with specified value
    }
}
```

#### 5.3 TORAX Benchmark (3 hours)

**File**: `Tests/GotenxTests/Integration/TORAXBenchmarkTests.swift` (NEW)

```swift
final class TORAXBenchmarkTests: XCTestCase {

    /// Compare ITER-like scenario with Python TORAX
    ///
    /// Use identical initial conditions, run for 10 time steps,
    /// compare profiles within 5% RMS error.
    func testITERScenario() {
        // Load ITER_LIKE configuration
        // Run both Gotenx and TORAX (via subprocess or pre-computed reference)
        // Compare Ti, Te, ne, psi profiles at t = 1.0 s

        // Acceptance criteria:
        // - RMS error < 5% for all profiles
        // - Peak values within 3%
        // - Gradient scales within 10%
    }
}
```

#### Deliverables
- ✅ 3 analytical solution tests (diffusion, convection-diffusion)
- ✅ 3 conservation tests (particles, energy, current)
- ✅ TORAX benchmark test with ITER scenario
- ✅ CI integration for regression detection

---

## Configuration Migration Guide

### JSON Schema Update

**File**: `Examples/Configurations/iter_like_improved.json` (NEW)

```json
{
  "runtime": {
    "static": {
      "mesh": {
        "nCells": 200
      },
      "solver": {
        "tolerances": {
          "ionTemperature": {
            "absoluteTolerance": 10.0,
            "relativeTolerance": 1e-4,
            "minValueThreshold": 100.0
          },
          "electronTemperature": {
            "absoluteTolerance": 10.0,
            "relativeTolerance": 1e-4,
            "minValueThreshold": 100.0
          },
          "electronDensity": {
            "absoluteTolerance": 1e17,
            "relativeTolerance": 1e-4,
            "minValueThreshold": 1e18
          },
          "poloidalFlux": {
            "absoluteTolerance": 1e-3,
            "relativeTolerance": 1e-5,
            "minValueThreshold": 0.1
          }
        },
        "physicalThresholds": {
          "fuelFractionTolerance": 1e-4,
          "minFusionPowerForQ": 1e-3,
          "minHeatingPowerForTauE": 1e-2,
          "fluxVariationThreshold": 1e-5,
          "minStoredEnergy": 1e-3
        },
        "maxIterations": 30,
        "lineSearchEnabled": true
      },
      "time": {
        "maxDt": 0.1,
        "minTimestepFraction": 0.001,
        "cflSafetyFactor": 0.9,
        "maxTimestepGrowth": 1.2
      }
    }
  }
}
```

### CLI Migration Path

**Backward Compatibility**: Old configs with `tolerance: 1e-6` will auto-upgrade:

```swift
// In GotenxConfigReader.swift
if let legacyTolerance = json["solver"]["tolerance"].float {
    // Convert to per-equation tolerances with default scaling
    return NumericalTolerances(
        ionTemperature: EquationTolerances(
            absoluteTolerance: legacyTolerance * 1e4,  // Scale to eV
            relativeTolerance: legacyTolerance,
            minValueThreshold: 100.0
        ),
        // ... similar for other equations
    )
}
```

---

## Validation Criteria

### Phase 1 (Configuration): ✅ Acceptance
- [ ] All 15 `1e-6` occurrences replaced with config values
- [ ] Per-equation tolerances accessible in solver
- [ ] JSON config validates with new schema
- [ ] Backward compatibility for old configs

### Phase 2 (Power-Law): ✅ Acceptance
- [ ] Péclet number calculation tested for Pe ∈ [0.01, 100]
- [ ] Power-law weighting matches Patankar formula within 1e-5
- [ ] Convection-diffusion test shows no oscillations for Pe = 50
- [ ] Integration into solver preserves Newton convergence

### Phase 3 (Sauter Bootstrap): ✅ Acceptance
- [ ] Collisionality ν* matches reference (ITER core: ν* ≈ 0.01)
- [ ] Sauter L₃₁ within 10% of Table I values for banana/plateau regimes
- [ ] Bootstrap current differs from simplified by 20-30% at edge (as expected)
- [ ] ITER benchmark: bootstrap fraction f_BS = 0.4 ± 0.05

### Phase 4 (Metrics): ✅ Acceptance
- [ ] Metric tensors g₀, g₁, g₂ propagated through flux calculations
- [ ] Shaped plasma (δ=0.4, κ=1.8): geometric error < 5%
- [ ] Exponential grid: convergence rate = O(Δr²) maintained
- [ ] Uniform grid results unchanged (backward compatibility)

### Phase 5 (Integration): ✅ Acceptance
- [ ] 1D diffusion: error < 5% vs. analytical (nCells=100)
- [ ] Particle conservation: drift < 1% over 100 steps
- [ ] Energy conservation: drift < 1% over 100 steps
- [ ] TORAX benchmark: RMS error < 5% for all profiles

---

## Risk Mitigation

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Power-law scheme breaks Newton convergence | Medium | High | Add line search adaptation, fallback to central diff |
| Sauter formula unstable at low density | Low | Medium | Add density floor (1e18 m⁻³), clamp ν* ∈ [1e-3, 1e3] |
| Metric tensors cause performance regression | Low | Low | Profile before/after, optimize eval() placement |
| Per-equation tolerances too complex for users | Medium | Low | Provide presets (ITER, DIII-D, JET), auto-tune mode |

### Schedule Risks

| Risk | Mitigation |
|------|------------|
| Phase 3 (Sauter) takes longer than estimated | Implement simplified Sauter first (L₃₁ only), defer L₃₂/L₃₄ to Phase 6 |
| Integration tests reveal fundamental issues | Pause implementation, triage with unit tests, fix root cause before proceeding |
| TORAX benchmark data unavailable | Use published ITER Baseline Scenario results as reference |

---

## Success Metrics

### Quantitative
- ✅ Code coverage: 90% for new modules (PowerLawScheme, CollisionalityHelpers)
- ✅ Performance: Full timestep < 15 ms (nCells=100, was 10 ms target + 50% margin for new features)
- ✅ Accuracy: TORAX benchmark RMS error < 5%
- ✅ Conservation: Particle/energy drift < 1% over 100 steps

### Qualitative
- ✅ Configuration system: User can tune tolerances via JSON without code changes
- ✅ Documentation: Every new module has physics background + references
- ✅ Maintainability: No magic numbers, all thresholds traced to config
- ✅ TORAX alignment: Power-law scheme, Sauter formula match Python implementation

---

## Timeline Summary

| Phase | Priority | Effort | Dependencies | Deliverables |
|-------|----------|--------|--------------|--------------|
| 1. Configuration Refactor | P0 | 8-10h | None | `NumericalTolerances`, `PhysicalThresholds`, updated 5 modules |
| 2. Power-Law Scheme | P0 | 6-8h | Phase 1 | `PowerLawScheme.swift`, tests, integration |
| 3. Sauter Bootstrap | P0 | 8-10h | None | `CollisionalityHelpers`, Sauter formula, tests |
| 4. Metric Tensors | P1 | 6-8h | None | Enhanced `GeometricFactors`, spatial operators |
| 5. Integration Tests | P2 | 6-8h | Phases 2-4 | Analytical, conservation, TORAX benchmark tests |
| **Total** | | **40-50h** | | **~1 week full-time** |

### Suggested Schedule

**Week 1**:
- Day 1-2: Phase 1 (Configuration) - Foundation for all other work
- Day 3: Phase 2 (Power-Law) - Critical for stability
- Day 4-5: Phase 3 (Sauter Bootstrap) - Physics accuracy

**Week 2** (if continuing):
- Day 1-2: Phase 4 (Metric Tensors) - Advanced geometry
- Day 3-5: Phase 5 (Integration Tests) - Validation

**Minimum Viable Product**: Phases 1-3 only (22-28 hours, ~3-4 days)

---

## References

### TORAX Core
1. **TORAX Paper**: arXiv:2406.06718v2, "TORAX: A Differentiable Tokamak Transport Simulator"
2. **TORAX GitHub**: https://github.com/google-deepmind/torax
3. **DeepWiki**: https://deepwiki.com/google-deepmind/torax

### Numerical Methods
4. **Patankar (1980)**: "Numerical Heat Transfer and Fluid Flow" (Power-law scheme)
5. **Hairer & Wanner (1996)**: "Solving ODEs II" (Theta method)
6. **Higham (2002)**: "Accuracy and Stability of Numerical Algorithms"

### Neoclassical Physics
7. **Sauter et al. (1999)**: "Neoclassical conductivity and bootstrap current formulas", PoP 6, 2834
8. **Wesson (2011)**: "Tokamak Physics" (2nd ed.), Chapter 7 (Neoclassical transport)
9. **Hirshman & Sigmar (1981)**: "Neoclassical transport of impurities", NF 21, 1079

### Tokamak Geometry
10. **Miller et al. (1998)**: "Noncircular, finite aspect ratio, local equilibrium model", PoP 5, 973
11. **Lao et al. (1985)**: "Reconstruction of current profile parameters", NF 25, 1611

---

## Appendix: File Impact Summary

### Files to Create (7 new files)
1. `Sources/Gotenx/Configuration/NumericalTolerances.swift`
2. `Sources/Gotenx/Configuration/PhysicalThresholds.swift`
3. `Sources/Gotenx/FVM/PowerLawScheme.swift`
4. `Sources/Gotenx/Solver/CollisionalityHelpers.swift`
5. `Tests/GotenxTests/FVM/PowerLawSchemeTests.swift`
6. `Tests/GotenxTests/Solver/BootstrapCurrentTests.swift`
7. `Tests/GotenxTests/Integration/FVMIntegrationTests.swift`

### Files to Modify (12 existing files)
1. `Sources/Gotenx/Configuration/TimeConfiguration.swift` (+20 lines)
2. `Sources/Gotenx/Configuration/SolverConfig.swift` (+15 lines)
3. `Sources/Gotenx/Configuration/RuntimeParams.swift` (+10 lines)
4. `Sources/GotenxCLI/Configuration/GotenxConfigReader.swift` (+50 lines)
5. `Sources/Gotenx/Solver/NewtonRaphsonSolver.swift` (+80 lines)
6. `Sources/Gotenx/Solver/Block1DCoeffsBuilder.swift` (+150 lines)
7. `Sources/Gotenx/Core/GeometricFactors.swift` (+30 lines)
8. `Sources/Gotenx/Orchestration/TimeStepCalculator.swift` (+15 lines)
9. `Sources/GotenxPhysics/Heating/OhmicHeating.swift` (+5 lines)
10. `Sources/GotenxPhysics/Heating/FusionPower.swift` (+5 lines)
11. `Sources/Gotenx/Configuration/ConfigurationValidator.swift` (+5 lines)
12. `Sources/Gotenx/Diagnostics/DerivedQuantitiesComputer.swift` (+20 lines)

**Total New Code**: ~1500 lines
**Total Modified Code**: ~405 lines
**Total Impact**: ~1900 lines across 19 files

---

**Document Status**: Ready for Implementation
**Next Action**: Begin Phase 1 (Configuration Refactor)
**Point of Contact**: Review with team, prioritize phases based on project needs

---

*End of Document*
