// ActuatorTimeSeries.swift
// Differentiable control parameters for optimization

import Foundation
import MLX

/// Actuator time series for optimization
///
/// Represents control parameters (ECRH power, ICRH power, gas puff, plasma current)
/// that can be optimized using gradient-based methods.
///
/// **Design (Gradient-preserving)**:
/// - Internal representation: MLXArray (preserves gradient tape)
/// - External interface: [Float] accessors (for convenience)
/// - Shape: [nSteps, 4] where 4 = [P_ECRH, P_ICRH, gas_puff, I_plasma]
/// - All operations maintain differentiability
public struct ActuatorTimeSeries {
    /// Internal MLXArray representation (gradient-preserving)
    /// Shape: [nSteps × 4] (flattened for optimization)
    private let data: MLXArray

    /// Number of timesteps
    public let nSteps: Int

    // MARK: - Read-only accessors (for display/logging)

    /// ECRH power at each timestep [MW]
    public var P_ECRH: [Float] {
        let start = 0
        let end = nSteps
        return Array(data.asArray(Float.self)[start..<end])
    }

    /// ICRH power at each timestep [MW]
    public var P_ICRH: [Float] {
        let start = nSteps
        let end = 2 * nSteps
        return Array(data.asArray(Float.self)[start..<end])
    }

    /// Gas puff rate at each timestep [particles/s]
    public var gas_puff: [Float] {
        let start = 2 * nSteps
        let end = 3 * nSteps
        return Array(data.asArray(Float.self)[start..<end])
    }

    /// Plasma current at each timestep [MA]
    public var I_plasma: [Float] {
        let start = 3 * nSteps
        let end = 4 * nSteps
        return Array(data.asArray(Float.self)[start..<end])
    }

    // MARK: - Initialization

    /// Create actuator time series from Float arrays
    public init(
        P_ECRH: [Float],
        P_ICRH: [Float],
        gas_puff: [Float],
        I_plasma: [Float]
    ) {
        precondition(P_ECRH.count == P_ICRH.count, "All actuators must have same length")
        precondition(P_ECRH.count == gas_puff.count, "All actuators must have same length")
        precondition(P_ECRH.count == I_plasma.count, "All actuators must have same length")
        precondition(P_ECRH.count > 0, "Must have at least one timestep")

        self.nSteps = P_ECRH.count

        // Create flat MLXArray (gradient-preserving)
        let flat = P_ECRH + P_ICRH + gas_puff + I_plasma
        self.data = MLXArray(flat)
    }

    /// Create from MLXArray (preserves gradient tape)
    private init(mlxArray: MLXArray, nSteps: Int) {
        precondition(mlxArray.shape[0] == nSteps * 4,
                    "Array shape \(mlxArray.shape[0]) != nSteps (\(nSteps)) × 4")

        self.data = mlxArray
        self.nSteps = nSteps
    }

    /// Create constant actuators (same value at all timesteps)
    public static func constant(
        P_ECRH: Float,
        P_ICRH: Float,
        gas_puff: Float,
        I_plasma: Float,
        nSteps: Int
    ) -> ActuatorTimeSeries {
        precondition(nSteps > 0, "Must have at least one timestep")

        return ActuatorTimeSeries(
            P_ECRH: [Float](repeating: P_ECRH, count: nSteps),
            P_ICRH: [Float](repeating: P_ICRH, count: nSteps),
            gas_puff: [Float](repeating: gas_puff, count: nSteps),
            I_plasma: [Float](repeating: I_plasma, count: nSteps)
        )
    }

    // MARK: - MLXArray Conversion (Gradient-preserving)

    /// Convert to MLXArray for differentiation
    ///
    /// **Critical**: Returns internal MLXArray directly (no copy)
    /// This preserves the gradient tape for automatic differentiation
    ///
    /// Layout: [P_ECRH_0, ..., P_ECRH_N, P_ICRH_0, ..., P_ICRH_N, ...]
    /// Total length: nSteps × 4
    public func toMLXArray() -> MLXArray {
        return data  // Return internal representation (gradient-preserving!)
    }

