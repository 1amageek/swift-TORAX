# Numerical Robustness Design

**Version:** 1.1
**Date:** 2025-10-25
**Status:** Implementation Ready
**Priority:** 🔥 Critical

## Document Status

**Revision 1.1 (2025-10-25)**:
- Added implementation gap analysis from code review
- Defined Sprint 1-3 phased implementation strategy
- Clarified minimal vs complete implementation tradeoffs
- Updated dependencies and priorities based on current codebase state

**Revision 1.0 (2025-10-25)**: Initial design

---

## Executive Summary

This document addresses critical numerical robustness issues discovered during Newton-Raphson solver execution, specifically NaN propagation in physics models and infinite residuals in iterative solvers. The design proposes a multi-layered defense strategy with input validation, safe fallbacks, and constraint enforcement.

### Implementation Status

**Current State** (as of 2025-10-25):
- ❌ ValidatedProfiles wrapper: **Not implemented**
- ❌ IonElectronExchange guards: **Not implemented** (crash still reproducible)
- ❌ Initial profile validation: **Not implemented** (missing Te detection absent)
- ❌ Newton-Raphson constraints: **Not implemented** (unconstrained line search)
- ✅ SourceTerms output validation: **Implemented** (precondition checks exist)

**Implementation Gap**: All Phase 1-4 defenses are missing, leaving the original crash unresolved.

**Recommended Approach**: Phased implementation (Sprint 1-3) starting with minimal ValidatedProfiles and IonElectronExchange guards.

### Key Issues Addressed

1. **NaN propagation** in `IonElectronExchange` model (Sources/GotenxPhysics/Heating/IonElectronExchange.swift:208)
2. **Infinite residuals** in Newton-Raphson solver's first iteration
3. **Uninitialized electron temperature** in initial profiles
4. **Unguarded line search** allowing physically invalid trial solutions

---

## Problem Analysis

### Crash Report

```
GotenxCore/SourceTerms.swift:60: Precondition failed: SourceTerms: Suspicious ion heating value: nan MW/m³
```

**Stack Trace**:
```
IonElectronExchange.applyToSources()  [Line 208]
  → IonElectronExchangeSource.computeTerms()
  → CompositeSourceModel.computeTerms()
  → SimulationOrchestrator.performStep()
  → NewtonRaphsonSolver.solve()  [lineSearch]
  → CRASH
```

**Debug Output**:
```
[DEBUG-NR-INIT] Initial profiles:
  Ti: min=100.0, max=100.0  ✅
  ne: min=2e+19, max=2e+19  ✅
  Te: <missing>              ❌

[DEBUG-NR] iter=0: residualNorm=inf  ❌
[DEBUG-HLS-COND] vnorm is not finite: inf  ❌
```

### Root Cause Analysis

#### Issue 1: Uninitialized Electron Temperature

**Location**: Initial profile creation (likely in AppViewModel or configuration loader)

**Evidence**:
- Debug log shows Ti and ne but not Te
- IonElectronExchange requires Te for calculation: `Q_ie ∝ (Te - Ti) / Ti^(3/2)`
- If Te = 0 or uninitialized, division by zero or NaN results

**Impact**: First-order failure - simulation cannot start

#### Issue 2: Unconstrained Line Search

**Location**: `Sources/GotenxCore/Solver/NewtonRaphsonSolver.swift:610`

**Problem**:
```swift
// Current implementation (simplified)
func lineSearch(...) -> Float {
    for alpha in alphas {
        let xTrial = x + alpha * delta  // ❌ No constraint checking
        let residualTrial = residualFn(xTrial)

        if norm(residualTrial) < norm(residual) {
            return alpha  // Accept trial
        }
    }
}
```

**Failure Mode**:
- Trial solution `xTrial` can have negative temperatures
- Trial solution can have NaN/Inf values
- Physics models called with invalid inputs → NaN propagation

#### Issue 3: Missing Input Validation in Physics Models

**Location**: `Sources/GotenxPhysics/Heating/IonElectronExchange.swift:208`

**Current State** (assumed):
```swift
public func applyToSources(...) -> SourceTerms {
    let Ti = profiles.ionTemperature.value
    let Te = profiles.electronTemperature.value  // ❌ Could be NaN/0
    let ne = profiles.electronDensity.value

    // ❌ No validation
    let Q_ie = computeExchangeRate(Ti: Ti, Te: Te, ne: ne)
    // If Te = 0: division by zero → NaN
    // If Te = NaN: NaN propagates

    return SourceTerms(ionHeating: Q_ie, ...)
}
```

**Physics Formula**:
```
Q_ie [MW/m³] = (3 me / mi) * ne * νei * (Te - Ti)
where νei = collision frequency ∝ ne / Te^(3/2)
```

If `Te = 0`:
```
νei → ∞ → Q_ie → NaN
```

#### Issue 4: Condition Number Estimation Failure

**Location**: `Sources/GotenxCore/Solver/HybridLinearSolver.swift`

**Debug Output**:
```
[DEBUG-HLS-COND] vnorm is not finite: inf, returning 1e15
```

**Problem**:
- Jacobian matrix has infinite entries due to upstream NaN/Inf
- Power iteration for condition number fails
- Solver switches to iterative method with corrupted matrix
- Convergence declared with `rel_change=0.00e+00` (false positive)

---

## Design Principles

### 1. Defense in Depth

Multiple layers of protection against numerical errors:

```
Layer 1: Input Validation (Configuration)
   ↓
Layer 2: Initialization Checks (CoreProfiles)
   ↓
Layer 3: Physics Model Guards (Source models, Transport models)
   ↓
Layer 4: Solver Constraints (Newton-Raphson, line search)
   ↓
Layer 5: Output Validation (SourceTerms, Block1DCoeffs)
```

### 2. Fail-Fast vs. Fail-Safe

**Fail-Fast** (preferred for development):
- Detect errors immediately with `precondition()`
- Provide detailed error messages
- Crash with stack trace for debugging

**Fail-Safe** (production fallback):
- Return safe default values (e.g., zero source terms)
- Log warning but continue execution
- Attempt recovery with reduced timestep

**Strategy**: Use fail-fast during development/testing, optionally enable fail-safe for production via configuration flag.

### 3. Physically-Motivated Constraints

All constraints must have physical justification:

| Constraint | Physical Basis | Enforcement |
|------------|----------------|-------------|
| `T > 1 eV` | Cold plasma limit (below 1 eV, neutral behavior dominates) | Minimum temperature |
| `T < 100 keV` | Thermonuclear regime upper bound | Maximum temperature |
| `n > 1e17 m⁻³` | Low-density tokamak limit | Minimum density |
| `n < 1e21 m⁻³` | Greenwald density limit | Maximum density |
| `ψ ∈ [0, 1]` | Normalized poloidal flux definition | Boundary conditions |

### 4. Graceful Degradation

When physics models encounter edge cases:

1. **Log warning** with detailed context
2. **Return conservative estimate** (e.g., zero exchange rate)
3. **Continue simulation** with reduced timestep
4. **Flag data point** as unreliable in output

---

## Architecture Design

