# Phase 9: Turbulence Transition Implementation Design

**Date**: 2025-10-23
**Status**: 📋 Design Phase
**Reference**: PhysRevLett.132.235101 (2024)

---

## 🎯 Objective

Implement density-dependent turbulence transition from **ITG** (Ion-Temperature Gradient) to **RI** (Resistive-Interchange) regimes, as discovered in the 2024 LHD experiments.

### Key Paper Findings

**Paper**: "Turbulence Transition in Magnetically Confined Hydrogen and Deuterium Plasmas"
- **Authors**: T. Kinoshita et al. (Kyushu Univ., NIFS, Kyoto Univ.)
- **Published**: Phys. Rev. Lett. 132, 235101 (June 7, 2024)
- **DOI**: 10.1103/PhysRevLett.132.235101

**Discovery**:
1. Turbulence **minimized** at transition density `n_trans`
2. **Below `n_trans`**: ITG turbulence (ion temperature gradient driven)
3. **Above `n_trans`**: RI turbulence (pressure gradient + resistivity driven)
4. **Isotope effect**: Deuterium shows stronger suppression in RI regime

**Experimental Parameters**:
- Density range: `1×10¹⁹ - 5×10¹⁹ m⁻³`
- Transition density: ~`2-3×10¹⁹ m⁻³` (density-dependent)
- Device: Large Helical Device (stellarator/heliotron)
- Validation: Gyrokinetic simulations + 2-fluid MHD

---

## 📊 Current TORAX/Gotenx Status

### Implemented Turbulence Models

| Model | ITG Support | RI Support | Transition | Status in Gotenx |
|-------|-------------|------------|------------|------------------|
| **Constant** | ❌ | ❌ | ❌ | ✅ Implemented |
| **Bohm-GyroBohm** | Empirical | Empirical | ❌ | ✅ Implemented |
| **CGM** (Critical Gradient) | ✅ ITG formula | ❌ | ❌ | ✅ Implemented |
| **QLKNN** | ✅ `include_ITG` | ❌ | Patch-based | ✅ Implemented |
| **QuaLiKiz** | ✅ Gyrokinetic | ❌ | Patch-based | ❌ Not implemented |

**Gap**: No explicit RI turbulence model, no density-dependent transition

### TORAX Transition Mechanisms

Current approach uses **spatial patches** (not density-dependent):
```python
# Inner/outer transport patches (TORAX)
apply_inner_patch: True
rho_inner: 0.0 - 0.3
apply_outer_patch: True
rho_outer: 0.8 - 1.0
```

**Limitation**: Static radial zones, not responsive to density evolution

---

## 🔧 Proposed Implementation

### Architecture: `DensityTransitionTransport` Model

New transport model that **dynamically blends** ITG and RI regimes based on local density.

```swift
public struct DensityTransitionTransport: TransportModel {
    // Sub-models
    private let itgModel: TransportModel    // Low-density regime
    private let riModel: TransportModel     // High-density regime

    // Transition parameters
    public let transitionDensity: Float      // n_trans [m⁻³]
    public let transitionWidth: Float        // Smoothing width
    public let isotopeMass: Float            // 1.0 (H), 2.0 (D), 3.0 (T)

    public func computeCoefficients(...) -> TransportCoefficients {
        let n_e = profiles.electronDensity.value

        // Compute blending weight based on density
        let alpha = transitionWeight(density: n_e)

        // ITG regime coefficients
        let chi_itg = itgModel.computeCoefficients(...)

        // RI regime coefficients
        let chi_ri = riModel.computeCoefficients(...)

        // Smooth transition
        let chi_eff = (1 - alpha) * chi_itg + alpha * chi_ri

        return chi_eff
    }

    private func transitionWeight(density: MLXArray) -> MLXArray {
        // Smooth sigmoid transition
        let delta_n = (density - transitionDensity) / transitionWidth
        return 1.0 / (1.0 + exp(-delta_n))
    }
}
```

---

## 🧮 RI Turbulence Model

### Physical Basis

**Resistive-Interchange Turbulence** is driven by:
1. **Pressure gradient**: `∇p` (interchange drive)
2. **Plasma resistivity**: `η` (enables magnetic reconnection)
3. **Magnetic curvature**: Bad curvature region (outboard side)

**Governing Equations** (Reduced MHD):

```
∂n/∂t + ∇·(n v_E) = ∇·(D_RI ∇n)
∂T/∂t + ∇·(T v_E) = ∇·(χ_RI ∇T) + Q
∂ψ/∂t = η J_∥  (resistive evolution)
```

