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

// MARK: - Parameter Access

extension TransportConfig {
    /// Get parameter value (returns nil if missing)
    ///
    /// Use this when you need to handle missing values explicitly.
    ///
    /// - Parameter key: Parameter key (e.g., "chi_ion")
    /// - Returns: Parameter value or nil if not found
    ///
    /// Example:
    /// ```swift
    /// if let chiIon = transport.parameter("chi_ion") {
    ///     print("chi_ion = \(chiIon) m²/s")
    /// } else {
    ///     print("chi_ion not specified")
    /// }
    /// ```
    public func parameter(_ key: String) -> Float? {
        parameters[key]
    }

    /// Get required parameter (throws if missing)
    ///
    /// Use this for parameters that are mandatory for the model.
    ///
    /// - Parameter key: Parameter key (e.g., "chi_ion")
    /// - Returns: Parameter value
    /// - Throws: ConfigurationError.missingRequired if parameter not found
    ///
    /// Example:
    /// ```swift
    /// let chiIon = try transport.requireParameter("chi_ion")
    /// ```
    public func requireParameter(_ key: String) throws -> Float {
        guard let value = parameters[key] else {
            throw ConfigurationError.missingRequired(
                key: "transport.parameters.\(key) for model \(modelType)"
            )
        }
        return value
    }

    /// Get parameter with explicit default
    ///
    /// Use this when you have a context-independent fallback value.
    ///
    /// - Parameters:
    ///   - key: Parameter key (e.g., "chi_ion")
    ///   - defaultValue: Fallback value
    /// - Returns: Parameter value or default
    ///
    /// Example:
    /// ```swift
    /// // particle_diffusivity is optional for some models
    /// let particleDiff = transport.parameter("particle_diffusivity", default: 0.0)
    /// ```
    public func parameter(_ key: String, default defaultValue: Float) -> Float {
        parameters[key] ?? defaultValue
    }
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
