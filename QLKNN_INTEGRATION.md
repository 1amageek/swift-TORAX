# QLKNN Transport Model Integration Plan

**Project**: swift-Gotenx
**Integration Target**: swift-fusion-surrogates (QLKNN neural network transport model)
**Date**: 2025-10-18
**Status**: Design Phase

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Design](#architecture-design)
3. [Implementation Phases](#implementation-phases)
4. [Technical Specifications](#technical-specifications)
5. [Testing Strategy](#testing-strategy)
6. [Deployment and Configuration](#deployment-and-configuration)
7. [Troubleshooting Guide](#troubleshooting-guide)
8. [Future Extensions](#future-extensions)

---

## Overview

### Objective

Integrate the QLKNN (QuaLiKiz Neural Network) turbulent transport model from `swift-fusion-surrogates` into swift-Gotenx to enable high-fidelity, GPU-accelerated transport coefficient predictions for tokamak plasma simulations.

### Background

**QLKNN** is a neural network surrogate model trained on QuaLiKiz gyrokinetic simulations that predicts turbulent transport coefficients across ITG (Ion Temperature Gradient), TEM (Trapped Electron Mode), and ETG (Electron Temperature Gradient) instabilities.

**Current State**:
- swift-Gotenx has `TransportModel` protocol with `ConstantTransportModel` and `BohmGyroBohmTransportModel`
- `TransportModelType.qlknn` is defined but not implemented (placeholder)
- swift-fusion-surrogates provides QLKNN wrapper with MLXArray support

**Goal**: Implement `QLKNNTransportModel` conforming to `TransportModel` protocol

### Benefits

1. **Physics Fidelity**: Neural network trained on gyrokinetic simulations (higher accuracy than empirical models)
2. **GPU Acceleration**: MLX-native computation with 10-100× speedup over CPU
3. **Multi-Mode Predictions**: Separate ITG/TEM/ETG contributions
4. **Validated Model**: Based on Google DeepMind's TORAX implementation
5. **Type Safety**: Swift wrapper maintains compile-time safety

---

## Architecture Design

### 1. Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    swift-Gotenx Simulation                        │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │            SimulationOrchestrator                         │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                          │
│                       ▼                                          │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │         TransportModel Protocol                           │  │
│  │  ┌──────────────┬──────────────┬──────────────────────┐  │  │
│  │  │  Constant    │ BohmGyroBohm │  QLKNNTransportModel │  │  │
│  │  │              │              │  (NEW)               │  │  │
│  │  └──────────────┴──────────────┴──────────────────────┘  │  │
│  └──────────────────────────────────┬───────────────────────┘  │
│                                      │                           │
└──────────────────────────────────────┼───────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────┐
│              swift-fusion-surrogates Package                     │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  QLKNN (Python wrapper)                                   │  │
│  │    - PythonKit bridge                                     │  │
│  │    - MLXArray conversion                                  │  │
│  │    - fusion_surrogates.models.QLKNNModel                 │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  TORAXIntegration                                         │  │
│  │    - combineFluxes()                                      │  │
│  │    - Mode-specific → Total coefficients                   │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Python: fusion_surrogates                      │
│                   (Google DeepMind)                              │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Data Flow

```
CoreProfiles (Ti, Te, ne, psi)  +  Geometry
         │
         ▼
┌────────────────────────────────────────────────────┐
│  QLKNNInputBuilder                                  │
│  1. Compute gradients: ∇Ti, ∇Te, ∇ne              │
│  2. Normalize: a/LT = -a(∇T/T), a/Ln = -a(∇n/n)   │
│  3. Compute physics parameters:                     │
│     - q (safety factor)                            │
│     - smag (magnetic shear)                        │
│     - x (inverse aspect ratio)                     │
│     - Ti_Te, LogNuStar, normni                     │
└────────────────────────────────────────────────────┘
         │
         ▼
10 normalized parameters as MLXArray (batch)
         │
         ▼
┌────────────────────────────────────────────────────┐
│  QLKNN.predict()                                    │
│  (swift-fusion-surrogates)                          │
│  - MLXArray → numpy (PythonKit)                    │
│  - Neural network inference                         │
│  - numpy → MLXArray                                │
└────────────────────────────────────────────────────┘
         │
         ▼
8 mode-specific fluxes as MLXArray
         │
         ▼
┌────────────────────────────────────────────────────┐
│  combineFluxes()                                    │
│  - chi_ion = efiITG + efiTEM                       │
│  - chi_electron = efeITG + efeTEM + efeETG         │
│  - particle_diffusivity = pfeITG + pfeTEM          │
│  - convection_velocity = 0 (pinch not modeled)     │
└────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────┐
│  Wrap in EvaluatedArray                            │
│  (guarantee eval() before crossing actor boundary)  │
└────────────────────────────────────────────────────┘
         │
         ▼
TransportCoefficients (Sendable)
```

### 3. New Components

#### A. `QLKNNTransportModel.swift`

**Location**: `Sources/Gotenx/Transport/Models/QLKNNTransportModel.swift`

**Purpose**: Conform to `TransportModel` protocol, coordinate QLKNN predictions

**Key Methods**:
```swift
public struct QLKNNTransportModel: TransportModel {
    private let qlknn: QLKNN  // swift-fusion-surrogates
    private let modelName: String

    public init(modelName: String = "qlknn_7_11_v1", pythonPath: String? = nil) throws

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients
}
```

**Error Handling**:
- Python import failures
- Invalid input parameters (NaN, Inf)
- Shape mismatches
- QLKNN prediction errors

#### B. `QLKNNInputBuilder.swift`

**Location**: `Sources/Gotenx/Transport/QLKNN/QLKNNInputBuilder.swift`

**Purpose**: Transform `CoreProfiles` + `Geometry` → QLKNN normalized inputs

**Key Functions**:

```swift
public struct QLKNNInputBuilder {
    /// Build all 10 QLKNN input parameters
    public static func buildInputs(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) throws -> [String: MLXArray]

    /// Compute normalized temperature gradient: a/LT = -a(∇T/T)
    private static func computeNormalizedGradient(
        profile: EvaluatedArray,
        geometry: Geometry
    ) -> MLXArray

    /// Compute safety factor profile
    private static func computeSafetyFactor(
        psi: MLXArray,
        geometry: Geometry
    ) -> MLXArray

    /// Compute magnetic shear: s = (r/q)(dq/dr)
    private static func computeMagneticShear(
        q: MLXArray,
        r: MLXArray
    ) -> MLXArray

    /// Compute collisionality: ν* = (q R / ε^1.5) * (m_e / m_i)^0.5 * Z_eff * ne * λ_ei / Te^2
    private static func computeCollisionality(
        ne: MLXArray,
        Te: MLXArray,
        geometry: Geometry
    ) -> MLXArray
}
```

**Input Parameters** (QLKNN API v2.0):

| Parameter | Description | Normalization |
|-----------|-------------|---------------|
| `Ati` | Ion temperature gradient | `-a(∇Ti/Ti)` |
| `Ate` | Electron temperature gradient | `-a(∇Te/Te)` |
| `Ane` | Electron density gradient | `-a(∇ne/ne)` |
| `Ani` | Ion density gradient | `-a(∇ni/ni)` (assume = Ane) |
| `q` | Safety factor | Direct from equilibrium |
| `smag` | Magnetic shear | `(r/q)(dq/dr)` |
| `x` | Inverse aspect ratio | `r/R` |
| `Ti_Te` | Temperature ratio | `Ti/Te` |
| `LogNuStar` | Log collisionality | `log10(ν*)` |
| `normni` | Normalized ion density | `ni/ne` (assume = 1 for now) |

#### C. `Geometry+QLKNN.swift`

**Location**: `Sources/Gotenx/Extensions/Geometry+QLKNN.swift`

**Purpose**: QLKNN-specific geometry calculations

```swift
extension Geometry {
    /// Compute safety factor profile from poloidal flux
    /// q(r) = (r * Bt) / (R * Bp)
    public func computeSafetyFactor(psi: MLXArray) -> MLXArray

    /// Compute magnetic shear profile
    /// s = (r/q)(dq/dr)
    public func computeMagneticShear(q: MLXArray, r: MLXArray) -> MLXArray

    /// Compute inverse aspect ratio profile
    /// x(r) = r / R
    public func inverseAspectRatio() -> MLXArray

    /// Compute electron-ion collision frequency
    public func computeCollisionality(
        ne: MLXArray,
        Te: MLXArray,
        Ti: MLXArray,
        Zeff: Float = 1.0
    ) -> MLXArray
}
```

### 4. Configuration Extensions

#### `TransportConfig.swift`

**Changes**:
```swift
public struct TransportConfig: Codable, Sendable, Equatable {
    public let modelType: String
    public let parameters: [String: Float]

    // QLKNN-specific configuration
    public let qlknnModelName: String?       // Default: "qlknn_7_11_v1"
    public let pythonPath: String?           // Custom Python path (optional)
    public let enableQlknnCaching: Bool?     // Cache predictions (default: true)

    public init(
        modelType: String,
        parameters: [String: Float] = [:],
        qlknnModelName: String? = nil,
        pythonPath: String? = nil,
        enableQlknnCaching: Bool? = nil
    ) {
        self.modelType = modelType
        self.parameters = parameters
        self.qlknnModelName = qlknnModelName
        self.pythonPath = pythonPath
        self.enableQlknnCaching = enableQlknnCaching
    }
}
```

**Example JSON Configuration**:
```json
{
  "transport": {
    "modelType": "qlknn",
    "qlknnModelName": "qlknn_7_11_v1",
    "pythonPath": "/opt/homebrew/bin/python3",
    "enableQlknnCaching": true
  }
}
```

#### `TransportModelFactory.swift`

**Changes**:
```swift
case .qlknn:
    let modelName = config.qlknnModelName ?? "qlknn_7_11_v1"
    let pythonPath = config.pythonPath

    do {
        return try QLKNNTransportModel(
            modelName: modelName,
            pythonPath: pythonPath
        )
    } catch {
        throw ConfigurationError.initializationFailed(
            component: "QLKNNTransportModel",
            reason: "Failed to initialize QLKNN: \(error.localizedDescription)"
        )
    }
```

**Remove**: `throw ConfigurationError.notImplemented(...)` for `.qlknn` case

---

## Implementation Phases

### Phase 1: Dependencies and Build Environment

**Goal**: Add swift-fusion-surrogates dependency and verify build

**Tasks**:

1. **Update Package.swift**
   - Add swift-fusion-surrogates dependency
   - Add FusionSurrogates to TORAX target dependencies
   - Resolve PythonKit transitive dependency

2. **Environment Setup**
   - Document Python 3.12+ requirement
   - Document `pip install fusion-surrogates` requirement
   - Create environment validation script

3. **Build Verification**
   - Run `swift build` and resolve any conflicts
   - Verify PythonKit links correctly
   - Test import of FusionSurrogates in Swift

**Acceptance Criteria**:
- ✅ `swift build` succeeds
- ✅ `import FusionSurrogates` works in Swift code
- ✅ Python environment with fusion_surrogates is documented

**Estimated Time**: 1-2 hours

---

### Phase 2: Core Implementation

**Goal**: Implement QLKNNInputBuilder, Geometry extensions, and QLKNNTransportModel

#### Task 2.1: Gradient Computation

**File**: `Sources/Gotenx/Transport/QLKNN/GradientComputation.swift`

**Implementation**:

```swift
import MLX

/// Finite difference gradient computation for FVM grids
public struct GradientComputation {
    /// Compute radial gradient using 2nd-order central differences
    /// Interior points: ∇f = (f[i+1] - f[i-1]) / (r[i+1] - r[i-1])
    /// Boundaries: One-sided differences
    public static func computeRadialGradient(
        _ field: MLXArray,
        radii: MLXArray
    ) -> MLXArray {
        let n = field.shape[0]
        var gradient = MLXArray.zeros(like: field)

        // Interior points: central difference
        for i in 1..<(n-1) {
            gradient[i] = (field[i+1] - field[i-1]) / (radii[i+1] - radii[i-1])
        }

        // Left boundary: forward difference
        gradient[0] = (field[1] - field[0]) / (radii[1] - radii[0])

        // Right boundary: backward difference
        gradient[n-1] = (field[n-1] - field[n-2]) / (radii[n-1] - radii[n-2])

        return gradient
    }

    /// Compute normalized gradient: a/LT = -a(∇T/T)
    public static func normalizedGradient(
        profile: MLXArray,
        radii: MLXArray,
        minorRadius: Float
    ) -> MLXArray {
        let gradient = computeRadialGradient(profile, radii: radii)
        return -(minorRadius * gradient) / profile
    }
}
```

**Tests**:
- Test with linear profile (∇T = constant)
- Test with exponential profile (a/LT = constant)
- Test boundary conditions
- Test with Gotenx-like grid spacing

#### Task 2.2: Geometry Extensions

**File**: `Sources/Gotenx/Extensions/Geometry+QLKNN.swift`

**Implementation**:

```swift
import MLX
import Numerics

extension Geometry {
    /// Compute safety factor profile from poloidal flux
    /// For circular geometry: q(ψ) ≈ (r²B_t) / (R B_p)
    /// Simplified: q(r) ≈ q₀ + (q_edge - q₀)(r/a)²
    public func computeSafetyFactor(
        _ psi: MLXArray,
        q0: Float = 1.0,
        qEdge: Float = 3.5
    ) -> MLXArray {
        let rNorm = grid.cellCenters / minorRadius
        return q0 + (qEdge - q0) * pow(rNorm, 2)
    }

    /// Compute magnetic shear: s = (r/q)(dq/dr)
    public func computeMagneticShear(
        _ q: MLXArray
    ) -> MLXArray {
        let r = grid.cellCenters
        let dqdr = GradientComputation.computeRadialGradient(q, radii: r)
        return (r / q) * dqdr
    }

    /// Compute inverse aspect ratio: x = r/R
    public func inverseAspectRatio() -> MLXArray {
        return grid.cellCenters / majorRadius
    }

    /// Compute collisionality: ν* (dimensionless)
    /// ν* = (q R / ε^1.5) * C * ne * log(Λ) / Te^2
    /// where C = e^4 / (4π ε₀² m_e^0.5)
    public func computeCollisionality(
        ne: MLXArray,  // [m^-3]
        Te: MLXArray,  // [eV]
        Ti: MLXArray,  // [eV]
        Zeff: Float = 1.0
    ) -> MLXArray {
        let epsilon = grid.cellCenters / majorRadius
        let q = computeSafetyFactor(MLXArray.zeros([grid.nCells]))  // Simplified

        // Coulomb logarithm: log(Λ) ≈ 15.2 - 0.5*log(ne/1e20) + log(Te/1000)
        let logLambda = 15.2 - 0.5 * log(ne / 1e20) + log(Te / 1000.0)

        // Collision frequency constant
        let C: Float = 6.92e-15  // [m^3 eV^2 / s]

        let nuStar = (q * majorRadius / pow(epsilon, 1.5))
                   * C * Zeff * ne * logLambda / pow(Te, 2)

        return log10(nuStar)  // Return log10(ν*)
    }
}
```

**Tests**:
- Test q(r) profile shape (monotonic increase)
- Test shear calculation (finite differences)
- Test collisionality scaling (∝ ne, ∝ 1/Te²)

#### Task 2.3: QLKNNInputBuilder

**File**: `Sources/Gotenx/Transport/QLKNN/QLKNNInputBuilder.swift`

**Implementation**:

```swift
import MLX
import Foundation

/// Build QLKNN input parameters from CoreProfiles and Geometry
public struct QLKNNInputBuilder {
    /// Build all 10 QLKNN input parameters
    public static func buildInputs(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) throws -> [String: MLXArray] {
        // Extract profiles
        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value

        let r = geometry.grid.cellCenters
        let a = geometry.minorRadius

        // 1. Normalized gradients
        let Ati = GradientComputation.normalizedGradient(
            profile: Ti, radii: r, minorRadius: a
        )
        let Ate = GradientComputation.normalizedGradient(
            profile: Te, radii: r, minorRadius: a
        )
        let Ane = GradientComputation.normalizedGradient(
            profile: ne, radii: r, minorRadius: a
        )
        let Ani = Ane  // Assume quasi-neutrality

        // 2. Safety factor and shear
        let q = geometry.computeSafetyFactor(profiles.poloidalFlux.value)
        let smag = geometry.computeMagneticShear(q)

        // 3. Geometric parameters
        let x = geometry.inverseAspectRatio()

        // 4. Temperature ratio
        let Ti_Te = Ti / Te

        // 5. Collisionality
        let LogNuStar = geometry.computeCollisionality(
            ne: ne, Te: Te, Ti: Ti
        )

        // 6. Ion density ratio (assume single ion species)
        let normni = MLXArray.ones([geometry.grid.nCells])

        // Validation
        try validateInputs([
            "Ati": Ati, "Ate": Ate, "Ane": Ane, "Ani": Ani,
            "q": q, "smag": smag, "x": x,
            "Ti_Te": Ti_Te, "LogNuStar": LogNuStar, "normni": normni
        ])

        return [
            "Ati": Ati, "Ate": Ate, "Ane": Ane, "Ani": Ani,
            "q": q, "smag": smag, "x": x,
            "Ti_Te": Ti_Te, "LogNuStar": LogNuStar, "normni": normni
        ]
    }

    /// Validate QLKNN inputs (no NaN/Inf, physical ranges)
    private static func validateInputs(_ inputs: [String: MLXArray]) throws {
        for (name, array) in inputs {
            // Check for NaN/Inf
            if any(isnan(array)).item(Bool.self) {
                throw QLKNNError.invalidInput(
                    parameter: name,
                    reason: "Contains NaN values"
                )
            }
            if any(isinf(array)).item(Bool.self) {
                throw QLKNNError.invalidInput(
                    parameter: name,
                    reason: "Contains Inf values"
                )
            }

            // Physical range checks (QLKNN training domain)
            switch name {
            case "Ati", "Ate", "Ane", "Ani":
                // Gradients typically in range [0, 20]
                if any(array .< 0).item(Bool.self) || any(array .> 20).item(Bool.self) {
                    print("Warning: \(name) outside typical range [0, 20]")
                }
            case "q":
                // Safety factor typically in range [1, 10]
                if any(array .< 0.5).item(Bool.self) || any(array .> 20).item(Bool.self) {
                    throw QLKNNError.invalidInput(
                        parameter: name,
                        reason: "q outside valid range [0.5, 20]"
                    )
                }
            case "x":
                // Inverse aspect ratio in range [0, 1]
                if any(array .< 0).item(Bool.self) || any(array .> 1).item(Bool.self) {
                    throw QLKNNError.invalidInput(
                        parameter: name,
                        reason: "x (r/R) outside valid range [0, 1]"
                    )
                }
            default:
                break
            }
        }
    }
}

/// QLKNN-specific errors
public enum QLKNNError: LocalizedError {
    case invalidInput(parameter: String, reason: String)
    case predictionFailed(reason: String)
    case pythonInteropError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let param, let reason):
            return "Invalid QLKNN input parameter '\(param)': \(reason)"
        case .predictionFailed(let reason):
            return "QLKNN prediction failed: \(reason)"
        case .pythonInteropError(let reason):
            return "Python interop error: \(reason)"
        }
    }
}
```

**Tests**:
- Test input generation from synthetic profiles
- Test validation (reject NaN, Inf)
- Test physical range warnings
- Test all 10 parameters present

#### Task 2.4: QLKNNTransportModel

**File**: `Sources/Gotenx/Transport/Models/QLKNNTransportModel.swift`

**Implementation**:

```swift
import MLX
import Foundation
import FusionSurrogates

/// QLKNN neural network transport model
public struct QLKNNTransportModel: TransportModel {
    // MARK: - Properties

    public let name = "qlknn"

    private let qlknn: QLKNN
    private let modelName: String
    private let enableCaching: Bool

    // MARK: - Initialization

    /// Initialize QLKNN transport model
    ///
    /// - Parameters:
    ///   - modelName: QLKNN model version (default: "qlknn_7_11_v1")
    ///   - pythonPath: Custom Python executable path (optional)
    ///   - enableCaching: Enable prediction caching (default: true)
    /// - Throws: QLKNNError if Python/model initialization fails
    public init(
        modelName: String = "qlknn_7_11_v1",
        pythonPath: String? = nil,
        enableCaching: Bool = true
    ) throws {
        self.modelName = modelName
        self.enableCaching = enableCaching

        do {
            // Initialize Python bridge if custom path provided
            if let path = pythonPath {
                // Configure PythonKit
                // Note: This is a global setting, ideally set once at app startup
            }

            // Initialize QLKNN model
            self.qlknn = try QLKNN(modelName: modelName)
        } catch {
            throw QLKNNError.pythonInteropError(
                reason: "Failed to initialize QLKNN model '\(modelName)': \(error.localizedDescription)"
            )
        }
    }

    /// Initialize from TransportParameters
    public init(params: TransportParameters) throws {
        let modelName = params.params["qlknn_model_name"].map {
            String(describing: $0)
        } ?? "qlknn_7_11_v1"
        let enableCaching = params.params["enable_caching"].map {
            $0 > 0.5
        } ?? true

        try self.init(
            modelName: modelName,
            pythonPath: nil,
            enableCaching: enableCaching
        )
    }

    // MARK: - TransportModel Protocol

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        do {
            // 1. Build QLKNN inputs
            let inputs = try QLKNNInputBuilder.buildInputs(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            // 2. Run QLKNN prediction
            let outputs = try qlknn.predict(inputs)

            // 3. Combine mode-specific fluxes
            let combined = combineFluxes(outputs)

            // 4. Wrap in EvaluatedArray (forces evaluation)
            let nCells = profiles.ionTemperature.shape[0]
            return TransportCoefficients(
                chiIon: EvaluatedArray(evaluating: combined.chi_ion),
                chiElectron: EvaluatedArray(evaluating: combined.chi_electron),
                particleDiffusivity: EvaluatedArray(evaluating: combined.particle_diffusivity),
                convectionVelocity: EvaluatedArray.zeros([nCells])
            )
        } catch {
            // Fallback: Return minimal diffusivity on error
            // TODO: Better error propagation strategy
            let nCells = profiles.ionTemperature.shape[0]
            let fallback: Float = 0.1  // Minimal diffusivity [m^2/s]

            print("⚠️  QLKNN prediction failed: \(error.localizedDescription)")
            print("   Falling back to minimal diffusivity: \(fallback) m^2/s")

            return TransportCoefficients(
                chiIon: EvaluatedArray(evaluating: MLXArray(fallback).broadcasted(to: [nCells])),
                chiElectron: EvaluatedArray(evaluating: MLXArray(fallback).broadcasted(to: [nCells])),
                particleDiffusivity: EvaluatedArray(evaluating: MLXArray(fallback).broadcasted(to: [nCells])),
                convectionVelocity: EvaluatedArray.zeros([nCells])
            )
        }
    }

    // MARK: - Flux Combination

    /// Combine mode-specific fluxes into total transport coefficients
    /// Uses swift-fusion-surrogates TORAXIntegration.combineFluxes()
    private func combineFluxes(_ outputs: [String: MLXArray]) -> (
        chi_ion: MLXArray,
        chi_electron: MLXArray,
        particle_diffusivity: MLXArray,
        convection_velocity: MLXArray
    ) {
        // Extract mode-specific fluxes
        let efiITG = outputs["efiITG"]!
        let efiTEM = outputs["efiTEM"]!
        let efeITG = outputs["efeITG"]!
        let efeTEM = outputs["efeTEM"]!
        let efeETG = outputs["efeETG"]!
        let pfeITG = outputs["pfeITG"]!
        let pfeTEM = outputs["pfeTEM"]!

        // Combine fluxes
        // Ion heat diffusivity: ITG + TEM contributions
        let chi_ion = efiITG + efiTEM

        // Electron heat diffusivity: ITG + TEM + ETG contributions
        let chi_electron = efeITG + efeTEM + efeETG

        // Particle diffusivity: ITG + TEM contributions
        let particle_diffusivity = pfeITG + pfeTEM

        // Convection velocity (pinch): not modeled by QLKNN
        let nCells = chi_ion.shape[0]
        let convection_velocity = MLXArray.zeros([nCells])

        return (chi_ion, chi_electron, particle_diffusivity, convection_velocity)
    }
}

// MARK: - Sendable Conformance

/// QLKNN uses PythonObject internally which is not Sendable by design.
/// However, PythonKit operations are thread-safe at the Python GIL level.
/// We mark this as @unchecked Sendable with the understanding that:
/// 1. QLKNN instances should not be shared across threads directly
/// 2. TransportModel is used within actors (SimulationOrchestrator)
/// 3. All inputs/outputs use Sendable types (MLXArray wrapped in EvaluatedArray)
extension QLKNNTransportModel: @unchecked Sendable {}
```

**Tests**:
- Test initialization with default model
- Test initialization with custom model name
- Test computeCoefficients with synthetic profiles
- Test error handling (invalid inputs)
- Test fallback behavior

**Estimated Time**: 8-12 hours

---

### Phase 3: Configuration and Factory

**Goal**: Update configuration system to support QLKNN

#### Task 3.1: Update TransportConfig

**File**: `Sources/Gotenx/Configuration/TransportConfig.swift`

**Changes**: (Already documented in Architecture Design section)

**Tests**:
- Test JSON decoding with QLKNN config
- Test default values
- Test custom pythonPath

#### Task 3.2: Update TransportModelFactory

**File**: `Sources/Gotenx/Configuration/TransportModelFactory.swift`

**Changes**: (Already documented in Architecture Design section)

**Tests**:
- Test factory creates QLKNNTransportModel
- Test error handling for invalid config
- Test fallback for missing QLKNN dependencies

#### Task 3.3: Example Configuration

**File**: `examples/qlknn_iter.json`

**Content**:
```json
{
  "mesh": {
    "nCells": 100,
    "rMin": 0.0,
    "rMax": 1.0
  },
  "geometry": {
    "majorRadius": 6.2,
    "minorRadius": 2.0,
    "toroidalField": 5.3,
    "plasmaCurrent": 15.0
  },
  "time": {
    "tStart": 0.0,
    "tEnd": 2.0,
    "dtInitial": 0.0001,
    "dtMax": 0.01
  },
  "transport": {
    "modelType": "qlknn",
    "qlknnModelName": "qlknn_7_11_v1",
    "enableQlknnCaching": true
  },
  "sources": {
    "fusionPower": {
      "enabled": true
    },
    "ohmicHeating": {
      "enabled": true
    }
  },
  "boundary": {
    "ionTemperature": {"value": 1000.0},
    "electronTemperature": {"value": 1000.0},
    "electronDensity": {"value": 1e19}
  },
  "solver": {
    "type": "newton-raphson",
    "maxIterations": 20,
    "tolerance": 1e-6
  }
}
```

**Estimated Time**: 2-3 hours

---

### Phase 4: Testing and Validation

**Goal**: Comprehensive testing of QLKNN integration

#### Task 4.1: Unit Tests

**File**: `Tests/GotenxTests/Transport/QLKNNInputBuilderTests.swift`

**Tests**:
```swift
@Test func testGradientComputation() {
    // Test with linear profile: ∇T = constant
    // Test with exponential profile: a/LT = constant
}

@Test func testSafetyFactorCalculation() {
    // Test q(r) monotonic increase
    // Test q at axis and edge
}

@Test func testMagneticShearCalculation() {
    // Test shear calculation with known q(r)
}

@Test func testCollisionalityScaling() {
    // Test ν* ∝ ne
    // Test ν* ∝ 1/Te²
}

@Test func testInputValidation() {
    // Test rejection of NaN inputs
    // Test rejection of Inf inputs
    // Test warning for out-of-range values
}
```

**File**: `Tests/GotenxTests/Transport/QLKNNTransportModelTests.swift`

**Tests**:
```swift
@Test func testQLKNNInitialization() throws {
    // Test with default model
    let model = try QLKNNTransportModel()
    #expect(model.name == "qlknn")
}

@Test func testComputeCoefficients() throws {
    // Create synthetic profiles
    let profiles = createTestProfiles()
    let geometry = createTestGeometry()
    let params = TransportParameters(modelType: "qlknn")

    let model = try QLKNNTransportModel()
    let coeffs = model.computeCoefficients(
        profiles: profiles,
        geometry: geometry,
        params: params
    )

    // Verify outputs
    #expect(coeffs.chiIon.shape[0] == 100)
    #expect(coeffs.chiElectron.shape[0] == 100)

    // Check physical ranges (χ typically 0.1 - 10 m^2/s)
    let chiValues = coeffs.chiElectron.value.asArray(Float.self)
    #expect(chiValues.allSatisfy { $0 > 0 && $0 < 100 })
}

@Test func testErrorHandling() throws {
    // Test with invalid inputs (NaN)
    // Verify fallback behavior
}
```

#### Task 4.2: Integration Tests

**File**: `Tests/GotenxTests/Integration/QLKNNSimulationTests.swift`

**Tests**:
```swift
@Test func testFullSimulationWithQLKNN() async throws {
    // Load QLKNN configuration
    let config = try ConfigurationLoader.load(
        from: "examples/qlknn_iter.json"
    )

    // Run simulation
    let runner = try SimulationRunner(configuration: config)
    let result = try await runner.run()

    // Verify convergence
    #expect(result.converged)
    #expect(result.steps > 0)

    // Verify physical profiles
    let finalState = result.finalState
    #expect(finalState.ionTemperature.core > 1000.0)  // keV
    #expect(finalState.electronDensity.core > 1e19)   // m^-3
}

@Test func testQLKNNvsBohmGyroBohm() async throws {
    // Run same configuration with both models
    // Compare results (QLKNN should have different transport)

    let configQLKNN = try loadConfig("qlknn_iter.json")
    let configBohm = try loadConfig("bohm_iter.json")

    let resultQLKNN = try await runSimulation(configQLKNN)
    let resultBohm = try await runSimulation(configBohm)

    // Expect different transport coefficients
    #expect(resultQLKNN.averageChiElectron != resultBohm.averageChiElectron)
}
```

#### Task 4.3: Performance Benchmarks

**File**: `Tests/GotenxTests/Performance/QLKNNPerformanceTests.swift`

**Benchmarks**:
```swift
@Test func benchmarkQLKNNPrediction() {
    // Measure time for single QLKNN prediction
    // Goal: < 10ms per prediction on Apple Silicon
}

@Test func benchmarkFullTimestep() {
    // Measure time for full timestep with QLKNN
    // Compare to BohmGyroBohm baseline
}
```

**Estimated Time**: 6-8 hours

---

## Technical Specifications

### 1. Gradient Calculation

**Finite Difference Scheme**:

For interior points (i = 1 to n-2):
```
∇f[i] = (f[i+1] - f[i-1]) / (r[i+1] - r[i-1])
```

For boundaries:
```
∇f[0] = (f[1] - f[0]) / (r[1] - r[0])           (forward)
∇f[n-1] = (f[n-1] - f[n-2]) / (r[n-1] - r[n-2])  (backward)
```

**Normalized Gradient**:
```
a/LT = -a(∇T/T) = -a * (∇T) / T
```

**Accuracy**: 2nd-order in interior, 1st-order at boundaries

### 2. Safety Factor Calculation

**Circular Geometry Approximation**:
```
q(r) = q₀ + (q_edge - q₀) * (r/a)²
```

**Typical Values**:
- q₀ (axis): 1.0 - 1.5
- q_edge: 3.0 - 6.0

**Full Calculation** (future enhancement):
```
q(ψ) = (1/2π) ∮ (B·∇φ) / (B·∇θ) dθ
```

### 3. Magnetic Shear

**Definition**:
```
s = (r/q)(dq/dr)
```

**Positive Shear**: s > 0 (q increases with r)
**Typical Range**: 0.5 - 3.0

### 4. Collisionality

**Formula**:
```
ν* = (q R / ε^1.5) * (6.92e-15) * Z_eff * ne * log(Λ) / Te²
```

**Units**:
- ne: [m^-3]
- Te: [eV]
- ν*: dimensionless

**Coulomb Logarithm**:
```
log(Λ) ≈ 15.2 - 0.5*log(ne/1e20) + log(Te/1000)
```

### 5. QLKNN Training Domain

**Valid Input Ranges** (from QLKNN paper):

| Parameter | Min | Max | Typical |
|-----------|-----|-----|---------|
| Ati, Ate | 0 | 15 | 2-6 |
| Ane | 0 | 10 | 1-3 |
| q | 0.5 | 10 | 1-5 |
| smag | -0.5 | 3.0 | 0.5-2.0 |
| x (r/R) | 0 | 0.6 | 0.1-0.4 |
| Ti_Te | 0.5 | 3.0 | 0.8-1.5 |
| LogNuStar | -3 | 2 | -1 to 1 |

**Out-of-Domain Behavior**: QLKNN extrapolation is unreliable; should warn user

---

## Testing Strategy

### Unit Test Coverage

**Target**: > 90% code coverage for new components

**Critical Paths**:
1. ✅ Gradient computation (interior + boundaries)
2. ✅ Input validation (NaN, Inf, ranges)
3. ✅ QLKNN prediction (mock Python calls)
4. ✅ Flux combination
5. ✅ Error handling and fallbacks

### Integration Test Scenarios

1. **Baseline ITER-like Case**
   - 100 cells, 2s simulation
   - Fusion + Ohmic heating
   - Newton-Raphson solver
   - Verify convergence

2. **Comparison Test**
   - Run same case with QLKNN vs BohmGyroBohm
   - Compare transport coefficients
   - Verify QLKNN predicts different (but reasonable) values

3. **Edge Case Tests**
   - Low temperature (< 100 eV): Verify fallback
   - High gradient (a/LT > 15): Verify warning
   - Large aspect ratio (R/a > 5): Test geometry

### Performance Benchmarks

**Target Metrics**:
- QLKNN prediction: < 10ms per call (100 cells)
- Full timestep: < 50ms (with Newton-Raphson)
- Full simulation (2s, 10,000 steps): < 5 minutes

**Baseline Comparison**:
- BohmGyroBohm: ~1ms per call (analytical)
- Expected overhead: 5-10× (acceptable for accuracy gain)

### Validation Against Reference

**Source**: Python TORAX with QLKNN (if available)

**Validation Tests**:
1. Load identical configuration
2. Run short simulation (0.1s, 100 steps)
3. Compare final profiles (Ti, Te, ne)
4. Tolerance: < 5% difference (acceptable for numerical differences)

---

## Deployment and Configuration

### Environment Requirements

**System Requirements**:
- macOS 13.3+ or iOS 16+
- Swift 6.2+
- Python 3.12+
- Apple Silicon (for MLX GPU acceleration)

**Python Dependencies**:
```bash
pip install fusion-surrogates
```

**Swift Package Dependencies**:
- MLX-Swift 0.29.1+
- swift-fusion-surrogates (latest)
- PythonKit (transitive dependency)

### Configuration Best Practices

**1. Python Path Configuration**

**Option A**: System Python (default)
```json
{
  "transport": {
    "modelType": "qlknn"
  }
}
```

**Option B**: Custom Python (e.g., conda environment)
```json
{
  "transport": {
    "modelType": "qlknn",
    "pythonPath": "/Users/username/miniconda3/envs/torax/bin/python"
  }
}
```

**2. Model Selection**

**Default**: `"qlknn_7_11_v1"` (most validated)

**Alternative**: Custom trained models
```json
{
  "transport": {
    "modelType": "qlknn",
    "qlknnModelName": "qlknn_custom_v2"
  }
}
```

**3. Performance Tuning**

**Enable Caching** (recommended):
```json
{
  "transport": {
    "modelType": "qlknn",
    "enableQlknnCaching": true
  }
}
```

**4. Solver Configuration**

**Recommended for QLKNN**:
```json
{
  "solver": {
    "type": "newton-raphson",
    "maxIterations": 20,
    "tolerance": 1e-6
  }
}
```

Rationale: QLKNN provides smooth gradients suitable for Newton-Raphson

### Logging and Debugging

**Enable Detailed Logging**:
```swift
// Set environment variable
GOTENX_LOG_LEVEL=debug swift run torax run --config qlknn_iter.json
```

**QLKNN-Specific Logs**:
- Input parameter ranges
- Prediction timings
- Out-of-domain warnings
- Python interop errors

**Example Log Output**:
```
[QLKNN] Initializing model: qlknn_7_11_v1
[QLKNN] Python path: /opt/homebrew/bin/python3
[QLKNN] Computing transport coefficients (100 cells)
[QLKNN]   Ati range: [2.1, 8.3]
[QLKNN]   Ate range: [2.5, 9.1]
[QLKNN]   q range: [1.0, 3.8]
[QLKNN] ⚠️  Warning: Ate[85] = 12.3 exceeds training domain (max 10)
[QLKNN] Prediction completed in 8.2ms
[QLKNN]   chi_ion range: [0.3, 4.2] m^2/s
[QLKNN]   chi_electron range: [0.5, 6.8] m^2/s
```

---

## Troubleshooting Guide

### Common Issues

#### Issue 1: Python Module Not Found

**Symptom**:
```
Error: Python module 'fusion_surrogates' not found
```

**Solution**:
```bash
# Install fusion_surrogates
pip install fusion-surrogates

# Verify installation
python -c "import fusion_surrogates; print(fusion_surrogates.__version__)"
```

**Alternative**: Specify custom Python path
```json
{
  "transport": {
    "pythonPath": "/path/to/python/with/fusion_surrogates"
  }
}
```

#### Issue 2: PythonKit Linking Errors

**Symptom**:
```
dyld: Library not loaded: @rpath/libpython3.12.dylib
```

**Solution**:
```bash
# Check Python installation
which python3
python3 --version

# Ensure Python is in system PATH
export PATH="/opt/homebrew/bin:$PATH"

# Rebuild
swift build --clean
swift build
```

#### Issue 3: QLKNN Predictions Out of Range

**Symptom**:
```
⚠️  QLKNN Warning: chi_electron = 150 m^2/s (exceeds physical expectations)
```

**Cause**: Input parameters outside QLKNN training domain

**Solution**:
1. Check input parameter ranges in logs
2. Identify out-of-domain parameters
3. Options:
   - Adjust initial conditions
   - Use BohmGyroBohm for out-of-domain regions
   - Clamp inputs to valid ranges

#### Issue 4: Performance Degradation

**Symptom**:
```
QLKNN prediction: 150ms (expected < 10ms)
```

**Possible Causes**:
1. Large batch size (> 1000 cells)
2. Python GIL contention
3. Disk I/O (model loading)

**Solutions**:
- Reduce mesh resolution
- Ensure model is loaded once (not per prediction)
- Enable caching
- Use MLX GPU mode (verify with `MLX.GPU.isAvailable`)

#### Issue 5: NaN in Outputs

**Symptom**:
```
Error: QLKNN output contains NaN
```

**Debugging**:
1. Check input parameters for NaN/Inf
2. Verify gradient calculations
3. Check for division by zero (T → 0)
4. Enable verbose logging

**Typical Cause**: Near-zero temperature at edge causing 1/T² → ∞

**Solution**: Apply minimum temperature threshold
```swift
let Te_safe = maximum(Te, 10.0)  // Minimum 10 eV
```

### Debug Checklist

Before reporting issues:

- [ ] Python 3.12+ installed?
- [ ] `fusion_surrogates` installed? (`pip list | grep fusion`)
- [ ] Swift 6.2+? (`swift --version`)
- [ ] MLX-Swift dependencies resolved? (`swift package resolve`)
- [ ] Configuration valid? (`swift run torax validate --config ...`)
- [ ] Logs captured? (`--log-level debug`)
- [ ] Minimal reproducible example?

---

## Future Extensions

### Phase 5: Performance Optimization

**1. Prediction Caching**
- Cache QLKNN predictions based on input hash
- LRU eviction policy
- Disk persistence across runs

**2. Batch Optimization**
- Group multiple timesteps into single QLKNN call
- Amortize Python interop overhead

**3. MLX compile() Integration**
- Explore compiling QLKNN wrapper
- Challenges: Python calls not compilable
- Alternative: Cache-aware wrapper

### Phase 6: Advanced Features

**1. Multi-Ion Species**
- Extend inputs for multiple ion species (D, T, impurities)
- Update `normni` calculation

**2. Rotation Effects**
- Add toroidal rotation velocity input
- Use QLKNN rotation models (if available)

**3. Electromagnetic Effects**
- Extend to include electromagnetic instabilities
- Requires QLKNN models with EM physics

**4. Pedestal Coupling**
- Integrate QLKNN with pedestal models
- Match core-edge boundary conditions

### Phase 7: Alternative Surrogate Models

**1. Other Neural Networks**
- TGLF surrogate (if available)
- GEM surrogate
- Custom trained models

**2. Gaussian Process Surrogates**
- Uncertainty quantification
- Active learning

**3. Hybrid Models**
- QLKNN in core, analytic at edge
- Model switching based on regime

---

## Appendix: Reference Equations

### A. QLKNN Input Normalization

**Temperature Gradient**:
```
a/L_Ti = -a * (d Ti / dr) / Ti
```

**Density Gradient**:
```
a/L_ne = -a * (d ne / dr) / ne
```

**Safety Factor** (circular):
```
q(r) = (r * B_t) / (R * B_p)
     ≈ q_axis * (1 + (r/a)^α)
```

**Magnetic Shear**:
```
s = (r/q) * (dq/dr)
  = d(ln q) / d(ln r)
```

**Collisionality**:
```
ν* = (q R / ε^1.5) * ν_ei / (v_th,e * ε)
```

where:
```
ν_ei = (n_e e^4 ln Λ) / (4π ε_0^2 m_e^0.5 T_e^1.5)
v_th,e = sqrt(T_e / m_e)
ε = r / R
```

### B. QLKNN Output Fluxes

**Gyro-Bohm Normalization**:
```
Q_GB = n_e T_e (ρ_s / a)^2 c_s
```

where:
```
ρ_s = sqrt(m_i T_e) / (e B)  (ion sound radius)
c_s = sqrt(T_e / m_i)         (sound speed)
```

**Thermal Diffusivity** (from flux):
```
χ = Q / (n ∇T)
```

**Particle Diffusivity** (from flux):
```
D = Γ / ∇n
```

### C. Unit Conversions

swift-Gotenx uses **eV** and **m^-3** internally.

**QLKNN Outputs** (Gyro-Bohm normalized):
- Need to multiply by `(ρ_s/a)^2 * c_s` to get SI units [m^2/s]

**Example**:
```swift
let chiGB = qlknnOutput["efeITG"]  // Dimensionless
let rhoS = sqrt(ionMass * Te_eV * e) / (e * B)
let cs = sqrt(Te_eV * e / ionMass)
let chi_SI = chiGB * pow(rhoS / minorRadius, 2) * cs  // [m^2/s]
```

---

## Conclusion

This integration plan provides a comprehensive roadmap for adding QLKNN transport model support to swift-Gotenx. The phased approach ensures:

1. **Minimal Risk**: Dependencies and build environment verified first
2. **Modular Design**: Components are independent and testable
3. **Backward Compatibility**: Existing transport models unaffected
4. **Extensibility**: Architecture supports future surrogate models
5. **Type Safety**: Swift's strong typing catches errors at compile time

**Estimated Total Implementation Time**: 20-30 hours

**Success Criteria**:
- ✅ QLKNN transport model fully functional
- ✅ All tests passing (unit + integration)
- ✅ Performance benchmarks met
- ✅ Documentation complete
- ✅ Example configuration working

**Next Step**: Begin Phase 1 implementation (dependencies and build environment)