Where:
- `v_E = (B × ∇φ) / B²`: E×B drift velocity
- `η`: Plasma resistivity (Spitzer formula)
- `D_RI, χ_RI`: RI-driven transport coefficients

### Scaling for Transport Coefficients

Based on resistive ballooning mode (RBM) theory:

```swift
// RI transport coefficients (simplified)
χ_RI = C_RI * (ρ_s²/τ_R) * (L_p/L_n)^α * exp(-β_crit/β)

Where:
ρ_s = c_s / ω_ci           // Ion sound Larmor radius
τ_R = μ₀ a² / η            // Resistive time
L_p = p / |∇p|             // Pressure gradient length
L_n = n / |∇n|             // Density gradient length
β = 2μ₀ p / B²             // Plasma beta
```

**Parameters**:
- `C_RI`: Empirical coefficient (~0.1 - 1.0, to be tuned)
- `α`: Gradient drive exponent (~1.5 - 2.0)
- `β_crit`: Critical beta for ballooning (~0.01 - 0.05)

**Isotope Scaling**:
```swift
// Deuterium suppression in RI regime (from paper)
χ_RI_D = χ_RI_H / sqrt(A_i)  // A_i = isotope mass

// For D/H comparison
χ_RI_D ≈ 0.7 × χ_RI_H
```

---

## 📋 Implementation Plan

### Phase 9.1: ITG Regime Enhancement (Use Existing)

**Approach**: Use existing `CGM` or `QLKNN` models for ITG regime

```swift
// Low-density ITG regime
let itgModel = CriticalGradientModel(
    chiCritical: 0.2,     // ITG critical gradient
    chiStiff: 1.0,        // Stiffness coefficient
    gradientScale: 1.0
)
```

**Status**: ✅ Already implemented in `ConstantChi.swift`, `BohmGyroBohm.swift`

### Phase 9.2: RI Turbulence Model (New)

**New File**: `Sources/GotenxCore/Physics/Transport/ResistiveInterchange.swift`

```swift
public struct ResistiveInterchangeModel: TransportModel {
    public let coefficientRI: Float       // C_RI
    public let gradientExponent: Float    // α
    public let betaCritical: Float        // β_crit

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> TransportCoefficients {
        // Compute resistivity from Spitzer formula
        let eta = spitzerResistivity(Te: profiles.electronTemperature.value)

        // Resistive time scale
        let tau_R = computeResistiveTime(eta: eta, geometry: geometry)

        // Pressure gradient scale length
        let L_p = pressureGradientLength(profiles: profiles)

        // Plasma beta
        let beta = plasmaBeta(profiles: profiles, geometry: geometry)

        // RI transport coefficient
        let chi_RI = coefficientRI * (rho_s^2 / tau_R)
                   * pow(L_p / L_n, gradientExponent)
                   * exp(-betaCritical / beta)

        return TransportCoefficients(
            chiIon: chi_RI,
            chiElectron: chi_RI,
            diffusivity: chi_RI / 3.0,
            convectivity: 0.0  // Simplified
        )
    }
}
```

**Required Helper Functions**:
1. `spitzerResistivity()`: η = η₀ T_e^(-3/2)
2. `pressureGradientLength()`: L_p = p / |∇p|
3. `plasmaBeta()`: β = 2μ₀(n_e T_e + n_i T_i) / B²

### Phase 9.3: Density Transition Logic (New)

**New File**: `Sources/GotenxCore/Physics/Transport/DensityTransitionModel.swift`

