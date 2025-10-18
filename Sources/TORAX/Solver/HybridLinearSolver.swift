import Foundation
import MLX

// MARK: - Hybrid Linear Solver

/// Hybrid linear solver combining direct and iterative methods
///
/// Strategy for numerical robustness:
/// 1. Estimate condition number of system matrix
/// 2. If well-conditioned (κ < threshold): Use MLX.solve() (fast, accurate)
/// 3. If ill-conditioned (κ ≥ threshold): Use iterative SOR solver (robust)
/// 4. Verify solution quality for direct solver
///
/// Expected performance:
/// - Well-conditioned systems: 10-50x faster than iterative (via MLX.solve)
/// - Ill-conditioned systems: Robust convergence via SOR
/// - Automatic fallback ensures numerical stability
public struct HybridLinearSolver: Sendable {
    /// Condition number threshold for switching to iterative solver
    ///
    /// Typical values:
    /// - 1e6: Very conservative (rarely use direct solver)
    /// - 1e8: Balanced (recommended for float32)
    /// - 1e10: Aggressive (may have numerical issues)
    public let conditionThreshold: Float

    /// Iterative solver tolerance
    ///
    /// Stopping criterion: ||x_new - x_old|| / ||x_new|| < tolerance
    public let iterativeTolerance: Float

    /// Maximum iterations for iterative solver
    public let maxIterations: Int

    /// SOR relaxation parameter (ω ∈ [1, 2])
    ///
    /// - ω = 1.0: Gauss-Seidel
    /// - ω ∈ (1, 2): Over-relaxation (faster convergence for some systems)
    /// - ω = 1.5: Typical default (good for many PDEs)
    public let omega: Float

    /// Create hybrid linear solver
    ///
    /// - Parameters:
    ///   - conditionThreshold: Condition number threshold (default: 1e8)
    ///   - iterativeTolerance: Convergence tolerance (default: 1e-8)
    ///   - maxIterations: Maximum iterations (default: 10000)
    ///   - omega: SOR relaxation parameter (default: 1.5)
    public init(
        conditionThreshold: Float = 1e8,
        iterativeTolerance: Float = 1e-8,
        maxIterations: Int = 10000,
        omega: Float = 1.5
    ) {
        self.conditionThreshold = conditionThreshold
        self.iterativeTolerance = iterativeTolerance
        self.maxIterations = maxIterations
        self.omega = omega
    }

    /// Solve linear system Ax = b with automatic method selection
    ///
    /// - Parameters:
    ///   - A: System matrix [n, n]
    ///   - b: Right-hand side [n]
    /// - Returns: Solution x [n]
    /// - Throws: SolverError if solution fails to converge
    public func solve(_ A: MLXArray, _ b: MLXArray) throws -> MLXArray {
        // Estimate condition number using power iteration
        let estimatedCond = estimateConditionNumber(A, maxIter: 20)

        if estimatedCond < conditionThreshold {
            // Well-conditioned → Try direct solver
            let x = MLX.solve(A, b)

            // Verify solution quality
            let residual = matmul(A, x) - b

            // CRITICAL: Force evaluation before calling .item()
            // MLX.norm() returns lazy MLXArray
            let residualNormArray = MLX.norm(residual)
            let rhsNormArray = MLX.norm(b)
            eval(residualNormArray, rhsNormArray)

            let residualNorm = residualNormArray.item(Float.self)
            let rhsNorm = rhsNormArray.item(Float.self)
            let relativeError = residualNorm / (rhsNorm + 1e-10)

            if relativeError < iterativeTolerance * 10 {
                // Direct solution is acceptable
                return x
            }

            // Direct solver produced poor solution → fall back
            print("[HybridLinearSolver] Direct solver failed quality check (rel_err=\(String(format: "%.2e", relativeError))), falling back to iterative")
        }

        // Ill-conditioned or direct solver failed → Use iterative
        print("[HybridLinearSolver] Using iterative solver (est_cond=\(String(format: "%.2e", estimatedCond)))")
        return try solveIterative(A, b)
    }