### Component Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Configuration Validation                          │
│  - ConfigurationValidator                                   │
│  - Pre-simulation checks (CFL, physical ranges)             │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Profile Initialization                            │
│  - CoreProfiles.init() with validation                      │
│  - Ensure Te, Ti, ne all initialized                        │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Physics Model Guards (NEW)                        │
│  - ValidatedProfiles wrapper                                │
│  - Input validation in all physics models                   │
│  - Safe fallback mechanisms                                 │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Solver Constraints (ENHANCED)                     │
│  - Newton-Raphson line search with constraint projection    │
│  - Physically-bounded trial solutions                       │
│  - Adaptive timestep reduction on failure                   │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 5: Output Validation (EXISTING)                      │
│  - SourceTerms precondition checks                          │
│  - Block1DCoeffs sanity checks                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Specification

### Phase 0: ValidatedProfiles Wrapper (FOUNDATION)

**Location**: `Sources/GotenxCore/Core/ValidatedProfiles.swift` (new file)

**Purpose**: Ensure all physics models receive valid input data

**Implementation Strategy**: Two-tier approach

#### Tier 1: Minimal ValidatedProfiles (Sprint 1)

**Scope**: Crash prevention only
- ✅ Finite value checking (NaN/Inf detection)
- ✅ Positive temperature checking (T > 0)
- ❌ Bounds checking deferred to Sprint 3
- ❌ Shape validation deferred to Sprint 3

```swift
/// Minimal validated wrapper for CoreProfiles (Sprint 1)
///
/// Critical checks only:
/// - All values finite (no NaN, no Inf)
/// - Temperatures positive (T > 0 eV)
///
/// Deferred to Sprint 3:
/// - Bounds checking (T < T_max, n ∈ [n_min, n_max])
/// - Shape consistency validation
public struct ValidatedProfiles {
    public let ionTemperature: EvaluatedArray
    public let electronTemperature: EvaluatedArray
    public let electronDensity: EvaluatedArray
    public let poloidalFlux: EvaluatedArray

    private init(
        ionTemperature: EvaluatedArray,
        electronTemperature: EvaluatedArray,
        electronDensity: EvaluatedArray,
        poloidalFlux: EvaluatedArray
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }

    /// Minimal validation (Sprint 1): finite + positive temperature only
    ///
    /// Returns nil if critical checks fail (NaN/Inf/negative T)
    /// Does NOT check bounds or shapes (deferred to Sprint 3)
    public static func validateMinimal(_ profiles: CoreProfiles) -> ValidatedProfiles? {
        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value
        let psi = profiles.poloidalFlux.value

        // Check 1: Finite values (critical - prevents NaN propagation)
        guard isfinite(Ti).all().item(),
              isfinite(Te).all().item(),
              isfinite(ne).all().item(),
              isfinite(psi).all().item() else {
            print("[VALIDATION-FAIL] Non-finite values detected")
            return nil
        }

        // Check 2: Positive temperatures (critical - prevents division by zero)
        guard Ti.min().item() > 0,
              Te.min().item() > 0 else {
            print("[VALIDATION-FAIL] Non-positive temperature detected")
            return nil
        }

        // Check 3: Positive density (critical)
        guard ne.min().item() > 0 else {
            print("[VALIDATION-FAIL] Non-positive density detected")
            return nil
        }

        return ValidatedProfiles(
            ionTemperature: profiles.ionTemperature,
            electronTemperature: profiles.electronTemperature,
            electronDensity: profiles.electronDensity,
            poloidalFlux: profiles.poloidalFlux
        )
    }

    /// Convert back to CoreProfiles (for solver interface compatibility)
    public func toCoreProfiles() -> CoreProfiles {
        return CoreProfiles(
            ionTemperature: ionTemperature,
            electronTemperature: electronTemperature,
            electronDensity: electronDensity,
            poloidalFlux: poloidalFlux
        )
    }
}
```

**Usage Pattern** (Sprint 1):
```swift
public func applyToSources(..., profiles: CoreProfiles, ...) -> SourceTerms {
    // Fail-safe: return unchanged sources if validation fails
    guard let validated = ValidatedProfiles.validateMinimal(profiles) else {
        print("[WARNING-PhysicsModel] Invalid profiles, returning unchanged sources")
        return currentSources
    }

    // Proceed with validated inputs
    let Ti = validated.ionTemperature.value
    // ...
}
```

**Critical Feature**: Optional return (`-> ValidatedProfiles?`) allows graceful degradation.

---

#### Tier 2: Complete ValidatedProfiles (Sprint 3)

**Scope**: Full specification compliance
- ✅ All Tier 1 checks
- ✅ Physical bounds: T ∈ [1 eV, 100 keV], n ∈ [1e17 m⁻³, 1e21 m⁻³]
- ✅ Shape consistency: all arrays same length
- ✅ Detailed error messages with suggestions

```swift
/// Complete validated wrapper for CoreProfiles (Sprint 3)
///
/// All values are guaranteed to be:
/// - Finite (no NaN, no Inf)
/// - Within physical bounds (T ∈ [1, 1e5] eV, n ∈ [1e17, 1e21] m⁻³)
/// - Consistently shaped (all arrays same length)
public struct ValidatedProfiles {
    public let ionTemperature: EvaluatedArray       // [eV], range: [1, 1e5]
    public let electronTemperature: EvaluatedArray  // [eV], range: [1, 1e5]
    public let electronDensity: EvaluatedArray      // [m⁻³], range: [1e17, 1e21]
    public let poloidalFlux: EvaluatedArray         // normalized [0, 1]

    /// Private initializer - only accessible via validate()
    private init(
        ionTemperature: EvaluatedArray,
        electronTemperature: EvaluatedArray,
        electronDensity: EvaluatedArray,
        poloidalFlux: EvaluatedArray
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }

    /// Validate and create ValidatedProfiles from CoreProfiles
    ///
    /// - Parameter profiles: Input profiles to validate
    /// - Returns: Validated profiles with constraints enforced
    /// - Throws: ValidationError if constraints cannot be satisfied
    public static func validate(_ profiles: CoreProfiles) throws -> ValidatedProfiles {
        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value
        let psi = profiles.poloidalFlux.value

        // Check 1: Finite values
        guard isfinite(Ti).all().item() else {
            throw ValidationError.nonFiniteValues(parameter: "ionTemperature",
                                                  min: Ti.min().item(),
                                                  max: Ti.max().item())
        }

        guard isfinite(Te).all().item() else {
            throw ValidationError.nonFiniteValues(parameter: "electronTemperature",
                                                  min: Te.min().item(),
                                                  max: Te.max().item())
        }

        guard isfinite(ne).all().item() else {
            throw ValidationError.nonFiniteValues(parameter: "electronDensity",
                                                  min: ne.min().item(),
                                                  max: ne.max().item())
        }

        guard isfinite(psi).all().item() else {
            throw ValidationError.nonFiniteValues(parameter: "poloidalFlux",
                                                  min: psi.min().item(),
                                                  max: psi.max().item())
        }

        // Check 2: Physical bounds
        let Ti_min = Ti.min().item()
        let Ti_max = Ti.max().item()
        guard Ti_min >= 1.0 && Ti_max <= 1e5 else {
            throw ValidationError.outOfPhysicalRange(
                parameter: "ionTemperature",
                min: Ti_min,
                max: Ti_max,
                expectedRange: (1.0, 1e5)
            )
        }

        let Te_min = Te.min().item()
        let Te_max = Te.max().item()
        guard Te_min >= 1.0 && Te_max <= 1e5 else {
            throw ValidationError.outOfPhysicalRange(
                parameter: "electronTemperature",
                min: Te_min,
                max: Te_max,
                expectedRange: (1.0, 1e5)
            )
        }

        let ne_min = ne.min().item()
        let ne_max = ne.max().item()
        guard ne_min >= 1e17 && ne_max <= 1e21 else {
            throw ValidationError.outOfPhysicalRange(
                parameter: "electronDensity",
                min: ne_min,
                max: ne_max,
                expectedRange: (1e17, 1e21)
            )
        }

        let psi_min = psi.min().item()
        let psi_max = psi.max().item()
        guard psi_min >= 0.0 && psi_max <= 1.0 else {
            throw ValidationError.outOfPhysicalRange(
                parameter: "poloidalFlux",
                min: psi_min,
                max: psi_max,
                expectedRange: (0.0, 1.0)
            )
        }

        // Check 3: Consistent shapes
        let nCells = Ti.shape[0]
        guard Te.shape[0] == nCells,
              ne.shape[0] == nCells,
              psi.shape[0] == nCells else {
            throw ValidationError.inconsistentShapes(
                Ti: Ti.shape,
                Te: Te.shape,
                ne: ne.shape,
                psi: psi.shape
            )
        }

        return ValidatedProfiles(
            ionTemperature: profiles.ionTemperature,
            electronTemperature: profiles.electronTemperature,
            electronDensity: profiles.electronDensity,
            poloidalFlux: profiles.poloidalFlux
        )
    }

    /// Convert back to CoreProfiles (for solver interface compatibility)
    public func toCoreProfiles() -> CoreProfiles {
        return CoreProfiles(
            ionTemperature: ionTemperature,
            electronTemperature: electronTemperature,
            electronDensity: electronDensity,
            poloidalFlux: poloidalFlux
        )
    }
}

/// Validation errors for profiles
public enum ValidationError: Error, LocalizedError {
    case nonFiniteValues(parameter: String, min: Float, max: Float)
    case outOfPhysicalRange(parameter: String, min: Float, max: Float, expectedRange: (Float, Float))
    case inconsistentShapes(Ti: [Int], Te: [Int], ne: [Int], psi: [Int])

    public var errorDescription: String? {
        switch self {
        case .nonFiniteValues(let param, let min, let max):
            return """
            ERROR: Profile validation failed - non-finite values
              Parameter: \(param)
              Min: \(min), Max: \(max)
              Contains NaN or Inf - check upstream calculations
            """
        case .outOfPhysicalRange(let param, let min, let max, let range):
            return """
            ERROR: Profile validation failed - out of physical range
              Parameter: \(param)
              Current: [\(min), \(max)]
              Expected: [\(range.0), \(range.1)]
            """
        case .inconsistentShapes(let Ti, let Te, let ne, let psi):
            return """
            ERROR: Profile validation failed - inconsistent array shapes
              Ti: \(Ti), Te: \(Te), ne: \(ne), psi: \(psi)
              All profiles must have same number of cells
            """
        }
    }
}
```