```swift
public struct DensityTransitionModel: TransportModel {
    private let itgModel: TransportModel
    private let riModel: TransportModel

    public let transitionDensity: Float    // n_trans [m⁻³]
    public let transitionWidth: Float      // Δn [m⁻³]
    public let isotopeMass: Float          // A_i (1, 2, 3)

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> TransportCoefficients {
        let n_e = profiles.electronDensity.value

        // Transition weight function (sigmoid)
        let alpha = transitionWeight(density: n_e)

        // ITG coefficients (low density)
        let chi_itg = itgModel.computeCoefficients(profiles: profiles, geometry: geometry)

        // RI coefficients (high density)
        var chi_ri = riModel.computeCoefficients(profiles: profiles, geometry: geometry)

        // Apply isotope scaling to RI regime
        chi_ri = applyIsotopeScaling(chi_ri, mass: isotopeMass)

        // Smooth blend
        let chi_blend = TransportCoefficients(
            chiIon: (1 - alpha) * chi_itg.chiIon + alpha * chi_ri.chiIon,
            chiElectron: (1 - alpha) * chi_itg.chiElectron + alpha * chi_ri.chiElectron,
            diffusivity: (1 - alpha) * chi_itg.diffusivity + alpha * chi_ri.diffusivity,
            convectivity: (1 - alpha) * chi_itg.convectivity + alpha * chi_ri.convectivity
        )

        return chi_blend
    }

    private func transitionWeight(density: MLXArray) -> MLXArray {
        // Sigmoid transition centered at n_trans with width Δn
        let delta_n = (density - transitionDensity) / transitionWidth
        return 1.0 / (1.0 + exp(-delta_n))
    }

    private func applyIsotopeScaling(
        _ chi: TransportCoefficients,
        mass: Float
    ) -> TransportCoefficients {
        // RI turbulence scaling: χ ∝ 1/√(A_i)
        let scaleFactor = 1.0 / sqrt(mass)

        return TransportCoefficients(
            chiIon: chi.chiIon * scaleFactor,
            chiElectron: chi.chiElectron * scaleFactor,
            diffusivity: chi.diffusivity * scaleFactor,
            convectivity: chi.convectivity
        )
    }
}
```

### Phase 9.4: Configuration Support

**Extension to**: `Sources/GotenxCore/Configuration/TransportConfig.swift`

```swift
public enum TransportModelType: String, Codable, Sendable, CaseIterable {
    case constant
    case bohmGyroBohm
    case criticalGradient
    case qlknn
    case densityTransition  // NEW
}

public struct DensityTransitionParameters: Codable, Sendable {
    // ITG regime (low density)
    public var itgModelType: TransportModelType = .criticalGradient

    // RI regime (high density)
    public var riCoefficient: Float = 0.5
    public var riGradientExponent: Float = 1.5
    public var riBetaCritical: Float = 0.02

    // Transition parameters
    public var transitionDensity: Float = 2.5e19  // m⁻³
    public var transitionWidth: Float = 0.5e19    // m⁻³

    // Isotope effects
    public var isotopeMass: Float = 2.0  // 1.0=H, 2.0=D, 3.0=T
}
```

**JSON Configuration Example**:

```json
{
  "runtime": {
    "dynamic": {
      "transport": {
        "modelType": "densityTransition",
        "densityTransition": {
          "itgModelType": "criticalGradient",
          "riCoefficient": 0.5,
          "riGradientExponent": 1.5,
          "riBetaCritical": 0.02,
          "transitionDensity": 2.5e19,
          "transitionWidth": 0.5e19,
          "isotopeMass": 2.0
        }
      }
    }
  }
}
```

### Phase 9.5: Validation Tests

**Test Suite**: `Tests/GotenxTests/Physics/Transport/DensityTransitionTests.swift`

```swift
@Suite("Density Transition Transport Tests")
struct DensityTransitionTests {
    @Test("ITG regime at low density")
    func lowDensityITGRegime() {
        let model = DensityTransitionModel(...)
        let profiles = createLowDensityProfiles(n_e: 1e19)
        let chi = model.computeCoefficients(profiles: profiles, geometry: geometry)

        // Should match ITG model behavior
        #expect(chi.chiIon > 0.0)
    }

    @Test("RI regime at high density")
    func highDensityRIRegime() {
        let model = DensityTransitionModel(...)
        let profiles = createHighDensityProfiles(n_e: 5e19)
        let chi = model.computeCoefficients(profiles: profiles, geometry: geometry)

        // Should match RI model behavior
        #expect(chi.chiIon > 0.0)
    }

    @Test("Smooth transition at n_trans")
    func smoothTransition() {
        let model = DensityTransitionModel(transitionDensity: 2.5e19, ...)

        // Scan density across transition
        let densities: [Float] = [1e19, 2.0e19, 2.5e19, 3.0e19, 4.0e19]
        var chiValues: [Float] = []

        for n_e in densities {
            let profiles = createProfiles(n_e: n_e)
            let chi = model.computeCoefficients(...)
            chiValues.append(chi.chiIon)
        }

        // Check smoothness (no discontinuities)
        for i in 0..<(chiValues.count - 1) {
            let gradient = abs(chiValues[i+1] - chiValues[i])
            #expect(gradient < 10.0)  // Reasonable smoothness
        }
    }

    @Test("Isotope scaling in RI regime")
    func isotopeScaling() {
        let modelH = DensityTransitionModel(isotopeMass: 1.0, ...)
        let modelD = DensityTransitionModel(isotopeMass: 2.0, ...)

        let profiles = createHighDensityProfiles(n_e: 4e19)  // RI regime

        let chiH = modelH.computeCoefficients(...)
        let chiD = modelD.computeCoefficients(...)

        // D should have ~0.7× suppression in RI regime
        let ratio = chiD.chiIon / chiH.chiIon
        #expect(abs(ratio - 0.707) < 0.1)  // 1/√2 ≈ 0.707
    }
}
```

