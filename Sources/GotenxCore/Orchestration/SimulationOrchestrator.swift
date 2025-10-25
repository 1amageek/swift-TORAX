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

    /// MHD models (sawteeth, NTMs, etc.)
    private let mhdModels: [any MHDModel]

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

    // MARK: - Pause/Resume State

    /// Pause state
    private var isPaused: Bool = false

    /// Continuation for pause/resume
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Initialization

    public init(
        staticParams: StaticRuntimeParams,
        initialProfiles: SerializableProfiles,
        transport: any TransportModel,
        sources: [any SourceModel] = [],
        mhdModels: [any MHDModel] = [],
        samplingConfig: SamplingConfig = .balanced,
        adaptiveConfig: AdaptiveTimestepConfig = .default
    ) async {
        self.staticParams = staticParams
        self.transport = transport
        self.sources = sources
        self.mhdModels = mhdModels
        self.samplingConfig = samplingConfig

        // Create geometry from static params
        self.geometry = Geometry(config: staticParams.mesh)

        self.timeStepCalculator = TimeStepCalculator(
            stabilityFactor: adaptiveConfig.safetyFactor,
            minTimestep: adaptiveConfig.effectiveMinDt,
            maxTimestep: adaptiveConfig.maxDt
        )

        // Create solver based on configuration
        switch staticParams.solverType {
        case .linear:
            self.solver = LinearSolver(
                nCorrectorSteps: staticParams.solverMaxIterations,
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
            // 🐛 DEBUG: Loop iteration
            if state.step % 10 == 0 || state.step < 5 {
                print("[DEBUG] Loop iteration: step=\(state.step), time=\(state.time)s / \(endTime)s")
            }

            // Check for task cancellation
            try Task.checkCancellation()

            // Check for pause state
            await checkPauseState()

            // Yield control periodically to allow getProgress() and other tasks to run
            // This prevents actor starvation when the simulation loop is running fast
            if state.step % 10 == 0 {
                await Task.yield()
            }

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

        // 🐛 DEBUG: Log timeSeries capture
        print("[DEBUG-Orchestrator] Simulation complete: \(timeSeries.count) time points captured")
        if !timeSeries.isEmpty {
            print("[DEBUG-Orchestrator] Time range: [\(timeSeries.first!.time)s, \(timeSeries.last!.time)s]")
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
    ///
    /// **App Integration**: Returns progress with optional profile data for live plotting.
    /// Enable `SamplingConfig.enableLivePlotting` to include profiles and derived quantities.
    ///
    /// - Returns: Progress information with optional profiles
    public func getProgress() async -> ProgressInfo {
        let includeProfiles = samplingConfig.enableLivePlotting

        // 🐛 DEBUG: Log when getProgress() is called
        print("[DEBUG-getProgress] Called: time=\(state.time)s, step=\(state.step), includeProfiles=\(includeProfiles)")

        // Convert profiles if needed
        let serializedProfiles: SerializableProfiles?
        if includeProfiles {
            print("[DEBUG-getProgress] Converting state.profiles to SerializableProfiles...")
            serializedProfiles = state.profiles.toSerializable()
            print("[DEBUG-getProgress] Conversion complete, returning ProgressInfo with profiles")
        } else {
            serializedProfiles = nil
        }

        return ProgressInfo(
            currentTime: state.time,
            totalSteps: state.statistics.totalSteps,
            lastDt: state.dt,
            converged: state.statistics.converged,
            profiles: serializedProfiles,
            derived: includeProfiles ? state.derived : nil
        )
    }

    /// Pause the simulation
    ///
    /// **App Integration**: Call from UI to pause long-running simulation.
    /// Simulation will pause at the beginning of the next timestep.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // From UI button handler
    /// Task {
    ///     await orchestrator.pause()
    /// }
    /// ```
    public func pause() {
        isPaused = true
    }

    /// Resume the simulation
    ///
    /// **App Integration**: Call from UI to resume paused simulation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // From UI button handler
    /// Task {
    ///     await orchestrator.resume()
    /// }
    /// ```
    public func resume() {
        isPaused = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    /// Check if simulation is paused
    ///
    /// - Returns: true if simulation is currently paused
    public func getIsPaused() -> Bool {
        isPaused
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

    // MARK: - Pause/Resume Helper

    /// Check if simulation is paused and wait for resume
    ///
    /// This method is called at the beginning of each timestep to check if the simulation
    /// should pause. If paused, it suspends execution until `resume()` is called.
    ///
    /// **Thread Safety**: Actor-isolated, so only one step can pause at a time.
    private func checkPauseState() async {
        // Use while loop instead of recursion to handle repeated pause/resume cycles
        while isPaused {
            await withCheckedContinuation { continuation in
                // Store continuation for resume()
                // If pause() is called multiple times before resume(), only the latest continuation is kept
                // (previous steps will have already resumed)
                pauseContinuation = continuation
            }
            // After resume, check isPaused again in case pause() was called during resume
        }
    }

    // MARK: - Time Stepping

    /// Last solver result (for diagnostics)
    private var lastSolverResult: SolverResult?

    /// Perform single timestep
    private func performStep(dynamicParams: DynamicRuntimeParams) async throws {
        // 🐛 DEBUG: performStep start
        if state.step < 5 {
            print("[DEBUG] performStep START: step=\(state.step), time=\(state.time)s")
        }

        // Construct geometry from mesh configuration
        let geometry = createGeometry(from: staticParams.mesh)

        // Calculate adaptive timestep (before MHD check)
        let dt: Float
        if state.step > 0 {
            // Compute transport coefficients for timestep calculation
            let transportCoeffs = transport.computeCoefficients(
                profiles: state.profiles,
                geometry: geometry,
                params: dynamicParams.transportParams
            )
            dt = timeStepCalculator.compute(
                transportCoeffs: transportCoeffs,
                dr: staticParams.mesh.dr
            )

            // 🐛 DEBUG: Adaptive dt
            if state.step < 5 {
                print("[DEBUG] Adaptive dt=\(dt)s")
            }
        } else {
            // First step: use configured timestep with safety lower bound
            // ✅ FIXED: Use dynamicParams.dt instead of hardcoded value
            dt = max(dynamicParams.dt, 1e-5)  // Enforce minimum for numerical stability
            print("[DEBUG] First step: dt=\(dt)s (configured: \(dynamicParams.dt)s)")
        }

        // Check for MHD events (sawteeth, NTMs, etc.)
        for model in mhdModels {
            // Apply MHD model - if it triggers, profiles are modified
            let modifiedProfiles = model.apply(
                to: state.profiles,
                geometry: geometry,
                time: state.time,
                dt: dt
            )

            // Check if profiles were modified (MHD event occurred)
            if modifiedProfiles != state.profiles {
                // MHD event occurred: bypass PDE solver and advance time

                // Get crash step duration if this is a sawtooth model
                let crashDt: Float
                if let sawtoothModel = model as? SawtoothModel {
                    crashDt = sawtoothModel.params.crashStepDuration
                } else {
                    crashDt = dt  // Use normal dt for other MHD models
                }

                // Update state with modified profiles
                let newStats = SimulationStatistics(
                    totalIterations: state.statistics.totalIterations,
                    totalSteps: state.statistics.totalSteps + 1,
                    converged: true,
                    maxResidualNorm: 0.0,  // No solver used
                    wallTime: state.statistics.wallTime
                )

                state = state.advanced(
                    by: crashDt,
                    profiles: modifiedProfiles,
                    statistics: newStats
                )

                // MHD event handled, skip PDE solver
                return
            }
        }

        // No MHD event: proceed with normal PDE solver step
        // Recompute transport coefficients (may have been done above, but ensure fresh values)
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

        // dt already calculated above (line 299-314)

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

        // Solve PDE (with adaptive retrial if not converged)
        let maxSolverRetries = 5
        var attempt = 0
        var dtAttempt = dt
        var accumulatedIterations = 0
        var worstResidual: Float = state.statistics.maxResidualNorm
        var finalResult: SolverResult? = nil

        while attempt <= maxSolverRetries {
            // 🐛 DEBUG: solver.solve() call
            if state.step < 5 {
                print("[DEBUG] Calling solver.solve(): step=\(state.step), dt=\(dtAttempt)s, attempt=\(attempt)")
            }

            let result = solver.solve(
                dt: dtAttempt,
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

            // 🐛 DEBUG: solver.solve() returned
            if state.step < 5 {
                print("[DEBUG] solver.solve() returned: converged=\(result.converged), iterations=\(result.iterations), residual=\(result.residualNorm)")
            }

            accumulatedIterations += result.iterations
            worstResidual = max(worstResidual, result.residualNorm)

            if result.converged {
                finalResult = result
                break
            }

            // 収束しなかった場合はタイムステップを半分にして再試行
            attempt += 1
            let nextDt = dtAttempt * 0.5

            if nextDt < timeStepCalculator.minimumTimestep {
                // これ以上タイムステップを縮小できないので即時エラー
                throw SolverError.convergenceFailure(
                    iterations: accumulatedIterations,
                    residualNorm: result.residualNorm
                )
            }

            if attempt > maxSolverRetries {
                throw SolverError.convergenceFailure(
                    iterations: accumulatedIterations,
                    residualNorm: result.residualNorm
                )
            }

            print("[SimulationOrchestrator] Solver did not converge; reducing dt to \(nextDt) s (attempt \(attempt) of \(maxSolverRetries))")
            dtAttempt = nextDt
        }

        guard let resolvedResult = finalResult else {
            throw SolverError.convergenceFailure(
                iterations: accumulatedIterations,
                residualNorm: worstResidual
            )
        }

        // Store solver result for diagnostics
        lastSolverResult = resolvedResult

        // Update state using high-precision time accumulation
        var newStats = state.statistics
        newStats.totalSteps += 1
        newStats.totalIterations += accumulatedIterations
        newStats.converged = true
        // Use final successful attempt's residual, not worst from failed attempts
        // This prevents false alarms in diagnostics when retries occurred
        newStats.maxResidualNorm = max(newStats.maxResidualNorm, resolvedResult.residualNorm)

        // Use advanced(by:profiles:statistics:transport:sources:) for high-precision time accumulation
        // This prevents cumulative round-off errors over long simulations (20,000+ steps)
        // Phase 3: Now also captures transport coefficients and source terms
        state = state.advanced(
            by: dtAttempt,
            profiles: resolvedResult.updatedProfiles,
            statistics: newStats,
            transport: transportCoeffs,
            sources: sourceTerms,
            geometry: geometry
        )

        // 🐛 DEBUG: state updated
        if state.step < 5 || state.step % 10 == 0 {
            print("[DEBUG] performStep END: step=\(state.step), time=\(state.time)s, dt=\(state.dt)s")
        }

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
                transportCoeffs: transportCoeffs,
                geometry: geometry
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
        print("[DEBUG-captureTimePoint] Capturing TimePoint at t=\(state.time)s, step=\(state.step)")
        let serialized = state.profiles.toSerializable()
        print("[DEBUG-captureTimePoint] TimePoint created for timeSeries")

        return TimePoint(
            time: state.time,
            profiles: serialized,
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
    ///   - geometry: Current geometry
    private func runDiagnostics(
        step: Int,
        time: Float,
        transportCoeffs: TransportCoefficients,
        geometry: Geometry
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
            // Check if solver provided condition number estimate in metadata
            if let solverResult = lastSolverResult,
               let conditionNumber = solverResult.metadata["condition_number"] {
                // Use explicit Jacobian if available
                let result = DiagnosticResult(
                    name: "Jacobian Condition Number",
                    severity: conditionNumber > 1e6 ? .warning : .info,
                    message: "Condition number: \(conditionNumber)",
                    value: conditionNumber,
                    threshold: 1e6,
                    time: time,
                    step: step
                )
                diagnosticResults.append(result)
            } else {
                // Fallback: Log that Jacobian check is enabled but unavailable
                // This avoids silent failure when user enables the feature
                let result = DiagnosticResult(
                    name: "Jacobian Diagnostics",
                    severity: .info,
                    message: "Enabled but condition number not available from solver",
                    time: time,
                    step: step
                )
                diagnosticResults.append(result)
            }
        }

        // 3. Conservation drift monitoring (passive)
        // Always monitor conservation drift, even if enforcer is disabled
        if let initial = initialState,
           step % 100 == 0 {  // Check every 100 steps to avoid overhead
            let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
                current: state.profiles,
                initial: initial.profiles,
                geometry: geometry
            )

            // Create passive monitoring results if enforcer is not active
            if conservationEnforcer == nil {
                // Wrap drifts as ConservationResult for unified reporting
                let particleResult = ConservationResult(
                    lawName: "Particle Conservation (passive)",
                    referenceQuantity: 0.0,  // Not used in passive mode
                    currentQuantity: 0.0,     // Not used in passive mode
                    relativeDrift: drifts.particle,
                    correctionFactor: 1.0,
                    corrected: false,
                    time: time,
                    step: step
                )
                conservationResults.append(particleResult)

                let energyResult = ConservationResult(
                    lawName: "Energy Conservation (passive)",
                    referenceQuantity: 0.0,
                    currentQuantity: 0.0,
                    relativeDrift: drifts.energy,
                    correctionFactor: 1.0,
                    corrected: false,
                    time: time,
                    step: step
                )
                conservationResults.append(energyResult)
            }
        }

        // Diagnose conservation results if available (from enforcer or passive monitoring)
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
