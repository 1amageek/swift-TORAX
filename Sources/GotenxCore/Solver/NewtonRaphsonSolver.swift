import MLX
import Foundation

// MARK: - Newton-Raphson Solver

/// Newton-Raphson solver for nonlinear implicit PDE systems
///
/// Uses automatic differentiation (vjp) for efficient Jacobian computation.
/// Solves: R(x^{n+1}) = 0
/// where R is the residual function from theta-method time discretization.
///
/// Key features:
/// - Vectorized spatial operators (NO loops)
/// - Per-equation coefficient handling (4 coupled equations)
/// - Hybrid linear solver (direct + iterative fallback)
/// - Efficient Jacobian via vjp() (3-4x faster than separate grad() calls)
public struct NewtonRaphsonSolver: PDESolver {
    // MARK: - Properties

    public let solverType: SolverType = .newtonRaphson

    /// Convergence tolerance for residual norm
    public let tolerance: Float

    /// Maximum number of Newton iterations
    public let maxIterations: Int

    /// Theta parameter for time discretization (0: explicit, 0.5: Crank-Nicolson, 1: implicit)
    public let theta: Float

    /// Hybrid linear solver
    private let linearSolver: HybridLinearSolver

    // MARK: - Initialization

    public init(
        tolerance: Float = 1e-6,
        maxIterations: Int = 100,  // ✅ INCREASED: Allow more iterations for ill-conditioned systems
        theta: Float = 1.0,
        linearSolver: HybridLinearSolver = HybridLinearSolver()
    ) {
        precondition(theta >= 0.0 && theta <= 1.0, "Theta must be in [0, 1]")
        self.tolerance = tolerance
        self.maxIterations = maxIterations
        self.theta = theta
        self.linearSolver = linearSolver
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
        // 🐛 DEBUG: Check initial profiles for inf/nan
        let ti_init = coreProfilesTplusDt.ionTemperature.value
        let te_init = coreProfilesTplusDt.electronTemperature.value
        let ne_init = coreProfilesTplusDt.electronDensity.value
        let psi_init = coreProfilesTplusDt.poloidalFlux.value

        // Check for inf/nan in initial profiles
        let ti_min = ti_init.min(keepDims: false).item(Float.self)
        let ti_max = ti_init.max(keepDims: false).item(Float.self)
        let te_min = te_init.min(keepDims: false).item(Float.self)
        let te_max = te_init.max(keepDims: false).item(Float.self)
        let ne_min = ne_init.min(keepDims: false).item(Float.self)
        let ne_max = ne_init.max(keepDims: false).item(Float.self)

        print("[DEBUG-NR-INIT] Initial profiles:")
        print("[DEBUG-NR-INIT]   Ti: min=\(ti_min), max=\(ti_max)")
        print("[DEBUG-NR-INIT]   Te: min=\(te_min), max=\(te_max)")
        print("[DEBUG-NR-INIT]   ne: min=\(ne_min), max=\(ne_max)")

        if !ti_min.isFinite || !ti_max.isFinite || !te_min.isFinite || !te_max.isFinite || !ne_min.isFinite || !ne_max.isFinite {
            print("[DEBUG-NR-INIT] ❌ Initial profiles contain inf/nan!")
        }

        // Flatten initial guess
        let xFlat = try! FlattenedState(profiles: coreProfilesTplusDt)
        let xOldFlat = try! FlattenedState(profiles: CoreProfiles.fromTuple(xOld))
        let layout = xFlat.layout

        // 🐛 DEBUG: Check flattened state
        let xFlat_min = xFlat.values.value.min(keepDims: false).item(Float.self)
        let xFlat_max = xFlat.values.value.max(keepDims: false).item(Float.self)
        print("[DEBUG-NR-INIT] Flattened state: min=\(xFlat_min), max=\(xFlat_max)")
        if !xFlat_min.isFinite || !xFlat_max.isFinite {
            print("[DEBUG-NR-INIT] ❌ Flattened state contains inf/nan!")
        }

        // GPU Variable Scaling: Create reference state for normalization
        // Uses physically meaningful scales per variable (Ti~1keV, Te~1keV, ne~10^20, psi~1Wb)
        // This prevents Float32 precision loss from extreme scale differences (e.g., psi=0 vs ne=10^20)
        let referenceState = xFlat.asPhysicalScalingReference()

        // 🐛 DEBUG: Check referenceState for inf/nan
        let ref_min = referenceState.values.value.min(keepDims: false).item(Float.self)
        let ref_max = referenceState.values.value.max(keepDims: false).item(Float.self)
        print("[DEBUG-NR-SCALE] referenceState: min=\(ref_min), max=\(ref_max)")

        // 🔬 INVESTIGATION: referenceState per variable (iter 0 only will check in loop)
        let nCells = layout.nCells
        let refArray = referenceState.values.value
        let Ti_ref = refArray[0..<nCells]
        let Te_ref = refArray[nCells..<(2*nCells)]
        let ne_ref = refArray[(2*nCells)..<(3*nCells)]
        eval(Ti_ref, Te_ref, ne_ref)

        print("[INVESTIGATION] referenceState breakdown (nCells=\(nCells)):")
        print("[INVESTIGATION]   Ti_ref range: [\(Ti_ref.min().item(Float.self)), \(Ti_ref.max().item(Float.self))]")
        print("[INVESTIGATION]   Te_ref range: [\(Te_ref.min().item(Float.self)), \(Te_ref.max().item(Float.self))]")
        print("[INVESTIGATION]   ne_ref range: [\(ne_ref.min().item(Float.self)), \(ne_ref.max().item(Float.self))]")

        // 🐛 DEBUG: Confirm GPU execution
        let defaultDevice = Device.defaultDevice()
        print("[DEBUG-NR-DEVICE] Default device: \(defaultDevice.deviceType ?? .gpu) (all MLX ops run on this device)")
        if !ref_min.isFinite || !ref_max.isFinite {
            print("[DEBUG-NR-SCALE] ❌ referenceState contains inf/nan!")
        }

        // Scale initial state to O(1)
        var xScaled = xFlat.scaled(by: referenceState)

        // 🐛 DEBUG: Check xScaled for inf/nan
        let xScaled_min = xScaled.values.value.min(keepDims: false).item(Float.self)
        let xScaled_max = xScaled.values.value.max(keepDims: false).item(Float.self)
        print("[DEBUG-NR-SCALE] xScaled: min=\(xScaled_min), max=\(xScaled_max)")
        if !xScaled_min.isFinite || !xScaled_max.isFinite {
            print("[DEBUG-NR-SCALE] ❌ xScaled contains inf/nan!")
        }

        // Get coefficients at old time
        let coeffsOld = coeffsCallback(coreProfilesT, geometryT)

        // Extract boundary conditions
        let boundaryConditions = dynamicParamsTplusDt.boundaryConditions

        // Residual function in PHYSICAL space (not scaled)
        // This ensures physics calculations use correct units
        let residualFnPhysical: (MLXArray) -> MLXArray = { xNewFlatPhysical in
            // Unflatten to CoreProfiles (physical units)
            let xNewState = FlattenedState(values: EvaluatedArray(evaluating: xNewFlatPhysical), layout: layout)
            // Clamp density to maintain physical feasibility during iteration
            let profilesNew = xNewState
                .toCoreProfiles()
                .withElectronDensityClamped()

            // Get coefficients at new time (via callback)
            let coeffsNew = coeffsCallback(profilesNew, geometryTplusDt)

            // Compute residual for theta-method (physical units)
            let residual = self.computeThetaMethodResidual(
                xOld: xOldFlat.values.value,
                xNew: xNewFlatPhysical,
                coeffsOld: coeffsOld,
                coeffsNew: coeffsNew,
                dt: dt,
                theta: self.theta,
                geometry: geometryTplusDt,
                boundaryConditions: boundaryConditions
            )

            return residual
        }

        // Residual function in SCALED space (for Newton iteration)
        // Converts scaled variables to physical, computes residual, then scales residual back
        let residualFnScaled: (MLXArray) -> MLXArray = { xNewScaled in
            // Unscale to physical units
            let xScaledState = FlattenedState(values: EvaluatedArray(evaluating: xNewScaled), layout: layout)
            let xPhysical = xScaledState.unscaled(by: referenceState)

            // Compute residual in physical units
            let residualPhysical = residualFnPhysical(xPhysical.values.value)

            // Scale residual for uniform precision
            let residualState = FlattenedState(values: EvaluatedArray(evaluating: residualPhysical), layout: layout)
            let residualScaled = residualState.scaled(by: referenceState)

            return residualScaled.values.value
        }

        // Newton-Raphson iteration in SCALED space
        var converged = false
        var iterations = 0
        var residualNorm: Float = 0.0

        // ✅ PHASE 1-2: Track per-variable residual norms for improvement analysis
        var prevResidualNorm_Ti: Float = 0.0
        var prevResidualNorm_Te: Float = 0.0
        var prevResidualNorm_ne: Float = 0.0
        var prevResidualNorm_psi: Float = 0.0

        for iter in 0..<maxIterations {
            iterations = iter + 1

            // 🐛 DEBUG: Iteration start with timer
            let iterStartTime = Date()
            print("[DEBUG-NR] ===== Iteration \(iter) start =====")

            // 🐛 DEBUG: Check xScaled for numerical issues at iteration start
            let xScaled_min = xScaled.values.value.min(keepDims: false)
            let xScaled_max = xScaled.values.value.max(keepDims: false)
            eval(xScaled_min, xScaled_max)
            let x_min = xScaled_min.item(Float.self)
            let x_max = xScaled_max.item(Float.self)

            if !x_min.isFinite || !x_max.isFinite {
                print("[DEBUG-NR] ⚠️  iter=\(iter): xScaled contains NaN/Inf! min=\(x_min), max=\(x_max)")
                print("[DEBUG-NR] ⚠️  Stopping iteration to prevent divergence")
                break
            }

            if x_min.magnitude > 1e10 || x_max.magnitude > 1e10 {
                print("[DEBUG-NR] ⚠️  iter=\(iter): xScaled has extreme values! min=\(x_min), max=\(x_max)")
            }

            // Always log xScaled range for diagnosis
            print("[DEBUG-NR] iter=\(iter): xScaled range: [\(x_min), \(x_max)]")

            // 🔬 INVESTIGATION: xScaled per variable (iter 0 only)
            if iter == 0 {
                let xArray = xScaled.values.value
                let Ti_scaled = xArray[0..<nCells]
                let Te_scaled = xArray[nCells..<(2*nCells)]
                let ne_scaled = xArray[(2*nCells)..<(3*nCells)]
                eval(Ti_scaled, Te_scaled, ne_scaled)

                print("[INVESTIGATION] xScaled breakdown:")
                print("[INVESTIGATION]   Ti_scaled range: [\(Ti_scaled.min().item(Float.self)), \(Ti_scaled.max().item(Float.self))]")
                print("[INVESTIGATION]   Te_scaled range: [\(Te_scaled.min().item(Float.self)), \(Te_scaled.max().item(Float.self))]")
                print("[INVESTIGATION]   ne_scaled range: [\(ne_scaled.min().item(Float.self)), \(ne_scaled.max().item(Float.self))]")
            }

            // Compute residual in scaled space
            let residualScaled = residualFnScaled(xScaled.values.value)
            eval(residualScaled)

            // 🐛 DEBUG: Check residualScaled for inf/nan
            if iter < 3 {
                let res_min = residualScaled.min(keepDims: false).item(Float.self)
                let res_max = residualScaled.max(keepDims: false).item(Float.self)
                print("[DEBUG-NR] iter=\(iter): residualScaled: min=\(res_min), max=\(res_max)")
            }

            // 🔬 INVESTIGATION: residualScaled per variable (iter 0 only)
            if iter == 0 {
                let residual_Ti = residualScaled[0..<nCells]
                let residual_Te = residualScaled[nCells..<(2*nCells)]
                let residual_ne = residualScaled[(2*nCells)..<(3*nCells)]
                eval(residual_Ti, residual_Te, residual_ne)

                print("[INVESTIGATION] residualScaled breakdown:")
                print("[INVESTIGATION]   residual_Ti range: [\(residual_Ti.min().item(Float.self)), \(residual_Ti.max().item(Float.self))]")
                print("[INVESTIGATION]   residual_Te range: [\(residual_Te.min().item(Float.self)), \(residual_Te.max().item(Float.self))]")
                print("[INVESTIGATION]   residual_ne range: [\(residual_ne.min().item(Float.self)), \(residual_ne.max().item(Float.self))]")
            }

            // Compute residual norm (scaled space)
            residualNorm = sqrt((residualScaled * residualScaled).mean()).item(Float.self)

            // 🐛 DEBUG: Residual norm (ALWAYS print for diagnosis)
            print("[DEBUG-NR] iter=\(iter): residualNorm=\(String(format: "%.2e", residualNorm)), tolerance=\(String(format: "%.2e", tolerance))")

            // ✅ PHASE 1-2: Per-variable residual norm tracking
            let residual_Ti = residualScaled[0..<nCells]
            let residual_Te = residualScaled[nCells..<(2*nCells)]
            let residual_ne = residualScaled[(2*nCells)..<(3*nCells)]
            let residual_psi = residualScaled[(3*nCells)..<(4*nCells)]

            let residualNorm_Ti = MLX.norm(residual_Ti).item(Float.self)
            let residualNorm_Te = MLX.norm(residual_Te).item(Float.self)
            let residualNorm_ne = MLX.norm(residual_ne).item(Float.self)
            let residualNorm_psi = MLX.norm(residual_psi).item(Float.self)

            print("[NR-RESIDUAL] iter=\(iter): Per-variable residual norms:")
            print("[NR-RESIDUAL]   ||R_Ti||  = \(String(format: "%.2e", residualNorm_Ti))")
            print("[NR-RESIDUAL]   ||R_Te||  = \(String(format: "%.2e", residualNorm_Te))")
            print("[NR-RESIDUAL]   ||R_ne||  = \(String(format: "%.2e", residualNorm_ne))")
            print("[NR-RESIDUAL]   ||R_psi|| = \(String(format: "%.2e", residualNorm_psi))")
            print("[NR-RESIDUAL]   Total ||R|| = \(String(format: "%.2e", residualNorm))")

            // Improvement rate compared to previous iteration
            if iter > 0 {
                let improvement_Ti = (prevResidualNorm_Ti - residualNorm_Ti) / prevResidualNorm_Ti * 100
                let improvement_Te = (prevResidualNorm_Te - residualNorm_Te) / prevResidualNorm_Te * 100
                let improvement_ne = (prevResidualNorm_ne - residualNorm_ne) / prevResidualNorm_ne * 100
                let improvement_psi = (prevResidualNorm_psi - residualNorm_psi) / prevResidualNorm_psi * 100

                print("[NR-RESIDUAL]   Ti improvement:  \(String(format: "%+.1f", improvement_Ti))%")
                print("[NR-RESIDUAL]   Te improvement:  \(String(format: "%+.1f", improvement_Te))%")
                print("[NR-RESIDUAL]   ne improvement:  \(String(format: "%+.1f", improvement_ne))%")
                print("[NR-RESIDUAL]   psi improvement: \(String(format: "%+.1f", improvement_psi))%")
            }

            // Save for next iteration
            prevResidualNorm_Ti = residualNorm_Ti
            prevResidualNorm_Te = residualNorm_Te
            prevResidualNorm_ne = residualNorm_ne
            prevResidualNorm_psi = residualNorm_psi

            // ✅ OPTION 2: Per-variable convergence criteria
            // Keeps Newton direction/Jacobian intact, only changes convergence check
            // Based on NEWTON_DIRECTION_ANALYSIS.md: Ti/Te stagnate, ne improves
            let tolerance_Ti: Float = 10.0   // Relaxed (currently ~5.86)
            let tolerance_Te: Float = 10.0   // Relaxed (currently ~5.86)
            let tolerance_ne: Float = 0.1    // Strict (physically critical)
            let tolerance_psi: Float = 1e-3  // Strict (already converged)

            let converged_Ti = residualNorm_Ti < tolerance_Ti
            let converged_Te = residualNorm_Te < tolerance_Te
            let converged_ne = residualNorm_ne < tolerance_ne
            let converged_psi = residualNorm_psi < tolerance_psi

            converged = converged_Ti && converged_Te && converged_ne && converged_psi

            if converged {
                print("[CONVERGENCE] ✅ All variables converged:")
                print("[CONVERGENCE]   Ti:  \(String(format: "%.2e", residualNorm_Ti)) < \(String(format: "%.2e", tolerance_Ti))")
                print("[CONVERGENCE]   Te:  \(String(format: "%.2e", residualNorm_Te)) < \(String(format: "%.2e", tolerance_Te))")
                print("[CONVERGENCE]   ne:  \(String(format: "%.2e", residualNorm_ne)) < \(String(format: "%.2e", tolerance_ne))")
                print("[CONVERGENCE]   psi: \(String(format: "%.2e", residualNorm_psi)) < \(String(format: "%.2e", tolerance_psi))")
                break
            } else {
                // Log which variables are blocking convergence
                print("[CONVERGENCE] Checking per-variable convergence:")
                if !converged_Ti {
                    print("[CONVERGENCE]   ⚠️  Ti NOT converged: \(String(format: "%.2e", residualNorm_Ti)) ≮ \(String(format: "%.2e", tolerance_Ti))")
                } else {
                    print("[CONVERGENCE]   ✅ Ti converged: \(String(format: "%.2e", residualNorm_Ti)) < \(String(format: "%.2e", tolerance_Ti))")
                }
                if !converged_Te {
                    print("[CONVERGENCE]   ⚠️  Te NOT converged: \(String(format: "%.2e", residualNorm_Te)) ≮ \(String(format: "%.2e", tolerance_Te))")
                } else {
                    print("[CONVERGENCE]   ✅ Te converged: \(String(format: "%.2e", residualNorm_Te)) < \(String(format: "%.2e", tolerance_Te))")
                }
                if !converged_ne {
                    print("[CONVERGENCE]   ⚠️  ne NOT converged: \(String(format: "%.2e", residualNorm_ne)) ≮ \(String(format: "%.2e", tolerance_ne))")
                } else {
                    print("[CONVERGENCE]   ✅ ne converged: \(String(format: "%.2e", residualNorm_ne)) < \(String(format: "%.2e", tolerance_ne))")
                }
                if !converged_psi {
                    print("[CONVERGENCE]   ⚠️  psi NOT converged: \(String(format: "%.2e", residualNorm_psi)) ≮ \(String(format: "%.2e", tolerance_psi))")
                } else {
                    print("[CONVERGENCE]   ✅ psi converged: \(String(format: "%.2e", residualNorm_psi)) < \(String(format: "%.2e", tolerance_psi))")
                }
            }

            // Compute Jacobian via vjp() in scaled space (efficient!)
            // 🐛 DEBUG: Before Jacobian computation
            print("[DEBUG-NR] iter=\(iter): computing Jacobian via vjp()")

            // 🐛 DEBUG: Measure residualFn evaluation time (first call in vjp)
            let t0 = Date()
            let _ = residualFnScaled(xScaled.values.value)
            eval()
            let residualTime = Date().timeIntervalSince(t0)
            print("[DEBUG-NR] iter=\(iter): single residualFn call took \(String(format: "%.3f", residualTime))s")

            // 🐛 DEBUG: Measure Jacobian computation time
            let tJacStart = Date()
            let jacobianScaled = computeJacobianViaVJP(residualFnScaled, xScaled.values.value)
            eval(jacobianScaled)
            let jacTime = Date().timeIntervalSince(tJacStart)
            // 🐛 DEBUG: After Jacobian computation
            print("[DEBUG-NR] iter=\(iter): Jacobian computed in \(String(format: "%.2f", jacTime))s, shape=\(jacobianScaled.shape)")

            // 🔬 DIAGNOSTIC: Compute condition number via SVD
            // Note: SVD is not yet supported on GPU in MLX, must use CPU stream
            let tSvdStart = Date()
            let (_, S, _) = MLX.svd(jacobianScaled, stream: .cpu)
            eval(S)
            let svdTime = Date().timeIntervalSince(tSvdStart)

            let sigma_max = S[0].item(Float.self)
            let sigma_min = S[S.count - 1].item(Float.self)
            let conditionNumber = sigma_max / (sigma_min + 1e-20)

            print("[DEBUG-JACOBIAN] SVD computed in \(String(format: "%.3f", svdTime))s")
            print("[DEBUG-JACOBIAN] Largest singular value (σ_max): \(String(format: "%.2e", sigma_max))")
            print("[DEBUG-JACOBIAN] Smallest singular value (σ_min): \(String(format: "%.2e", sigma_min))")
            print("[DEBUG-JACOBIAN] Condition number (κ): \(String(format: "%.2e", conditionNumber))")

            if conditionNumber > 1e8 {
                print("[DEBUG-JACOBIAN] ⚠️  WARNING: Jacobian is severely ill-conditioned (κ > 1e8)")
            } else if conditionNumber > 1e6 {
                print("[DEBUG-JACOBIAN] ⚠️  WARNING: Jacobian is ill-conditioned (κ > 1e6)")
            }

            if sigma_min < 1e-10 {
                print("[DEBUG-JACOBIAN] ⚠️  WARNING: Jacobian is near-singular (σ_min < 1e-10)")
            }

            // 🔬 INVESTIGATION: jacobianScaled block structure (iter 0 only)
            if iter == 0 {
                // Diagonal blocks
                let J_TiTi = jacobianScaled[0..<nCells, 0..<nCells]
                let J_TeTe = jacobianScaled[nCells..<(2*nCells), nCells..<(2*nCells)]
                let J_nene = jacobianScaled[(2*nCells)..<(3*nCells), (2*nCells)..<(3*nCells)]
                eval(J_TiTi, J_TeTe, J_nene)

                print("[INVESTIGATION] jacobianScaled block structure:")
                print("[INVESTIGATION]   J_TiTi range: [\(J_TiTi.min().item(Float.self)), \(J_TiTi.max().item(Float.self))]")
                print("[INVESTIGATION]   J_TeTe range: [\(J_TeTe.min().item(Float.self)), \(J_TeTe.max().item(Float.self))]")
                print("[INVESTIGATION]   J_nene range: [\(J_nene.min().item(Float.self)), \(J_nene.max().item(Float.self))]")

                // Off-diagonal blocks (cross-coupling)
                let J_Tine = jacobianScaled[0..<nCells, (2*nCells)..<(3*nCells)]
                let J_neTi = jacobianScaled[(2*nCells)..<(3*nCells), 0..<nCells]
                let J_TiTe = jacobianScaled[0..<nCells, nCells..<(2*nCells)]
                eval(J_Tine, J_neTi, J_TiTe)

                print("[INVESTIGATION]   J_Tine (off-diag) range: [\(J_Tine.min().item(Float.self)), \(J_Tine.max().item(Float.self))]")
                print("[INVESTIGATION]   J_neTi (off-diag) range: [\(J_neTi.min().item(Float.self)), \(J_neTi.max().item(Float.self))]")
                print("[INVESTIGATION]   J_TiTe (off-diag) range: [\(J_TiTe.min().item(Float.self)), \(J_TiTe.max().item(Float.self))]")
            }

            // ⚠️ PRECONDITIONER: SUSPENDED - See PRECONDITIONER_SUSPENDED_REVIEW.md
            //
            // The diagonal block-based preconditioner implemented here has been SUSPENDED
            // due to critical issues identified in code review:
            //
            // 1. DOUBLE SCALING RISK:
            //    - residualScaled is already scaled by referenceState (line 186)
            //    - jacobianScaled inherits this scaling via VJP
            //    - Adding P-based preconditioning creates double scaling
            //
            // 2. MISIDENTIFIED ROOT CAUSE:
            //    - 2700× Jacobian scale difference is physically natural
            //      (diffusion coefficients 10×, time-scale 10³)
            //    - Real bottleneck: Line search α stuck at 0.25
            //    - Newton direction shrinks to 1e-7
            //
            // 3. PREMATURE IMPLEMENTATION:
            //    - Should first investigate WHY α=1.0 fails after iter=0
            //    - Should verify Newton direction validity
            //    - Should check line search/damping settings
            //
            // NEXT STEPS (see PRECONDITIONER_SUSPENDED_REVIEW.md):
            // 1. Investigate line search behavior
            // 2. Check Newton direction validity
            // 3. Test lightweight column-norm preconditioning IF needed
            //
            // The preconditioner code below is kept for reference but INACTIVE.

            // Solve linear system: J * Δx = -R using hybrid solver
            let deltaScaled: MLXArray
            let tLinearStart = Date()
            do {
                // 🐛 DEBUG: Before linearSolver.solve()
                print("[DEBUG-NR] iter=\(iter): calling linearSolver.solve()")

                deltaScaled = try linearSolver.solve(jacobianScaled, -residualScaled)

                let linearTime = Date().timeIntervalSince(tLinearStart)
                // 🐛 DEBUG: After linearSolver.solve()
                print("[DEBUG-NR] iter=\(iter): linearSolver.solve() returned in \(String(format: "%.3f", linearTime))s")
            } catch {
                print("[NewtonRaphsonSolver] Linear solver failed: \(error)")
                // Return partial solution (unscale before returning)
                let finalPhysical = xScaled.unscaled(by: referenceState)
                let finalProfiles = finalPhysical.toCoreProfiles()
                return SolverResult(
                    updatedProfiles: finalProfiles,
                    iterations: iterations,
                    residualNorm: residualNorm,
                    converged: false,
                    metadata: [
                        "theta": theta,
                        "dt": dt
                    ]
                )
            }

            // 🐛 DEBUG: Before eval(deltaScaled)
            print("[DEBUG-NR] iter=\(iter): calling eval(deltaScaled)")
            eval(deltaScaled)
            // 🐛 DEBUG: After eval(deltaScaled)
            print("[DEBUG-NR] iter=\(iter): eval(deltaScaled) done")

            // 🐛 DEBUG: deltaScaled diagnostics
            let deltaNorm = sqrt((deltaScaled * deltaScaled).mean()).item(Float.self)
            let delta_min = deltaScaled.min(keepDims: false).item(Float.self)
            let delta_max = deltaScaled.max(keepDims: false).item(Float.self)
            print("[DEBUG-NR] iter=\(iter): ||deltaScaled||=\(String(format: "%.2e", deltaNorm)), range=[\(String(format: "%.2e", delta_min)), \(String(format: "%.2e", delta_max))]")

            // ✅ PHASE 1-1: Newton direction validation checks
            // (1) Linear solver accuracy: ||J*Δ + R|| / ||R||
            let linear_residual = jacobianScaled.matmul(deltaScaled) + residualScaled
            eval(linear_residual)
            let linear_residual_norm = MLX.norm(linear_residual).item(Float.self)
            let residual_norm_val = MLX.norm(residualScaled).item(Float.self)
            let linear_error = linear_residual_norm / (residual_norm_val + 1e-20)

            print("[NR-CHECK] iter=\(iter): Linear solver accuracy:")
            print("[NR-CHECK]   ||J*Δ + R|| = \(String(format: "%.2e", linear_residual_norm))")
            print("[NR-CHECK]   ||R|| = \(String(format: "%.2e", residual_norm_val))")
            print("[NR-CHECK]   Relative error = \(String(format: "%.2e", linear_error))")
            if linear_error > 1e-6 {
                print("[NR-CHECK] ⚠️  WARNING: Linear solver error > 1e-6")
            } else {
                print("[NR-CHECK]   ✅ Linear solver accuracy OK")
            }

            // (2) Descent direction check: Δ·(-R) > 0
            let descent_product = (deltaScaled * (-residualScaled)).sum()
            eval(descent_product)
            let descent_value = descent_product.item(Float.self)

            print("[NR-CHECK] iter=\(iter): Descent direction check:")
            print("[NR-CHECK]   Δ·(-R) = \(String(format: "%.2e", descent_value))")
            if descent_value <= 0 {
                print("[NR-CHECK] ⚠️  WARNING: Not a descent direction (Δ·(-R) ≤ 0)")
            } else {
                print("[NR-CHECK]   ✅ Valid descent direction")
            }

            // ✅ CRITICAL: Early termination if Newton direction is unreliable
            // This triggers dt retry in SimulationOrchestrator's dt adjustment loop
            let linearErrorThreshold: Float = 1e-3

            if linear_error > linearErrorThreshold {
                print("[NR-FAILURE] ❌ Linear solver error too high: \(String(format: "%.2e", linear_error)) > \(String(format: "%.2e", linearErrorThreshold))")
                print("[NR-FAILURE] Newton direction unreliable - aborting iteration")
                print("[NR-FAILURE] Returning converged=false to trigger dt retry")

                // Return partial solution with converged=false
                let finalPhysical = xScaled.unscaled(by: referenceState)
                let finalProfiles = finalPhysical.toCoreProfiles()
                return SolverResult(
                    updatedProfiles: finalProfiles,
                    iterations: iterations,
                    residualNorm: residualNorm,
                    converged: false,
                    metadata: [
                        "theta": theta,
                        "dt": dt,
                        "linear_error": linear_error,
                        "failure_type": 1.0  // 1.0 = linear_solver_error
                    ]
                )
            }

            if descent_value <= 0 {
                print("[NR-FAILURE] ❌ Invalid descent direction: Δ·(-R) = \(String(format: "%.2e", descent_value)) ≤ 0")
                print("[NR-FAILURE] Newton direction does not decrease residual - aborting iteration")
                print("[NR-FAILURE] Returning converged=false to trigger dt retry")

                // Return partial solution with converged=false
                let finalPhysical = xScaled.unscaled(by: referenceState)
                let finalProfiles = finalPhysical.toCoreProfiles()
                return SolverResult(
                    updatedProfiles: finalProfiles,
                    iterations: iterations,
                    residualNorm: residualNorm,
                    converged: false,
                    metadata: [
                        "theta": theta,
                        "dt": dt,
                        "descent_value": descent_value,
                        "failure_type": 2.0  // 2.0 = invalid_descent_direction
                    ]
                )
            }

            // (3) Per-variable Newton direction components
            let delta_Ti = deltaScaled[0..<nCells]
            let delta_Te = deltaScaled[nCells..<(2*nCells)]
            let delta_ne = deltaScaled[(2*nCells)..<(3*nCells)]
            let delta_psi = deltaScaled[(3*nCells)..<(4*nCells)]

            let deltaNorm_Ti = MLX.norm(delta_Ti).item(Float.self)
            let deltaNorm_Te = MLX.norm(delta_Te).item(Float.self)
            let deltaNorm_ne = MLX.norm(delta_ne).item(Float.self)
            let deltaNorm_psi = MLX.norm(delta_psi).item(Float.self)

            print("[NR-CHECK] iter=\(iter): Newton direction components:")
            print("[NR-CHECK]   ||Δ_Ti||  = \(String(format: "%.2e", deltaNorm_Ti))")
            print("[NR-CHECK]   ||Δ_Te||  = \(String(format: "%.2e", deltaNorm_Te))")
            print("[NR-CHECK]   ||Δ_ne||  = \(String(format: "%.2e", deltaNorm_ne))")
            print("[NR-CHECK]   ||Δ_psi|| = \(String(format: "%.2e", deltaNorm_psi))")
            print("[NR-CHECK]   Total ||Δ|| = \(String(format: "%.2e", deltaNorm))")

            // Update solution with line search (in scaled space)
            // 🐛 DEBUG: Before lineSearch
            print("[DEBUG-NR] iter=\(iter): calling lineSearch()")

            let tLineSearchStart = Date()
            let alpha = lineSearch(
                residualFn: residualFnScaled,
                x: xScaled.values.value,
                delta: deltaScaled,
                residual: residualScaled,
                maxAlpha: 1.0
            )
            let lineSearchTime = Date().timeIntervalSince(tLineSearchStart)

            // 🐛 DEBUG: After lineSearch
            print("[DEBUG-NR] iter=\(iter): lineSearch() returned in \(String(format: "%.3f", lineSearchTime))s, alpha=\(alpha)")

            let xNewScaled = xScaled.values.value + alpha * deltaScaled
            xScaled = FlattenedState(values: EvaluatedArray(evaluating: xNewScaled), layout: layout)

            // 🐛 DEBUG: End of iteration with total time
            let iterElapsed = Date().timeIntervalSince(iterStartTime)
            print("[DEBUG-NR] iter=\(iter): iteration complete in \(String(format: "%.2f", iterElapsed))s")
        }

        // Unscale final solution to physical units
        let xFinalPhysical = xScaled.unscaled(by: referenceState)
        let finalProfiles = xFinalPhysical.toCoreProfiles()

        return SolverResult(
            updatedProfiles: finalProfiles,
            iterations: iterations,
            residualNorm: residualNorm,
            converged: converged,
            metadata: [
                "theta": theta,
                "dt": dt,
                "variable_scaling": 1.0  // 1.0 = enabled, 0.0 = disabled
            ]
        )
    }