---

## 📈 Expected Results

### Turbulence vs. Density Profile

Reproducing paper Figure 1 behavior:

```
χ_turb
  ^
  |     ITG          Transition        RI
  |      ╲              │            ╱
  |       ╲             │           ╱
  |        ╲            │          ╱
  |         ╲___________│_________╱   (H plasma)
  |          ╲          │        ╱
  |           ╲         │       ╱
  |            ╲________│______╱      (D plasma, suppressed RI)
  |                     │
  +─────────────────────┼───────────────> n_e
                    n_trans
```

### Confinement Time Improvement

Expected impact on energy confinement:

```
τ_E ∝ 1/χ_eff

- At n < n_trans: ITG-limited (standard scaling)
- At n = n_trans: Optimal confinement (minimum turbulence)
- At n > n_trans: RI-limited (D shows 30% improvement over H)
```

---

## 🔮 Future Extensions

### Phase 9+: Advanced Features

1. **Gyrokinetic RI Model**: Replace simplified scaling with QuaLiKiz-equivalent RI solver
2. **Multi-mode Coupling**: ITG-TEM-ETG-RI interaction
3. **Radial Dependence**: Transition density varies with radius (core vs. edge)
4. **Time-dependent Transition**: Hysteresis effects during density ramps
5. **Electromagnetic Effects**: Include magnetic flutter in RI model

### Phase 10: Experimental Validation

1. **LHD Benchmark**: Compare with Kinoshita et al. (2024) data
2. **ITER Predictions**: Apply to ITER baseline scenarios
3. **Isotope Scan**: H → D → T confinement projections

---

## 📚 References

### Primary Paper

- **Kinoshita et al. (2024)**: "Turbulence Transition in Magnetically Confined Hydrogen and Deuterium Plasmas", Phys. Rev. Lett. 132, 235101
  - DOI: 10.1103/PhysRevLett.132.235101
  - https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.132.235101

### Related Physics

- **Hasegawa-Wakatani Model**: Resistive drift wave turbulence
- **Resistive Ballooning Modes**: Interchange-driven edge turbulence
- **Braginskii Equations**: Two-fluid MHD transport

### TORAX Implementation

- TORAX GitHub: https://github.com/google-deepmind/torax
- Transport models: `torax/_src/transport_model/`
- QLKNN ITG/TEM/ETG: `torax/_src/transport_model/qlknn_wrapper.py`

---

## ✅ Implementation Checklist

### Phase 9.1: Foundation
- [ ] Review existing ITG models (CGM, QLKNN)
- [ ] Document RI turbulence physics
- [ ] Design `ResistiveInterchangeModel` API

### Phase 9.2: RI Model
- [ ] Implement Spitzer resistivity formula
- [ ] Implement pressure gradient calculation
- [ ] Implement plasma beta computation
- [ ] Create `ResistiveInterchangeModel` class
- [ ] Test RI transport coefficients

### Phase 9.3: Transition Logic
- [ ] Implement sigmoid transition function
- [ ] Create `DensityTransitionModel` class
- [ ] Add isotope mass scaling
- [ ] Test smooth blending

### Phase 9.4: Configuration
- [ ] Extend `TransportModelType` enum
- [ ] Add `DensityTransitionParameters` struct
- [ ] Update `GotenxConfigReader` for new model
- [ ] Create example JSON configuration

### Phase 9.5: Validation
- [ ] Create test suite for density transition
- [ ] Test ITG regime behavior
- [ ] Test RI regime behavior
- [ ] Test smooth transition
- [ ] Test isotope scaling
- [ ] Verify against paper qualitative trends

### Phase 9.6: Documentation
- [ ] Complete implementation guide
- [ ] Add usage examples
- [ ] Document parameter tuning
- [ ] Update CLAUDE.md with new model

---

## 🎉 Success Criteria

1. ✅ Turbulence minimized at transition density
2. ✅ Smooth transition from ITG to RI regimes
3. ✅ Deuterium shows suppression in RI regime (χ_D < χ_H)
4. ✅ Qualitative match to PRL 132, 235101 Fig. 1
5. ✅ Improved confinement near transition density
6. ✅ All tests pass (Float32 compatible)
7. ✅ Zero compilation warnings

---

*Last updated: 2025-10-23*
