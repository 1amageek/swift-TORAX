import MLX
import Foundation

// MARK: - Linear Solver

/// Linear solver using predictor-corrector fixed-point iteration
///
/// Solves implicit transport equations using a predictor-corrector scheme:
/// 1. Predictor: Simple forward Euler step
/// 2. Corrector: Fixed-point iteration with Pereverzev correction (optional)
///
/// This solver is faster than Newton-Raphson for weakly nonlinear problems
/// but may not converge for strongly nonlinear cases.
public struct LinearSolver: PDESolver {
    // MARK: - Properties

    public let solverType: SolverType = .linear

    /// Number of corrector steps
    public let nCorrectorSteps: Int

    /// Use Pereverzev corrector (improves convergence)
    public let usePereversevCorrector: Bool

    /// Theta parameter for time discretization
    public let theta: Float

    // MARK: - Initialization

    public init(
        nCorrectorSteps: Int = 3,
        usePereversevCorrector: Bool = true,
        theta: Float = 1.0
    ) {
        precondition(nCorrectorSteps >= 1, "Must have at least 1 corrector step")
        precondition(theta >= 0.0 && theta <= 1.0, "Theta must be in [0, 1]")
        self.nCorrectorSteps = nCorrectorSteps
        self.usePereversevCorrector = usePereversevCorrector
        self.theta = theta
    }

    // MARK: - PDESolver Protocol

    public func solve(
        dt: Float,
        staticParams: StaticRuntimeParams,
        dynamicParamsT: DynamicRuntimeParams,
        dynamicParamsTplusDt: DynamicRuntimeParams,
        geometryT: Geometry,
        geometryTplusDt: Geometry,
        xOld: (CellVariable, CellVariable, CellVariable, CellVariable),
        coreProfilesT: CoreProfiles,
        coreProfilesTplusDt: CoreProfiles,
        coeffsCallback: @escaping CoeffsCallback
    ) -> SolverResult {
        // Initial guess
        var xNew = coreProfilesTplusDt

        // Get coefficients at old time
        let coeffsOld = coeffsCallback(coreProfilesT, geometryT)

        // Predictor step: Explicit Euler
        xNew = predictorStep(
            xOld: coreProfilesT,
            coeffsOld: coeffsOld,
            dt: dt,
            dr: staticParams.mesh.dr
        )

        // Corrector steps: Fixed-point iteration
        var residualNorm: Float = 0.0

        for iter in 0..<nCorrectorSteps {
            let xPrev = xNew

            // Get coefficients at new time
            let coeffsNew = coeffsCallback(xNew, geometryTplusDt)

            // Corrector step
            xNew = correctorStep(
                xOld: coreProfilesT,
                xPrev: xPrev,
                coeffsOld: coeffsOld,
                coeffsNew: coeffsNew,
                dt: dt,
                theta: theta,
                dr: staticParams.mesh.dr,
                usePereversev: usePereversevCorrector
            )

            // Compute residual norm
            residualNorm = computeResidualNorm(xNew: xNew, xPrev: xPrev)

            // Check convergence
            if residualNorm < 1e-6 {
                break
            }
        }

        return SolverResult(
            updatedProfiles: xNew,
            iterations: nCorrectorSteps,
            residualNorm: residualNorm,
            converged: residualNorm < 1e-6,
            metadata: [
                "theta": theta,
                "dt": dt,
                "corrector_steps": Float(nCorrectorSteps)
            ]
        )
    }

    // MARK: - Predictor Step