**Usage in Physics Models**:
```swift
// OLD: Direct usage (no validation)
public func applyToSources(
    _ currentSources: SourceTerms,
    profiles: CoreProfiles,  // ❌ Unchecked
    geometry: Geometry
) -> SourceTerms {
    let Te = profiles.electronTemperature.value  // Could be NaN
    // ...
}

// NEW: Validated wrapper
public func applyToSources(
    _ currentSources: SourceTerms,
    profiles: CoreProfiles,
    geometry: Geometry
) -> SourceTerms {
    // Validate at entry point
    guard let validatedProfiles = try? ValidatedProfiles.validate(profiles) else {
        print("[WARNING-IonElectronExchange] Invalid profiles, returning zero exchange")
        return currentSources  // Fail-safe: no modification
    }

    let Te = validatedProfiles.electronTemperature.value  // ✅ Guaranteed valid
    // ... proceed with calculation
}
```

---

### Phase 1b: Enhanced IonElectronExchange Robustness (Sprint 1)

**Location**: `Sources/GotenxPhysics/Heating/IonElectronExchange.swift:169-218`

**Current State**:
- ❌ No input validation (raw CoreProfiles used directly)
- ❌ No output validation (Q_ie added to SourceTerms unchecked)
- ❌ Crash on NaN: `SourceTerms` precondition fails if Q_ie contains NaN

**Changes** (Sprint 1):
1. Input validation with ValidatedProfiles.validateMinimal()
2. Fail-safe return of currentSources on validation failure
3. Output validation before return (NaN/Inf check)
4. Preserve accumulated metadata in fail-safe path

```swift
/// Ion-electron collisional energy exchange
///
/// Physics: Q_ie = (3 me / mi) * ne * νei * (Te - Ti)
/// where νei = 4√(2π) * e⁴ * ne * ln(Λ) / (3 * (4πε₀)² * me^(1/2) * (kB*Te)^(3/2))
///
/// Edge cases handled:
/// - Te ≈ Ti: Returns small exchange rate (not zero, to maintain smoothness)
/// - Te → 0: Clamps to minimum temperature (1 eV) before calculation
/// - High density: Checks for numerical overflow in collision frequency
public func applyToSources(
    _ currentSources: SourceTerms,
    profiles: CoreProfiles,
    geometry: Geometry
) -> SourceTerms {
    // Step 1: Validate inputs
    guard let validatedProfiles = try? ValidatedProfiles.validate(profiles) else {
        print("[WARNING-IonElectronExchange] Invalid input profiles")
        print("  Ti: min=\(profiles.ionTemperature.value.min().item()), max=\(profiles.ionTemperature.value.max().item())")
        print("  Te: min=\(profiles.electronTemperature.value.min().item()), max=\(profiles.electronTemperature.value.max().item())")
        print("  ne: min=\(profiles.electronDensity.value.min().item()), max=\(profiles.electronDensity.value.max().item())")

        // Fail-safe: return current sources unchanged
        return currentSources
    }

    let Ti = validatedProfiles.ionTemperature.value
    let Te = validatedProfiles.electronTemperature.value
    let ne = validatedProfiles.electronDensity.value

    // Step 2: Apply safety clamps (belt-and-suspenders)
    let Ti_safe = maximum(Ti, MLXArray(1.0))  // Clamp to 1 eV minimum
    let Te_safe = maximum(Te, MLXArray(1.0))
    let ne_safe = maximum(ne, MLXArray(1e17))  // Clamp to 1e17 m⁻³ minimum

    // Step 3: Compute collision frequency
    // νei [s⁻¹] = C * ne / Te^(3/2)
    // where C = 4√(2π) * e⁴ * ln(Λ) / (3 * (4πε₀)² * me^(1/2) * kB^(3/2))
    let lnLambda = coulombLogarithm(ne: ne_safe, Te: Te_safe)

    // Constants
    let elementaryCharge: Float = 1.602e-19  // [C]
    let electronMass: Float = 9.109e-31      // [kg]
    let epsilon0: Float = 8.854e-12          // [F/m]
    let kB: Float = 1.602e-19                // [J/eV] (converts eV to Joules)

    let prefactor = 4.0 * sqrt(2.0 * Float.pi) * pow(elementaryCharge, 4)
                    / (3.0 * pow(4.0 * Float.pi * epsilon0, 2) * sqrt(electronMass))

    let C = prefactor / pow(kB, 1.5)  // [m³·eV^(3/2)/s]

    // νei = C * ne * ln(Λ) / Te^(3/2)
    let Te_eV = Te_safe  // Already in eV
    let nu_ei = C * ne_safe * lnLambda / pow(Te_eV, 1.5)  // [s⁻¹]

    // Check for overflow
    guard isfinite(nu_ei).all().item() else {
        print("[ERROR-IonElectronExchange] Collision frequency contains non-finite values")
        print("  nu_ei: min=\(nu_ei.min().item()), max=\(nu_ei.max().item())")
        return currentSources  // Fail-safe
    }

    // Step 4: Compute exchange power
    // Q_ie = (3 me / mi) * ne * νei * (Te - Ti)  [eV·m⁻³·s⁻¹]
    let ionMass: Float = 2.0 * 1.673e-27  // Deuterium mass [kg]
    let massRatio = (3.0 * electronMass) / ionMass

    let deltaT = Te_safe - Ti_safe  // [eV]
    let Q_ie_eV = massRatio * ne_safe * nu_ei * deltaT  // [eV·m⁻³·s⁻¹]

    // Step 5: Convert to MW/m³
    // [MW/m³] = [eV·m⁻³·s⁻¹] * [J/eV] / [W/MW]
    let Q_ie_MW = Q_ie_eV * elementaryCharge / 1e6  // [MW/m³]

    // Step 6: Validate output
    guard isfinite(Q_ie_MW).all().item() else {
        print("[ERROR-IonElectronExchange] Output contains non-finite values")
        print("  Q_ie: min=\(Q_ie_MW.min().item()), max=\(Q_ie_MW.max().item())")
        return currentSources  // Fail-safe
    }

    // Check for unreasonably large values (likely unit error)
    let Q_max = Q_ie_MW.max().item()
    if Q_max > 1000.0 {  // 1 GW/m³ is unrealistic
        print("[WARNING-IonElectronExchange] Suspiciously large exchange rate: \(Q_max) MW/m³")
        print("  Check if result was computed in eV/(m³·s) instead of MW/m³")
    }

    // Step 7: Apply to sources
    // Ions lose energy: -Q_ie (cooling)
    // Electrons gain energy: +Q_ie (heating)
    let newIonHeating = currentSources.ionHeating - Q_ie_MW
    let newElectronHeating = currentSources.electronHeating + Q_ie_MW

    return SourceTerms(
        ionHeating: newIonHeating,
        electronHeating: newElectronHeating,
        particleSource: currentSources.particleSource,
        currentSource: currentSources.currentSource,
        metadata: currentSources.metadata.merging(
            ["ionElectronExchange_MW_per_m3": Q_ie_MW.mean().item()],
            uniquingKeysWith: { $1 }
        )
    )
}

/// Compute Coulomb logarithm ln(Λ)
///
/// Uses NRL Plasma Formulary approximation:
/// ln(Λ) ≈ 24 - 0.5 * ln(ne [cm⁻³]) + ln(Te [eV])
///
/// Valid for: Te > 10 eV, ne < 1e20 m⁻³
private func coulombLogarithm(ne: MLXArray, Te: MLXArray) -> MLXArray {
    // Convert ne from m⁻³ to cm⁻³
    let ne_cm3 = ne / 1e6

    // NRL formula
    let lnLambda = 24.0 - 0.5 * log(ne_cm3) + log(Te)

    // Physical bounds: ln(Λ) ∈ [5, 25]
    return clip(lnLambda, min: MLXArray(5.0), max: MLXArray(25.0))
}
```

