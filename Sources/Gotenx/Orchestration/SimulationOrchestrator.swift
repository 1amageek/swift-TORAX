import MLX
import Foundation

// MARK: - Simulation Orchestrator

/// Actor-isolated orchestrator for tokamak transport simulation
///
/// Manages simulation lifecycle with strict concurrency safety:
/// - Mutable state isolated within actor
/// - Pure compiled functions (no actor self capture)
/// - EvaluatedArray boundary pattern for MLXArray evaluation
///
/// Architecture follows Gotenx design with MLX optimization:
/// 1. Static parameters trigger recompilation
/// 2. Dynamic parameters can change without recompilation
/// 3. CoeffsCallback with closure capture for context
/// 4. Compiled step function for performance
public actor SimulationOrchestrator {
    // MARK: - Actor-Isolated State

    /// Current simulation state
    private var state: SimulationState

    /// Static configuration (triggers recompilation if changed)
    private let staticParams: StaticRuntimeParams

    /// Transport model
    private let transport: any TransportModel

    /// Source models
    private let sources: [any SourceModel]

    /// Timestep calculator
    private let timeStepCalculator: TimeStepCalculator

    /// Solver
    private let solver: any PDESolver

    /// Conservation enforcer (optional)
    private var conservationEnforcer: ConservationEnforcer?

    /// Accumulated diagnostic results
    private var diagnosticResults: [DiagnosticResult] = []

    /// Accumulated conservation results
    private var conservationResults: [ConservationResult] = []

    /// Diagnostics configuration
    private var diagnosticsConfig: DiagnosticsConfig?

    /// Initial state for conservation reference
    private var initialState: SimulationState?

    /// Sampling configuration for time series capture
    private let samplingConfig: SamplingConfig

    /// Geometry (cached for diagnostics computation)
    private let geometry: Geometry

    // MARK: - Initialization

    public init(
        staticParams: StaticRuntimeParams,
        initialProfiles: SerializableProfiles,
        transport: any TransportModel,
        sources: [any SourceModel] = [],
        samplingConfig: SamplingConfig = .balanced
    ) async {
        self.staticParams = staticParams
        self.transport = transport
        self.sources = sources
        self.samplingConfig = samplingConfig

        // Create geometry from static params
        self.geometry = Geometry(config: staticParams.mesh)

        self.timeStepCalculator = TimeStepCalculator(
            stabilityFactor: 0.9,
            minTimestep: 1e-6,
            maxTimestep: 1e-2
        )

        // Create solver based on configuration
        switch staticParams.solverType {
        case .linear:
            self.solver = LinearSolver(
                nCorrectorSteps: 3,
                usePereversevCorrector: true,
                theta: staticParams.theta
            )
        case .newtonRaphson:
            self.solver = NewtonRaphsonSolver(
                tolerance: staticParams.solverTolerance,
                maxIterations: staticParams.solverMaxIterations,
                theta: staticParams.theta
            )
        case .optimizer:
            // TODO: Implement optimizer solver
            self.solver = NewtonRaphsonSolver(
                tolerance: staticParams.solverTolerance,
                maxIterations: staticParams.solverMaxIterations,
                theta: staticParams.theta
            )
        }

        // Initialize state with high-precision time accumulation
        self.state = SimulationState(
            profiles: CoreProfiles(from: initialProfiles),
            timeAccumulator: 0.0,
            dt: 1e-4,
            step: 0
        )

        // Store initial state for conservation reference
        self.initialState = self.state
    }

    // MARK: - Public API

    /// Run simulation until specified end time
    ///
    /// - Parameters:
    ///   - endTime: Simulation end time [s]
    ///   - dynamicParams: Time-dependent dynamic parameters
    ///   - saveInterval: Interval for saving time series (nil = use samplingConfig)
    /// - Returns: Simulation result
    public func run(
        until endTime: Float,
        dynamicParams: DynamicRuntimeParams,
        saveInterval: Float? = nil  // Deprecated: Use samplingConfig instead
    ) async throws -> SimulationResult {
        let startWallTime = Date()
        var timeSeries: [TimePoint] = []

        // Capture initial state (always)
        if samplingConfig.profileSamplingInterval != nil {
            timeSeries.append(captureTimePoint())
        }

        while state.time < endTime {
            let stepStartTime = Date()

            // Perform single timestep
            try await performStep(dynamicParams: dynamicParams)

            let stepWallTime = Float(Date().timeIntervalSince(stepStartTime))

            // Compute derived quantities and diagnostics
            if samplingConfig.enableDerivedQuantities || samplingConfig.enableDiagnostics {
                updateStateWithDiagnostics(stepWallTime: stepWallTime)
            }

            // Save time series based on sampling config
            if samplingConfig.shouldCaptureProfile(at: state.step) {
                timeSeries.append(captureTimePoint())
            }

            // Legacy saveInterval support (deprecated)
            // This is kept for backward compatibility but samplingConfig is preferred

            // Check for numerical issues
            if !state.statistics.converged {
                throw SolverError.convergenceFailure(
                    iterations: state.statistics.totalIterations,
                    residualNorm: state.statistics.maxResidualNorm
                )
            }
        }

        // Capture final state (always)
        if samplingConfig.profileSamplingInterval != nil && !timeSeries.isEmpty {
            timeSeries.append(captureTimePoint())
        }

        // Update final statistics
        let wallTime = Float(Date().timeIntervalSince(startWallTime))
        var finalStats = state.statistics
        finalStats.wallTime = wallTime

        return SimulationResult(
            finalProfiles: state.profiles.toSerializable(),
            statistics: finalStats,
            timeSeries: timeSeries.isEmpty ? nil : timeSeries
        )
    }

    /// Get current progress
    public func getProgress() async -> ProgressInfo {
        ProgressInfo(
            currentTime: state.time,
            totalSteps: state.statistics.totalSteps,
            lastDt: state.dt,
            converged: state.statistics.converged
        )
    }

    /// Enable conservation enforcement
    ///
    /// - Parameters:
    ///   - laws: Conservation laws to enforce
    ///   - interval: Enforcement interval (default: every 100 steps)
    ///
    /// ## Example
    ///
    /// ```swift
    /// await orchestrator.enableConservation(
    ///     laws: [
    ///         ParticleConservation(),
    ///         EnergyConservation()
    ///     ],
    ///     interval: 100
    /// )
    /// ```
    public func enableConservation(
        laws: [any ConservationLaw],
        interval: Int = 100
    ) async throws {
        guard let initial = initialState else {
            throw OrchestratorError.noInitialState
        }

        let geometry = createGeometry(from: staticParams.mesh)

        self.conservationEnforcer = ConservationEnforcer(
            laws: laws,
            initialProfiles: initial.profiles,
            geometry: geometry,
            enforcementInterval: interval
        )
    }

    /// Enable diagnostics
    ///
    /// - Parameter config: Diagnostics configuration
    ///
    /// ## Example
    ///
    /// ```swift
    /// await orchestrator.enableDiagnostics(
    ///     DiagnosticsConfig(
    ///         enableJacobianCheck: true,
    ///         jacobianCheckInterval: 5000,
    ///         conditionThreshold: 1e6
    ///     )
    /// )
    /// ```
    public func enableDiagnostics(_ config: DiagnosticsConfig) async {
        self.diagnosticsConfig = config
    }

    /// Get diagnostics report
    ///
    /// - Returns: Comprehensive diagnostics report
    ///
    /// ## Example
    ///
    /// ```swift
    /// let report = await orchestrator.getDiagnosticsReport()
    /// print(report.summary())
    /// try report.exportJSON(to: "diagnostics.json")
    /// ```
    public func getDiagnosticsReport() async -> DiagnosticsReport {
        guard let initial = initialState else {
            return DiagnosticsReport(
                results: diagnosticResults,
                conservationResults: conservationResults,
                startTime: 0.0,
                endTime: state.time,
                totalSteps: state.statistics.totalSteps
            )
        }

        return DiagnosticsReport(
            results: diagnosticResults,
            conservationResults: conservationResults,
            startTime: initial.time,
            endTime: state.time,
            totalSteps: state.statistics.totalSteps
        )
    }

    // MARK: - Time Stepping

    /// Last solver result (for diagnostics)
    private var lastSolverResult: SolverResult?

    /// Perform single timestep
    private func performStep(dynamicParams: DynamicRuntimeParams) async throws {
        // Construct geometry from mesh configuration
        let geometry = createGeometry(from: staticParams.mesh)

        // Compute transport coefficients
        let transportCoeffs = transport.computeCoefficients(
            profiles: state.profiles,
            geometry: geometry,
            params: dynamicParams.transportParams
        )

        // Compute source terms (before solving, for capture)
        // Note: These will be recomputed in callback for iterative solvers
        let sourceTerms = sources.reduce(into: SourceTerms.zero(nCells: staticParams.mesh.nCells)) { total, model in
            if let params = dynamicParams.sourceParams[model.name] {
                let contribution = model.computeTerms(
                    profiles: state.profiles,
                    geometry: geometry,
                    params: params
                )
                total = total + contribution
            }
        }

        // Calculate adaptive timestep
        let dt: Float
        if state.step > 0 {
            // Use adaptive timestep based on transport coefficients
            dt = timeStepCalculator.compute(
                transportCoeffs: transportCoeffs,
                dr: staticParams.mesh.dr
            )
        } else {
            // First step: use fixed small timestep
            dt = 1e-5
        }

        // Build CoeffsCallback with closure capture
        // Note: Source terms are computed inside the callback because they depend
        // on the profiles being solved, which may be updated iteratively (Newton-Raphson)
        let coeffsCallback: CoeffsCallback = { [transport, sources, dynamicParams, staticParams] profiles, geo in
            // Capture context from outer scope
            let transportCoeffs = transport.computeCoefficients(
                profiles: profiles,
                geometry: geo,
                params: dynamicParams.transportParams
            )

            let sourceTerms = sources.reduce(into: SourceTerms.zero(nCells: staticParams.mesh.nCells)) { total, model in
                if let params = dynamicParams.sourceParams[model.name] {
                    let contribution = model.computeTerms(
                        profiles: profiles,
                        geometry: geo,
                        params: params
                    )
                    total = total + contribution
                }
            }

            return buildBlock1DCoeffs(
                transport: transportCoeffs,
                sources: sourceTerms,
                geometry: geo,
                staticParams: staticParams,
                profiles: profiles
            )
        }

        // Convert profiles to CellVariable tuple
        let xOld = state.profiles.asTuple(
            dr: staticParams.mesh.dr,
            boundaryConditions: dynamicParams.boundaryConditions
        )

        // Solve PDE
        let result = solver.solve(
            dt: dt,
            staticParams: staticParams,
            dynamicParamsT: dynamicParams,
            dynamicParamsTplusDt: dynamicParams,
            geometryT: geometry,
            geometryTplusDt: geometry,
            xOld: xOld,
            coreProfilesT: state.profiles,
            coreProfilesTplusDt: state.profiles,
            coeffsCallback: coeffsCallback
        )

        // Store solver result for diagnostics
        lastSolverResult = result

        // Update state using high-precision time accumulation
        var newStats = state.statistics
        newStats.totalSteps += 1
        newStats.totalIterations += result.iterations
        newStats.converged = result.converged
        newStats.maxResidualNorm = max(newStats.maxResidualNorm, result.residualNorm)

        // Use advanced(by:profiles:statistics:transport:sources:) for high-precision time accumulation
        // This prevents cumulative round-off errors over long simulations (20,000+ steps)
        // Phase 3: Now also captures transport coefficients and source terms
        state = state.advanced(
            by: dt,
            profiles: result.updatedProfiles,
            statistics: newStats,
            transport: transportCoeffs,
            sources: sourceTerms,
            geometry: geometry
        )

        // Apply conservation enforcement if enabled
        if let enforcer = conservationEnforcer, enforcer.shouldEnforce(step: state.step) {
            let (correctedProfiles, results) = enforcer.enforce(
                profiles: state.profiles,
                geometry: geometry,
                step: state.step,
                time: state.time
            )

            // Update state with corrected profiles (preserving time accumulator)
            state = state.updated(profiles: correctedProfiles)

            // Accumulate conservation results
            conservationResults.append(contentsOf: results)
        }

        // Run diagnostics periodically
        if state.step % 100 == 0 {
            runDiagnostics(
                step: state.step,
                time: state.time,
                transportCoeffs: transportCoeffs
            )
        }
    }

    // MARK: - Phase 2: Derived Quantities & Diagnostics

    /// Update state with computed derived quantities and diagnostics
    ///
    /// **Phase 2**: Computes basic metrics (central values, averages, energies, solver diagnostics)
    /// **Phase 3**: Adds advanced metrics (τE, Q, βN) and conservation drift monitoring
    ///
    /// - Parameter stepWallTime: Wall clock time for this timestep [s]
    private func updateStateWithDiagnostics(stepWallTime: Float) {
        var derived: DerivedQuantities? = nil
        var diagnostics: NumericalDiagnostics? = nil

        // Compute derived quantities if enabled
        if samplingConfig.enableDerivedQuantities {
            derived = DerivedQuantitiesComputer.compute(
                profiles: state.profiles,
                geometry: geometry,
                transport: state.transport,
                sources: state.sources
            )
        }

        // Compute numerical diagnostics if enabled
        // Phase 3: Now includes conservation drift monitoring
        if samplingConfig.enableDiagnostics, let solverResult = lastSolverResult {
            diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
                from: solverResult,
                dt: state.dt,
                wallTime: stepWallTime,
                cflNumber: 0,  // TODO: Compute CFL number
                currentProfiles: state.profiles,
                initialProfiles: initialState?.profiles,
                geometry: geometry
            )
        }

        // Update state with computed diagnostics
        if derived != nil || diagnostics != nil {
            state = state.updated(
                derived: derived,
                diagnostics: diagnostics
            )
        }

        // Phase 3.4: Monitor conservation health
        if let diag = diagnostics {
            checkConservationHealth(diag)
        }
    }

    /// Monitor conservation health and emit warnings if drifts exceed thresholds
    ///
    /// **Phase 3.4**: Conservation monitoring with graduated warning levels
    ///
    /// - Parameter diagnostics: Numerical diagnostics with conservation drifts
    private func checkConservationHealth(_ diagnostics: NumericalDiagnostics) {
        // Skip if solver didn't converge (expected to have drift)
        guard diagnostics.converged else { return }

        let level = diagnostics.warningLevel

        switch level {
        case 0:
            // Healthy: No warnings
            break

        case 1:
            // Minor warning: 1-5% drift
            let maxDrift = max(
                abs(diagnostics.particle_drift),
                abs(diagnostics.energy_drift),
                abs(diagnostics.current_drift)
            )
            if state.step % 1000 == 0 {  // Log every 1000 steps to avoid spam
                print("[Warning] Conservation drift detected at step \(state.step), t=\(state.time)s:")
                print("  Max drift: \(maxDrift * 100)%")
                if abs(diagnostics.particle_drift) > 0.01 {
                    print("  - Particle drift: \(diagnostics.particle_drift * 100)%")
                }
                if abs(diagnostics.energy_drift) > 0.01 {
                    print("  - Energy drift: \(diagnostics.energy_drift * 100)%")
                }
                if abs(diagnostics.current_drift) > 0.01 {
                    print("  - Current drift: \(diagnostics.current_drift * 100)%")
                }
            }

        case 2:
            // Critical warning: > 5% drift
            let maxDrift = max(
                abs(diagnostics.particle_drift),
                abs(diagnostics.energy_drift),
                abs(diagnostics.current_drift)
            )
            print("[CRITICAL] Large conservation drift at step \(state.step), t=\(state.time)s:")
            print("  Max drift: \(maxDrift * 100)%")
            print("  - Particle drift: \(diagnostics.particle_drift * 100)%")
            print("  - Energy drift: \(diagnostics.energy_drift * 100)%")
            print("  - Current drift: \(diagnostics.current_drift * 100)%")
            print("  Recommendation: Check timestep (dt=\(state.dt)s) and mesh resolution")

        default:
            break
        }
    }

    /// Capture current state as TimePoint for time series
    ///
    /// - Returns: TimePoint with current state data
    private func captureTimePoint() -> TimePoint {
        TimePoint(
            time: state.time,
            profiles: state.profiles.toSerializable(),
            derived: state.derived,
            diagnostics: state.diagnostics
        )
    }

    // MARK: - Diagnostics

    /// Run all enabled diagnostics
    ///
    /// Performs comprehensive diagnostics based on configuration:
    /// - Transport coefficient checks (always)
    /// - Jacobian conditioning (if enabled)
    /// - Conservation drift monitoring (passive)
    ///
    /// - Parameters:
    ///   - step: Current timestep
    ///   - time: Current simulation time [s]
    ///   - transportCoeffs: Current transport coefficients
    private func runDiagnostics(
        step: Int,
        time: Float,
        transportCoeffs: TransportCoefficients
    ) {
        // 1. Transport diagnostics (always enabled, cheap)
        let transportResults = TransportDiagnostics.diagnose(
            coefficients: transportCoeffs,
            step: step,
            time: time
        )
        diagnosticResults.append(contentsOf: transportResults)

        // 2. Jacobian diagnostics (optional, expensive)
        if let config = diagnosticsConfig,
           config.enableJacobianCheck,
           step % config.jacobianCheckInterval == 0 {
            // TODO: Compute Jacobian from solver state
            // This requires access to the Jacobian matrix from the solver
            // For now, skip this diagnostic
        }

        // 3. Conservation drift monitoring (passive)
        if !conservationResults.isEmpty {
            let recentResults = conservationResults.suffix(10)
            let conservationDiag = ConservationDiagnostics.diagnose(
                results: Array(recentResults)
            )
            diagnosticResults.append(contentsOf: conservationDiag)
        }
    }
}

// MARK: - Errors

enum OrchestratorError: Error, CustomStringConvertible {
    case noInitialState

    var description: String {
        switch self {
        case .noInitialState:
            return "No initial state available for conservation enforcement"
        }
    }
}
