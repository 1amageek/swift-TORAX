// NumericalDiagnostics.swift
// Numerical solver diagnostics for monitoring convergence and conservation
//
// Phase 1 Implementation: Minimal structure with default values
// Phase 2 Implementation: Actual diagnostics from solver state

import Foundation

/// Numerical solver diagnostics for monitoring simulation health
///
/// **Purpose**:
/// - Track convergence behavior of Newton-Raphson solver
/// - Monitor conservation laws (particles, energy, current)
/// - Detect numerical instabilities early
///
/// **Implementation Phases**:
/// - Phase 1 (Current): Returns default values
/// - Phase 2: Captures actual solver diagnostics
/// - Phase 3: Adds conservation monitoring
public struct NumericalDiagnostics: Sendable, Codable, Equatable {
    // MARK: - Convergence Metrics

    /// L2 norm of residual ||R|| at current timestep
    public let residual_norm: Float

    /// Number of Newton-Raphson iterations taken
    public let newton_iterations: Int

    /// Number of linear solver iterations
    public let linear_iterations: Int

    /// Convergence flag (true if residual < tolerance)
    public let converged: Bool

    // MARK: - Conservation Metrics

    /// Particle conservation drift: (N - N_0) / N_0
    ///
    /// **Acceptance Criteria**: |drift| < 0.01 (1%)
    public let particle_drift: Float

    /// Energy conservation drift: (W - W_0) / W_0
    ///
    /// **Acceptance Criteria**: |drift| < 0.01 (1%)
    public let energy_drift: Float

    /// Current conservation drift: (I - I_0) / I_0
    ///
    /// **Acceptance Criteria**: |drift| < 0.01 (1%)
    public let current_drift: Float

    // MARK: - Performance Metrics

    /// Wall clock time for this timestep [s]
    public let wall_time: Float

    /// Number of residual function evaluations
    public let eval_count: Int

    // MARK: - Timestep Control

    /// Adaptive timestep size [s]
    public let dt: Float

    /// CFL number (Courant-Friedrichs-Lewy condition)
    public let cfl_number: Float

    // MARK: - Initialization

    public init(
        residual_norm: Float,
        newton_iterations: Int,
        linear_iterations: Int,
        converged: Bool,
        particle_drift: Float,
        energy_drift: Float,
        current_drift: Float,
        wall_time: Float,
        eval_count: Int,
        dt: Float,
        cfl_number: Float
    ) {
        self.residual_norm = residual_norm
        self.newton_iterations = newton_iterations
        self.linear_iterations = linear_iterations
        self.converged = converged
        self.particle_drift = particle_drift
        self.energy_drift = energy_drift
        self.current_drift = current_drift
        self.wall_time = wall_time
        self.eval_count = eval_count
        self.dt = dt
        self.cfl_number = cfl_number
    }
}

// MARK: - Phase 1: Default Values

extension NumericalDiagnostics {
    /// Phase 1 implementation: Return sensible defaults
    ///
    /// **Rationale**: Allows compilation and testing without breaking existing code.
    /// Actual diagnostics will be captured in Phase 2.
    public static let `default` = NumericalDiagnostics(
        residual_norm: 0,
        newton_iterations: 0,
        linear_iterations: 0,
        converged: true,  // Assume convergence by default
        particle_drift: 0,
        energy_drift: 0,
        current_drift: 0,
        wall_time: 0,
        eval_count: 0,
        dt: 1e-4,  // Default timestep
        cfl_number: 0
    )
}

// MARK: - Validation

extension NumericalDiagnostics {
    /// Check if diagnostics indicate healthy simulation
    public var isHealthy: Bool {
        // Convergence check
        guard converged else { return false }

        // Conservation checks (within 1% tolerance)
        guard abs(particle_drift) < 0.01 else { return false }
        guard abs(energy_drift) < 0.01 else { return false }
        guard abs(current_drift) < 0.01 else { return false }

        return true
    }

    /// Warning level (0 = healthy, 1 = warning, 2 = critical)
    public var warningLevel: Int {
        if !converged { return 2 }

        let maxDrift = max(
            abs(particle_drift),
            abs(energy_drift),
            abs(current_drift)
        )

        if maxDrift > 0.05 { return 2 }  // > 5% drift
        if maxDrift > 0.01 { return 1 }  // > 1% drift
        return 0  // Healthy
    }
}