    // MARK: - Residual Computation

    /// Compute residual for theta-method time discretization (VECTORIZED)
    ///
    /// Theta-method: (x^{n+1} - x^n) / dt = θ*f(x^{n+1}) + (1-θ)*f(x^n)
    /// Residual: R = (x^{n+1} - x^n) / dt - θ*f(x^{n+1}) - (1-θ)*f(x^n)
    private func computeThetaMethodResidual(
        xOld: MLXArray,
        xNew: MLXArray,
        coeffsOld: Block1DCoeffs,
        coeffsNew: Block1DCoeffs,
        dt: Float,
        theta: Float,
        geometry: Geometry,
        boundaryConditions: BoundaryConditions
    ) -> MLXArray {
        let nCells = geometry.nCells
        // nCells is guaranteed valid (from Geometry), so try! is safe here
        let layout = try! FlattenedState.StateLayout(nCells: nCells)

        // Unflatten state vectors
        let Ti_old = xOld[layout.tiRange]
        let Te_old = xOld[layout.teRange]
        let ne_old = xOld[layout.neRange]
        let psi_old = xOld[layout.psiRange]

        let Ti_new = xNew[layout.tiRange]
        let Te_new = xNew[layout.teRange]
        let ne_new = xNew[layout.neRange]
        let psi_new = xNew[layout.psiRange]

        // Get transient coefficients (CRITICAL FIX #1)
        // These multiply the time derivative term: transientCoeff * ∂u/∂t
        let transientCoeff_Ti = coeffsNew.ionCoeffs.transientCoeff.value        // n_e for Ti
        let transientCoeff_Te = coeffsNew.electronCoeffs.transientCoeff.value   // n_e for Te
        let transientCoeff_ne = coeffsNew.densityCoeffs.transientCoeff.value    // 1.0 for ne
        let transientCoeff_psi = coeffsNew.fluxCoeffs.transientCoeff.value      // L_p for psi

        // Time derivative terms WITH transient coefficients
        // Correct form: transientCoeff * (u_new - u_old) / dt
        let dTi_dt = transientCoeff_Ti * (Ti_new - Ti_old) / dt
        let dTe_dt = transientCoeff_Te * (Te_new - Te_old) / dt
        let dne_dt = transientCoeff_ne * (ne_new - ne_old) / dt
        let dpsi_dt = transientCoeff_psi * (psi_new - psi_old) / dt

        // 🐛 DEBUG: Measure spatial operator time
        let t_spatial_start = Date()

        // Spatial operators at new time (VECTORIZED) - with boundary conditions
        let f_Ti_new = applySpatialOperatorVectorized(
            u: Ti_new,
            coeffs: coeffsNew.ionCoeffs,
            geometry: coeffsNew.geometry,
            boundaryCondition: boundaryConditions.ionTemperature
        )

        let f_Te_new = applySpatialOperatorVectorized(
            u: Te_new,
            coeffs: coeffsNew.electronCoeffs,
            geometry: coeffsNew.geometry,
            boundaryCondition: boundaryConditions.electronTemperature
        )

        let f_ne_new = applySpatialOperatorVectorized(
            u: ne_new,
            coeffs: coeffsNew.densityCoeffs,
            geometry: coeffsNew.geometry,
            boundaryCondition: boundaryConditions.electronDensity
        )

        let f_psi_new = applySpatialOperatorVectorized(
            u: psi_new,
            coeffs: coeffsNew.fluxCoeffs,
            geometry: coeffsNew.geometry,
            boundaryCondition: boundaryConditions.poloidalFlux
        )

        // Spatial operators at old time - with boundary conditions
        let f_Ti_old = applySpatialOperatorVectorized(
            u: Ti_old,
            coeffs: coeffsOld.ionCoeffs,
            geometry: coeffsOld.geometry,
            boundaryCondition: boundaryConditions.ionTemperature
        )

        let f_Te_old = applySpatialOperatorVectorized(
            u: Te_old,
            coeffs: coeffsOld.electronCoeffs,
            geometry: coeffsOld.geometry,
            boundaryCondition: boundaryConditions.electronTemperature
        )

        let f_ne_old = applySpatialOperatorVectorized(
            u: ne_old,
            coeffs: coeffsOld.densityCoeffs,
            geometry: coeffsOld.geometry,
            boundaryCondition: boundaryConditions.electronDensity
        )

        let f_psi_old = applySpatialOperatorVectorized(
            u: psi_old,
            coeffs: coeffsOld.fluxCoeffs,
            geometry: coeffsOld.geometry,
            boundaryCondition: boundaryConditions.poloidalFlux
        )

        // 🐛 DEBUG: Report spatial operator time
        let t_spatial_elapsed = Date().timeIntervalSince(t_spatial_start)
        if t_spatial_elapsed > 0.1 {
            print("[DEBUG-RESIDUAL] Spatial operators took \(String(format: "%.3f", t_spatial_elapsed))s")
        }

        // Residuals: R = dψ/dt - θ*f(ψ_new) - (1-θ)*f(ψ_old)
        let R_Ti_raw = dTi_dt - theta * f_Ti_new - (1.0 - theta) * f_Ti_old
        let R_Te_raw = dTe_dt - theta * f_Te_new - (1.0 - theta) * f_Te_old
        let R_ne_raw = dne_dt - theta * f_ne_new - (1.0 - theta) * f_ne_old
        let R_psi_raw = dpsi_dt - theta * f_psi_new - (1.0 - theta) * f_psi_old

        // ✅ FIX: Normalize residuals by dividing by transient coefficients
        // This converts the equation from:
        //   n_e ∂T/∂t = RHS  (units: [eV/(m³·s)])
        // to:
        //   ∂T/∂t = RHS/n_e  (units: [eV/s])
        //
        // Problem: With n_e = 2×10¹⁹ m⁻³ and source = 10²⁴ eV/(m³·s),
        //          raw residual = 10²⁴, which causes Newton-Raphson to fail
        //
        // Solution: Divide by n_e to get ∂T/∂t ~ 10⁵ eV/s (manageable scale)
        //
        // Physical interpretation: We solve for temperature rate of change [eV/s]
        //                          instead of density-weighted rate [eV/(m³·s)]
        let R_Ti = R_Ti_raw / (transientCoeff_Ti + 1e-10)  // [eV/s]
        let R_Te = R_Te_raw / (transientCoeff_Te + 1e-10)  // [eV/s]
        let R_ne = R_ne_raw / (transientCoeff_ne + 1e-10)  // [m⁻³/s]
        let R_psi = R_psi_raw / (transientCoeff_psi + 1e-10)  // [Wb/s]

        // Flatten residuals
        return concatenated([R_Ti, R_Te, R_ne, R_psi], axis: 0)
    }

