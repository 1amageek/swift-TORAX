// SourceModelFactory.swift
// Factory for creating source models from configuration

import Foundation
import Gotenx

/// Factory for creating source models from configuration
public struct SourceModelFactory {
    /// Create source models from configuration
    ///
    /// Creates instances of enabled physics sources based on configuration.
    /// Returns a composite model that combines all enabled sources.
    ///
    /// - Parameter config: Sources configuration
    /// - Returns: Composite source model containing all enabled sources
    public static func create(config: SourcesConfig) -> any SourceModel {
        var sources: [String: any SourceModel] = [:]

        // Add Ohmic heating if enabled
        if config.ohmicHeating {
            sources["ohmic"] = OhmicHeatingSource()
        }

        // Add fusion power if enabled
        if config.fusionPower {
            if let fusionConfig = config.fusionConfig {
                // Create with specific fuel parameters
                let params = SourceParameters(
                    modelType: "fusion",
                    params: [
                        "deuteriumFraction": fusionConfig.deuteriumFraction,
                        "tritiumFraction": fusionConfig.tritiumFraction,
                        "dilution": fusionConfig.dilution
                    ]
                )
                sources["fusion"] = FusionPowerSource(params: params)
            } else {
                // Use defaults
                sources["fusion"] = FusionPowerSource()
            }
        }

        // Add ion-electron exchange if enabled
        if config.ionElectronExchange {
            sources["ionElectronExchange"] = IonElectronExchangeSource()
        }

        // Add Bremsstrahlung radiation if enabled
        if config.bremsstrahlung {
            sources["bremsstrahlung"] = BremsstrahlungSource()
        }

        // Add ECRH if enabled
        if let ecrhConfig = config.ecrh {
            let params = SourceParameters(
                modelType: "ecrh",
                params: [
                    "total_power": ecrhConfig.totalPower,
                    "deposition_rho": ecrhConfig.depositionRho,
                    "deposition_width": ecrhConfig.depositionWidth,
                    "launch_angle": ecrhConfig.launchAngle ?? 0.0,
                    "frequency": ecrhConfig.frequency ?? 0.0,
                    "current_drive": ecrhConfig.currentDriveEnabled ? 1.0 : 0.0
                ]
            )
            do {
                sources["ecrh"] = try ECRHSource(params: params)
            } catch {
                print("⚠️  Warning: Failed to initialize ECRH source: \(error)")
            }
        }

        // Add Gas Puff if enabled
        if let gasPuffConfig = config.gasPuff {
            let params = SourceParameters(
                modelType: "gasPuff",
                params: [
                    "puff_rate": gasPuffConfig.puffRate,
                    "penetration_depth": gasPuffConfig.penetrationDepth
                ]
            )
            do {
                sources["gasPuff"] = try GasPuffSource(params: params)
            } catch {
                print("⚠️  Warning: Failed to initialize Gas Puff source: \(error)")
            }
        }

        // Add Impurity Radiation if enabled
        if let impurityConfig = config.impurityRadiation {
            // Encode species as atomic number
            let atomicNumber: Float
            switch impurityConfig.species.lowercased() {
            case "carbon": atomicNumber = 6
            case "neon": atomicNumber = 10
            case "argon": atomicNumber = 18
            case "tungsten": atomicNumber = 74
            default: atomicNumber = 18
            }

            let params = SourceParameters(
                modelType: "impurityRadiation",
                params: [
                    "impurity_fraction": impurityConfig.impurityFraction,
                    "atomic_number": atomicNumber
                ]
            )
            do {
                sources["impurityRadiation"] = try ImpurityRadiationSource(params: params)
            } catch {
                print("⚠️  Warning: Failed to initialize Impurity Radiation source: \(error)")
            }
        }

        // Return composite model combining all sources
        return CompositeSourceModel(sources: sources)
    }

    /// Create source models from a dictionary of source parameters
    ///
    /// - Parameter sourceParams: Dictionary of source parameters by name
    /// - Returns: Composite source model
    /// - Throws: ConfigurationError if source type is unknown
    public static func create(from sourceParams: [String: SourceParameters]) throws -> any SourceModel {
        var sources: [String: any SourceModel] = [:]

        for (name, params) in sourceParams {
            switch params.modelType {
            case "ohmic":
                sources[name] = OhmicHeatingSource()

            case "fusion":
                sources[name] = FusionPowerSource(params: params)

            case "ionElectronExchange":
                sources[name] = IonElectronExchangeSource(params: params)

            case "bremsstrahlung":
                sources[name] = BremsstrahlungSource(params: params)

            case "ecrh":
                sources[name] = try ECRHSource(params: params)

            case "gasPuff":
                sources[name] = try GasPuffSource(params: params)

            case "impurityRadiation":
                sources[name] = try ImpurityRadiationSource(params: params)

            default:
                throw ConfigurationError.invalidValue(
                    key: "source.modelType",
                    value: params.modelType,
                    reason: "Unknown source model type. Valid types: ohmic, fusion, ionElectronExchange, bremsstrahlung, ecrh, gasPuff, impurityRadiation"
                )
            }
        }

        return CompositeSourceModel(sources: sources)
    }

    /// Create a single source model by name
    ///
    /// - Parameters:
    ///   - name: Source model name
    ///   - params: Optional source parameters
    /// - Returns: Source model instance
    /// - Throws: ConfigurationError if source name is unknown
    public static func createSingle(name: String, params: SourceParameters? = nil) throws -> any SourceModel {
        switch name {
        case "ohmic":
            return OhmicHeatingSource()

        case "fusion":
            if let params = params {
                return FusionPowerSource(params: params)
            } else {
                return FusionPowerSource()
            }

        case "ionElectronExchange":
            return IonElectronExchangeSource()

        case "bremsstrahlung":
            return BremsstrahlungSource()

        case "ecrh":
            if let params = params {
                return try ECRHSource(params: params)
            } else {
                // Use default ECRH configuration
                let defaultParams = SourceParameters(
                    modelType: "ecrh",
                    params: [
                        "total_power": 20e6,
                        "deposition_rho": 0.5,
                        "deposition_width": 0.1
                    ]
                )
                return try ECRHSource(params: defaultParams)
            }

        case "gasPuff":
            if let params = params {
                return try GasPuffSource(params: params)
            } else {
                // Use default Gas Puff configuration
                let defaultParams = SourceParameters(
                    modelType: "gasPuff",
                    params: [
                        "puff_rate": 1e21,
                        "penetration_depth": 0.1
                    ]
                )
                return try GasPuffSource(params: defaultParams)
            }

        case "impurityRadiation":
            if let params = params {
                return try ImpurityRadiationSource(params: params)
            } else {
                // Use default Impurity Radiation configuration
                let defaultParams = SourceParameters(
                    modelType: "impurityRadiation",
                    params: [
                        "impurity_fraction": 0.001,
                        "atomic_number": 18  // Argon
                    ]
                )
                return try ImpurityRadiationSource(params: defaultParams)
            }

        default:
            throw ConfigurationError.invalidValue(
                key: "sourceName",
                value: name,
                reason: "Unknown source model name. Valid names: ohmic, fusion, ionElectronExchange, bremsstrahlung, ecrh, gasPuff, impurityRadiation"
            )
        }
    }
}
