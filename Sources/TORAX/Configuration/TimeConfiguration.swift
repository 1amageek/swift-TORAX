// TimeConfiguration.swift
// Time configuration

import Foundation

/// Time configuration
public struct TimeConfiguration: Codable, Sendable, Equatable {
    /// Initial time [s]
    public let start: Float

    /// Final time [s]
    public let end: Float

    /// Initial timestep [s]
    public let initialDt: Float

    /// Adaptive timestepping
    public let adaptive: AdaptiveTimestepConfig?

    public init(
        start: Float = 0.0,
        end: Float,
        initialDt: Float = 1e-3,
        adaptive: AdaptiveTimestepConfig? = .default
    ) {
        self.start = start
        self.end = end
        self.initialDt = initialDt
        self.adaptive = adaptive
    }
}

/// Adaptive timestep configuration
public struct AdaptiveTimestepConfig: Codable, Sendable, Equatable {
    /// Minimum timestep [s]
    public let minDt: Float

    /// Maximum timestep [s]
    public let maxDt: Float

    /// Safety factor (< 1.0)
    public let safetyFactor: Float

    public static let `default` = AdaptiveTimestepConfig(
        minDt: 1e-6,
        maxDt: 1e-1,
        safetyFactor: 0.9
    )

    public init(minDt: Float, maxDt: Float, safetyFactor: Float) {
        self.minDt = minDt
        self.maxDt = maxDt
        self.safetyFactor = safetyFactor
    }
}