**Key Features**:
- ✅ Input validation with ValidatedProfiles
- ✅ Safety clamps (minimum T = 1 eV, minimum n = 1e17 m⁻³)
- ✅ Overflow checking on collision frequency
- ✅ Output validation before return
- ✅ Unit conversion with explicit documentation
- ✅ Fail-safe fallback (return unchanged sources)

---

### Phase 2: Newton-Raphson NaN Detection (Sprint 2)

**Location**: `Sources/GotenxCore/Solver/NewtonRaphsonSolver.swift:592-624`

**Current State**:
- ❌ Unconstrained line search (no physical bounds enforcement)
- ❌ No NaN/Inf detection (crashes if residualFn returns NaN)
- ❌ No logging of trial failures

**Sprint 2 Changes** (Minimal):
Add NaN/Inf detection only (no constraint projection yet)

```swift
private func lineSearch(
    residualFn: (MLXArray) -> MLXArray,
    x: MLXArray,
    delta: MLXArray,
    residual: MLXArray,
    maxAlpha: Float = 1.0
) -> Float {
    let norm0 = linalg.norm(residual).item()

    let alphas: [Float] = [1.0, 0.5, 0.25, 0.1, 0.01, 0.001]

    for alpha in alphas where alpha <= maxAlpha {
        let xTrial = x + alpha * delta

        // ✅ NEW: Check trial solution is finite
        guard isfinite(xTrial).all().item() else {
            print("[DEBUG-NR-LS] α=\(alpha): xTrial contains NaN/Inf, skipping")
            continue
        }

        let residualTrial = residualFn(xTrial)

        // ✅ NEW: Check residual is finite
        guard isfinite(residualTrial).all().item() else {
            print("[DEBUG-NR-LS] α=\(alpha): residualTrial contains NaN/Inf, skipping")
            continue
        }

        let normTrial = linalg.norm(residualTrial).item()

        if normTrial < norm0 {
            return alpha
        }
    }

    return alphas.last!
}
```

**Rationale**:
- NaN detection prevents crashes (95% of solver failures)
- Constraint projection can wait (negative T still possible, but caught by downstream validation)
- Minimal implementation time (30 minutes vs 4 hours for full projection)

---

### Phase 3: Constrained Line Search (Sprint 3 - OPTIONAL)

**Location**: `Sources/GotenxCore/Solver/NewtonRaphsonSolver.swift`

**Sprint 3 Enhancement**: Add full constraint projection

**Current Implementation** (after Sprint 2):
```swift
private func lineSearch(
    residualFn: (MLXArray) -> MLXArray,
    x: MLXArray,
    delta: MLXArray,
    residual: MLXArray,
    maxAlpha: Float = 1.0
) -> Float {
    let norm0 = linalg.norm(residual).item()

    let alphas: [Float] = [1.0, 0.5, 0.25, 0.1, 0.01]

    for alpha in alphas where alpha <= maxAlpha {
        let xTrial = x + alpha * delta  // ❌ No constraint checking
        let residualTrial = residualFn(xTrial)
        let normTrial = linalg.norm(residualTrial).item()

        if normTrial < norm0 {
            return alpha
        }
    }

    return alphas.last!
}
```

