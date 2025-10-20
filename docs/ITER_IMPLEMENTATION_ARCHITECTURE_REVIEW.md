# ITER Scenario Implementation: Architecture Review & Design

**Document Version**: 1.0
**Date**: 2025-01-20
**Purpose**: Accurate implementation plan based on actual codebase architecture

---

## 1. Current Architecture Understanding

### 1.1 Source Model Data Flow (As Actually Implemented)

```
Physics Models (GotenxPhysics)
    ↓ compute() returns W/m³ or MW/m³
applyToSources(SourceTerms, CoreProfiles) → SourceTerms
    ↓ returns MW/m³ in SourceTerms
SourceModelAdapters
    ↓ implements SourceModel protocol
CompositeSourceModel
    ↓ aggregates all sources → SourceTerms [MW/m³]
Block1DCoeffsBuilder
    ↓ UnitConversions.megawattsToEvDensity()
    ↓ MW/m³ → eV/(m³·s)  (factor: 6.2415×10²⁴)
PDESolver
    ↓ solves with [eV/(m³·s)] units
CoreProfiles [eV, m⁻³]
```

**Key Insight**:
- **SourceTerms uses MW/m³** (standard in plasma physics community)
- **Conversion happens in Block1DCoeffsBuilder**, NOT in physics models
- This is **correct and intentional design**

### 1.2 Unit System (Actual Implementation)

| Layer | Temperature | Density | Heating | Particles |
|-------|-------------|---------|---------|-----------|
| **CoreProfiles** | eV | m⁻³ | - | - |
| **SourceTerms** | - | - | **MW/m³** | m⁻³/s |
| **PDE Solver** | eV | m⁻³ | **eV/(m³·s)** | m⁻³/s |

**Critical**: CLAUDE.md incorrectly states "all eV/s". The actual implementation uses **MW/m³** in SourceTerms with conversion at solver boundary.

### 1.3 SourceModel Protocol Pattern

**Interface** (`Protocols/SourceModel.swift`):
```swift
protocol SourceModel: PhysicsComponent, Sendable {
    func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms
}
```

**Physics Models** (GotenxPhysics):
```swift
// Example: FusionPower
func applyToSources(
    _ sources: SourceTerms,
    profiles: CoreProfiles
) throws -> SourceTerms {
    let P_watts = compute(ne, Ti)
    let P_MW = P_watts / 1e6  // → MW/m³

    return SourceTerms(
        ionHeating: ...,        // MW/m³
        electronHeating: ...,   // MW/m³
        particleSource: ...,
        currentSource: ...
    )
}
```

**Adapter Pattern** (`GotenxPhysics/SourceModelAdapters.swift`):
```swift
struct FusionPowerSource: SourceModel {
    private let model: FusionPower

    func computeTerms(...) -> SourceTerms {
        let empty = SourceTerms.zero(nCells)
        return try model.applyToSources(empty, profiles: profiles)
    }
}
```

**Composite Aggregation**:
```swift
struct CompositeSourceModel: SourceModel {
    private let sources: [String: any SourceModel]

    func computeTerms(...) -> SourceTerms {
        // Accumulate MLXArrays
        var totalIonHeating = MLXArray.zeros([nCells])
        for source in sources.values {
            let terms = source.computeTerms(...)
            totalIonHeating = totalIonHeating + terms.ionHeating.value
        }
        return SourceTerms(...) // MW/m³
    }
}
```

---

## 2. Implementation Strategy for New Sources

### 2.1 ECRH (Electron Cyclotron Resonance Heating)

**Architecture Integration**:
```
ECRHModel (GotenxPhysics/Heating/)
    ↓ implements physics calculation [W/m³]
ECRHSource (adapter in SourceModelAdapters.swift)
    ↓ implements SourceModel protocol
SourceModelFactory
    ↓ factory method for "ecrh"
SourcesConfig
    ↓ ECRHConfig struct
```

**Implementation Pattern**:

