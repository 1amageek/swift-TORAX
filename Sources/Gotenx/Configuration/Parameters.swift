import Foundation

// MARK: - Transport Parameters

/// Transport model parameters
public struct TransportParameters: Sendable, Codable, Equatable {
    /// Transport model type (enum for type safety)
    public var modelType: TransportModelType

    /// Model-specific parameters
    public var params: [String: Float]

    public init(modelType: TransportModelType, params: [String: Float] = [:]) {
        self.modelType = modelType
        self.params = params
    }
}

// MARK: - Source Parameters

/// Source model parameters
public struct SourceParameters: Sendable, Codable, Equatable {
    /// Source model type
    public var modelType: String

    /// Model-specific parameters
    public var params: [String: Float]

    /// Time-dependent scaling factor
    public var timeDependent: Bool

    public init(
        modelType: String,
        params: [String: Float] = [:],
        timeDependent: Bool = false
    ) {
        self.modelType = modelType
        self.params = params
        self.timeDependent = timeDependent
    }
}