**Enhanced Implementation**:
```swift
/// Line search with physical constraint enforcement
///
/// Ensures trial solutions satisfy:
/// - T > T_min (minimum temperature)
/// - n > n_min (minimum density)
/// - ψ ∈ [0, 1] (normalized flux)
/// - All values finite (no NaN, no Inf)
///
/// If unconstrained trial violates constraints, projects onto feasible region
/// before evaluating residual.
private func lineSearch(
    residualFn: (MLXArray) -> MLXArray,
    x: MLXArray,
    delta: MLXArray,
    residual: MLXArray,
    nCells: Int,
    maxAlpha: Float = 1.0
) -> Float {
    let norm0 = linalg.norm(residual).item()

    print("[DEBUG-NR-LS] Starting line search: norm0=\(norm0)")

    let alphas: [Float] = [1.0, 0.5, 0.25, 0.1, 0.01, 0.001]

    for alpha in alphas where alpha <= maxAlpha {
        // Trial solution (unconstrained)
        let xTrialRaw = x + alpha * delta

        // Project onto physically feasible region
        guard let xTrial = projectOntoFeasibleRegion(xTrialRaw, nCells: nCells) else {
            print("[DEBUG-NR-LS] α=\(alpha): projection failed (extreme violation)")
            continue
        }

        // Check if projection was needed
        let projectionNorm = linalg.norm(xTrial - xTrialRaw).item()
        if projectionNorm > 1e-6 {
            print("[DEBUG-NR-LS] α=\(alpha): projection applied (|Δx|=\(projectionNorm))")
        }

        // Evaluate residual at projected trial solution
        let residualTrial = residualFn(xTrial)

        // Check residual is finite
        guard isfinite(residualTrial).all().item() else {
            print("[DEBUG-NR-LS] α=\(alpha): residual contains NaN/Inf, skipping")
            continue
        }

        let normTrial = linalg.norm(residualTrial).item()
        print("[DEBUG-NR-LS] α=\(alpha): normTrial=\(normTrial) (target < \(norm0))")

        // Armijo condition: sufficient decrease
        if normTrial < norm0 {
            print("[DEBUG-NR-LS] α=\(alpha): ACCEPTED (sufficient decrease)")
            return alpha
        }
    }

    print("[DEBUG-NR-LS] Line search failed, returning smallest α=\(alphas.last!)")
    return alphas.last!
}

/// Project flattened state vector onto physically feasible region
///
/// State vector layout: [Ti[0], ..., Ti[n-1], Te[0], ..., Te[n-1], ne[0], ..., ne[n-1], ψ[0], ..., ψ[n-1]]
///
/// Constraints:
/// - Ti, Te ∈ [T_min, T_max] = [1 eV, 100 keV]
/// - ne ∈ [n_min, n_max] = [1e17 m⁻³, 1e21 m⁻³]
/// - ψ ∈ [0, 1]
///
/// Returns nil if constraints are severely violated (e.g., all negative values)
private func projectOntoFeasibleRegion(_ x: MLXArray, nCells: Int) -> MLXArray? {
    // Extract components
    let Ti = x[0..<nCells]
    let Te = x[nCells..<(2*nCells)]
    let ne = x[(2*nCells)..<(3*nCells)]
    let psi = x[(3*nCells)..<(4*nCells)]

    // Physical bounds
    let T_min: Float = 1.0       // 1 eV
    let T_max: Float = 1e5       // 100 keV
    let n_min: Float = 1e17      // m⁻³
    let n_max: Float = 1e21      // m⁻³
    let psi_min: Float = 0.0
    let psi_max: Float = 1.0

    // Check for severe violations (more than 50% of values out of range)
    let Ti_violations = Float(sum(Ti .< (0.1 * T_min)).item())
    let Te_violations = Float(sum(Te .< (0.1 * T_min)).item())
    if (Ti_violations + Te_violations) / Float(2 * nCells) > 0.5 {
        print("[WARNING-projection] Severe constraint violations: Ti=\(Ti_violations)/\(nCells), Te=\(Te_violations)/\(nCells)")
        return nil
    }

    // Project temperatures
    let Ti_proj = clip(Ti, min: MLXArray(T_min), max: MLXArray(T_max))
    let Te_proj = clip(Te, min: MLXArray(T_min), max: MLXArray(T_max))

    // Project density
    let ne_proj = clip(ne, min: MLXArray(n_min), max: MLXArray(n_max))

    // Project poloidal flux
    let psi_proj = clip(psi, min: MLXArray(psi_min), max: MLXArray(psi_max))

    // Reconstruct state vector
    let x_proj = concatenate([Ti_proj, Te_proj, ne_proj, psi_proj], axis: 0)

    return x_proj
}
```

**Key Features**:
- ✅ Physical constraint enforcement (T > 1 eV, n > 1e17 m⁻³)
- ✅ Projection onto feasible region instead of rejecting trials
- ✅ Finite-value checking before residual evaluation
- ✅ Detailed logging for debugging
- ✅ Severe violation detection (return nil if > 50% out of bounds)

---

### Phase 1a: Initial Profile Validation (Sprint 1)

**Location**: `Sources/GotenxCore/Orchestration/SimulationRunner.swift:225-281`

**Current State**:
- ❌ No Te fallback (if config has `electronTemperature: 0`, creates zero profile)
- ❌ No validation before returning to solver
- ❌ Reproduces "Te: <missing>" crash signature

**Sprint 1 Changes**:

**Solution 1**: Configuration file enforcement (NOT RECOMMENDED)

Ensure all JSON configs specify initial `electronTemperature`:

```json
{
  "runtime": {
    "dynamic": {
      "boundary": {
        "ionTemperature": 5000.0,          // eV
        "electronTemperature": 5000.0,      // ✅ Must be specified
        "density": 2.5e19                   // m⁻³
      }
    }
  }
}
```

**Solution 2**: Auto-fallback in profile initialization (RECOMMENDED - Sprint 1)

```swift
// In CoreProfiles initialization or configuration loader
extension CoreProfiles {
    /// Create initial profiles with validation
    ///
    /// If electronTemperature is not specified, defaults to ionTemperature
    public static func createInitial(
        ionTemperature: MLXArray,
        electronTemperature: MLXArray? = nil,  // Optional with default
        electronDensity: MLXArray,
        poloidalFlux: MLXArray
    ) throws -> CoreProfiles {
        // Default Te = Ti if not specified
        let Te = electronTemperature ?? ionTemperature

        // Validate all inputs
        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: ionTemperature),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: electronDensity),
            poloidalFlux: EvaluatedArray(evaluating: poloidalFlux)
        )

        // Validate before returning
        _ = try ValidatedProfiles.validate(profiles)

        return profiles
    }
}
```

**Solution 3**: Validation before returning (REQUIRED - Sprint 1)

```swift
// In SimulationRunner.createInitialProfiles()
private func createInitialProfiles(...) -> CoreProfiles {
    // ... generate profiles

    // ✅ Validate before returning
    guard let _ = ValidatedProfiles.validateMinimal(profiles) else {
        fatalError("""
        ERROR: Initial profiles validation failed
          Ti: [\(profiles.ionTemperature.value.min().item()), \
               \(profiles.ionTemperature.value.max().item())] eV
          Te: [\(profiles.electronTemperature.value.min().item()), \
               \(profiles.electronTemperature.value.max().item())] eV
          ne: [\(profiles.electronDensity.value.min().item()), \
               \(profiles.electronDensity.value.max().item())] m⁻³

        Check configuration file or profile initialization code.
        This is a fatal error during startup - profiles must be valid.
        """)
    }

    return profiles
}
```

**Rationale**:
- fatalError() is acceptable for startup validation (fail-fast)
- Provides clear diagnostic information
- User can fix configuration and retry

**Solution 4**: Configuration validator check (Sprint 3 - OPTIONAL)

Add to `ConfigurationValidator.swift`:

```swift
/// Validate that all required initial conditions are specified
private static func validateInitialConditions(_ config: SimulationConfiguration) throws {
    let boundary = config.runtime.dynamic.boundary

    // Check all required fields are present and positive
    guard boundary.ionTemperature > 0 else {
        throw ValidationError.invalidInitialCondition(
            parameter: "ionTemperature",
            value: boundary.ionTemperature,
            requirement: "Must be positive (> 0 eV)"
        )
    }

    guard boundary.electronTemperature > 0 else {
        throw ValidationError.invalidInitialCondition(
            parameter: "electronTemperature",
            value: boundary.electronTemperature,
            requirement: "Must be positive (> 0 eV)"
        )
    }

    guard boundary.density > 0 else {
        throw ValidationError.invalidInitialCondition(
            parameter: "density",
            value: boundary.density,
            requirement: "Must be positive (> 0 m⁻³)"
        )
    }

    // Warn if Te and Ti are very different (may indicate unit error)
    let ratio = boundary.electronTemperature / boundary.ionTemperature
    if ratio < 0.1 || ratio > 10.0 {
        print("[WARNING] Large Te/Ti ratio: \(ratio)")
        print("  Te = \(boundary.electronTemperature) eV")
        print("  Ti = \(boundary.ionTemperature) eV")
        print("  Check for unit conversion errors (keV vs eV)")
    }
}
```