    /// Create from MLXArray (preserves gradient tape)
    ///
    /// **Critical**: Wraps MLXArray directly without conversion
    /// This preserves the gradient tape for backpropagation
    public static func fromMLXArray(_ array: MLXArray, nSteps: Int) -> ActuatorTimeSeries {
        return ActuatorTimeSeries(mlxArray: array, nSteps: nSteps)
    }

    /// Get actuator values at specific timestep index
    public func at(step: Int) -> ActuatorValues {
        precondition(step >= 0 && step < nSteps, "Step \(step) out of range [0, \(nSteps))")

        return ActuatorValues(
            P_ECRH: P_ECRH[step],
            P_ICRH: P_ICRH[step],
            gas_puff: gas_puff[step],
            I_plasma: I_plasma[step]
        )
    }

    /// Get actuator values at specific time (interpolated)
    public func at(time: Float, dt: Float) -> ActuatorValues {
        let step = Int(time / dt)

        // Clamp to valid range
        let clampedStep = max(0, min(step, nSteps - 1))

        return at(step: clampedStep)
    }
}

/// Actuator values at a single timestep
public struct ActuatorValues {
    /// ECRH power [MW]
    public let P_ECRH: Float

    /// ICRH power [MW]
    public let P_ICRH: Float

    /// Gas puff rate [particles/s]
    public let gas_puff: Float

    /// Plasma current [MA]
    public let I_plasma: Float

    public init(
        P_ECRH: Float,
        P_ICRH: Float,
        gas_puff: Float,
        I_plasma: Float
    ) {
        self.P_ECRH = P_ECRH
        self.P_ICRH = P_ICRH
        self.gas_puff = gas_puff
        self.I_plasma = I_plasma
    }
}

/// Actuator constraints (physical limits)
public struct ActuatorConstraints: Sendable {
    public let minECRH: Float
    public let maxECRH: Float
    public let minICRH: Float
    public let maxICRH: Float
    public let minCurrent: Float
    public let maxCurrent: Float
    public let minGasPuff: Float
    public let maxGasPuff: Float

    public init(
        minECRH: Float,
        maxECRH: Float,
        minICRH: Float,
        maxICRH: Float,
        minCurrent: Float,
        maxCurrent: Float,
        minGasPuff: Float,
        maxGasPuff: Float
    ) {
        self.minECRH = minECRH
        self.maxECRH = maxECRH
        self.minICRH = minICRH
        self.maxICRH = maxICRH
        self.minCurrent = minCurrent
        self.maxCurrent = maxCurrent
        self.minGasPuff = minGasPuff
        self.maxGasPuff = maxGasPuff
    }

    /// ITER Baseline constraints
    public static let iter = ActuatorConstraints(
        minECRH: 0.0,
        maxECRH: 30.0,        // 30 MW maximum
        minICRH: 0.0,
        maxICRH: 20.0,        // 20 MW maximum
        minCurrent: 5.0,      // 5 MA minimum
        maxCurrent: 20.0,     // 20 MA maximum (ITER: 15 MA baseline)
        minGasPuff: 0.0,
        maxGasPuff: 1e21      // 10²¹ particles/s maximum
    )

    /// Apply constraints (clamp to limits)
    public func apply(to actuators: ActuatorTimeSeries) -> ActuatorTimeSeries {
        return ActuatorTimeSeries(
            P_ECRH: actuators.P_ECRH.map { clamp($0, min: minECRH, max: maxECRH) },
            P_ICRH: actuators.P_ICRH.map { clamp($0, min: minICRH, max: maxICRH) },
            gas_puff: actuators.gas_puff.map { clamp($0, min: minGasPuff, max: maxGasPuff) },
            I_plasma: actuators.I_plasma.map { clamp($0, min: minCurrent, max: maxCurrent) }
        )
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        return Swift.max(min, Swift.min(max, value))
    }
}
