// TransportModelFactory.swift
// Factory for creating transport models from configuration

import Foundation

/// Factory for creating transport models from configuration
public struct TransportModelFactory {
    /// Create a transport model from configuration
    ///
    /// - Parameter config: Transport model configuration
    /// - Returns: Instantiated transport model
    /// - Throws: ConfigurationError if model type is invalid or not implemented
    public static func create(config: TransportConfig) throws -> any TransportModel {
        let params = config.toTransportParameters()

        guard let modelType = TransportModelType(rawValue: config.modelType) else {
            throw ConfigurationError.invalidValue(
                key: "transport.modelType",
                value: config.modelType,
                reason: "Unknown transport model type. Valid types: constant, bohmGyrobohm, qlknn"
            )
        }

        switch modelType {
        case .constant:
            return ConstantTransportModel(params: params)

        case .bohmGyrobohm:
            return BohmGyroBohmTransportModel(params: params)

        case .qlknn:
            // Future implementation
            throw ConfigurationError.notImplemented(
                feature: "QLKNN transport model (planned for future release)"
            )
        }
    }

    /// Create a transport model with default parameters
    ///
    /// - Parameter modelType: Transport model type
    /// - Returns: Instantiated transport model with default parameters
    /// - Throws: ConfigurationError if model type is not implemented
    public static func createDefault(_ modelType: TransportModelType) throws -> any TransportModel {
        let config = TransportConfig(model: modelType)
        return try create(config: config)
    }
}

// MARK: - Configuration Error Extensions

extension ConfigurationError {
    /// Feature not yet implemented
    static func notImplemented(feature: String) -> ConfigurationError {
        .invalidValue(
            key: "feature",
            value: feature,
            reason: "This feature is not yet implemented"
        )
    }
}
