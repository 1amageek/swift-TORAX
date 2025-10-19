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
/// Architecture follows TORAX design with MLX optimization:
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

    // MARK: - Initialization

    public init(
        staticParams: StaticRuntimeParams,
        initialProfiles: SerializableProfiles,
        transport: any TransportModel,
        sources: [any SourceModel] = []
    ) async {
        self.staticParams = staticParams
        self.transport = transport
        self.sources = sources
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
    }

    // MARK: - Public API

    /// Run simulation until specified end time
    ///
    /// - Parameters:
    ///   - endTime: Simulation end time [s]
    ///   - dynamicParams: Time-dependent dynamic parameters
    ///   - saveInterval: Interval for saving time series (nil = don't save)
    /// - Returns: Simulation result
    public func run(
        until endTime: Float,
        dynamicParams: DynamicRuntimeParams,
        saveInterval: Float? = nil
    ) async throws -> SimulationResult {
        let startWallTime = Date()
        var timeSeries: [TimePoint] = []
        var lastSaveTime: Float = 0.0

        while state.time < endTime {
            // Perform single timestep
            try await performStep(dynamicParams: dynamicParams)

            // Save time series if requested
            if let interval = saveInterval, state.time - lastSaveTime >= interval {
                timeSeries.append(TimePoint(
                    time: state.time,
                    profiles: state.profiles.toSerializable()
                ))
                lastSaveTime = state.time
            }

            // Check for numerical issues
            if !state.statistics.converged {
                throw SolverError.convergenceFailure(
                    iterations: state.statistics.totalIterations,
                    residualNorm: state.statistics.maxResidualNorm
                )
            }
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

    // MARK: - Time Stepping

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

        // Update state using high-precision time accumulation
        var newStats = state.statistics
        newStats.totalSteps += 1
        newStats.totalIterations += result.iterations
        newStats.converged = result.converged
        newStats.maxResidualNorm = max(newStats.maxResidualNorm, result.residualNorm)

        // Use advanced(by:profiles:statistics:) for high-precision time accumulation
        // This prevents cumulative round-off errors over long simulations (20,000+ steps)
        state = state.advanced(
            by: dt,
            profiles: result.updatedProfiles,
            statistics: newStats
        )
    }
}