---

## Testing Strategy

### Unit Tests

**Test 1: ValidatedProfiles with invalid inputs**
```swift
@Test("ValidatedProfiles rejects NaN")
func testValidatedProfilesRejectsNaN() {
    let nCells = 100
    let Ti = MLXArray.full([nCells], values: MLXArray(1000.0))
    let Te = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ NaN
    let ne = MLXArray.full([nCells], values: MLXArray(2e19))
    let psi = MLXArray.linspace(0.0, 1.0, count: nCells)

    let profiles = CoreProfiles(
        ionTemperature: EvaluatedArray(evaluating: Ti),
        electronTemperature: EvaluatedArray(evaluating: Te),
        electronDensity: EvaluatedArray(evaluating: ne),
        poloidalFlux: EvaluatedArray(evaluating: psi)
    )

    #expect(throws: ValidationError.self) {
        try ValidatedProfiles.validate(profiles)
    }
}

@Test("ValidatedProfiles rejects out-of-range temperature")
func testValidatedProfilesRejectsOutOfRange() {
    let nCells = 100
    let Ti = MLXArray.full([nCells], values: MLXArray(0.1))  // ❌ < 1 eV
    let Te = MLXArray.full([nCells], values: MLXArray(1000.0))
    let ne = MLXArray.full([nCells], values: MLXArray(2e19))
    let psi = MLXArray.linspace(0.0, 1.0, count: nCells)

    let profiles = CoreProfiles(
        ionTemperature: EvaluatedArray(evaluating: Ti),
        electronTemperature: EvaluatedArray(evaluating: Te),
        electronDensity: EvaluatedArray(evaluating: ne),
        poloidalFlux: EvaluatedArray(evaluating: psi)
    )

    #expect(throws: ValidationError.self) {
        try ValidatedProfiles.validate(profiles)
    }
}
```

**Test 2: IonElectronExchange with edge cases**
```swift
@Test("IonElectronExchange handles Ti ≈ Te")
func testIonElectronExchangeSmallDeltaT() throws {
    let nCells = 10
    let Ti = MLXArray.full([nCells], values: MLXArray(1000.0))
    let Te = MLXArray.full([nCells], values: MLXArray(1000.1))  // ΔT = 0.1 eV
    let ne = MLXArray.full([nCells], values: MLXArray(2e19))
    let psi = MLXArray.linspace(0.0, 1.0, count: nCells)

    let profiles = CoreProfiles(
        ionTemperature: EvaluatedArray(evaluating: Ti),
        electronTemperature: EvaluatedArray(evaluating: Te),
        electronDensity: EvaluatedArray(evaluating: ne),
        poloidalFlux: EvaluatedArray(evaluating: psi)
    )

    let geometry = try createTestGeometry(nCells: nCells)
    let exchange = IonElectronExchange()

    let emptySource = SourceTerms(
        ionHeating: MLXArray.zeros([nCells]),
        electronHeating: MLXArray.zeros([nCells]),
        particleSource: MLXArray.zeros([nCells]),
        currentSource: MLXArray.zeros([nCells]),
        metadata: [:]
    )

    let result = exchange.applyToSources(emptySource, profiles: profiles, geometry: geometry)

    // Should return small but finite exchange rate
    let Q_ie = result.ionHeating
    #expect(isfinite(Q_ie).all().item())
    #expect(abs(Q_ie.mean().item()) < 1.0)  // Small exchange for small ΔT
}

@Test("IonElectronExchange with invalid profiles returns fallback")
func testIonElectronExchangeInvalidInput() throws {
    let nCells = 10
    let Ti = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ Invalid
    let Te = MLXArray.full([nCells], values: MLXArray(1000.0))
    let ne = MLXArray.full([nCells], values: MLXArray(2e19))
    let psi = MLXArray.linspace(0.0, 1.0, count: nCells)

    let profiles = CoreProfiles(
        ionTemperature: EvaluatedArray(evaluating: Ti),
        electronTemperature: EvaluatedArray(evaluating: Te),
        electronDensity: EvaluatedArray(evaluating: ne),
        poloidalFlux: EvaluatedArray(evaluating: psi)
    )

    let geometry = try createTestGeometry(nCells: nCells)
    let exchange = IonElectronExchange()

    let emptySource = SourceTerms(
        ionHeating: MLXArray.zeros([nCells]),
        electronHeating: MLXArray.zeros([nCells]),
        particleSource: MLXArray.zeros([nCells]),
        currentSource: MLXArray.zeros([nCells]),
        metadata: [:]
    )

    let result = exchange.applyToSources(emptySource, profiles: profiles, geometry: geometry)

    // Should return fallback (unchanged sources)
    #expect(result.ionHeating.sum().item() == 0.0)
    #expect(result.electronHeating.sum().item() == 0.0)
}
```

**Test 3: Line search with constrained projection**
```swift
@Test("Line search projects negative temperatures")
func testLineSearchProjection() {
    let nCells = 10
    let solver = NewtonRaphsonSolver()

    // Create state with valid values
    let Ti = MLXArray.full([nCells], values: MLXArray(1000.0))
    let Te = MLXArray.full([nCells], values: MLXArray(1000.0))
    let ne = MLXArray.full([nCells], values: MLXArray(2e19))
    let psi = MLXArray.linspace(0.0, 1.0, count: nCells)
    let x = concatenate([Ti, Te, ne, psi], axis: 0)

    // Create delta that would produce negative temperatures
    let delta_Ti = MLXArray.full([nCells], values: MLXArray(-2000.0))  // Would give Ti = -1000
    let delta_Te = MLXArray.full([nCells], values: MLXArray(-500.0))
    let delta_ne = MLXArray.zeros([nCells])
    let delta_psi = MLXArray.zeros([nCells])
    let delta = concatenate([delta_Ti, delta_Te, delta_ne, delta_psi], axis: 0)

    // Mock residual function (returns norm of x)
    let residualFn = { (x: MLXArray) -> MLXArray in
        return x - MLXArray.ones(like: x)
    }
    let residual = residualFn(x)

    // Line search should project onto feasible region
    let alpha = solver.lineSearch(
        residualFn: residualFn,
        x: x,
        delta: delta,
        residual: residual,
        nCells: nCells
    )

    let xTrial = x + alpha * delta
    let xTrialProjected = solver.projectOntoFeasibleRegion(xTrial, nCells: nCells)

    // Check projection enforced minimum temperature
    let Ti_trial = xTrialProjected![0..<nCells]
    let Te_trial = xTrialProjected![(nCells)..<(2*nCells)]

    #expect(Ti_trial.min().item() >= 1.0)  // T_min = 1 eV
    #expect(Te_trial.min().item() >= 1.0)
}
```

### Integration Tests

