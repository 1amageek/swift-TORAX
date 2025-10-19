import Foundation

// MARK: - Diagnostic Result

/// Result from a simulation diagnostic check
///
/// Diagnostics monitor simulation health in real-time, detecting issues like:
/// - Ill-conditioned Jacobian matrices
/// - Negative/non-physical transport coefficients
/// - Conservation law drift
/// - NaN/Inf values
///
/// ## Severity Levels
///
/// - **info**: Normal operation, informational message
/// - **warning**: Potential issue, but simulation can continue
/// - **error**: Significant problem, results may be unreliable
/// - **critical**: Catastrophic failure imminent (NaN, Inf, singularity)
///
/// ## Example Usage
///
/// ```swift
/// let result = DiagnosticResult(
///     name: "JacobianConditioning",
///     severity: .warning,
///     message: "Jacobian condition number: κ = 5.2e5",
///     value: 520000.0,
///     threshold: 1e6,
///     time: 1.234,
///     step: 12340
/// )
///
/// if result.severity == .error || result.severity == .critical {
///     print(result.formatted())
/// }
/// ```
public struct DiagnosticResult: Sendable, Codable {
    /// Diagnostic name (e.g., "JacobianConditioning")
    public let name: String

    /// Severity level
    public let severity: Severity

    /// Human-readable message
    public let message: String

    /// Measured value (optional)
    public let value: Float?

    /// Threshold value (optional)
    public let threshold: Float?

    /// Simulation time [s]
    public let time: Float

    /// Timestep number
    public let step: Int

    /// Severity level for diagnostics
    public enum Severity: String, Sendable, Codable {
        case info = "ℹ️"
        case warning = "⚠️"
        case error = "❌"
        case critical = "🔥"
    }

    public init(
        name: String,
        severity: Severity,
        message: String,
        value: Float? = nil,
        threshold: Float? = nil,
        time: Float,
        step: Int
    ) {
        self.name = name
        self.severity = severity
        self.message = message
        self.value = value
        self.threshold = threshold
        self.time = time
        self.step = step
    }

    /// Formatted output for logging
    public func formatted() -> String {
        var output = "[\(severity.rawValue) \(name)] \(message)"

        if let value = value {
            output += "\n  Value: \(value)"
        }

        if let threshold = threshold {
            output += "\n  Threshold: \(threshold)"
        }

        output += "\n  Time: \(String(format: "%.4f", time))s, Step: \(step)"

        return output
    }
}

// MARK: - Diagnostics Configuration

/// Configuration for optional diagnostics
///
/// Some diagnostics (like Jacobian SVD) are expensive and disabled by default.
///
/// ## Example
///
/// ```swift
/// let config = DiagnosticsConfig(
///     enableJacobianCheck: true,
///     jacobianCheckInterval: 5000,
///     conditionThreshold: 1e6
/// )
/// ```
public struct DiagnosticsConfig: Sendable {
    /// Enable expensive Jacobian SVD check (disabled by default)
    public let enableJacobianCheck: Bool

    /// Check interval for Jacobian (only if enabled)
    public let jacobianCheckInterval: Int

    /// Condition number threshold for warnings
    public let conditionThreshold: Float

    public init(
        enableJacobianCheck: Bool = false,
        jacobianCheckInterval: Int = 5000,
        conditionThreshold: Float = 1e6
    ) {
        self.enableJacobianCheck = enableJacobianCheck
        self.jacobianCheckInterval = jacobianCheckInterval
        self.conditionThreshold = conditionThreshold
    }
}