```swift
// 1. Physics Model (GotenxPhysics/Heating/ECRHModel.swift)
public struct ECRHModel: Sendable {
    let totalPower: Float         // [W]
    let depositionRho: Float      // [dimensionless]
    let depositionWidth: Float    // [dimensionless]

    /// Compute ECRH power deposition
    /// - Returns: Power density [W/m³]
    public func compute(
        geometry: Geometry,
        profiles: CoreProfiles
    ) -> MLXArray {
        let rho = geometry.rho.value
        let volumes = geometry.cellVolumes.value

        // Gaussian deposition
        let sigma = depositionWidth / 3.0
        let profile = exp(-pow((rho - depositionRho) / sigma, 2))

        // Normalize to total power
        let integral = (profile * volumes).sum()
        let P_density = totalPower * profile / (integral + 1e-10)  // [W/m³]

        return P_density
    }

    /// Apply to existing source terms (MW/m³)
    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles,
        geometry: Geometry
    ) throws -> SourceTerms {
        let P_watts = compute(geometry: geometry, profiles: profiles)
        let P_MW = P_watts / 1e6  // Convert to MW/m³

        // ECRH heats electrons only
        let updated_electron = sources.electronHeating.value + P_MW

        return SourceTerms(
            ionHeating: sources.ionHeating,
            electronHeating: EvaluatedArray(evaluating: updated_electron),
            particleSource: sources.particleSource,
            currentSource: sources.currentSource
        )
    }
}

// 2. SourceModel Adapter (SourceModelAdapters.swift)
public struct ECRHSource: SourceModel {
    public let name = "ecrh"
    private let model: ECRHModel

    public init(params: SourceParameters) throws {
        self.model = ECRHModel(
            totalPower: params.params["total_power"] ?? 20e6,
            depositionRho: params.params["deposition_rho"] ?? 0.5,
            depositionWidth: params.params["deposition_width"] ?? 0.1
        )
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        let empty = SourceTerms.zero(nCells: profiles.ionTemperature.shape[0])
        do {
            return try model.applyToSources(empty, profiles: profiles, geometry: geometry)
        } catch {
            print("⚠️  ECRH computation failed: \(error)")
            return empty
        }
    }
}
```

**Configuration Extension**:

```swift
// SourcesConfig.swift
public struct SourcesConfig: Codable, Sendable {
    // Existing
    public let ohmicHeating: Bool
    public let fusionPower: Bool
    public let ionElectronExchange: Bool
    public let bremsstrahlung: Bool

    // NEW
    public let ecrh: ECRHConfig?
    public let gasPuff: GasPuffConfig?
    public let impurityRadiation: ImpurityRadiationConfig?
}

public struct ECRHConfig: Codable, Sendable {
    public let enabled: Bool
    public let totalPower: Float        // [W]
    public let depositionRho: Float     // [0-1]
    public let depositionWidth: Float   // [0-1]
    public let launchAngle: Float?      // [degrees] (future: ray tracing)
    public let frequency: Float?        // [Hz] (future: absorption calc)
}
```

**Factory Extension**:

```swift
// SourceModelFactory.swift
public static func create(config: SourcesConfig) -> any SourceModel {
    var sources: [String: any SourceModel] = [:]

    // Existing sources...

    // NEW: ECRH
    if let ecrhConfig = config.ecrh, ecrhConfig.enabled {
        let params = SourceParameters(
            modelType: "ecrh",
            params: [
                "total_power": ecrhConfig.totalPower,
                "deposition_rho": ecrhConfig.depositionRho,
                "deposition_width": ecrhConfig.depositionWidth
            ]
        )
        sources["ecrh"] = try! ECRHSource(params: params)
    }

    return CompositeSourceModel(sources: sources)
}
```

**JSON Configuration**:

```json
{
  "dynamic": {
    "sources": {
      "ecrh": {
        "enabled": true,
        "totalPower": 20000000.0,
        "depositionRho": 0.5,
        "depositionWidth": 0.1,
        "launchAngle": 20.0,
        "frequency": 170000000000.0
      }
    }
  }
}
```