**Test 4: Full simulation with initial NaN protection**
```swift
@Test("Simulation detects uninitialized electron temperature")
func testSimulationDetectsUninitializedTe() async throws {
    // Create configuration with missing Te (set to 0)
    let config = SimulationConfiguration(
        runtime: RuntimeConfiguration(
            static: ...,
            dynamic: DynamicConfiguration(
                boundary: BoundaryConfig(
                    ionTemperature: 1000.0,
                    electronTemperature: 0.0,  // ❌ Uninitialized
                    density: 2e19
                ),
                // ...
            )
        ),
        time: ...,
        output: ...
    )

    // Should throw during validation or initialization
    #expect(throws: ValidationError.self) {
        try ConfigurationValidator.validate(config)
    }
}

@Test("Simulation runs with valid initial conditions")
func testSimulationWithValidInitialConditions() async throws {
    let config = SimulationConfiguration(
        runtime: RuntimeConfiguration(
            static: ...,
            dynamic: DynamicConfiguration(
                boundary: BoundaryConfig(
                    ionTemperature: 1000.0,
                    electronTemperature: 1000.0,  // ✅ Valid
                    density: 2e19
                ),
                // ...
            )
        ),
        time: TimeConfiguration(
            start: 0.0,
            end: 0.01,  // Short simulation
            initialDt: 1e-4
        ),
        output: ...
    )

    let runner = try await SimulationRunner(config: config)

    // Should complete without crashes
    try await runner.run { progress in
        // Monitor progress
    }
}
```

---

## Implementation Plan (Revised)

### Implementation Dependencies

```
Phase 0 (Foundation)
    ↓
Sprint 1 (Crash Prevention) ← CRITICAL PATH
    ↓
Sprint 2 (Robustness) ← Recommended
    ↓
Sprint 3 (Optimization) ← Optional
```

---

### Sprint 1: Crash Prevention (REQUIRED)

**Timeline**: 1-2 days (10 hours)
**Priority**: 🔥 P0-P1 (Critical, blocks all development)
**Goal**: Eliminate original crash (NaN in IonElectronExchange)

#### Phase 0: ValidatedProfiles Foundation

| Task | File | Effort | Priority | Blocker |
|------|------|--------|----------|---------|
| Implement minimal ValidatedProfiles | `Sources/GotenxCore/Core/ValidatedProfiles.swift` (new) | 3h | P0 | None |
| Add finite/positive validation only | Same | Included | P0 | None |
| Unit tests for ValidatedProfiles | `Tests/GotenxTests/Core/ValidatedProfilesTests.swift` (new) | 1h | P0 | Phase 0 |

**Minimal Implementation**:
```swift
// Checks only: isfinite() && T > 0
public struct ValidatedProfiles {
    public static func validateMinimal(_ profiles: CoreProfiles) -> ValidatedProfiles? {
        // Critical checks only (no bounds, no shapes)
        guard isfinite(Ti).all().item(), Ti.min().item() > 0,
              isfinite(Te).all().item(), Te.min().item() > 0 else {
            return nil
        }
        return ValidatedProfiles(...)
    }
}
```

**Rationale**: Full validation (bounds, shapes) can wait; NaN/Inf/negative are the crash culprits.

#### Phase 1a: Initial Profile Validation

| Task | File | Effort | Priority | Blocker |
|------|------|--------|----------|---------|
| Add Te fallback (Te = Ti if missing) | `Sources/GotenxCore/Orchestration/SimulationRunner.swift:225-281` | 1h | P1 | Phase 0 |
| Add validateMinimal() check | Same | 1h | P1 | Phase 0 |
| Integration test (missing Te) | `Tests/GotenxTests/Integration/` | 1h | P1 | Phase 1a |

**Critical Decision**: Auto-fallback Te = Ti (physically sound) instead of throwing error.

#### Phase 1b: IonElectronExchange Guards

| Task | File | Effort | Priority | Blocker |
|------|------|--------|----------|---------|
| Add ValidatedProfiles check | `Sources/GotenxPhysics/Heating/IonElectronExchange.swift:169-218` | 2h | P1 | Phase 0 |
| Add output validation | Same | 1h | P1 | Phase 0 |
| Return currentSources on fail | Same | Included | P1 | None |
| Unit test (crash reproduction) | `Tests/GotenxTests/Physics/IonElectronExchangeTests.swift` | 1h | P1 | Phase 1b |

**Key Feature**: Fail-safe returns `currentSources` unchanged (preserves metadata).

**Sprint 1 Total**: 10 hours

**Success Criteria**:
- ✅ Original crash (NaN in IonElectronExchange.swift:208) cannot be reproduced
- ✅ Missing Te auto-fills with Ti (no startup crash)
- ✅ Unit test `testOriginalCrashScenario()` passes
- ✅ Integration test with zero Te config starts successfully

---

### Sprint 2: Robustness Enhancement (RECOMMENDED)

**Timeline**: 1 day (7.5 hours)
**Priority**: ⚠️ P2 (High, improves reliability)
**Goal**: Extend guards to all physics models and add solver NaN detection

| Task | File | Effort | Priority | Blocker |
|------|------|--------|----------|---------|
| Newton-Raphson NaN detection | `Sources/GotenxCore/Solver/NewtonRaphsonSolver.swift:592-624` | 0.5h | P2 | None |
| Add guards to other sources | `Sources/GotenxPhysics/Sources/` | 2h | P2 | Sprint 1 |
| Add guards to transport models | `Sources/GotenxPhysics/Transport/` | 2h | P2 | Sprint 1 |
| Integration tests (100 steps) | `Tests/GotenxTests/Integration/` | 3h | P2 | Sprint 2 |

**Minimal Newton-Raphson Enhancement**:
```swift
// Line search: Add NaN/Inf detection only (no constraint projection)
guard isfinite(xTrial).all().item() else { continue }
guard isfinite(residualTrial).all().item() else { continue }
```

**Rationale**: NaN detection prevents crashes; constraint projection (negative T) can wait for Sprint 3.

**Sprint 2 Total**: 7.5 hours

**Success Criteria**:
- ✅ All physics models protected (OhmicHeating, ECRH, Bremsstrahlung, etc.)
- ✅ Newton-Raphson skips NaN trials (no crash on solver failure)
- ✅ 100-timestep simulation completes without crashes

---

### Sprint 3: Complete Implementation (OPTIONAL)

**Timeline**: 2 days (13 hours)
**Priority**: 📋 P3 (Medium, optimization/polish)
**Goal**: Full design spec compliance, constraint projection, bounds checking

| Task | File | Effort | Priority | Blocker |
|------|------|--------|----------|---------|
| Upgrade to full ValidatedProfiles | `Sources/GotenxCore/Core/ValidatedProfiles.swift` | 3h | P3 | Sprint 1 |
| Constrained line search + projection | `Sources/GotenxCore/Solver/NewtonRaphsonSolver.swift` | 4h | P3 | Sprint 2 |
| Adapter layer metadata preservation | `Sources/GotenxPhysics/SourceModelAdapters.swift:149-172` | 2h | P3 | Sprint 2 |
| Comprehensive unit tests | `Tests/GotenxTests/` | 4h | P3 | Sprint 3 |

**Full ValidatedProfiles**:
- Add bounds checking: T ∈ [1 eV, 100 keV], n ∈ [1e17, 1e21 m⁻³]
- Add shape consistency validation
- Add detailed error messages

**Constrained Line Search**:
- Project trial solutions onto feasible region
- Adaptive logging for debugging
- Severe violation detection (> 50% out of bounds)

**Sprint 3 Total**: 13 hours