    /// Estimate condition number using power iteration
    ///
    /// Computes κ(A) ≈ ||A|| * ||A⁻¹|| using power method
    ///
    /// - Parameters:
    ///   - A: Matrix [n, n]
    ///   - maxIter: Maximum power iterations
    /// - Returns: Estimated condition number
    private func estimateConditionNumber(_ A: MLXArray, maxIter: Int = 20) -> Float {
        let n = A.shape[0]

        // Estimate ||A|| using power iteration
        var v = MLXArray.ones([n])  // Use ones instead of random for deterministic behavior
        for _ in 0..<maxIter {
            v = matmul(A, v)

            // CRITICAL: Force evaluation before calling .item()
            // MLX.norm(v) is a lazy MLXArray
            let vnormArray = MLX.norm(v)
            eval(vnormArray)
            let vnorm = vnormArray.item(Float.self)

            if vnorm < 1e-10 {
                return 1e15  // Matrix is essentially singular
            }
            v = v / vnorm
        }

        // CRITICAL: Force evaluation before calling .item()
        // MLX.norm(matmul(A, v)) is a lazy MLXArray
        let normAArray = MLX.norm(matmul(A, v))
        eval(normAArray)
        let normA = normAArray.item(Float.self)

        // Estimate ||A⁻¹|| by solving Ay = v using few SOR iterations
        var y = MLXArray.zeros([n])
        for _ in 0..<maxIter {
            // Approximate A⁻¹v using few SOR iterations
            y = sorIteration(A, v, x: y, omega: 1.0, iterations: 5)
        }

        // CRITICAL: Force evaluation before calling .item()
        // MLX.norm(y) and MLX.norm(v) are lazy MLXArrays
        let normYArray = MLX.norm(y)
        let normVArray = MLX.norm(v)
        eval(normYArray, normVArray)

        let normY = normYArray.item(Float.self)
        let normV = normVArray.item(Float.self)
        let normAinv = normY / (normV + 1e-10)

        let cond = normA * normAinv
        return cond.isFinite ? cond : 1e15
    }

    /// Solve using Successive Over-Relaxation (SOR)
    ///
    /// SOR iteration: x_new[i] = (1-ω)x[i] + (ω/a_ii)(b[i] - Σ a_ij x_j)
    ///
    /// - Parameters:
    ///   - A: System matrix [n, n]
    ///   - b: Right-hand side [n]
    /// - Returns: Solution x [n]
    /// - Throws: SolverError.convergenceFailure if not converged
    private func solveIterative(_ A: MLXArray, _ b: MLXArray) throws -> MLXArray {
        let n = A.shape[0]
        var x = MLXArray.zeros([n])

        for iter in 0..<maxIterations {
            let xOld = x
            x = sorIteration(A, b, x: x, omega: omega, iterations: 1)

            // Check convergence
            let diff = x - xOld

            // CRITICAL: Force evaluation before calling .item()
            // MLX.norm() returns lazy MLXArray
            let normDiffArray = MLX.norm(diff)
            let normXArray = MLX.norm(x)
            eval(normDiffArray, normXArray)

            let relativeChange = normDiffArray.item(Float.self) / (normXArray.item(Float.self) + 1e-10)

            if relativeChange < iterativeTolerance {
                print("[HybridLinearSolver] Converged in \(iter + 1) iterations (rel_change=\(String(format: "%.2e", relativeChange)))")
                return x
            }

            // Early stopping if diverging
            if relativeChange > 1e6 || !relativeChange.isFinite {
                print("[HybridLinearSolver] SOR diverging (rel_change=\(String(format: "%.2e", relativeChange)))")
                throw SolverError.convergenceFailure(
                    iterations: iter + 1,
                    residualNorm: relativeChange
                )
            }
        }

        print("[HybridLinearSolver] SOR did not converge in \(maxIterations) iterations")
        throw SolverError.convergenceFailure(
            iterations: maxIterations,
            residualNorm: Float.infinity
        )
    }

