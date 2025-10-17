# TORAXPhysics Implementation Review

**Date**: 2025-10-17
**Reviewer**: Claude Code
**Status**: Phase 1 Complete - Issues Identified

---

## Executive Summary

Phase 1 physics models implementation is **COMPLETE** and builds successfully. However, there are **3 CRITICAL issues**, **5 HIGH priority issues**, and **4 MEDIUM priority issues** that need to be addressed before production use.

**Overall Assessment**: ⚠️ **Implementation is logically sound but needs refinement**

---

## Model-by-Model Analysis

### 1. IonElectronExchange ✅ GOOD

**File**: `Sources/TORAXPhysics/Heating/IonElectronExchange.swift`

#### ✅ Strengths

1. **Physics correctness**: Formula is correct
   ```
   Q_ie = (3/2) * (m_e/m_i) * n_e * ν_ei * k_B * (T_e - T_i)
   ```

2. **Energy conservation**: Perfect
   - Adds Q_ie to ion heating
   - Subtracts Q_ie from electron heating
   - Q_ion + Q_electron = 0 ✓

3. **Unit consistency**: Correct throughout
   - Input: n_e [m⁻³], T_e [eV], T_i [eV]
   - Output: Q_ie [W/m³]

4. **Sign convention**: Correct
   - Positive Q_ie = heating ions (when Te > Ti)
   - Negative Q_ie = heating electrons (when Ti > Te)

#### ⚠️ Issues

**MEDIUM #1: Coulomb Logarithm Edge Cases**
- **Location**: Line 61
- **Issue**: `ln(Λ) = 24 - ln(√(n_e/10⁶) / T_e)` can become negative for extreme conditions
- **When**: Very high density (n_e > 1e26) or very low temperature (T_e < 10 eV)
- **Impact**: Unphysical collision frequencies
- **Fix**: Add bounds checking
  ```swift
  let lnLambda = max(5.0, 24.0 - log(sqrt(ne / 1e6) / Te))
  ```

**MEDIUM #2: Temperature Validity**
- **Issue**: No check for T_e, T_i > 0
- **Impact**: sqrt(Te) or pow(Te, 1.5) with negative values
- **Fix**: Add validation in compute()

#### 📊 Test Coverage

- ✅ Equilibration test
- ✅ Density scaling test
- ✅ Temperature scaling test
- ✅ Energy conservation test
- ✅ Zero exchange test

---

### 2. FusionPower ⚠️ NEEDS REFINEMENT

**File**: `Sources/TORAXPhysics/Heating/FusionPower.swift`

#### ✅ Strengths

1. **Bosch-Hale parameterization**: Correctly implemented
2. **Unit consistency**: Correct
3. **Peak reactivity**: Correctly peaks near 70 keV

#### ⚠️ Issues

**HIGH #1: Fuel Density Assumption**
- **Location**: Lines 93-96
- **Issue**: Equal D-T assumption `n_D = n_T = n_e/2` is oversimplified
- **Problem**:
  ```swift
  // Current (WRONG for realistic plasmas):
  nD = ne / 2.0  // Assumes no impurities!
  nT = ne / 2.0
  ```
- **Reality**: Plasmas have impurities (C, O, Fe, etc.)
  - Quasi-neutrality: `n_e = n_D + n_T + Σ(Z_i * n_i)`
  - For Z_eff = 1.5: significant impurity content
- **Impact**: Overestimates fusion power by ~30-50%
- **Fix**:
  ```swift
  // Account for impurities:
  // n_e = n_D + n_T + n_imp * Z_imp
  // For equal D-T with Z_eff:
  nD = ne / (2.0 * Zeff)
  nT = ne / (2.0 * Zeff)
  ```

**HIGH #2: Alpha Energy Deposition Split**
- **Location**: Lines 207-208
- **Issue**: Fixed 20-80 split is simplistic
- **Problem**: Alpha slowing-down depends on:
  - Electron temperature
  - Ion temperature
  - Density
  - Z_eff
- **Current**:
  ```swift
  let P_ion = P_fusion * 0.2  // Too simple!
  let P_electron = P_fusion * 0.8
  ```
- **Reality**: At low T_e (<10 keV), ions get more; at high T_e (>20 keV), electrons get more
- **Impact**: Incorrect power balance in different regimes
- **Fix**: Implement proper alpha slowing-down model (can defer to Phase 2)

**MEDIUM #3: Reactivity Formula Edge Cases**
- **Location**: Line 118
- **Issue**: No bounds on theta calculation
- **Problem**: `theta = T / (1.0 - numerator/denominator)` can diverge
- **Fix**: Add saturation for T > 1000 keV

#### 📊 Test Coverage

- ✅ Peak reactivity test
- ✅ Density scaling test
- ✅ Low temperature test
- ✅ Fuel mixture test

---

### 3. Bremsstrahlung ✅ EXCELLENT

**File**: `Sources/TORAXPhysics/Radiation/Bremsstrahlung.swift`

#### ✅ Strengths

