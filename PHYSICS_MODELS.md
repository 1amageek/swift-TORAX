# swift-TORAX Physics Models Implementation Guide

**Date**: 2025-10-17
**Version**: 1.0
**Status**: Implementation Guide

---

## Table of Contents

1. [Overview](#overview)
2. [Package Structure](#package-structure)
3. [Phase 1: Essential Models](#phase-1-essential-models)
4. [Phase 2: Advanced Models](#phase-2-advanced-models)
5. [Implementation Examples](#implementation-examples)
6. [Testing Strategy](#testing-strategy)
7. [References](#references)

---

## Overview

This document provides detailed specifications for implementing physics models in swift-TORAX. Physics models are separated into a dedicated target (`TORAXPhysics`) to maintain clean architecture and enable independent testing.

**Coordinate System**: All models use normalized toroidal flux coordinate ρ̂ = √(ψ/ψ_edge), where ρ̂ ∈ [0, 1].

---

## Package Structure

### Recommended Package Organization

```
swift-TORAX/
├── Package.swift                  // Package manifest
├── Sources/
│   ├── TORAX/                    // Core solver (existing)
│   │   ├── Core/
│   │   ├── FVM/
│   │   ├── Solver/
│   │   └── ...
│   │
│   └── TORAXPhysics/             // Physics models (NEW TARGET)
│       ├── Heating/
│       │   ├── IonElectronExchange.swift
│       │   ├── OhmicHeating.swift
│       │   ├── FusionPower.swift
│       │   └── HeatingModels.swift
│       │
│       ├── Radiation/
│       │   ├── Bremsstrahlung.swift
│       │   ├── Cyclotron.swift
│       │   └── RadiationModels.swift
│       │
│       ├── Transport/
│       │   ├── TransportProtocol.swift
│       │   ├── ConstantTransport.swift
│       │   ├── BohmGyroBohm.swift
│       │   └── QLKNN/
│       │       ├── QLKNNModel.swift
│       │       ├── QLKNNPreprocessor.swift
│       │       ├── TurbulentFluxes.swift
│       │       └── Resources/
│       │
│       ├── Neoclassical/
│       │   ├── BootstrapCurrent.swift
│       │   ├── SauterModel.swift
│       │   └── CollisionalityModel.swift
│       │
│       ├── Pedestal/
│       │   ├── PedestalModel.swift
│       │   └── AdaptivePedestal.swift
│       │
│       ├── MHD/
│       │   ├── SawtoothModel.swift
│       │   ├── SafetyFactor.swift
│       │   └── MagneticShear.swift
│       │
│       ├── ParticleSources/
│       │   ├── GasPuff.swift
│       │   ├── PelletInjection.swift
│       │   └── ParticleSourceModels.swift
│       │
│       └── Utilities/
│           ├── PhysicsConstants.swift
│           ├── UnitConversions.swift
│           └── PlasmaParameters.swift
│
├── Tests/
│   ├── TORAXTests/              // Core solver tests
│   └── TORAXPhysicsTests/       // Physics model tests (NEW)
│       ├── HeatingTests/
│       ├── TransportTests/
│       └── IntegrationTests/
│
└── Resources/
    └── QLKNN/
        └── qlknn_weights.mlmodel
```

### Package.swift Configuration

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-TORAX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TORAX",
            targets: ["TORAX"]
        ),
        .library(
            name: "TORAXPhysics",
            targets: ["TORAXPhysics"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.18.0"),
    ],
    targets: [
        // Core solver target
        .target(
            name: "TORAX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),

        // Physics models target (depends on TORAX)
        .target(
            name: "TORAXPhysics",
            dependencies: [
                "TORAX",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            resources: [
                .copy("Resources")
            ]
        ),

        // Tests
        .testTarget(
            name: "TORAXTests",
            dependencies: ["TORAX"]
        ),
        .testTarget(
            name: "TORAXPhysicsTests",
            dependencies: ["TORAX", "TORAXPhysics"]
        ),
    ]
)
```

---

## Phase 1: Essential Models

### 1. Ion-Electron Heat Exchange

**File**: `Sources/TORAXPhysics/Heating/IonElectronExchange.swift`

#### Mathematical Formulation

```
Q_ie = (3/2) * (m_e/m_i) * n_e * ν_ei * (T_e - T_i)
```

Where collision frequency:
```
ν_ei = 2.91 × 10⁻⁶ * n_e * Z_eff * ln(Λ) / T_e^(3/2)
```

Coulomb logarithm:
```
ln(Λ) = 24 - ln(√(n_e[m⁻³]/10⁶) / T_e[eV])
```

#### Implementation

```swift
import MLX
import TORAX

/// Ion-electron collisional heat exchange model
///
/// Computes power density transferred from electrons to ions (or vice versa)
/// through Coulomb collisions.
///
/// Physical equation:
/// Q_ie = (3/2) * (m_e/m_i) * n_e * ν_ei * (T_e - T_i)
///
/// Units:
/// - Input: n_e [m⁻³], T_e [eV], T_i [eV]
/// - Output: Q_ie [W/m³] (positive = heating ions)
public struct IonElectronExchange: Sendable {

    /// Effective charge number
    public let Zeff: Float

    /// Ion mass in atomic mass units
    public let ionMass: Float

    /// Physical constants
    private let kB: Float = 1.602e-19      // eV to Joules
    private let me: Float = 9.109e-31      // electron mass [kg]
    private let mp: Float = 1.673e-27      // proton mass [kg]

    public init(Zeff: Float = 1.5, ionMass: Float = 2.014) {
        self.Zeff = Zeff
        self.ionMass = ionMass
    }

    /// Compute ion-electron heat exchange power density
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³], shape [nCells]
    ///   - Te: Electron temperature [eV], shape [nCells]
    ///   - Ti: Ion temperature [eV], shape [nCells]
    /// - Returns: Heat exchange power [W/m³], shape [nCells]
    ///            Positive = heating ions, Negative = heating electrons
    public func compute(
        ne: MLXArray,
        Te: MLXArray,
        Ti: MLXArray
    ) -> MLXArray {

        // Coulomb logarithm
        let lnLambda = 24.0 - log(sqrt(ne / 1e6) / Te)

        // Electron-ion collision frequency [Hz]
        let nu_ei = 2.91e-6 * ne * Zeff * lnLambda / pow(Te, 1.5)

        // Ion mass [kg]
        let mi = ionMass * mp

        // Exchange power density [W/m³]
        let Q_ie = (3.0/2.0) * (me/mi) * ne * nu_ei * kB * (Te - Ti)

        return Q_ie
    }
}

// MARK: - Source Model Protocol Conformance

extension IonElectronExchange {

    /// Apply heat exchange to source terms
    ///
    /// - Parameter sources: Source terms to modify
    /// - Returns: Modified source terms with heat exchange
    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles
    ) -> SourceTerms {

        let Q_ie = compute(
            ne: profiles.electronDensity.value,
            Te: profiles.electronTemperature.value,
            Ti: profiles.ionTemperature.value
        )

        // Modify source terms
        var newSources = sources
        newSources.ionHeating.value = sources.ionHeating.value + Q_ie
        newSources.electronHeating.value = sources.electronHeating.value - Q_ie

        return newSources
    }
}
```

#### Unit Tests

```swift
// Tests/TORAXPhysicsTests/HeatingTests/IonElectronExchangeTests.swift

import Testing
import MLX
@testable import TORAX
@testable import TORAXPhysics

@Test("Ion-electron exchange equilibration")
func testEquilibration() {
    let exchange = IonElectronExchange(Zeff: 1.5, ionMass: 2.014)

    let ne = MLXArray.full([100], values: MLXArray(5e19))
    var Te = MLXArray.full([100], values: MLXArray(10000.0))  // 10 keV
    var Ti = MLXArray.full([100], values: MLXArray(5000.0))   // 5 keV

    let dt: Float = 0.001  // 1 ms
    let nSteps = 1000

    for _ in 0..<nSteps {
        let Q_ie = exchange.compute(ne: ne, Te: Te, Ti: Ti)

        // Forward Euler
        Te = Te - dt * Q_ie / (ne * 1.602e-19)
        Ti = Ti + dt * Q_ie / (ne * 1.602e-19)
    }

    // Should equilibrate within 100 eV
    let diff = abs(Te - Ti).mean().item(Float.self)
    #expect(diff < 100.0)
}

@Test("Collision frequency scaling")
func testCollisionFrequency() {
    let exchange = IonElectronExchange()

    // ν_ei ∝ n_e / T_e^(3/2)

    // Double density → double collision frequency
    let ne1 = MLXArray([1e19])
    let ne2 = MLXArray([2e19])
    let Te = MLXArray([1000.0])
    let Ti = MLXArray([1000.0])

    let Q1 = exchange.compute(ne: ne1, Te: Te, Ti: Te + 100.0)
    let Q2 = exchange.compute(ne: ne2, Te: Te, Ti: Te + 100.0)

    let ratio = (Q2 / Q1).item(Float.self)
    #expect(abs(ratio - 2.0) < 0.1)  // Within 10%
}
```

---

### 2. Ohmic Heating

**File**: `Sources/TORAXPhysics/Heating/OhmicHeating.swift`

#### Mathematical Formulation

```
Q_ohm = η_∥ * j_∥²
```

Spitzer resistivity:
```
η_Spitzer = 5.2 × 10⁻⁵ * Z_eff * ln(Λ) / T_e^(3/2)  [Ω·m]
```

Neoclassical correction:
```
η_neo = η_Spitzer * (1 + ε^(3/2))
```

#### Implementation

```swift
import MLX
import TORAX

/// Ohmic heating model
///
/// Computes resistive heating power from plasma current:
/// Q_ohm = η_∥ * j_∥²
///
/// Uses Spitzer resistivity with optional neoclassical correction
/// for trapped particles.
public struct OhmicHeating: Sendable {

    /// Effective charge
    public let Zeff: Float

    /// Coulomb logarithm
    public let lnLambda: Float

    /// Apply neoclassical correction
    public let useNeoclassical: Bool

    public init(
        Zeff: Float = 1.5,
        lnLambda: Float = 17.0,
        useNeoclassical: Bool = true
    ) {
        self.Zeff = Zeff
        self.lnLambda = lnLambda
        self.useNeoclassical = useNeoclassical
    }

    /// Compute Ohmic heating power density
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV]
    ///   - jParallel: Parallel current density [A/m²]
    ///   - geometry: Tokamak geometry
    /// - Returns: Heating power [W/m³]
    public func compute(
        Te: MLXArray,
        jParallel: MLXArray,
        geometry: Geometry
    ) -> MLXArray {

        // Spitzer resistivity [Ω·m]
        let eta_Spitzer = 5.2e-5 * Zeff * lnLambda / pow(Te, 1.5)

        var eta = eta_Spitzer

        if useNeoclassical {
            // Trapped particle correction
            let epsilon = geometry.rCell.value / geometry.majorRadius
            let f_trap = 1.0 + pow(epsilon, 1.5)
            eta = eta * f_trap
        }

        // Ohmic power [W/m³]
        let Q_ohm = eta * jParallel * jParallel

        return Q_ohm
    }
}
```

---

### 3. Bremsstrahlung Radiation

**File**: `Sources/TORAXPhysics/Radiation/Bremsstrahlung.swift`

#### Mathematical Formulation

```
P_brems = -C_brems * n_e² * Z_eff * √T_e * (1 + f_rel)
```

Where:
```
C_brems = 5.35 × 10⁻³⁷  [W·m³·eV^(-1/2)]
f_rel = (T_e/511000) * (4√2 - 1) / π  (relativistic correction)
```

#### Implementation

```swift
import MLX
import TORAX

/// Bremsstrahlung radiation model
///
/// Free electrons radiating when deflected by ions.
/// Always a loss term (negative power).
///
/// P_brems = C * n_e² * Z_eff * √T_e * (1 + f_rel)
public struct Bremsstrahlung: Sendable {

    public let Zeff: Float
    public let includeRelativistic: Bool

    private let C_brems: Float = 5.35e-37  // W·m³·eV^(-1/2)

    public init(Zeff: Float = 1.5, includeRelativistic: Bool = true) {
        self.Zeff = Zeff
        self.includeRelativistic = includeRelativistic
    }

    /// Compute Bremsstrahlung radiation power
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Te: Electron temperature [eV]
    /// - Returns: Radiation power [W/m³] (negative = loss)
    public func compute(ne: MLXArray, Te: MLXArray) -> MLXArray {

        var f_rel = MLXArray.zeros(like: Te)

        if includeRelativistic {
            // Only apply for Te > 1 keV
            let mask = Te > 1000.0
            f_rel = mask * (Te / 511000.0) * (4.0 * sqrt(2.0) - 1.0) / Float.pi
        }

        // Bremsstrahlung power (negative = loss)
        let P_brems = -C_brems * ne * ne * Zeff * sqrt(Te) * (1.0 + f_rel)

        return P_brems
    }
}
```

---

### 4. Fusion Power

**File**: `Sources/TORAXPhysics/Heating/FusionPower.swift`

#### Mathematical Formulation

D-T reaction: D + T → He⁴ (3.5 MeV) + n (14.1 MeV)

```
P_fusion = (n_e²/4) * ⟨σv⟩(T_i) * E_alpha
```

Bosch-Hale parameterization for ⟨σv⟩(T_i).

#### Implementation

```swift
import MLX
import TORAX

/// Fusion power model for D-T reactions
///
/// Computes alpha particle heating power from fusion reactions.
/// Uses Bosch-Hale parameterization for reactivity.
public struct FusionPower: Sendable {

    /// Fuel mixture
    public enum FuelMixture {
        case equalDT        // 50-50 D-T
        case custom(nD_frac: Float, nT_frac: Float)
    }

    public let fuelMix: FuelMixture
    public let alphaEnergy: Float  // MeV

    // Bosch-Hale coefficients for D-T
    private let C1: Float = 1.17302e-9
    private let C2: Float = 1.51361e-2
    private let C3: Float = 7.51886e-2
    private let C4: Float = 4.60643e-3
    private let C5: Float = 1.35000e-2
    private let C6: Float = -1.06750e-4
    private let C7: Float = 1.36600e-5
    private let BG: Float = 34.3827  // Gamow constant

    public init(
        fuelMix: FuelMixture = .equalDT,
        alphaEnergy: Float = 3.5  // MeV
    ) {
        self.fuelMix = fuelMix
        self.alphaEnergy = alphaEnergy
    }

    /// Compute fusion power density
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Ti: Ion temperature [eV]
    /// - Returns: Fusion power [W/m³]
    public func compute(ne: MLXArray, Ti: MLXArray) -> MLXArray {

        let Ti_keV = Ti / 1000.0

        // Bosch-Hale reactivity calculation
        let numerator = Ti_keV * (C2 + Ti_keV * (C4 + Ti_keV * C6))
        let denominator = 1.0 + Ti_keV * (C3 + Ti_keV * (C5 + Ti_keV * C7))
        let theta = Ti_keV / (1.0 - numerator / denominator)

        let xi = pow(BG * BG / (4.0 * theta), 1.0/3.0)

        let mrc2: Float = 1124656.0  // Reduced mass * c² [keV]
        let sigma_v = C1 * theta * sqrt(xi / (mrc2 * Ti_keV))
                      * exp(-3.0 * pow(xi, 1.0/3.0))

        // Fuel densities
        let nD: MLXArray
        let nT: MLXArray

        switch fuelMix {
        case .equalDT:
            nD = ne / 2.0
            nT = ne / 2.0
        case .custom(let fD, let fT):
            nD = ne * fD
            nT = ne * fT
        }

        // Fusion power [W/m³]
        let E_alpha_J = alphaEnergy * 1e6 * 1.602e-19  // MeV to Joules
        let P_fusion = nD * nT * sigma_v * E_alpha_J

        return P_fusion
    }
}
```

#### Unit Test

```swift
@Test("Fusion reactivity peak at 70 keV")
func testFusionPeak() {
    let fusion = FusionPower()

    let ne = MLXArray([1e20])
    let Ti_range = MLXArray(stride(from: 1.0, through: 100.0, by: 1.0)) * 1000.0

    var powers: [Float] = []
    for Ti in Ti_range {
        let P = fusion.compute(ne: ne, Ti: MLXArray([Ti.item(Float.self)]))
        powers.append(P.item(Float.self))
    }

    let peakIdx = powers.enumerated().max(by: { $0.1 < $1.1 })!.0
    let peakTi_keV = Float(peakIdx + 1)

    // Peak should be around 70 keV
    #expect(abs(peakTi_keV - 70.0) < 15.0)
}
```

---

### 5. Bootstrap Current (Sauter Model)

**File**: `Sources/TORAXPhysics/Neoclassical/BootstrapCurrent.swift`

#### Mathematical Formulation

```
j_bs = σ_bs * (L31 * ∇p_e/p_e + L32 * ∇n_e/n_e + L34 * ∇T_e/T_e)
```

Sauter coefficients L31, L32, L34 depend on:
- Trapped fraction: f_trap
- Collisionality: ν*
- Geometry: ε = r/R₀

#### Implementation

```swift
import MLX
import TORAX

/// Bootstrap current using Sauter model
///
/// Reference: Sauter et al., Physics of Plasmas 6(7), 2834-2839 (1999)
///
/// Computes self-generated toroidal current from pressure gradients
/// and trapped particles.
public struct SauterBootstrapModel: Sendable {

    public let Zeff: Float
    public let lnLambda: Float

    public init(Zeff: Float = 1.5, lnLambda: Float = 17.0) {
        self.Zeff = Zeff
        self.lnLambda = lnLambda
    }

    /// Compute bootstrap current density
    ///
    /// - Parameters:
    ///   - profiles: Core plasma profiles
    ///   - geometry: Tokamak geometry
    ///   - q: Safety factor
    /// - Returns: Bootstrap current density [A/m²]
    public func compute(
        profiles: CoreProfiles,
        geometry: Geometry,
        q: MLXArray
    ) -> MLXArray {

        let ne = profiles.electronDensity.value
        let Te = profiles.electronTemperature.value
        let Ti = profiles.ionTemperature.value

        let R0 = geometry.majorRadius
        let r = geometry.rCell.value
        let epsilon = r / R0
        let sqrt_eps = sqrt(epsilon)

        // Trapped particle fraction
        let f_trap = 1.46 * sqrt_eps / (1.0 + 0.46 * sqrt_eps)

        // Collisionality
        let nu_star = 6.921e-18 * q * R0 * ne * Zeff * lnLambda
                      / (Te * Te * pow(epsilon, 1.5))

        // Sauter F-functions (simplified fits)
        let F31 = computeF31(nu_star: nu_star, epsilon: epsilon)
        let F32_eff = computeF32_eff(nu_star: nu_star, epsilon: epsilon)
        let F32_ee = computeF32_ee(nu_star: nu_star, epsilon: epsilon)

        // Sauter L-coefficients
        let L31 = ((1.0 + 0.15 / (f_trap * f_trap)) * F31
                   + 0.4 / (1.0 + 0.5 * Zeff) * sqrt_eps * F32_eff / (f_trap * f_trap))
                  / (1.0 + 0.7 * sqrt(Zeff - 1.0))

        let L32 = (1.0 + 0.15 / (f_trap * f_trap)) * F32_ee / f_trap
        let L34 = -F32_ee / f_trap

        // Compute gradients
        let grad_pe = computeGradient(ne * Te, geometry: geometry)
        let grad_ne = computeGradient(ne, geometry: geometry)
        let grad_Te = computeGradient(Te, geometry: geometry)

        let pe = ne * Te * 1.602e-19  // Pressure [Pa]

        // Bootstrap current [A/m²]
        let j_bs = L31 * grad_pe / (pe + 1e-10)
                 + L32 * grad_ne / (ne + 1e-10)
                 + L34 * grad_Te / (Te + 1e-10)

        // Multiply by conductivity factor
        let sigma_factor = computeConductivityFactor(Te: Te, ne: ne, B: geometry.toroidalField)

        return sigma_factor * j_bs
    }

    // MARK: - Private Helpers

    private func computeF31(nu_star: MLXArray, epsilon: MLXArray) -> MLXArray {
        let sqrt_eps = sqrt(epsilon)
        let F31_banana = sqrt_eps * (0.75 + 0.25 * nu_star)
        let F31_plateau = epsilon / (1.0 + 0.5 * nu_star)
        return F31_banana * exp(-nu_star) + F31_plateau * (1.0 - exp(-nu_star))
    }

    private func computeF32_eff(nu_star: MLXArray, epsilon: MLXArray) -> MLXArray {
        let sqrt_eps = sqrt(epsilon)
        return sqrt_eps * (1.0 + nu_star) / pow(1.0 + 0.15 * nu_star, 2)
    }

    private func computeF32_ee(nu_star: MLXArray, epsilon: MLXArray) -> MLXArray {
        let sqrt_eps = sqrt(epsilon)
        return (0.05 + 0.62 * Zeff) / (Zeff * Zeff) * (sqrt_eps / (1.0 + 0.44 * nu_star))
    }

    private func computeGradient(_ field: MLXArray, geometry: Geometry) -> MLXArray {
        // Central difference
        let dr = geometry.rCell.value[1..<field.shape[0]] - geometry.rCell.value[0..<(field.shape[0]-1)]
        let df = field[1..<field.shape[0]] - field[0..<(field.shape[0]-1)]
        let grad_interior = df / (dr + 1e-10)

        // Boundary handling
        let grad_left = grad_interior[0..<1]
        let grad_right = grad_interior[(field.shape[0]-2)..<(field.shape[0]-1)]

        return concatenated([grad_left, grad_interior, grad_right], axis: 0)
    }

    private func computeConductivityFactor(Te: MLXArray, ne: MLXArray, B: Float) -> MLXArray {
        // Simplified conductivity factor
        return ne * pow(Te, 1.5) / (B * B + 1e-10)
    }
}
```

---

## Phase 2: Advanced Models

### QLKNN Transport Model

**File**: `Sources/TORAXPhysics/Transport/QLKNN/QLKNNModel.swift`

Implementation strategy:

**Option 1: CoreML (Recommended)**
- Convert Python QLKNN weights to CoreML format
- Use `MLModel` for inference
- Optimized for Apple Silicon

**Option 2: MLX Neural Network**
- Load weights directly
- Implement forward pass in Swift
- More portable but slower

**Directory structure for QLKNN**:
```
Sources/TORAXPhysics/Transport/QLKNN/
├── QLKNNModel.swift              // Main model interface
├── QLKNNPreprocessor.swift       // Input normalization
├── QLKNNPostprocessor.swift      // Output denormalization
├── TurbulentFluxes.swift         // Output data structures
├── GyroBohmUnits.swift           // Unit conversions
└── Resources/
    ├── qlknn_weights.mlmodel     // CoreML model (50 MB)
    ├── input_stats.json          // Normalization statistics
    └── output_stats.json         // Denormalization statistics
```

Detailed implementation in separate document due to complexity.

---

## Testing Strategy

### Unit Tests

Each physics model should have comprehensive unit tests:

```swift
// Tests/TORAXPhysicsTests/

// 1. Dimensional analysis
@Test("Ohmic heating units")
func testOhmicHeatingUnits() {
    // Verify output has correct units [W/m³]
}

// 2. Physical limits
@Test("Fusion power temperature scaling")
func testFusionScaling() {
    // Verify P_fusion ∝ n² * ⟨σv⟩(T)
}

// 3. Conservation laws
@Test("Ion-electron exchange conservation")
func testExchangeConservation() {
    // Verify S_i + S_e = 0
}

// 4. Known solutions
@Test("Bootstrap current analytic")
func testBootstrapAnalytic() {
    // Compare with known analytic solutions
}
```

### Integration Tests

```swift
// Tests/TORAXPhysicsTests/IntegrationTests/

@Test("Full physics integration")
func testFullPhysicsSimulation() {
    // Run complete simulation with all models
    // Verify energy balance
    // Check against Python TORAX
}
```

### Benchmark Tests

```swift
@Test("QLKNN performance")
func testQLKNNPerformance() {
    // Measure inference time
    // Target: < 1 ms per radial point
}
```

---

## References

### Key Papers

1. **Sauter et al.** (1999). "Neoclassical conductivity and bootstrap current". *Phys. Plasmas* 6(7), 2834.
2. **Bosch & Hale** (1992). "Fusion cross-sections". *Nucl. Fusion* 32(4), 611.
3. **QLKNN**: Van de Plassche et al. (2020). *Phys. Plasmas* 27(2), 022310.
4. **Wesson** (2011). *Tokamaks*, 4th ed. Oxford University Press.

### TORAX Documentation

- GitHub: https://github.com/google-deepmind/torax
- Docs: https://torax.readthedocs.io/

---

**Implementation Roadmap**:

**Week 1-2**: Phase 1 models (IonElectronExchange, OhmicHeating, Bremsstrahlung, FusionPower)
**Week 3-4**: Bootstrap current + basic transport models
**Month 2-3**: QLKNN implementation (most complex)
**Month 4**: Integration testing + validation against Python TORAX

---

**Next Steps**:
1. Update `Package.swift` with `TORAXPhysics` target
2. Create directory structure
3. Implement Phase 1 models with tests
4. Validate against analytic solutions