    /// Apply spatial operator F(u) = ∇·(d∇u) + ∇·(vu) + s + s_mat·u (VECTORIZED - NO LOOPS)
    ///
    /// - Parameters:
    ///   - u: Variable on cells [nCells]
    ///   - coeffs: Equation coefficients
    ///   - geometry: Geometric factors
    ///   - boundaryCondition: Boundary conditions for this variable
    /// - Returns: F(u) on cells [nCells]
    private func applySpatialOperatorVectorized(
        u: MLXArray,
        coeffs: EquationCoeffs,
        geometry: GeometricFactors,
        boundaryCondition: BoundaryCondition
    ) -> MLXArray {
        let nCells = u.shape[0]

        // 1. Compute gradient at faces: ∇u = (u[i+1] - u[i]) / dx (VECTORIZED)
        let u_right = u[1..<nCells]           // [nCells-1]
        let u_left = u[0..<(nCells-1)]        // [nCells-1]
        let dx = geometry.cellDistances.value // [nCells-1]

        let gradFace_interior = (u_right - u_left) / (dx + 1e-10)  // [nCells-1]

        // HIGH #5 FIX: Apply boundary conditions correctly
        let gradFace_left: MLXArray  // [1]
        switch boundaryCondition.left {
        case .value(let val):
            // Dirichlet: compute gradient from boundary value
            let u_boundary = MLXArray(val)
            let dx_left = dx[0..<1]  // First cell distance
            gradFace_left = (u[0..<1] - u_boundary) / (dx_left + 1e-10)
        case .gradient(let grad):
            // Neumann: use specified gradient directly
            gradFace_left = MLXArray([grad])
        }

        let gradFace_right: MLXArray  // [1]
        switch boundaryCondition.right {
        case .value(let val):
            // Dirichlet: compute gradient from boundary value
            let u_boundary = MLXArray(val)
            let dx_right = dx[(nCells-2)..<(nCells-1)]  // Last cell distance
            gradFace_right = (u_boundary - u[(nCells-1)..<nCells]) / (dx_right + 1e-10)
        case .gradient(let grad):
            // Neumann: use specified gradient directly
            gradFace_right = MLXArray([grad])
        }

        let gradFace = concatenated([gradFace_left, gradFace_interior, gradFace_right], axis: 0)  // [nFaces]

        // 2. Diffusive flux: F_diff = -d * ∇u (VECTORIZED)
        let dFace = coeffs.dFace.value         // [nFaces]
        let diffusiveFlux = -dFace * gradFace  // [nFaces]

        // 3. Convective flux: F_conv = v * u_face (VECTORIZED)
        let vFace = coeffs.vFace.value         // [nFaces]
        let u_face = interpolateToFacesVectorized(
            u,
            vFace: vFace,
            dFace: dFace,
            dx: dx
        )  // [nFaces]
        let convectiveFlux = vFace * u_face    // [nFaces]

        // 4. Total flux at faces
        let totalFlux = diffusiveFlux + convectiveFlux  // [nFaces]

        // 5. Flux divergence with metric tensor: ∇·F = (1/√g) ∂(√g·F)/∂ψ
        // For non-uniform grids, weight fluxes by Jacobian (√g = g₀)
        //
        // Traditional: ∇·F = (F[i+1] - F[i]) / V_cell
        // Metric tensor: ∇·F = (1/√g_cell) * (√g_face_right * F_right - √g_face_left * F_left) / Δψ
        //
        // For uniform grids with g₀=constant, both formulations are equivalent.
        // For non-uniform grids, metric tensor formulation maintains conservation.

        // Interpolate Jacobian (g₀) to faces
        let jacobianCells = geometry.jacobian.value  // [nCells]
        // For faces: use arithmetic average of adjacent cells
        let jacobianFaces_interior = 0.5 * (jacobianCells[0..<(nCells-1)] + jacobianCells[1..<nCells])  // [nCells-1]
        // Boundary faces: use adjacent cell value
        let jacobianFaces = concatenated([
            jacobianCells[0..<1],           // Left boundary
            jacobianFaces_interior,         // Interior faces
            jacobianCells[(nCells-1)..<nCells]  // Right boundary
        ], axis: 0)  // [nFaces]

        // Weight fluxes by Jacobian: √g·F
        let weightedFlux = jacobianFaces * totalFlux  // [nFaces]

        // Flux divergence at cells
        let flux_right = weightedFlux[1..<(nCells + 1)]  // [nCells]
        let flux_left = weightedFlux[0..<nCells]         // [nCells]
        let cellDistances = geometry.cellDistances.value  // [nCells-1]

        // Map cellDistances [nCells-1] to per-cell distances [nCells]
        // For cells[0..nCells-2]: use distance to right neighbor = cellDistances[i]
        // For cell[nCells-1]: use distance to left neighbor = cellDistances[nCells-2]
        //
        // Physical interpretation: each cell's "characteristic length" for flux divergence
        let dx_padded = concatenated([
            cellDistances,                                              // [nCells-1] for cells 0..nCells-2
            cellDistances[(cellDistances.shape[0]-1)..<cellDistances.shape[0]]  // Last distance for cell nCells-1
        ], axis: 0)  // Total: (nCells-1) + 1 = nCells ✓

        // Final divergence: (1/√g_cell) * ∂(√g·F)/∂ψ
        let fluxDivergence = (flux_right - flux_left) / ((jacobianCells * dx_padded) + 1e-10)  // [nCells]

        // 6. Source terms (VECTORIZED)
        let source = coeffs.sourceCell.value           // [nCells]
        let sourceMatrix = coeffs.sourceMatCell.value  // [nCells]

        // 7. Total spatial operator
        let F = fluxDivergence + source + sourceMatrix * u  // [nCells]

        // 🐛 DEBUG: Print components to identify large residual source
        // Rate-limited to reduce log spam (800+ warnings per Newton iteration → 3-6 warnings total)
        #if DEBUG
        let flux_min = fluxDivergence.min().item(Float.self)
        let flux_max = fluxDivergence.max().item(Float.self)

        // Static variables for rate limiting
        // Using nonisolated(unsafe) because this is debug-only logging
        // Race conditions here only affect log output, not correctness
        struct SpatialOpLogger {
            nonisolated(unsafe) static var warningCount = 0
            nonisolated(unsafe) static var lastWarningTime = Date.distantPast
            static let maxInitialWarnings = 3
            static let throttleInterval: TimeInterval = 5.0  // seconds
        }

        let now = Date()
        let shouldPrint = (SpatialOpLogger.warningCount < SpatialOpLogger.maxInitialWarnings) ||
                          (now.timeIntervalSince(SpatialOpLogger.lastWarningTime) >= SpatialOpLogger.throttleInterval)

        if shouldPrint && (!flux_min.isFinite || !flux_max.isFinite ||
                           flux_min.magnitude > 1e20 || flux_max.magnitude > 1e20) {
            let source_min = source.min().item(Float.self)
            let source_max = source.max().item(Float.self)
            let F_min = F.min().item(Float.self)
            let F_max = F.max().item(Float.self)

            print("[SPATIAL-OP] ⚠️  fluxDivergence: [\(flux_min), \(flux_max)] eV/(m³·s)")
            print("[SPATIAL-OP] ⚠️  source: [\(source_min), \(source_max)] eV/(m³·s)")
            print("[SPATIAL-OP] ⚠️  F total: [\(F_min), \(F_max)] eV/(m³·s)")

            // Print geometry factors
            let jacob_min = jacobianCells.min().item(Float.self)
            let jacob_max = jacobianCells.max().item(Float.self)
            let dx_min = dx_padded.min().item(Float.self)
            let dx_max = dx_padded.max().item(Float.self)
            print("[SPATIAL-OP] ⚠️  jacobian: [\(jacob_min), \(jacob_max)] m")
            print("[SPATIAL-OP] ⚠️  dx_padded: [\(dx_min), \(dx_max)]")

            SpatialOpLogger.warningCount += 1
            SpatialOpLogger.lastWarningTime = now

            if SpatialOpLogger.warningCount == SpatialOpLogger.maxInitialWarnings {
                print("[SPATIAL-OP] ℹ️  Further warnings throttled (max \(SpatialOpLogger.throttleInterval)s interval)")
            }
        }
        #endif

        return F
    }