1. **Classical formula**: Perfect
   ```
   P_brems = -C * n_e² * Z_eff * √T_e
   ```

2. **Relativistic correction**: Correct implementation
   - Only applies for T_e > 1 keV
   - Formula matches Wesson textbook

3. **Sign convention**: Correct
   - Always negative (energy loss)

4. **Edge case handling**: Good
   - Mask for relativistic correction
   - Element-wise comparison using `.>`

5. **Diagnostic functions**: Excellent
   - Total power integration
   - Radiation fraction computation

#### ⚠️ Issues

**LOW #1: Mask Efficiency**
- **Location**: Line 57
- **Issue**: `mask = Te .> 1000.0` creates boolean array, then multiplies
- **Minor optimization**: Could use `where(condition, true_value, false_value)`
- **Impact**: Negligible (this is fine as-is)

---

### 4. OhmicHeating 🔴 CRITICAL ISSUES

**File**: `Sources/TORAXPhysics/Heating/OhmicHeating.swift`

#### ✅ Strengths

1. **Spitzer resistivity**: Correct formula
2. **Neoclassical correction**: Reasonable trapped particle factor
3. **Unit consistency**: Correct

#### 🔴 Critical Issues

**CRITICAL #1: Parallel Current is Always Zero**
- **Location**: Lines 177-185
- **Issue**: `computeParallelCurrent()` returns zeros!
- **Code**:
  ```swift
  private func computeParallelCurrent(...) -> MLXArray {
      // Placeholder: Return zeros
      let nCells = profiles.electronTemperature.value.shape[0]
      return MLXArray.zeros([nCells])  // ⚠️ ALWAYS ZERO!
  }
  ```
- **Impact**: **Ohmic heating is ALWAYS ZERO** - this breaks power balance!
- **Why critical**: Ohmic heating is essential for startup scenarios
- **Fix Required**: Implement proper j_parallel computation from poloidal flux
  ```swift
  // Need to implement:
  // j_∥ = (1/μ₀) * (1/R) * ∂ψ/∂r * ...
  ```