**Success Criteria**:
- ✅ Full design specification implemented
- ✅ No out-of-bounds temperatures in solver (projection active)
- ✅ Metadata preserved across all failure modes
- ✅ Performance overhead < 5%

---

### Sprint Decision Matrix

| Sprint | Time | Crash Fix | Robustness | Optimization | Recommended |
|--------|------|-----------|------------|--------------|-------------|
| 1 | 10h | ✅ 95% | ⚠️ 60% | ❌ 0% | **YES** (Required) |
| 1+2 | 17.5h | ✅ 99% | ✅ 95% | ⚠️ 30% | **YES** (Strongly) |
| 1+2+3 | 30.5h | ✅ 99.9% | ✅ 99% | ✅ 100% | MAYBE (After testing) |

**Recommendation**:
- **DO Sprint 1 immediately** (blocks all development)
- **DO Sprint 2 after validation** (high ROI for 7.5h)
- **EVALUATE Sprint 3 after performance tests** (diminishing returns)

---

## Success Criteria (Revised)

### Sprint 1 Completion (REQUIRED)
**Target**: Eliminate original crash, make simulation startable

- ✅ No crashes on `IonElectronExchange.swift:208` (NaN detection active)
- ✅ Missing Te auto-fills with Ti (no startup crash)
- ✅ All initial profiles validated before solver start
- ✅ Unit test `testOriginalCrashScenario()` passes (NaN Te → fallback)
- ✅ Integration test with zero Te config starts successfully
- ✅ Clear error messages for invalid initial conditions

**Acceptance Test**:
```bash
# Original crash config (Te = 0)
swift test --filter testOriginalCrashScenario  # Should pass
.build/debug/GotenxCLI run --config crash_config.json  # Should start (not crash)
```

### Sprint 2 Completion (RECOMMENDED)
**Target**: Extend robustness to all physics models and solver

- ✅ All source models protected (OhmicHeating, ECRH, Bremsstrahlung, IonElectronExchange)
- ✅ All transport models protected (Constant, BohmGyroBohm, QLKNN)
- ✅ Newton-Raphson skips NaN trials (no crash on inf residual)
- ✅ 100-timestep simulation completes without crashes
- ✅ Integration tests pass for all model combinations

**Acceptance Test**:
```bash
swift test --filter RobustnessIntegrationTests  # All pass
.build/debug/GotenxCLI run --config iter_like.json --end 0.1  # Completes 100 steps
```

### Sprint 3 Completion (OPTIONAL)
**Target**: Full specification compliance, optimization

- ✅ Full ValidatedProfiles with bounds checking
- ✅ Constrained line search with projection active
- ✅ Line search never produces out-of-bounds temperatures
- ✅ Metadata preserved across all failure modes
- ✅ Performance overhead < 5% (validation cost)
- ✅ Comprehensive unit tests for edge cases

**Acceptance Test**:
```bash
swift test --filter NumericalRobustnessTests  # All edge cases covered
# Performance regression test
time .build/release/GotenxCLI run --config benchmark.json  # < 5% slowdown
```

---

## Decision Points

### After Sprint 1
**Question**: Is the crash fully resolved?

**Test**:
1. Run original crash scenario (NaN Te config)
2. Run 10-step simulation with all source models enabled
3. Check logs for validation failures

**If YES**: Proceed to Sprint 2
**If NO**: Debug and fix Sprint 1 implementation before proceeding

### After Sprint 2
**Question**: Are 100-timestep simulations stable?

**Test**:
1. Run ITER-like config for 100 timesteps
2. Monitor for NaN/Inf in logs
3. Check conservation laws

**If YES**: Evaluate Sprint 3 (ROI analysis)
**If NO**: Identify root cause (may need Sprint 3 constraint projection)

### Sprint 3 ROI Analysis
**Question**: Does constraint projection improve results?

**Metrics**:
- Convergence rate improvement (iterations per timestep)
- Timestep size increase (dt can be larger if more stable)
- Simulation accuracy (compare with/without projection)

**If ROI > 50%**: Implement Sprint 3
**If ROI < 50%**: Defer to future optimization phase

---

## References

### Internal Documents
- [docs/NUMERICAL_PRECISION.md](NUMERICAL_PRECISION.md) - Float32 constraints and stability
- [docs/MLX_BEST_PRACTICES.md](MLX_BEST_PRACTICES.md) - MLX evaluation patterns
- [docs/CONFIGURATION_VALIDATION_SPEC.md](CONFIGURATION_VALIDATION_SPEC.md) - Pre-simulation validation

### External References
- **Newton-Raphson with Constraints**: Nocedal & Wright, "Numerical Optimization" (2006), Chapter 18
- **Projection Methods**: Boyd & Vandenberghe, "Convex Optimization" (2004), Chapter 8
- **Collision Frequency**: NRL Plasma Formulary (2019), Section 4
- **Line Search Algorithms**: Dennis & Schnabel, "Numerical Methods for Unconstrained Optimization" (1996)

---

## Risk Mitigation

### Risk 1: Sprint 1 Implementation Introduces New Crashes
**Probability**: Medium
**Impact**: High (blocks development)

**Mitigation**:
- Implement incrementally (Phase 0 → 1a → 1b)
- Merge after each phase with unit tests
- Feature flag for validation (can disable if issues)

### Risk 2: Performance Overhead > 5%
**Probability**: Low (validation is cheap)
**Impact**: Medium

**Mitigation**:
- Profile before/after Sprint 1
- Optimize hot paths if needed (cache validation results)
- Sprint 3 optional if performance unacceptable

### Risk 3: Fail-Safe Masks Physics Bugs
**Probability**: Medium
**Impact**: Medium (silent errors)

**Mitigation**:
- Always log validation failures (never silent)
- Add metric tracking (count of fallback invocations)
- Alert if fallback rate > 1% of timesteps

### Risk 4: Te = Ti Fallback Physically Incorrect
**Probability**: Low (Te ≈ Ti is common)
**Impact**: Low

**Mitigation**:
- Log fallback with warning
- User can override in configuration
- Only used for missing Te, not invalid Te

---

## Changelog

### Version 1.1 (2025-10-25)
- Added implementation gap analysis from code review
- Defined Sprint 1-3 phased implementation with dependencies
- Added minimal vs complete implementation tradeoffs
- Updated success criteria with sprint-specific goals
- Added decision points for sprint continuation
- Added risk mitigation strategies

### Version 1.0 (2025-10-25)
- Initial design document
- Identified root causes of NaN propagation
- Proposed ValidatedProfiles architecture
- Specified constrained line search implementation
- Defined testing strategy

---

## Quick Start Guide

### For Implementers

**Step 1**: Read "Implementation Plan (Revised)" section
**Step 2**: Start with Sprint 1, Phase 0 (ValidatedProfiles minimal)
**Step 3**: Proceed sequentially (0 → 1a → 1b)
**Step 4**: Run acceptance tests after Sprint 1
**Step 5**: Evaluate Sprint 2 continuation

### For Reviewers

**Check**: Implementation follows Sprint 1 minimal spec (not Sprint 3 complete)
**Check**: Fail-safe returns currentSources (not zeros)
**Check**: All validation failures are logged
**Check**: Unit tests cover crash reproduction scenario

---

**Document Status**: Implementation Ready (Sprint 1 spec finalized)
**Next Steps**:
1. Implement Sprint 1 (10 hours)
2. Run acceptance tests
3. Evaluate Sprint 2 (if tests pass)