    /// Predictor step: Explicit Euler
    ///
    /// x^* = x^n + dt * f(x^n)
    private func predictorStep(
        xOld: CoreProfiles,
        coeffsOld: Block1DCoeffs,
        dt: Float,
        dr: Float
    ) -> CoreProfiles {
        // Apply spatial operator: f(x^n)
        let fOld = applySpatialOperator(
            profiles: xOld,
            coeffs: coeffsOld,
            dr: dr
        )

        // Update: x^* = x^n + dt * f(x^n)
        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: xOld.ionTemperature.value + dt * fOld.0),
            electronTemperature: EvaluatedArray(evaluating: xOld.electronTemperature.value + dt * fOld.1),
            electronDensity: EvaluatedArray(evaluating: xOld.electronDensity.value + dt * fOld.2),
            poloidalFlux: EvaluatedArray(evaluating: xOld.poloidalFlux.value + dt * fOld.3)
        )
    }

    // MARK: - Corrector Step

    /// Corrector step: Theta-method iteration
    ///
    /// x^{k+1} = x^n + dt * [θ*f(x^k) + (1-θ)*f(x^n)]
    private func correctorStep(
        xOld: CoreProfiles,
        xPrev: CoreProfiles,
        coeffsOld: Block1DCoeffs,
        coeffsNew: Block1DCoeffs,
        dt: Float,
        theta: Float,
        dr: Float,
        usePereversev: Bool
    ) -> CoreProfiles {
        // Spatial operator at old time: f(x^n)
        let fOld = applySpatialOperator(profiles: xOld, coeffs: coeffsOld, dr: dr)

        // Spatial operator at new time: f(x^k)
        let fNew = applySpatialOperator(profiles: xPrev, coeffs: coeffsNew, dr: dr)

        // Theta-method update
        let dtTheta = dt * theta
        let dtOneMinusTheta = dt * (1.0 - theta)

        var tiNew = xOld.ionTemperature.value + dtTheta * fNew.0 + dtOneMinusTheta * fOld.0
        var teNew = xOld.electronTemperature.value + dtTheta * fNew.1 + dtOneMinusTheta * fOld.1
        var neNew = xOld.electronDensity.value + dtTheta * fNew.2 + dtOneMinusTheta * fOld.2
        var psiNew = xOld.poloidalFlux.value + dtTheta * fNew.3 + dtOneMinusTheta * fOld.3

        // Pereverzev correction (improves convergence)
        if usePereversev {
            let alpha: Float = 0.5  // Damping factor
            tiNew = alpha * tiNew + (1.0 - alpha) * xPrev.ionTemperature.value
            teNew = alpha * teNew + (1.0 - alpha) * xPrev.electronTemperature.value
            neNew = alpha * neNew + (1.0 - alpha) * xPrev.electronDensity.value
            psiNew = alpha * psiNew + (1.0 - alpha) * xPrev.poloidalFlux.value
        }

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: tiNew),
            electronTemperature: EvaluatedArray(evaluating: teNew),
            electronDensity: EvaluatedArray(evaluating: neNew),
            poloidalFlux: EvaluatedArray(evaluating: psiNew)
        )
    }

    // MARK: - Spatial Operator

    /// Apply spatial operator to all profiles
    ///
    /// Returns: (f_Ti, f_Te, f_ne, f_psi)
    private func applySpatialOperator(
        profiles: CoreProfiles,
        coeffs: Block1DCoeffs,
        dr: Float
    ) -> (MLXArray, MLXArray, MLXArray, MLXArray) {
        // Apply per-equation operators

        let fTi = applyOperatorToVariable(
            x: profiles.ionTemperature.value,
            eqCoeffs: coeffs.ionCoeffs,
            geometry: coeffs.geometry
        )

        let fTe = applyOperatorToVariable(
            x: profiles.electronTemperature.value,
            eqCoeffs: coeffs.electronCoeffs,
            geometry: coeffs.geometry
        )

        let fNe = applyOperatorToVariable(
            x: profiles.electronDensity.value,
            eqCoeffs: coeffs.densityCoeffs,
            geometry: coeffs.geometry
        )

        let fPsi = applyOperatorToVariable(
            x: profiles.poloidalFlux.value,
            eqCoeffs: coeffs.fluxCoeffs,
            geometry: coeffs.geometry
        )

        return (fTi, fTe, fNe, fPsi)
    }

    /// Apply operator to single variable: ∇·(D ∇x) + v·∇x + S
    private func applyOperatorToVariable(
        x: MLXArray,
        eqCoeffs: EquationCoeffs,
        geometry: GeometricFactors
    ) -> MLXArray {
        let nCells = x.shape[0]

        // Extract coefficients
        let dFace = eqCoeffs.dFace.value
        let vFace = eqCoeffs.vFace.value
        let sourceCell = eqCoeffs.sourceCell.value

        // Get cell distance (assume uniform grid)
        let dx = geometry.cellDistances.value

        // Compute gradients at interior faces (vectorized)
        let x_right = x[1..<nCells]
        let x_left = x[0..<(nCells-1)]
        let gradFace_interior = (x_right - x_left) / (dx + 1e-10)

        // Boundary gradients
        let gradFace_left = gradFace_interior[0..<1]
        let gradFace_right = gradFace_interior[(nCells-2)..<(nCells-1)]
        let gradFace = concatenated([gradFace_left, gradFace_interior, gradFace_right], axis: 0)

        // Diffusion flux
        let diffFlux = -dFace * gradFace

        // Convection flux
        let xFace = interpolateToFaces(x)
        let convFlux = vFace * xFace

        // Total flux
        let totalFlux = diffFlux + convFlux

        // Divergence (vectorized)
        let flux_right = totalFlux[1..<(nCells + 1)]
        let flux_left = totalFlux[0..<nCells]
        let cellVolumes = geometry.cellVolumes.value
        let divergence = (flux_right - flux_left) / (cellVolumes + 1e-10)

        return divergence + sourceCell
    }

    /// Interpolate cell values to faces (vectorized)
    private func interpolateToFaces(_ cellValues: MLXArray) -> MLXArray {
        let nCells = cellValues.shape[0]

        // Interior faces (central difference)
        let left = cellValues[0..<(nCells-1)]
        let right = cellValues[1..<nCells]
        let interior = 0.5 * (left + right)

        // Boundary faces
        let leftBoundary = cellValues[0..<1]
        let rightBoundary = cellValues[(nCells-1)..<nCells]

        return concatenated([leftBoundary, interior, rightBoundary], axis: 0)
    }

    // MARK: - Convergence Check

    /// Compute residual norm between iterations
    private func computeResidualNorm(xNew: CoreProfiles, xPrev: CoreProfiles) -> Float {
        let diffTi = xNew.ionTemperature.value - xPrev.ionTemperature.value
        let diffTe = xNew.electronTemperature.value - xPrev.electronTemperature.value
        let diffNe = xNew.electronDensity.value - xPrev.electronDensity.value
        let diffPsi = xNew.poloidalFlux.value - xPrev.poloidalFlux.value

        let norm = sqrt(
            (diffTi * diffTi).mean() +
            (diffTe * diffTe).mean() +
            (diffNe * diffNe).mean() +
            (diffPsi * diffPsi).mean()
        )

        return norm.item(Float.self)
    }
}
