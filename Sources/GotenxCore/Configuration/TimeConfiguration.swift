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

/// Adaptive timestep configuration (EXTENDED for better scalability)
public struct AdaptiveTimestepConfig: Codable, Sendable, Equatable {
    /// Minimum timestep [s] (absolute) - optional for backward compatibility
    /// If set, takes precedence over minDtFraction
    public let minDt: Float?

    /// Minimum timestep fraction of maxDt (default: 0.001)
    /// Ignored if minDt is explicitly set
    /// Recommended approach: minDt = maxDt * minDtFraction
    public let minDtFraction: Float?

    /// Maximum timestep [s]
    public let maxDt: Float

    /// CFL safety factor (< 1.0)
    public let safetyFactor: Float

    /// Maximum timestep growth rate per step (default: 1.2)
    /// Limits how quickly timestep can increase: dt_new ≤ dt_old * maxTimestepGrowth
    public let maxTimestepGrowth: Float

    /// Computed minimum timestep (adaptive)
    /// Priority: explicit minDt > minDtFraction > default (maxDt * 0.001)
    public var effectiveMinDt: Float {
        if let minDt = minDt {
            return minDt  // Explicit value takes precedence (old configs)
        } else if let fraction = minDtFraction {
            return maxDt * fraction
        } else {
            return maxDt * 0.001  // Default fallback: maxDt / 1000
        }
    }

    public static let `default` = AdaptiveTimestepConfig(
        minDt: nil,              // Use fraction instead
        minDtFraction: 0.001,    // maxDt / 1000
        maxDt: 1e-1,
        safetyFactor: 0.9,
        maxTimestepGrowth: 1.2
    )

    public init(
        minDt: Float? = nil,
        minDtFraction: Float? = 0.001,
        maxDt: Float,
        safetyFactor: Float,
        maxTimestepGrowth: Float = 1.2
    ) {
        self.minDt = minDt
        self.minDtFraction = minDtFraction
        self.maxDt = maxDt
        self.safetyFactor = safetyFactor
        self.maxTimestepGrowth = maxTimestepGrowth
    }
}
