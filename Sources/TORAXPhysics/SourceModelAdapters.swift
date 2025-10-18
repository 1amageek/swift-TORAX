// SourceModelAdapters.swift
// Adapters to make physics sources conform to SourceModel protocol

import Foundation
import MLX
import TORAX

// MARK: - Ohmic Heating Source

/// Ohmic heating source model adapter
public struct OhmicHeatingSource: SourceModel {
    public let name: String = "ohmic"
    private let model: OhmicHeating

    public init() {
        self.model = OhmicHeating()
    }

    public init(Zeff: Float = 1.5, lnLambda: Float = 17.0, useNeoclassical: Bool = true) {
        self.model = OhmicHeating(Zeff: Zeff, lnLambda: lnLambda, useNeoclassical: useNeoclassical)
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        // Start with zero sources
        let nCells = profiles.ionTemperature.shape[0]
        let zeros = EvaluatedArray.zeros([nCells])

        let emptySourceTerms = SourceTerms(
            ionHeating: zeros,
            electronHeating: zeros,
            particleSource: zeros,
            currentSource: zeros
        )

        // Apply Ohmic heating (needs geometry)
        do {
            return try model.applyToSources(
                emptySourceTerms,
                profiles: profiles,
                geometry: geometry,
                plasmaCurrentDensity: nil
            )
        } catch {
            // If computation fails, return zeros with warning
            print("⚠️  Warning: Ohmic heating computation failed: \(error)")
            return emptySourceTerms
        }
    }
}

// MARK: - Fusion Power Source

/// Fusion power source model adapter
public struct FusionPowerSource: SourceModel {
    public let name: String = "fusion"
    private let model: FusionPower

    public init() {
        // Use default equal D-T mix
        self.model = try! FusionPower(fuelMix: .equalDT, fuelDilution: 0.9)
    }

    public init(params: SourceParameters) {
        let dFraction = params.params["deuteriumFraction"] ?? 0.5
        let tFraction = params.params["tritiumFraction"] ?? 0.5
        let dilution = params.params["dilution"] ?? 0.9

        // Create fuel mix from fractions
        let fuelMix = FusionPower.FuelMixture.custom(nD_frac: dFraction, nT_frac: tFraction)

        self.model = try! FusionPower(fuelMix: fuelMix, fuelDilution: dilution)
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        let nCells = profiles.ionTemperature.shape[0]
        let zeros = EvaluatedArray.zeros([nCells])

        let emptySourceTerms = SourceTerms(
            ionHeating: zeros,
            electronHeating: zeros,
            particleSource: zeros,
            currentSource: zeros
        )

        // FusionPower.applyToSources does NOT take geometry parameter
        do {
            return try model.applyToSources(
                emptySourceTerms,
                profiles: profiles
            )
        } catch {
            print("⚠️  Warning: Fusion power computation failed: \(error)")
            return emptySourceTerms
        }
    }
}

// MARK: - Ion-Electron Exchange Source

/// Ion-electron heat exchange source model adapter
public struct IonElectronExchangeSource: SourceModel {
    public let name: String = "ionElectronExchange"
    private let model: IonElectronExchange

    public init() {
        self.model = IonElectronExchange()
    }

    public init(params: SourceParameters) {
        self.model = IonElectronExchange()
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        let nCells = profiles.ionTemperature.shape[0]
        let zeros = EvaluatedArray.zeros([nCells])

        let emptySourceTerms = SourceTerms(
            ionHeating: zeros,
            electronHeating: zeros,
            particleSource: zeros,
            currentSource: zeros
        )

        // IonElectronExchange.applyToSources does NOT take geometry parameter
        do {
            return try model.applyToSources(
                emptySourceTerms,
                profiles: profiles
            )
        } catch {
            print("⚠️  Warning: Ion-electron exchange computation failed: \(error)")
            return emptySourceTerms
        }
    }
}

// MARK: - Bremsstrahlung Source

/// Bremsstrahlung radiation source model adapter
public struct BremsstrahlungSource: SourceModel {
    public let name: String = "bremsstrahlung"
    private let model: Bremsstrahlung

    public init() {
        self.model = Bremsstrahlung()
    }

    public init(params: SourceParameters) {
        self.model = Bremsstrahlung()
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        let nCells = profiles.ionTemperature.shape[0]
        let zeros = EvaluatedArray.zeros([nCells])

        let emptySourceTerms = SourceTerms(
            ionHeating: zeros,
            electronHeating: zeros,
            particleSource: zeros,
            currentSource: zeros
        )

        // Bremsstrahlung.applyToSources does NOT take geometry parameter
        do {
            return try model.applyToSources(
                emptySourceTerms,
                profiles: profiles
            )
        } catch {
            print("⚠️  Warning: Bremsstrahlung computation failed: \(error)")
            return emptySourceTerms
        }
    }
}

// MARK: - Composite Source Model

/// Composite source model that combines multiple sources
public struct CompositeSourceModel: SourceModel {
    public let name: String = "composite"
    private let sources: [String: any SourceModel]

    public init(sources: [String: any SourceModel]) {
        self.sources = sources
    }

    public func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms {
        let nCells = profiles.ionTemperature.shape[0]
        var totalIonHeating = MLXArray.zeros([nCells])
        var totalElectronHeating = MLXArray.zeros([nCells])
        var totalParticleSource = MLXArray.zeros([nCells])
        var totalCurrentSource = MLXArray.zeros([nCells])

        // Accumulate contributions from all sources
        for (_, source) in sources {
            let terms = source.computeTerms(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            totalIonHeating = totalIonHeating + terms.ionHeating.value
            totalElectronHeating = totalElectronHeating + terms.electronHeating.value
            totalParticleSource = totalParticleSource + terms.particleSource.value
            totalCurrentSource = totalCurrentSource + terms.currentSource.value
        }

        // Evaluate all arrays in batch
        let evaluated = EvaluatedArray.evaluatingBatch([
            totalIonHeating,
            totalElectronHeating,
            totalParticleSource,
            totalCurrentSource
        ])

        return SourceTerms(
            ionHeating: evaluated[0],
            electronHeating: evaluated[1],
            particleSource: evaluated[2],
            currentSource: evaluated[3]
        )
    }
}