---

### 2.2 Gas Puff (Particle Fueling)

**Key Difference**: Returns particle source [m⁻³/s], NOT heating

**Implementation**:

```swift
// GotenxPhysics/Particles/GasPuffModel.swift
public struct GasPuffModel: Sendable {
    let puffRate: Float           // [particles/s] - total puffed per second
    let penetrationDepth: Float   // [dimensionless] - λ_n in ρ coordinates

    /// Compute gas puff particle source
    /// - Returns: Particle source density [m⁻³/s]
    public func compute(geometry: Geometry) -> MLXArray {
        let rho = geometry.rho.value
        let volumes = geometry.cellVolumes.value

        // Exponential penetration from edge
        let profile = exp(-(1.0 - rho) / penetrationDepth)

        // Normalize to total puff rate
        let integral = (profile * volumes).sum()
        let S_particles = puffRate * profile / (integral + 1e-10)  // [m⁻³/s]

        return S_particles
    }

    public func applyToSources(
        _ sources: SourceTerms,
        geometry: Geometry
    ) -> SourceTerms {
        let S = compute(geometry: geometry)
        let updated_particles = sources.particleSource.value + S

        return SourceTerms(
            ionHeating: sources.ionHeating,
            electronHeating: sources.electronHeating,
            particleSource: EvaluatedArray(evaluating: updated_particles),
            currentSource: sources.currentSource
        )
    }
}
```

**Units**:
- Input: `puffRate` [particles/s] (e.g., 1e21 for ITER)
- Output: `S_particles` [m⁻³/s] (volumetric source rate)
- **No MW/m³ conversion needed** - particles, not power

---

### 2.3 Impurity Radiation

**Key Point**: Negative heating (radiation loss)

**Implementation**:

```swift
// GotenxPhysics/Radiation/ImpurityRadiation.swift
public struct ImpurityRadiationModel: Sendable {
    let impurityFraction: Float  // n_imp / n_e
    let species: ImpuritySpecies

    public enum ImpuritySpecies: Sendable {
        case carbon
        case neon
        case argon
        case tungsten

        var adasCoefficients: [Float] {
            // Polynomial coefficients for L_z(T_e)
        }
    }

    /// Compute radiation power loss
    /// - Returns: Power loss [W/m³] (positive value)
    public func compute(
        ne: MLXArray,
        Te: MLXArray
    ) -> MLXArray {
        // L_z(T_e) from ADAS polynomial
        let log10_Te = log10(Te + 1.0)  // Avoid log(0)
        let coeffs = species.adasCoefficients

        var L_z = pow(10.0, coeffs[0])  // Base coefficient
        for (i, coeff) in coeffs.dropFirst().enumerated() {
            L_z = L_z + coeff * pow(log10_Te, Float(i + 1))
        }

        // P_rad = n_e × n_imp × L_z [W/m³]
        let n_imp = impurityFraction * ne
        let P_rad = ne * n_imp * L_z

        return P_rad
    }

    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles
    ) -> SourceTerms {
        let P_watts = compute(
            ne: profiles.electronDensity.value,
            Te: profiles.electronTemperature.value
        )
        let P_MW = P_watts / 1e6

        // Radiation reduces electron heating (negative source)
        let updated_electron = sources.electronHeating.value - P_MW

        return SourceTerms(
            ionHeating: sources.ionHeating,
            electronHeating: EvaluatedArray(evaluating: updated_electron),
            particleSource: sources.particleSource,
            currentSource: sources.currentSource
        )
    }
}
```

**Units**:
- L_z: [W⋅m³] (cooling rate coefficient from ADAS)
- P_rad: [W/m³] → [MW/m³] for SourceTerms
- **Applied as negative heating** (subtracts from electron heating)

---

## 3. Pedestal Model Integration

### 3.1 Architectural Challenge