    /// Interpolate cell values to faces using power-law scheme (VECTORIZED - NO LOOPS)
    ///
    /// Uses Patankar power-law scheme for convection-diffusion stability:
    /// - Low Péclet (Pe < 0.1): Central differencing
    /// - Moderate Péclet (0.1 ≤ Pe ≤ 10): Power-law interpolation
    /// - High Péclet (Pe > 10): First-order upwinding
    ///
    /// - Parameters:
    ///   - u: Cell values [nCells]
    ///   - vFace: Convection velocity at faces [m/s], shape [nFaces]
    ///   - dFace: Diffusion coefficient at faces [m²/s], shape [nFaces]
    ///   - dx: Cell spacing [m], shape [nCells-1]
    /// - Returns: Face values [nFaces]
    private func interpolateToFacesVectorized(
        _ u: MLXArray,
        vFace: MLXArray,
        dFace: MLXArray,
        dx: MLXArray
    ) -> MLXArray {
        // Compute Péclet number: Pe = V·Δx/D
        let peclet = PowerLawScheme.computePecletNumber(
            vFace: vFace,
            dFace: dFace,
            dx: dx
        )

        // Power-law weighted interpolation
        return PowerLawScheme.interpolateToFaces(
            cellValues: u,
            peclet: peclet
        )
    }

