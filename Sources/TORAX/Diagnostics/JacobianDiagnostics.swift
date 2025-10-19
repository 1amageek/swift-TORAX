import MLX
import Foundation

// MARK: - Jacobian Diagnostics

/// Diagnostics for Jacobian matrix conditioning
///
/// Monitors the condition number κ(J) = σ_max / σ_min to detect ill-conditioned
/// or singular matrices that can cause Newton-Raphson convergence failures.
///
/// ## Condition Number Interpretation
///
/// - κ < 10³: Well-conditioned (excellent)
/// - 10³ < κ < 10⁵: Moderate (acceptable)
/// - 10⁵ < κ < 10⁶: Poor (enable preconditioning)
/// - κ > 10⁶: Ill-conditioned (numerical issues likely)
/// - κ = ∞: Singular matrix (σ_min = 0)
///
/// ## Performance Note
///
/// SVD is O(n³) → expensive! Run only periodically (e.g., every 5000 steps)
/// or on-demand for debugging. Disabled by default.
///
/// ## Example Usage
///
/// ```swift
/// let config = DiagnosticsConfig(
///     enableJacobianCheck: true,
///     jacobianCheckInterval: 5000,
///     conditionThreshold: 1e6
/// )
///
/// if step % config.jacobianCheckInterval == 0 {
///     let result = JacobianDiagnostics.diagnose(
///         jacobian: jacobian,
///         step: step,
///         time: time,
///         threshold: config.conditionThreshold
///     )
///
///     if result.severity == .critical {
///         print(result.formatted())
///     }
/// }
/// ```
public struct JacobianDiagnostics {

    /// Diagnose Jacobian conditioning
    ///
    /// Computes condition number via SVD and maps to severity level.
    ///
    /// - Parameters:
    ///   - jacobian: Jacobian matrix [n×n]
    ///   - step: Current timestep
    ///   - time: Current simulation time [s]
    ///   - threshold: Condition number threshold for error (default: 1e6)
    /// - Returns: Diagnostic result
    ///
    /// ## Implementation
    ///
    /// ```swift
    /// let (_, S, _) = svd(jacobian)  // O(n³)
    /// let kappa = S.max() / S.min()
    ///
    /// if sigma_min < 1e-12:
    ///     severity = .critical  // Singular matrix
    /// elif kappa > threshold:
    ///     severity = .error     // Ill-conditioned
    /// elif kappa > threshold/10:
    ///     severity = .warning   // Moderate conditioning
    /// else:
    ///     severity = .info      // Well-conditioned
    /// ```
    public static func diagnose(
        jacobian: MLXArray,
        step: Int,
        time: Float,
        threshold: Float = 1e6
    ) -> DiagnosticResult {
        // Perform SVD to get singular values
        let (_, S, _) = MLX.svd(jacobian)
        eval(S)

        let sigma_max = S.max().item(Float.self)
        let sigma_min = S.min().item(Float.self)

        // Check for singularity FIRST (σ_min ≈ 0)
        if sigma_min < 1e-12 || !sigma_min.isFinite {
            return DiagnosticResult(
                name: "JacobianConditioning",
                severity: .critical,
                message: "Singular matrix detected: σ_min = \(String(format: "%.2e", sigma_min))",
                value: Float.infinity,
                threshold: threshold,
                time: time,
                step: step
            )
        }

        // Compute condition number
        let kappa = sigma_max / sigma_min

        // Check for non-finite condition number
        guard kappa.isFinite else {
            return DiagnosticResult(
                name: "JacobianConditioning",
                severity: .critical,
                message: "Non-finite condition number",
                value: Float.infinity,
                threshold: threshold,
                time: time,
                step: step
            )
        }

        // Map condition number to severity
        let severity: DiagnosticResult.Severity
        let severityDesc: String

        if kappa > threshold {
            severity = .error
            severityDesc = "Ill-conditioned"
        } else if kappa > threshold / 10 {
            severity = .warning
            severityDesc = "Moderate conditioning"
        } else {
            severity = .info
            severityDesc = "Well-conditioned"
        }

        return DiagnosticResult(
            name: "JacobianConditioning",
            severity: severity,
            message: "\(severityDesc): κ = \(String(format: "%.2e", kappa))",
            value: kappa,
            threshold: threshold,
            time: time,
            step: step
        )
    }

    /// Compute condition number (convenience method)
    ///
    /// - Parameter jacobian: Jacobian matrix [n×n]
    /// - Returns: Condition number κ = σ_max / σ_min
    public static func computeConditionNumber(_ jacobian: MLXArray) -> Float {
        let (_, S, _) = MLX.svd(jacobian)
        eval(S)

        let sigma_max = S.max().item(Float.self)
        let sigma_min = S.min().item(Float.self)

        guard sigma_min > 0, sigma_min.isFinite else {
            return Float.infinity
        }

        return sigma_max / sigma_min
    }
}