**Problem**: Pedestal model doesn't fit the `SourceModel` pattern cleanly because:
1. It needs to apply **after** transport coefficient calculation
2. It modifies profiles **iteratively** during PDE solve
3. TORAX uses adaptive sources **inside solver loop**

**Current PedestalModel Protocol**:
```swift
protocol PedestalModel: PhysicsComponent {
    func computePedestal(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: [String: Float]
    ) -> PedestalOutput
}

struct PedestalOutput {
    let temperature: Float  // [eV]
    let density: Float      // [m⁻³]
    let width: Float        // [m]
}
```

**Issue**: This only returns **target values**, not adaptive sources!

### 3.2 Redesign Required

**Option A: Extend PedestalModel with Adaptive Source Method**

```swift
protocol PedestalModel: PhysicsComponent {
    // Existing
    func computePedestal(...) -> PedestalOutput

    // NEW: Compute adaptive sources
    func computeAdaptiveSources(
        profiles: CoreProfiles,
        geometry: Geometry,
        targets: PedestalOutput
    ) -> SourceTerms  // Returns MW/m³ like other sources
}
```

**Option B: Treat Pedestal as Special SourceModel**

```swift
// Pedestal conformsTo SourceModel directly
struct SimplePedestalModel: SourceModel, PedestalModel {
    let rhoPed: Float
    let width: Float
    let tPedIon: Float
    let tPedElectron: Float
    let nPed: Float
    let adaptiveGain: Float

    func computeTerms(...) -> SourceTerms {
        // Compute adaptive sources based on profile errors
        let mask = createPedestalMask(rho, rhoPed, width)
        let deltaT_i = (tPedIon - profiles.ionTemperature.value) * mask
        let deltaT_e = (tPedElectron - profiles.electronTemperature.value) * mask
        let delta_n = (nPed - profiles.electronDensity.value) * mask

        // S [MW/m³] or [m⁻³/s] proportional to error
        let S_ion_MW = adaptiveGain * deltaT_i / (volumes + 1e-10)
        let S_electron_MW = adaptiveGain * deltaT_e / (volumes + 1e-10)
        let S_particles = adaptiveGain * delta_n / (volumes + 1e-10)

        return SourceTerms(
            ionHeating: EvaluatedArray(evaluating: S_ion_MW),
            electronHeating: EvaluatedArray(evaluating: S_electron_MW),
            particleSource: EvaluatedArray(evaluating: S_particles),
            currentSource: .zeros([nCells])
        )
    }
}
```

**Recommendation**: **Option B** - Treat pedestal as SourceModel
- Simpler integration (uses existing CompositeSourceModel)
- Consistent with TORAX's "adaptive source" approach
- No special handling needed in solver

### 3.3 Adaptive Gain Selection

**Physical Interpretation**:
```
S_adaptive = gain × Δ / V

where:
- Δ = (target - current) [eV or m⁻³]
- V = volume [m³]
- S must have dimension [MW/m³] or [m⁻³/s]

For heating:
gain [MW⋅m³/eV] × [eV] / [m³] = [MW/m³] ✓

For particles:
gain [m³/s] × [m⁻³] / [m³] = [m⁻³/s] ✓
```

**Typical Values**:
- Heating gain: 10¹⁸ - 10²¹ [MW⋅m³/eV]
- Particle gain: 10²⁰ - 10²² [m³/s]

**Tuning Strategy**:
1. Start with low gain (10¹⁸)
2. Gradually increase until pedestal forms
3. If oscillations appear, reduce gain
4. Target response time ~10-100 timesteps

---

## 4. Integration into SimulationOrchestrator

### 4.1 Current Source Aggregation

**Location**: `SimulationOrchestrator.swift`

