// SolverConfig.swift
// Solver configuration

import Foundation

/// Solver configuration
public struct SolverConfig: Codable, Sendable, Equatable, Hashable {
    /// Solver type (using existing SolverType from RuntimeParams)
    public let type: String

    /// Legacy convergence tolerance (deprecated, use tolerances instead)
    /// Kept for backward compatibility
    public let tolerance: Float?

    /// Per-equation numerical tolerances (recommended)
    /// If nil, falls back to legacy tolerance
    public let tolerances: NumericalTolerances?

    /// Physical thresholds for diagnostics
    /// Optional for backward compatibility with old JSON files
    public let physicalThresholds: PhysicalThresholds?

    /// Maximum iterations
    public let maxIterations: Int

    /// Line search enabled (default: true)
    public let lineSearchEnabled: Bool

    /// Maximum line search alpha (default: 1.0)
    public let lineSearchMaxAlpha: Float

    /// Effective physical thresholds (with fallback)
    public var effectiveThresholds: PhysicalThresholds {
        return physicalThresholds ?? .default
    }

    /// Computed tolerances (prioritizes new over legacy)
    public var effectiveTolerances: NumericalTolerances {
        if let tolerances = tolerances {
            return tolerances
        } else if let legacyTol = tolerance {
            return NumericalTolerances.fromLegacy(tolerance: legacyTol)
        } else {
            return .iterScale
        }
    }

    public static let `default` = SolverConfig(
        type: "newtonRaphson",
        tolerance: nil,  // Use new tolerances instead
        tolerances: .iterScale,
        physicalThresholds: .default,
        maxIterations: 30,
        lineSearchEnabled: true,
        lineSearchMaxAlpha: 1.0
    )

    public init(
        type: String = "newtonRaphson",
        tolerance: Float? = nil,
        tolerances: NumericalTolerances? = .iterScale,
        physicalThresholds: PhysicalThresholds? = .default,
        maxIterations: Int = 100,  // ✅ INCREASED: Match NewtonRaphsonSolver default
        lineSearchEnabled: Bool = true,
        lineSearchMaxAlpha: Float = 1.0
    ) {
        self.type = type
        self.tolerance = tolerance
        self.tolerances = tolerances
        self.physicalThresholds = physicalThresholds
        self.maxIterations = maxIterations
        self.lineSearchEnabled = lineSearchEnabled
        self.lineSearchMaxAlpha = lineSearchMaxAlpha
    }

    // MARK: - Custom Decoding for Backward Compatibility

    enum CodingKeys: String, CodingKey {
        case type
        case tolerance
        case tolerances
        case physicalThresholds
        case maxIterations
        case lineSearchEnabled
        case lineSearchMaxAlpha
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields (always present in old and new configs)
        type = try container.decode(String.self, forKey: .type)
        maxIterations = try container.decode(Int.self, forKey: .maxIterations)

        // Optional legacy field
        tolerance = try container.decodeIfPresent(Float.self, forKey: .tolerance)

        // Phase 1 new fields with defaults for backward compatibility
        tolerances = try container.decodeIfPresent(NumericalTolerances.self, forKey: .tolerances)
        physicalThresholds = try container.decodeIfPresent(PhysicalThresholds.self, forKey: .physicalThresholds)
        lineSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .lineSearchEnabled) ?? true
        lineSearchMaxAlpha = try container.decodeIfPresent(Float.self, forKey: .lineSearchMaxAlpha) ?? 1.0
    }
}
