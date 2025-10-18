// SourceModelFactory.swift
// Factory for creating source models from configuration

import Foundation
import TORAX

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

            default:
                throw ConfigurationError.invalidValue(
                    key: "source.modelType",
                    value: params.modelType,
                    reason: "Unknown source model type. Valid types: ohmic, fusion, ionElectronExchange, bremsstrahlung"
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

        default:
            throw ConfigurationError.invalidValue(
                key: "sourceName",
                value: name,
                reason: "Unknown source model name. Valid names: ohmic, fusion, ionElectronExchange, bremsstrahlung"
            )
        }
    }
}
