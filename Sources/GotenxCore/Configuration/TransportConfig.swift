// TransportConfig.swift
// Transport model configuration

import Foundation

/// Transport model configuration
public struct TransportConfig: Codable, Sendable, Equatable {
    /// Transport model type (enum for type safety)
    public let modelType: TransportModelType

    /// Model-specific parameters
    public let parameters: [String: Float]

    public init(modelType: TransportModelType, parameters: [String: Float] = [:]) {
        self.modelType = modelType
        self.parameters = parameters
    }

    // MARK: - Codable Support

    enum CodingKeys: String, CodingKey {
        case modelType
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelType = try container.decode(TransportModelType.self, forKey: .modelType)
        self.parameters = try container.decodeIfPresent([String: Float].self, forKey: .parameters) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(parameters, forKey: .parameters)
    }
}

/// Transport model types
public enum TransportModelType: String, Codable, Sendable, CaseIterable {
    case constant
    case bohmGyrobohm
    case qlknn
    case densityTransition
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
