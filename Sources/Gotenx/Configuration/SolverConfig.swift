// SolverConfig.swift
// Solver configuration

import Foundation

/// Solver configuration
public struct SolverConfig: Codable, Sendable, Equatable, Hashable {
    /// Solver type (using existing SolverType from RuntimeParams)
    public let type: String

    /// Convergence tolerance
    public let tolerance: Float

    /// Maximum iterations
    public let maxIterations: Int

    public static let `default` = SolverConfig(
        type: "newtonRaphson",
        tolerance: 1e-6,
        maxIterations: 30
    )

    public init(
        type: String = "newtonRaphson",
        tolerance: Float = 1e-6,
        maxIterations: Int = 30
    ) {
        self.type = type
        self.tolerance = tolerance
        self.maxIterations = maxIterations
    }
}