    /// True SOR iteration (HIGH #4 FIX)
    ///
    /// Implements proper Successive Over-Relaxation with forward sweep.
    /// Uses updated values immediately (Gauss-Seidel style + over-relaxation).
    ///
    /// Algorithm: x_new[i] = (1-ω)x[i] + (ω/A[i,i]) * (b[i] - Σ(j≠i) A[i,j]*x[j])
    ///
    /// Note: This requires a sequential forward sweep, so it's less vectorized
    /// than the previous Jacobi-style implementation. However, it converges
    /// 2-10x faster for many PDE systems.
    ///
    /// - Parameters:
    ///   - A: System matrix [n, n]
    ///   - b: Right-hand side [n]
    ///   - x: Current solution [n]
    ///   - omega: Relaxation parameter (1.0 = Gauss-Seidel, >1.0 = over-relaxation)
    ///   - iterations: Number of SOR sweeps
    /// - Returns: Updated solution [n]
    private func sorIteration(
        _ A: MLXArray,
        _ b: MLXArray,
        x: MLXArray,
        omega: Float,
        iterations: Int
    ) -> MLXArray {
        var xCurrent = x
        let n = A.shape[0]

        // Extract diagonal once (vectorized)
        let diag = extractDiagonal(A, n: n)  // [n]

        for _ in 0..<iterations {
            // True SOR: Forward sweep with immediate updates
            // Note: This loop is necessary for Gauss-Seidel convergence properties
            for i in 0..<n {
                // Compute: b[i] - Σ(j≠i) A[i,j] * x[j]
                // Use row slice and dot product for efficiency
                let A_row = A[i, 0..<n]  // Get entire row [n]

                // CRITICAL: Force evaluation before calling .item()
                // All of these are lazy MLXArrays (slices and arithmetic results)
                let axArray = (A_row * xCurrent).sum()
                let b_i_array = b[i]
                let a_ii_array = diag[i]
                let x_i_old_array = xCurrent[i]
                eval(axArray, b_i_array, a_ii_array, x_i_old_array)

                let ax = axArray.item(Float.self)  // A[i,:] · x
                let b_i = b_i_array.item(Float.self)
                let a_ii = a_ii_array.item(Float.self)
                let x_i_old = x_i_old_array.item(Float.self)

                // SOR update: x_new[i] = (1-ω)x[i] + (ω/a_ii)(b[i] - Σ(j≠i) a_ij*x_j)
                // Note: ax includes a_ii*x_i, so we subtract it
                let residual_i = b_i - (ax - a_ii * x_i_old)
                let x_i_new = (1.0 - omega) * x_i_old + (omega / (a_ii + 1e-10)) * residual_i

                // Update x[i] immediately (key difference from Jacobi)
                xCurrent[i] = MLXArray(x_i_new)
            }

            // Ensure computation is complete before next iteration
            eval(xCurrent)
        }

        return xCurrent
    }

    /// Extract diagonal from matrix (VECTORIZED - MEDIUM #6 FIX)
    ///
    /// - Parameters:
    ///   - A: Matrix [n, n]
    ///   - n: Matrix size
    /// - Returns: Diagonal elements [n]
    private func extractDiagonal(_ A: MLXArray, n: Int) -> MLXArray {
        // MEDIUM #6 FIX: Vectorized diagonal extraction
        // Create index array [0, 1, 2, ..., n-1]
        let indices = MLXArray(0..<n)

        // Extract diagonal using advanced indexing: A[indices, indices]
        // This extracts A[0,0], A[1,1], A[2,2], ..., A[n-1,n-1] in one operation
        let diag = A[indices, indices]

        return diag
    }
}