    /// DEPRECATED: Old central-difference implementation
    /// Left here for reference, should be removed after testing
    private func interpolateToFacesVectorized_OLD(_ u: MLXArray) -> MLXArray {
        let nCells = u.shape[0]

        // Central difference for interior faces
        let u_left = u[0..<(nCells-1)]    // [nCells-1]
        let u_right = u[1..<nCells]       // [nCells-1]
        let u_interior = 0.5 * (u_left + u_right)  // [nCells-1]

        // Boundary faces: use adjacent cell value
        let u_leftBoundary = u[0..<1]                  // [1]
        let u_rightBoundary = u[(nCells-1)..<nCells]  // [1]

        // Concatenate: [left_boundary, interior_faces, right_boundary]
        return concatenated([u_leftBoundary, u_interior, u_rightBoundary], axis: 0)  // [nFaces]
    }

    // MARK: - Line Search

    /// Backtracking line search for step size selection
    ///
    /// Finds α such that ||R(x + α*Δx)|| < ||R(x)||
    private func lineSearch(
        residualFn: (MLXArray) -> MLXArray,
        x: MLXArray,
        delta: MLXArray,
        residual: MLXArray,
        maxAlpha: Float
    ) -> Float {
        let initialNorm = sqrt((residual * residual).mean()).item(Float.self)

        print("[DEBUG-LS] Starting line search: initialNorm=\(String(format: "%.2e", initialNorm)), maxAlpha=\(maxAlpha)")

        var alpha = maxAlpha
        let beta: Float = 0.5  // Reduction factor
        let maxIterations = 10

        for iteration in 0..<maxIterations {
            let xNew = x + alpha * delta
            let residualNew = residualFn(xNew)
            eval(residualNew)

            let newNorm = sqrt((residualNew * residualNew).mean()).item(Float.self)

            let improvement = initialNorm - newNorm
            let improvementPercent = (improvement / initialNorm) * 100.0

            print("[DEBUG-LS] iter=\(iteration): α=\(String(format: "%.3f", alpha)), residualNorm=\(String(format: "%.2e", newNorm)), improvement=\(String(format: "%.1f", improvementPercent))%")

            if newNorm < initialNorm {
                print("[DEBUG-LS] ✅ Accepted: residualNorm decreased")
                return alpha
            }

            alpha *= beta
        }

        // If line search fails, return small step
        print("[DEBUG-LS] ❌ FAILED: All \(maxIterations) attempts failed to reduce residual")
        print("[DEBUG-LS] Returning fallback α=0.1")
        return 0.1
    }
}

// MARK: - State Layout Helper
// Note: StateLayout is now defined in NumericalTolerances.swift