**HIGH #3: Missing Ohm's Law Integration**
- **Issue**: Should compute current from E-field or vice versa
- **Current**: Assumes j_parallel is known (but it's not!)
- **Fix**: Needs integration with poloidal flux equation solver

#### 📊 Status

- ⚠️ **Model exists but is non-functional**
- ⚠️ **Must be fixed before any realistic simulations**

---

### 5. SauterBootstrapModel ⚠️ NEEDS WORK

**File**: `Sources/TORAXPhysics/Neoclassical/SauterBootstrapModel.swift`

#### ✅ Strengths

1. **Sauter formulas**: Correct F31, F32_eff, F32_ee functions
2. **Trapped fraction**: Correct formula
3. **Collisionality**: Correct formula
4. **Gradient computation**: Works (central differences)

#### ⚠️ Issues

**HIGH #4: Simplified Conductivity Factor**
- **Location**: Lines 218-230
- **Issue**: Highly simplified and has **arbitrary normalization**
- **Code**:
  ```swift
  let sigma = ne * pow(Te, 1.5) / (B * B + 1e-10)
  let normalization: Float = 1e-3  // ⚠️ ARBITRARY!
  return sigma * normalization
  ```
- **Problem**: This normalization factor (1e-3) is NOT physics-based
- **Impact**: Bootstrap current magnitude is uncertain by orders of magnitude
- **Fix**: Use proper Spitzer conductivity with geometric factors

**HIGH #5: Unused Variable Warning**
- **Location**: Line 56
- **Issue**: `Ti` is loaded but never used
- **Code**:
  ```swift
  let Ti = profiles.ionTemperature.value  // ⚠️ Unused!
  ```
- **Problem**: Sauter model should depend on T_i/T_e ratio
- **Impact**: Missing physics
- **Fix**: Include ion temperature effects in L-coefficients

**MEDIUM #4: Gradient Computation**
- **Location**: Lines 170-203
- **Issue**: Uses simple central differences
- **Problem**: Less accurate than solver's FVM gradients
- **Fix**: Should use same gradient method as core solver

**MEDIUM #5: GeometricFactors Recreation**
- **Location**: Line 59, 176, 286
- **Issue**: Calls `GeometricFactors.from(geometry:)` multiple times
- **Problem**: Recreates same data repeatedly (inefficient)
- **Fix**: Pass GeometricFactors as parameter or cache it

#### 📊 Status

- ⚠️ **Model works but magnitudes are uncertain**
- ⚠️ **Needs calibration against known bootstrap current data**

---

## Cross-Model Issues

### CRITICAL #2: Unit Inconsistency in SourceTerms

**Location**: `Sources/TORAX/Core/SourceTerms.swift` (lines 8-18)

**Problem**: Source terms documented as:
```swift
/// Ion heating [MW/m^3]      // ⚠️ MEGAWATTS!
/// Electron heating [MW/m^3] // ⚠️ MEGAWATTS!
```

But physics models return:
```swift
// All models return [W/m³]  // ⚠️ WATTS!
```

**Impact**: **Physics models are off by factor of 1,000,000!**

**Evidence**:
1. IonElectronExchange line 72: Returns `[W/m³]`
2. FusionPower line 98: Returns `[W/m³]`
3. Bremsstrahlung line 65: Returns `[W/m³]`

**Fix Options**:

**Option A: Convert physics models to MW/m³** (Recommended)
```swift
// In each model's compute():
let Q_ie_MW = Q_ie / 1e6  // Convert W/m³ → MW/m³
return Q_ie_MW
```

**Option B: Convert when applying to sources**
```swift
// In applyToSources():
return SourceTerms(
    ionHeating: EvaluatedArray(
        evaluating: sources.ionHeating.value + Q_ie / 1e6  // W→MW
    ),
    ...
)
```

**Recommendation**: Choose Option A for consistency

### CRITICAL #3: No Input Validation

**Problem**: None of the models validate inputs

**Examples**:
- No check for T_e, T_i > 0
- No check for n_e > 0
- No check for finite values
- No check for array shape consistency

**Impact**: Silent failures or NaN propagation

**Fix**: Add validation helper
```swift
private func validate(ne: MLXArray, Te: MLXArray, Ti: MLXArray) throws {
    guard (Te .> 0.0).all().item(Bool.self) else {
        throw PhysicsError.invalidTemperature("Te must be positive")
    }
    // ... more checks
}
```

---

## Summary of Issues

### 🔴 Critical (Must Fix)

| ID | Issue | Model | Impact |
|----|-------|-------|--------|
| C1 | j_parallel always zero | OhmicHeating | Ohmic heating non-functional |
| C2 | Unit mismatch (W vs MW) | All models | Off by 10⁶ factor! |
| C3 | No input validation | All models | Silent failures |

### 🟠 High Priority (Should Fix)

| ID | Issue | Model | Impact |
|----|-------|-------|--------|
| H1 | Fuel density assumption | FusionPower | 30-50% error |
| H2 | Alpha deposition split | FusionPower | Wrong power balance |
| H3 | Missing Ohm's law | OhmicHeating | Incomplete model |
| H4 | Arbitrary normalization | SauterBootstrap | Uncertain magnitudes |
| H5 | Unused Ti variable | SauterBootstrap | Missing physics |

### 🟡 Medium Priority (Nice to Have)

| ID | Issue | Model | Impact |
|----|-------|-------|--------|
| M1 | Coulomb log bounds | IonElectronExchange | Edge case failures |
| M2 | Temperature validation | IonElectronExchange | Robustness |
| M3 | Reactivity bounds | FusionPower | Edge case stability |
| M4 | Gradient method | SauterBootstrap | Accuracy |
| M5 | GeometricFactors caching | SauterBootstrap | Performance |

---

## Recommendations

### Immediate Actions (Before Next Phase)

1. **Fix CRITICAL #2 (Unit Mismatch)**
   - Decide on W/m³ vs MW/m³
   - Update all models consistently
   - Update documentation

2. **Fix CRITICAL #1 (Ohmic Heating)**
   - Implement j_parallel computation
   - OR document that Ohmic heating is placeholder
   - OR remove applyToSources() until implemented

3. **Fix CRITICAL #3 (Input Validation)**
   - Add PhysicsError enum
   - Add validation to all compute() methods

### Phase 2 Priorities

1. **Refine FusionPower**
   - Implement proper fuel density with Z_eff
   - Add alpha slowing-down model

2. **Complete OhmicHeating**
   - Integrate with poloidal flux solver
   - Implement Ohm's law coupling

3. **Calibrate SauterBootstrap**
   - Replace arbitrary normalization
   - Add Ti/Te ratio effects
   - Validate against experimental data

### Testing Strategy

1. **Unit tests**: Already good coverage ✓
2. **Integration tests**: Need to add
3. **Physics validation**: Compare with Python TORAX
4. **Benchmark cases**: ITER, JET, DIII-D scenarios

---

## Positive Highlights 🎉

1. **Architecture**: Clean separation of physics models ✓
2. **Documentation**: Excellent inline documentation ✓
3. **Type Safety**: Full Swift 6 concurrency compliance ✓
4. **Test Coverage**: Comprehensive unit tests ✓
5. **Bremsstrahlung**: Perfect implementation ✓
6. **IonElectronExchange**: Nearly perfect (minor edge cases only) ✓

---

## Final Verdict

**Current Status**: ⚠️ **70% Complete**

**Blockers for Production**:
1. Fix unit mismatch (W vs MW)
2. Fix or document Ohmic heating placeholder
3. Add input validation

**Timeline Estimate**:
- Fix critical issues: 1-2 days
- Fix high priority issues: 3-5 days
- Complete Phase 2 (QLKNN, etc.): 2-3 weeks

**Conclusion**: The implementation is **structurally sound** and demonstrates **good understanding of plasma physics**. The identified issues are fixable and mostly relate to **edge cases** and **coupling with the core solver**, not fundamental physics errors.

---

**Next Steps**: Implement fixes for CRITICAL issues, then proceed with integration testing.
