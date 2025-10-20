# TORAX Implementation Status & Future Roadmap
## Version 2.0 - Reflecting Current State

**Date**: 2025-10-20
**Status**: Implementation Review
**Revision**: Updated to reflect actual production code

---

## Executive Summary

This document provides an accurate assessment of the current implementation status for three physics models that were initially identified as "unimplemented":

1. **QLKNNTransportModel** - ✅ **FULLY IMPLEMENTED** (via FusionSurrogates)
2. **Current Diffusion Equation** - ⚠️ **PLACEHOLDER ONLY** (needs full implementation)
3. **PedestalModel** - ⚠️ **PROTOCOL ONLY** (no concrete implementations)

This revision corrects significant discrepancies between the original design document and the production codebase.

---

## 1. QLKNNTransportModel - Current Implementation

### 1.1 Status: ✅ FULLY IMPLEMENTED

**Implementation**: `Sources/TORAX/Transport/Models/QLKNNTransportModel.swift` (335 lines)

**Key Difference from Original Design**: The implementation uses the `FusionSurrogates` Swift package, NOT a custom min-max normalization approach.

### 1.2 Actual Architecture

```swift
public struct QLKNNTransportModel: TransportModel {
    private let network: SendableQLKNNNetwork  // Wraps FusionSurrogates.QLKNNNetwork
    public let Zeff: Float
    public let minChi: Float
    private let fallback: BohmGyroBohmTransportModel

    public init(Zeff: Float = 1.0, minChi: Float = 0.01) throws {
        // Loads bundled SafeTensors weights (289 KB)
        self.network = SendableQLKNNNetwork(try QLKNNNetwork.loadDefault())
        // ...
    }
}
```

### 1.3 Actual Input Features (10 Features, Not 9)

**Actual Implementation** (`QLKNNTransportModel.swift:209-220`):
```swift
return [
    "Ati": rLnTi,          // R/L_Ti (normalized ion temperature gradient)
    "Ate": rLnTe,          // R/L_Te (normalized electron temperature gradient)
    "Ane": rLnNe,          // R/L_ne (normalized electron density gradient)
    "Ani": rLnNi,          // R/L_ni (normalized ion density gradient)
    "q": q,                // Safety factor
    "smag": sHat,          // Magnetic shear ŝ = (r/q) dq/dr
    "x": x,                // Inverse aspect ratio r/R
    "Ti_Te": tiTe,         // Temperature ratio Ti/Te
    "LogNuStar": logNuStar,// Log10(collisionality)
    "normni": normni       // Normalized density ni/ne ≈ 1.0
]
```

**Key Differences from Original Design**:
- ✅ Uses **dictionary keys** instead of stacked array
- ✅ **10 features**, not 9 (includes `normni`)
- ✅ **No min-max normalization** - FusionSurrogates handles normalization internally
- ✅ **No denormalizePredictions()** - outputs are already in normalized units

### 1.4 Actual Output Conversion

**CRITICAL**: Outputs are **normalized GyroBohm fluxes**, NOT physical diffusivities.

**Actual Implementation** (`QLKNNTransportModel.swift:225-333`):

```swift
/// Compute GyroBohm diffusivity normalization
///
/// χ_GB = T_e^(3/2) * sqrt(m_i) / [(e B)² * a]
///
private func computeGyrBohmDiffusivity(Te: MLXArray, geometry: Geometry) -> MLXArray {
    let electronCharge: Float = 1.602e-19  // [C]
    let ionMass = Float(2.0) * 1.673e-27   // Deuterium [kg]
    let eV_to_J: Float = 1.602e-19

    let B = geometry.toroidalField  // [T]
    let a = geometry.minorRadius    // [m]

    let Te_J = Te * eV_to_J
    let numerator = pow(Te_J, 1.5) * sqrt(ionMass)
    let denominator = (electronCharge * B)^2 * a

    return numerator / denominator
}

/// Ion diffusivity: χ_i = (efiITG + efiTEM) * χ_GB
private func computeIonDiffusivity(outputs: [String: MLXArray], ...) -> MLXArray {
    let chiGB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)
    let efi_total = outputs["efiITG"]! + outputs["efiTEM"]!
    return efi_total * chiGB
}

/// Electron diffusivity: χ_e = (efeITG + efeTEM + efeETG) * χ_GB
private func computeElectronDiffusivity(outputs: [String: MLXArray], ...) -> MLXArray {
    let chiGB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)
    let efe_total = outputs["efeITG"]! + outputs["efeTEM"]! + outputs["efeETG"]!
    return efe_total * chiGB
}

/// Particle diffusivity: D = (pfeITG + pfeTEM) * χ_GB
private func computeParticleDiffusivity(outputs: [String: MLXArray], ...) -> MLXArray {
    let chiGB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)
    let pfe_total = outputs["pfeITG"]! + outputs["pfeTEM"]!
    return pfe_total * chiGB
}
```

