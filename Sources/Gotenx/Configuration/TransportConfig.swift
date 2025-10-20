// TransportConfig.swift
// Transport model configuration

import Foundation

/// Transport model configuration
public struct TransportConfig: Codable, Sendable, Equatable {
    /// Transport model type (string to avoid conflict with protocol)
    public let modelType: String

    /// Model-specific parameters
    public let parameters: [String: Float]

    public init(modelType: String, parameters: [String: Float] = [:]) {
        self.modelType = modelType
        self.parameters = parameters
    }

    /// Convenience initializer with enum
    public init(model: TransportModelType, parameters: [String: Float] = [:]) {
        self.modelType = model.rawValue
        self.parameters = parameters
    }
}

/// Transport model types
public enum TransportModelType: String, Codable, Sendable {
    case constant
    case bohmGyrobohm
    case qlknn
}

// MARK: - Conversion to Runtime Parameters

extension TransportConfig {
    /// Convert to TransportParameters for runtime
    public func toTransportParameters() -> TransportParameters {
        TransportParameters(
            modelType: modelType,
            params: parameters
        )
    }
}