```swift
// Current implementation (simplified)
public actor SimulationOrchestrator {
    private let sources: [any SourceModel]  // Array of sources

    func performStep(dynamicParams: DynamicRuntimeParams) {
        // Compute transport coefficients
        let transport = self.transport.computeCoefficients(...)

        // Compute ALL sources (including pedestal if present)
        let allSources = computeAllSources(profiles, geometry, params)

        // Solve PDE with sources
        let newProfiles = solver.solve(
            profiles: profiles,
            transport: transport,
            sources: allSources,  // MW/m³ → converted in solver
            ...
        )
    }

    private func computeAllSources(...) -> SourceTerms {
        let composite = CompositeSourceModel(sources: self.sources)
        return composite.computeTerms(
            profiles: profiles,
            geometry: geometry,
            params: sourceParams
        )
    }
}
```

**With Pedestal**:
```swift
// Pedestal is just another source in the array!
public init(
    ...
    sources: [any SourceModel] = [],
    pedestalModel: (any SourceModel)? = nil  // Optional pedestal
) {
    var allSources = sources
    if let pedestal = pedestalModel {
        allSources.append(pedestal)  // Add to source list
    }
    self.sources = allSources
}
```

**No special handling needed** - pedestal is aggregated like any other source.

---

## 5. Testing Strategy

### 5.1 Unit Tests per Component

**ECRHModelTests.swift**:
```swift
@Test func testECRHPowerConservation() async throws {
    let model = ECRHModel(
        totalPower: 20e6,  // 20 MW
        depositionRho: 0.5,
        depositionWidth: 0.1
    )

    let geometry = Geometry(...)
    let profiles = CoreProfiles(...)

    let P_watts = model.compute(geometry: geometry, profiles: profiles)
    let volumes = geometry.cellVolumes.value
    let totalPower = (P_watts * volumes).sum().item(Float.self)

    // Should equal input power (within 1%)
    #expect(abs(totalPower - 20e6) / 20e6 < 0.01)
}

@Test func testECRHDepositionLocation() async throws {
    // Verify peak at specified rho
}
```

**GasPuffModelTests.swift**:
```swift
@Test func testGasPuffParticleConservation() async throws {
    let model = GasPuffModel(
        puffRate: 1e21,  // particles/s
        penetrationDepth: 0.1
    )

    let S = model.compute(geometry: geometry)
    let totalPuffed = (S * volumes).sum().item(Float.self)

    #expect(abs(totalPuffed - 1e21) / 1e21 < 0.01)
}
```

### 5.2 Integration Tests

**ITER Baseline Scenario**:
```swift
@Test func testITERBaselineWithNewSources() async throws {
    let config = SimulationConfiguration(
        runtime: RuntimeConfiguration(
            static: StaticConfig(...),
            dynamic: DynamicConfig(
                sources: SourcesConfig(
                    ohmicHeating: true,
                    fusionPower: true,
                    ecrh: ECRHConfig(
                        enabled: true,
                        totalPower: 20e6,
                        ...
                    ),
                    gasPuff: GasPuffConfig(
                        enabled: true,
                        puffRate: 1e21,
                        ...
                    ),
                    impurityRadiation: ImpurityRadiationConfig(
                        enabled: true,
                        species: "argon",
                        fraction: 0.01
                    )
                ),
                pedestal: PedestalConfig(
                    model: "simple",
                    rhoPed: 0.9,
                    width: 0.05,
                    tPedIon: 1000.0,
                    tPedElectron: 1000.0,
                    nPed: 5e19
                )
            )
        ),
        time: TimeConfiguration(end: 2.0),
        output: OutputConfiguration(...)
    )

    let result = try await runner.run(config: config)

    // Validation
    #expect(result.fusionGain > 9.0)  // Q ≥ 9
    #expect(result.pedestalPresent)   // H-mode feature
}
```

---

## 6. Implementation Checklist

### Phase 1: ECRH (2 days)

- [ ] Create `ECRHModel` in `GotenxPhysics/Heating/`
- [ ] Implement Gaussian deposition profile
- [ ] Power conservation validation
- [ ] Create `ECRHSource` adapter in `SourceModelAdapters.swift`
- [ ] Extend `ECRHConfig` in `SourcesConfig.swift`
- [ ] Add factory case in `SourceModelFactory.swift`
- [ ] Unit tests for power conservation
- [ ] Integration test with example config

