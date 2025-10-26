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

            if iter < 5 {
                print("[DEBUG-NR] iter=\(iter): xScaled range: [\(x_min), \(x_max)]")
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

            // Compute residual norm (scaled space)
            residualNorm = sqrt((residualScaled * residualScaled).mean()).item(Float.self)

            // 🐛 DEBUG: Residual norm
            if iter < 3 {
                print("[DEBUG-NR] iter=\(iter): residualNorm=\(String(format: "%.2e", residualNorm)), tolerance=\(String(format: "%.2e", tolerance))")
            }

            // Check convergence
            if residualNorm < tolerance {
                converged = true
                if iter < 3 {
                    print("[DEBUG-NR] iter=\(iter): CONVERGED")
                }
                break
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

        var alpha = maxAlpha
        let beta: Float = 0.5  // Reduction factor
        let maxIterations = 10

        for _ in 0..<maxIterations {
            let xNew = x + alpha * delta
            let residualNew = residualFn(xNew)
            eval(residualNew)

            let newNorm = sqrt((residualNew * residualNew).mean()).item(Float.self)

            if newNorm < initialNorm {
                return alpha
            }

            alpha *= beta
        }

        // If line search fails, return small step
        return 0.1
    }
}

// MARK: - State Layout Helper
// Note: StateLayout is now defined in NumericalTolerances.swift