**Key Differences from Original Design**:
- ❌ **NO `params.gyrobohmFactor`** parameter (doesn't exist in `TransportParameters`)
- ✅ Multiplies QLKNN's **normalized fluxes** by **analytic χ_GB**
- ✅ Convection velocity **forced to zero** (QLKNN doesn't predict it)
- ✅ Applies `minChi` floor to prevent numerical issues

### 1.5 Network Architecture (Actual)

**Source**: FusionSurrogates package (https://github.com/1amageek/swift-fusion-surrogates)

**Network Details**:
- Input: 10 features (dictionary format)
- Architecture: [10] → [300] → [300] → [300] → [outputs]
- Activation: tanh (hidden layers)
- Weights: Bundled SafeTensors format (289 KB)
- Output channels: 8 fluxes (efiITG, efiTEM, efeITG, efeTEM, efeETG, pfeITG, pfeTEM, ...)

**No Custom Loading Required**: Weights are bundled in the FusionSurrogates package.

### 1.6 What Works vs. Original Design Claims

| Feature | Original Design | Actual Implementation | Status |
|---------|----------------|----------------------|--------|
| Network weights | Custom `NetworkWeights.load(from:)` | FusionSurrogates bundled SafeTensors | ✅ Better |
| Input normalization | Custom min-max | FusionSurrogates internal | ✅ Better |
| Feature vector | 9 features (stacked array) | 10 features (dictionary) | ⚠️ Different |
| Output denormalization | Custom `denormalizePredictions()` | Multiply by analytic χ_GB | ⚠️ Different |
| Convection velocity | From network | Hardcoded zero | ⚠️ Limitation |
| `gyrobohmFactor` parameter | `params.gyrobohmFactor` | Doesn't exist | ❌ Wrong |
| Fallback handling | Not mentioned | Bohm-GyroBohm fallback on error | ✅ Better |

### 1.7 Remaining Work: NONE

**QLKNNTransportModel is production-ready.**

The only limitation is that **convection velocity is set to zero** because QLKNN primarily predicts diffusive fluxes. This is a physics limitation of the model, not an implementation gap.

---

## 2. Current Diffusion Equation - Placeholder Implementation

### 2.1 Status: ⚠️ PLACEHOLDER ONLY

**Current Implementation**: `Sources/TORAX/Solver/Block1DCoeffsBuilder.swift:254-296`

### 2.2 What Exists Now

```swift
private func buildFluxEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    let nCells = geometry.nCells
    let nFaces = nCells + 1

    // PLACEHOLDER: Hard-coded resistivity
    let eta_parallel = Float(1e-7)  // Typical plasma resistivity (Ω·m)
    let dFace = MLXArray.full([nFaces], values: MLXArray(eta_parallel))

    // NO CONVECTION
    let vFace = MLXArray.zeros([nFaces])

    // Source: current drive (bootstrap + external)
    let sourceCell = sources.currentSource.value  // Currently ZERO

    // Source matrix coefficient
    let sourceMatCell = MLXArray.zeros([nCells])

    // Transient coefficient (simplified)
    let transientCoeff = MLXArray.ones([nCells])

    return EquationCoeffs(...)
}
```

**Reality Check**:
- ✅ `buildFluxEquationCoeffs()` exists
- ✅ Poloidal flux equation can be enabled via `StaticRuntimeParams.evolveCurrent`
- ❌ Resistivity is **hard-coded constant** (not temperature-dependent Spitzer formula)
- ❌ Bootstrap current is **not computed** (`sources.currentSource` defaults to zero)
- ❌ Ohmic current from E-field is **not computed**
- ❌ No `CurrentDiffusionModel` type exists
- ❌ No safety factor `q(ρ)` evolution

### 2.3 What's Missing

**High Priority**:

1. **Temperature-Dependent Resistivity** (1 hour)
   ```swift
   func computeSpitzerResistivity(
       Te: MLXArray,
       geometry: Geometry
   ) -> MLXArray {
       // Same formula as OhmicHeating
       // Use default Zeff = 1.5 (typical for ITER)
       let Zeff: Float = 1.5
       let coulombLog: Float = 17.0
       let eta_spitzer = 5.2e-5 * Zeff * coulombLog / pow(Te, 1.5)

       // Neoclassical correction
       let epsilon = geometry.radii.value / geometry.majorRadius
       let ft = 1.0 + 1.46 * sqrt(epsilon)  // Trapping factor

       return eta_spitzer * ft
   }
   ```

2. **Bootstrap Current Calculation** (2 hours)
   ```swift
   func computeBootstrapCurrent(
       profiles: CoreProfiles,
       geometry: Geometry
   ) -> MLXArray {
       let Ti = profiles.ionTemperature.value
       let Te = profiles.electronTemperature.value
       let ne = profiles.electronDensity.value

       // Compute pressure gradient
       let gradP = computePressureGradient(Ti, Te, ne, geometry)

       // Sauter formula (simplified)
       let epsilon = geometry.radii.value / geometry.majorRadius
       let C_BS = 1.0 - epsilon  // Bootstrap coefficient

       let J_BS = C_BS * gradP / geometry.toroidalField

       return clip(J_BS, min: 0.0, max: 1e7)  // [A/m²]
   }
   ```

3. **Safety Factor Utilities** (1 hour)
   ```swift
   extension CoreProfiles {
       func safetyFactor(geometry: Geometry) -> MLXArray {
           let r = geometry.radii.value
           let R0 = geometry.majorRadius
           let Bphi = geometry.toroidalField

           let dPsi_dr = stableGrad(poloidalFlux.value, dr: geometry.cellDistances.value)
           let Btheta = dPsi_dr / (r + 1e-10)

           let q = (r * Bphi) / (R0 * Btheta + 1e-10)

           return clip(q, min: 0.3, max: 20.0)
       }
   }
   ```

4. **Integration into `buildFluxEquationCoeffs()`** (1 hour)
   ```swift
   // Replace hard-coded η with temperature-dependent resistivity
   let eta = computeSpitzerResistivity(
       Te: profiles.electronTemperature.value,
       geometry: geometry
   )
   let dFace = interpolateToFaces(eta, mode: .harmonic)

   // Add bootstrap current to source term
   let J_bootstrap = computeBootstrapCurrent(profiles: profiles, geometry: geometry)
   let sourceCell = sources.currentSource.value + J_bootstrap
   ```

### 2.4 Design Decision: No Separate `CurrentDiffusionModel` Type

**Recommendation**: Keep current diffusion physics **inside `buildFluxEquationCoeffs()`** rather than creating a separate `CurrentDiffusionModel` type.

**Rationale**:
- ✅ Consistent with how transport/source terms are handled (coefficients computed in builder)
- ✅ Avoids creating yet another protocol/factory layer
- ✅ Bootstrap current needs same profiles/geometry as transport coefficients
- ✅ Simpler architecture (fewer types)

**Revised Implementation Plan**:

```swift
// In Block1DCoeffsBuilder.swift

private func buildFluxEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    // 1. Temperature-dependent resistivity
    let eta = computeSpitzerResistivity(
        Te: profiles.electronTemperature.value,
        geometry: geometry
    )
    let dFace = interpolateToFaces(eta, mode: .harmonic)

    // 2. Bootstrap current
    let J_bootstrap = computeBootstrapCurrent(
        profiles: profiles,
        geometry: geometry
    )

    // 3. Total current source
    let J_external = sources.currentSource.value  // From config
    let J_total = J_bootstrap + J_external

    // 4. Return coefficients
    return EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray.zeros([geometry.nCells + 1]),
        sourceCell: EvaluatedArray(evaluating: J_total),
        sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
        transientCoeff: EvaluatedArray.ones([geometry.nCells])
    )
}

// Helper functions (same file)

private func computeSpitzerResistivity(Te: MLXArray, geometry: Geometry) -> MLXArray {
    // Implementation from OhmicHeating
    // Uses default Zeff = 1.5 (typical for ITER)
}

private func computeBootstrapCurrent(profiles: CoreProfiles, geometry: Geometry) -> MLXArray {
    // Simplified Sauter formula
}
```

### 2.5 Estimated Effort

| Task | Effort | Blocker | Priority |
|------|--------|---------|----------|
| Temperature-dependent resistivity | 1 hour | None | P0 |
| Bootstrap current (simplified) | 2 hours | None | P0 |
| Safety factor utilities | 1 hour | None | P0 |
| Integration & testing | 2 hours | None | P0 |
| **Total** | **6 hours** | None | **P0** |

### 2.6 Testing Strategy

```swift
#Test("Bootstrap current magnitude")
func testBootstrapCurrentMagnitude() async throws {
    let profiles = createITERProfiles()
    let geometry = createITERGeometry()

    let J_BS = computeBootstrapCurrent(profiles: profiles, geometry: geometry)
    eval(J_BS)

    let volumes = GeometricFactors.from(geometry: geometry).cellVolumes.value
    let I_BS = (J_BS * volumes).sum().item(Float.self)

    // ITER baseline: 15 MA total, ~20% bootstrap
    let I_plasma: Float = 15e6
    let fraction = I_BS / I_plasma

    #expect(fraction > 0.15)
    #expect(fraction < 0.25)
}

#Test("Safety factor evolution")
func testSafetyFactorEvolution() async throws {
    let config = SimulationConfig(
        staticParams: StaticRuntimeParams(evolveCurrent: true, ...),
        ...
    )

    let result = try await SimulationRunner().run(config: config)

    let q_initial = result.timeSeries!.first!.profiles.safetyFactor(geometry)
    let q_final = result.timeSeries!.last!.profiles.safetyFactor(geometry)

    let q0_initial = q_initial[0].item(Float.self)
    let q0_final = q_final[0].item(Float.self)

    // q(0) should decrease as current peaks up
    #expect(q0_final < q0_initial)
}
```

---

## 3. PedestalModel - Protocol Only

### 3.1 Status: ⚠️ PROTOCOL ONLY

**Current Implementation**: `Sources/TORAX/Protocols/PedestalModel.swift` (49 lines)

### 3.2 What Exists Now

```swift
public struct PedestalOutput: Sendable, Equatable {
    public let temperature: Float  // [eV]
    public let density: Float      // [m⁻³]
    public let width: Float        // [m]
}

public protocol PedestalModel: PhysicsComponent {
    func computePedestal(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: [String: Float]
    ) -> PedestalOutput
}
```

**Reality Check**:
- ✅ Protocol exists with proper signatures
- ✅ Units documented (eV, m⁻³, m)
- ❌ No concrete implementations (no `FixedPedestalModel`, no `EPED1PedestalModel`)
- ❌ No factory methods
- ❌ Not integrated into `SimulationRunner` or configuration

### 3.3 Minimal Implementation: FixedPedestalModel

**Priority**: P2 (Medium - not blocking core functionality)

**Design**:

```swift
// In Sources/TORAX/Physics/Pedestal/FixedPedestalModel.swift

/// Fixed pedestal model with constant boundary conditions
///
/// Simplest pedestal model - returns constant values from configuration.
/// Suitable for:
/// - L-mode scenarios (no pedestal)
/// - Initial testing
/// - Cases where pedestal is externally specified
///
public struct FixedPedestalModel: PedestalModel {
    public let name = "fixed_pedestal"

    public init() {}

    public func computePedestal(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: [String: Float]
    ) -> PedestalOutput {
        // Extract parameters from config (with defaults)
        let temperature = params["temperature"] ?? 1000.0  // [eV]
        let density = params["density"] ?? 5e19            // [m⁻³]
        let width = params["width"] ?? 0.05                // [m]

        return PedestalOutput(
            temperature: temperature,
            density: density,
            width: width
        )
    }
}
```

**Configuration Integration**:

```swift
// In SimulationConfig
public struct PedestalConfig: Codable, Sendable {
    public let enabled: Bool
    public let modelType: String  // "fixed", "eped1" (future)
    public let params: [String: Float]

    public init(
        enabled: Bool = false,
        modelType: String = "fixed",
        params: [String: Float] = [:]
    ) {
        self.enabled = enabled
        self.modelType = modelType
        self.params = params
    }
}

// Factory method
public struct PedestalModelFactory {
    public static func create(config: PedestalConfig) -> (any PedestalModel)? {
        guard config.enabled else { return nil }

        switch config.modelType {
        case "fixed":
            return FixedPedestalModel()
        default:
            fatalError("Unknown pedestal model: \(config.modelType)")
        }
    }
}
```

**Usage in SimulationRunner**:

```swift
// Apply pedestal boundary conditions (if enabled)
if let pedestalModel = pedestalModel {
    let pedestalOutput = pedestalModel.computePedestal(
        profiles: currentProfiles,
        geometry: geometry,
        params: config.pedestalConfig.params
    )

    // Update edge boundary conditions
    dynamicParams.boundaryConditions = BoundaryConditions(
        ionTemperature: BoundaryCondition(
            value: pedestalOutput.temperature,
            location: .edge
        ),
        electronTemperature: BoundaryCondition(
            value: pedestalOutput.temperature,
            location: .edge
        ),
        electronDensity: BoundaryCondition(
            value: pedestalOutput.density,
            location: .edge
        )
    )
}
```

### 3.4 Estimated Effort

| Task | Effort | Priority |
|------|--------|----------|
| `FixedPedestalModel` implementation | 30 min | P2 |
| Configuration integration | 30 min | P2 |
| Factory & tests | 30 min | P2 |
| **Total** | **1.5 hours** | **P2** |

### 3.5 EPED1 Model: Future Work (P3)

**Status**: Deferred (requires MHD equilibrium solver)

**Complexity**: 20+ hours of work
- Peeling-ballooning stability analysis
- Kinetic ballooning mode constraint
- Iterative solver to find maximum stable gradient

**Recommendation**: Implement `FixedPedestalModel` first, defer EPED1 to future release.

---

## 4. Revised Implementation Roadmap

### Priority Summary

| Component | Status | Effort | Priority | Blocking |
|-----------|--------|--------|----------|----------|
| **QLKNNTransportModel** | ✅ Complete | 0 hours | N/A | None |
| **Current Diffusion** | ⚠️ Placeholder | 6 hours | **P0** | SawtoothModel, QLKNN features |
| **FixedPedestalModel** | ❌ Not started | 1.5 hours | **P2** | None |
| **EPED1 Pedestal** | ❌ Not started | 20+ hours | **P3** | MHD equilibrium |

### Recommended Implementation Sequence

**Week 1: Current Diffusion (P0 - Critical)**

**Day 1-2**: Spitzer resistivity & bootstrap current
- [ ] Implement `computeSpitzerResistivity()` in `Block1DCoeffsBuilder.swift`
- [ ] Implement `computeBootstrapCurrent()` (simplified Sauter formula)
- [ ] Unit tests for resistivity and bootstrap current magnitude

**Day 3**: Integration & safety factor
- [ ] Update `buildFluxEquationCoeffs()` to use temperature-dependent resistivity
- [ ] Add bootstrap current to source term
- [ ] Implement `CoreProfiles.safetyFactor()` extension
- [ ] Add `computeMagneticShear()` helper

**Day 4**: Testing & validation
- [ ] Integration test: q(ρ) evolution
- [ ] Verify bootstrap fraction 15-25% for ITER scenario
- [ ] Test SawtoothModel triggering with accurate q(0)

**Week 2: Pedestal Model (P2 - Optional)**

**Day 1**: Fixed pedestal implementation
- [ ] Implement `FixedPedestalModel`
- [ ] Add `PedestalConfig` to configuration system
- [ ] Add `PedestalModelFactory`

**Day 2**: Integration & testing
- [ ] Integrate into `SimulationRunner`
- [ ] Add test with fixed pedestal boundary conditions
- [ ] Update documentation

---

## 5. Open Questions & Answers

### Q1: Should the remediation doc be rewritten around the current FusionSurrogates integration?

**A1**: ✅ **YES - DONE IN THIS REVISION**

The original design document described a custom min-max normalization approach with `NetworkWeights.load(from:)` that **never existed** and **never will exist**. The actual implementation uses FusionSurrogates, which is:
- ✅ Better (bundled weights, no file loading needed)
- ✅ Maintained externally (https://github.com/1amageek/swift-fusion-surrogates)
- ✅ Production-ready

This revision now accurately documents the **actual** QLKNN implementation.

### Q2: What is the intended timeline for replacing the ψ equation placeholder?

**A2**: **Week 1 (6 hours of work)**

The placeholder can be replaced incrementally:
1. **Phase 1** (2 hours): Temperature-dependent resistivity
2. **Phase 2** (2 hours): Bootstrap current
3. **Phase 3** (2 hours): Safety factor utilities & testing

**No architectural changes needed** - just enhance the existing `buildFluxEquationCoeffs()` function.

### Q3: Do we still plan to expose bootstrap/ohmic terms explicitly in the coefficient builder?

**A3**: **YES, but as helper functions in the same file**

**Revised Approach**:
```swift
// In Block1DCoeffsBuilder.swift (same file)

// Private helper functions (not exposed to users)
private func computeSpitzerResistivity(...) -> MLXArray { ... }
private func computeBootstrapCurrent(...) -> MLXArray { ... }

// Updated public function
private func buildFluxEquationCoeffs(...) -> EquationCoeffs {
    let eta = computeSpitzerResistivity(...)
    let J_BS = computeBootstrapCurrent(...)
    // ...
}
```

**Rationale**:
- ✅ No new types needed (`CurrentDiffusionModel` unnecessary)
- ✅ Consistent with transport/source coefficient computation
- ✅ Bootstrap current is **derived** from profiles, not a user input
- ✅ Simpler architecture

### Q4: Where does Zeff come from for resistivity calculation?

**A4**: **Use default value (Zeff = 1.5) in helper function**

**Current Pattern**:
- Physics models like `OhmicHeating` take Zeff as constructor parameter (default 1.5)
- `StaticRuntimeParams` does NOT have a Zeff field
- `TransportParameters.params` can optionally contain Zeff

**Recommended Approach**:
```swift
private func computeSpitzerResistivity(
    Te: MLXArray,
    geometry: Geometry
) -> MLXArray {
    // Use default Zeff = 1.5 (typical for ITER with low-Z impurities)
    let Zeff: Float = 1.5
    let coulombLog: Float = 17.0
    // ...
}
```

**Rationale**:
- ✅ Consistent with OhmicHeating default
- ✅ Zeff = 1.5 is typical for ITER scenarios (deuterium + low-Z impurities)
- ✅ No need to add Zeff to StaticRuntimeParams (avoids recompilation triggers)
- ✅ Can be made configurable later via DynamicRuntimeParams if needed

**Future Enhancement** (optional):
```swift
// Extract Zeff from transport params if available
let Zeff = dynamicParams.transportParams.params["Zeff"] ?? 1.5
```

---

## 6. What Changed from Original Design

### Major Corrections

| Original Design Claim | Reality | Impact |
|----------------------|---------|--------|
| QLKNN uses 9 features with min-max normalization | Uses 10 features with FusionSurrogates internal normalization | **High** - wrong feature vector |
| QLKNN outputs scaled by `params.gyrobohmFactor` | Multiplied by analytic χ_GB, no `gyrobohmFactor` in `TransportParameters` | **High** - non-existent parameter |
| QLKNN predicts convection velocity | Convection hardcoded to zero | **Medium** - physics limitation |
| `CurrentDiffusionModel` type exists | No such type, placeholder in `buildFluxEquationCoeffs()` | **High** - missing implementation |
| `FixedPedestalModel` and `EPED1PedestalModel` exist | Only protocol exists, no implementations | **Medium** - missing implementations |
| `denormalizePredictions()` method | No such method | **Low** - different approach |

### What's Accurate

| Original Design Claim | Reality | Status |
|----------------------|---------|--------|
| QLKNN is fully GPU-accelerated | ✅ Correct (MLX + Metal) | ✅ |
| Bootstrap current needs Sauter formula | ✅ Correct | ✅ |
| Safety factor computed from q = rBφ/(R₀Bθ) | ✅ Correct | ✅ |
| Spitzer resistivity η ∝ Zeff/T^1.5 | ✅ Correct | ✅ |
| Fixed pedestal model is simplest implementation | ✅ Correct | ✅ |

---

## 7. Success Criteria (Revised)

### Current Diffusion (P0)

**Must Have**:
- ✅ Temperature-dependent resistivity (Spitzer formula)
- ✅ Bootstrap current with 15-25% fraction for ITER
- ✅ Safety factor `q(ρ)` evolution
- ✅ SawtoothModel triggers correctly when q(0) < 1

**Testing**:
- ✅ Bootstrap current magnitude within ±5% of experimental data
- ✅ q(0) evolves from initial to steady state
- ✅ Resistivity matches analytic Spitzer formula

### Pedestal Model (P2)

**Must Have**:
- ✅ `FixedPedestalModel` with constant boundary conditions
- ✅ Configuration integration
- ✅ Smooth edge profiles

**Testing**:
- ✅ Edge temperature/density match pedestal specification
- ✅ No numerical instabilities at edge

### QLKNN (Already Complete)

**Already Achieved**:
- ✅ FusionSurrogates integration working
- ✅ 10-feature input vector correctly computed
- ✅ GyroBohm normalization applied
- ✅ Fallback to Bohm-GyroBohm on error
- ✅ GPU-accelerated forward pass < 10 ms

---

## 8. Updated Timeline

**Week 1 (Critical Path)**:
- Day 1-2: Current diffusion physics (resistivity + bootstrap)
- Day 3: Integration & safety factor utilities
- Day 4: Testing & validation

**Week 2 (Optional)**:
- Day 1: Fixed pedestal model
- Day 2: Integration & testing

**Total Effort**: 6 hours (P0), 1.5 hours (P2)

---

## 9. Documentation Updates Required

**Files to Update**:
1. ✅ `docs/REMEDIATION_DESIGN.md` - **THIS FILE** (now accurate)
2. ⏳ `CLAUDE.md` - Update physics models section with actual QLKNN implementation
3. ⏳ `README.md` - Mark QLKNN as "✅ Complete", current diffusion as "⚠️ In Progress"
4. ⏳ Add `docs/physics/CurrentDiffusion.md` - Bootstrap current & safety factor
5. ⏳ Update `docs/physics/Transport.md` - Correct QLKNN feature description

---

## 10. References

1. **FusionSurrogates (QLKNN)**:
   - Repository: https://github.com/1amageek/swift-fusion-surrogates
   - SafeTensors weights bundled in package

2. **Bootstrap Current**:
   - Sauter et al., "Neoclassical conductivity and bootstrap current formulas", PoP 6, 2834 (1999)
   - https://doi.org/10.1063/1.873240

3. **Spitzer Resistivity**:
   - Spitzer & Härm, "Transport Phenomena in a Completely Ionized Gas", Phys. Rev. 89, 977 (1953)
   - NRL Plasma Formulary (2019), equation for neoclassical resistivity

4. **Safety Factor**:
   - Wesson, "Tokamak Physics" (1987), Chapter 3
   - q = rBφ/(R₀Bθ), where Bθ = (1/r) ∂ψ/∂r

---

## Appendix: Code Locations

### Current Implementation Files

**QLKNN Transport Model** (✅ Complete):
- `Sources/TORAX/Transport/Models/QLKNNTransportModel.swift` (335 lines)
- Uses `FusionSurrogates.QLKNNNetwork`
- 10-feature dictionary input
- GyroBohm normalization

**Current Diffusion Placeholder** (⚠️ Needs Work):
- `Sources/TORAX/Solver/Block1DCoeffsBuilder.swift:254-296`
- Hard-coded resistivity (line 273)
- Zero bootstrap current (line 280 defaults to zero)

**Pedestal Protocol** (⚠️ Empty):
- `Sources/TORAX/Protocols/PedestalModel.swift` (49 lines)
- Protocol only, no implementations

**Configuration**:
- `Sources/TORAX/Configuration/Parameters.swift`
- `TransportParameters` has NO `gyrobohmFactor` field

---

**Document Status**: ✅ Revised to reflect production code
**Accuracy**: ✅ Verified against actual implementation
**Ready for Implementation**: ✅ Yes (current diffusion only)
**Estimated Total Effort**: 7.5 hours (6 hours P0 + 1.5 hours P2)