### Phase 2: Gas Puff (1 day)

- [ ] Create `GasPuffModel` in `GotenxPhysics/Particles/`
- [ ] Implement exponential penetration
- [ ] Particle conservation validation
- [ ] Create `GasPuffSource` adapter
- [ ] Extend `GasPuffConfig`
- [ ] Add factory case
- [ ] Unit tests for particle conservation
- [ ] Density evolution test

### Phase 3: Impurity Radiation (2 days)

- [ ] Create `ImpurityRadiationModel` in `GotenxPhysics/Radiation/`
- [ ] Implement ADAS polynomial L_z(Te)
- [ ] Add species enum (carbon, neon, argon, tungsten)
- [ ] Create `ImpurityRadiationSource` adapter
- [ ] Extend `ImpurityRadiationConfig`
- [ ] Add factory case
- [ ] Unit tests for cooling rate
- [ ] Power balance test

### Phase 4: Pedestal Model (2 days)

- [ ] Create `SimplePedestalModel` conforming to both `PedestalModel` and `SourceModel`
- [ ] Implement Gaussian mask generation
- [ ] Implement adaptive source calculation
- [ ] Tune adaptive gain parameter
- [ ] Extend `PedestalConfig` with all parameters
- [ ] Integration into source aggregation
- [ ] Unit tests for mask shape
- [ ] H-mode profile test

### Phase 5: Integration & Validation (1 day)

- [ ] Create ITER baseline configuration JSON
- [ ] Run full scenario to t=2.0s
- [ ] Verify Q > 9, pedestal formation
- [ ] Compare with TORAX Python (if available)
- [ ] Profile plots and diagnostics
- [ ] Documentation update

---

## 7. Risk Mitigation

### 7.1 Unit Consistency Errors

**Risk**: Mixing MW/m³ and eV/(m³·s)

**Mitigation**:
- All physics models return W/m³ or MW/m³
- Conversion **only** in `Block1DCoeffsBuilder`
- Unit tests verify dimensions
- Add validation in SourceTerms constructor

### 7.2 Pedestal Oscillations

**Risk**: Adaptive gain too high → numerical instabilities

**Mitigation**:
- Start with low gain (10¹⁸)
- Implement gain auto-tuning based on convergence rate
- Add damping term: `S = gain × Δ × (1 - exp(-t/τ))`

### 7.3 Performance Degradation

**Risk**: Too many sources slow down simulation

**Mitigation**:
- CompositeSourceModel already aggregates efficiently
- Use MLX batch evaluation
- Profile GPU kernels if needed

---

## 8. Documentation Updates

### CLAUDE.md Corrections

**Section to Update**: "Unit System Standard"

**Current (Incorrect)**:
> All internal units are eV and m⁻³, matching CoreProfiles

**Corrected**:
> CoreProfiles and solver use eV and m⁻³. SourceTerms uses MW/m³ for heating (plasma physics standard), with conversion in Block1DCoeffsBuilder.

### New Documentation

- [ ] `ITER_SCENARIO_GUIDE.md`: How to configure ITER scenarios
- [ ] `SOURCE_MODELS.md`: Documentation of all source models
- [ ] `PEDESTAL_MODELS.md`: Pedestal model physics and tuning

---

## 9. Summary

**Architecture Compatibility**: ✅ Fully compatible
**Unit System**: ✅ Correctly understood
**Integration Complexity**: ✅ Low (uses existing patterns)
**Estimated Effort**: 7-8 days for P0 features

**Key Architectural Insights**:
1. SourceTerms uses MW/m³ (not eV/s as documented)
2. Conversion happens in Block1DCoeffsBuilder
3. Pedestal can be treated as SourceModel
4. CompositeSourceModel handles aggregation
5. No SimulationOrchestrator changes needed

**Implementation Ready**: Yes, with corrected understanding.

---

**Next Step**: Begin implementation with ECRH as prototype to validate architecture.
