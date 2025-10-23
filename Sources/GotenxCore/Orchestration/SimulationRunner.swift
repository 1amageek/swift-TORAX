// SimulationRunner.swift
// High-level simulation runner that integrates configuration with execution

import Foundation
import MLX

/// High-level simulation runner
///
/// Integrates the configuration system with simulation execution.
/// Responsible for:
/// - Running the simulation loop with provided models
/// - Managing timesteps and progress
/// - Coordinating with SimulationOrchestrator
///
/// **Protocol Conformance**: Conforms to `SimulationRunnable` for dependency injection.
/// This enables testing with `MockSimulationRunner` and future implementations
/// like `RemoteSimulationRunner`.
///
/// ## Example
///
/// ```swift
/// // Direct usage (production)
/// let runner = SimulationRunner(config: config)
/// try await runner.initialize(...)
/// let result = try await runner.run()
///
/// // Protocol usage (testing)
/// let runner: any SimulationRunnable = SimulationRunner(config: config)
/// try await runner.initialize(...)
/// let result = try await runner.run()
/// ```
public actor SimulationRunner: SimulationRunnable {
    private let config: SimulationConfiguration
    private var orchestrator: SimulationOrchestrator?

    public init(config: SimulationConfiguration) {
        self.config = config
    }

    /// Initialize the simulation with pre-created models
    ///
    /// - Parameters:
    ///   - transportModel: Pre-created transport model
    ///   - sourceModels: Pre-created source models
    ///   - mhdModels: MHD models (optional, default: created from config)
    /// - Throws: ConfigurationError if initialization fails
    public func initialize(
        transportModel: any TransportModel,
        sourceModels: [any SourceModel],
        mhdModels: [any MHDModel]? = nil
    ) async throws {
        // Create static runtime parameters
        let staticParams = try config.runtime.static.toRuntimeParams()

        // Generate initial profiles from boundary conditions
        let initialProfiles = try generateInitialProfiles(
            mesh: config.runtime.static.mesh,
            boundaries: config.runtime.dynamic.boundaries
        )

        // Convert to serializable format
        let serializableProfiles = initialProfiles.toSerializable()

        // Create MHD models from config if not provided
        let mhdModelsToUse: [any MHDModel]
        if let provided = mhdModels {
            mhdModelsToUse = provided
        } else {
            mhdModelsToUse = MHDModelFactory.createAllModels(config: config.runtime.dynamic.mhd)
        }

        // Initialize orchestrator with provided models
        self.orchestrator = await SimulationOrchestrator(
            staticParams: staticParams,
            initialProfiles: serializableProfiles,
            transport: transportModel,
            sources: sourceModels,
            mhdModels: mhdModelsToUse
        )

        print("✓ Simulation initialized")
        print("  Mesh: \(staticParams.mesh.nCells) cells")
        print("  Solver: \(staticParams.solverType)")
        print("  Transport: \(config.runtime.dynamic.transport.modelType)")
        if !mhdModelsToUse.isEmpty {
            print("  MHD models: \(mhdModelsToUse.count) enabled")
        }
    }

    /// Run the simulation
    ///
    /// Executes the simulation loop for the configured time range.
    /// - Parameter progressCallback: Optional callback for progress updates
    /// - Returns: Final simulation result
    /// - Throws: Error if simulation fails
    public func run(
        progressCallback: (@Sendable (Float, ProgressInfo) -> Void)? = nil
    ) async throws -> SimulationResult {
        guard let orchestrator = orchestrator else {
            throw SimulationError.notInitialized
        }

        let timeConfig = config.time
        let dynamicConfig = config.runtime.dynamic

        // Create dynamic parameters
        let dynamicParams = dynamicConfig.toDynamicRuntimeParams(dt: timeConfig.initialDt)

        let endTime = timeConfig.end

        print("\n🚀 Starting simulation")
        print("  Time range: [\(timeConfig.start), \(timeConfig.end)] s")
        print("  Initial dt: \(timeConfig.initialDt) s")

        // Start background task for progress monitoring
        let progressTask: Task<Void, Never>? = if let callback = progressCallback {
            Task {
                while !Task.isCancelled {
                    let progress = await orchestrator.getProgress()
                    let fraction = progress.currentTime / endTime
                    callback(fraction, progress)

                    // Update every 0.1 seconds
                    try? await Task.sleep(for: .milliseconds(100))

                    // Stop when simulation completes
                    if progress.currentTime >= endTime {
                        break
                    }
                }
            }
        } else {
            nil
        }

        // Run simulation via orchestrator
        let result = try await orchestrator.run(
            until: endTime,
            dynamicParams: dynamicParams,
            saveInterval: nil  // Could be made configurable
        )

        // Cancel progress monitoring
        progressTask?.cancel()

        print("✓ Simulation complete")
        print("  Steps: \(result.statistics.totalSteps)")
        print("  Final time: \(endTime) s")
        print("  Wall time: \(result.statistics.wallTime) s")

        return result
    }

    /// Pause the simulation
    ///
    /// **App Integration**: Call from UI to pause long-running simulation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // From SwiftUI button
    /// Button("Pause") {
    ///     Task {
    ///         await runner.pause()
    ///     }
    /// }
    /// ```
    public func pause() async {
        await orchestrator?.pause()
    }

    /// Resume the simulation
    ///
    /// **App Integration**: Call from UI to resume paused simulation.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // From SwiftUI button
    /// Button("Resume") {
    ///     Task {
    ///         await runner.resume()
    ///     }
    /// }
    /// ```
    public func resume() async {
        await orchestrator?.resume()
    }

    /// Check if simulation is paused
    ///
    /// - Returns: true if simulation is currently paused
    public func isPaused() async -> Bool {
        await orchestrator?.getIsPaused() ?? false
    }

    /// Generate initial profiles from boundary conditions
    private func generateInitialProfiles(
        mesh: MeshConfig,
        boundaries: BoundaryConfig
    ) throws -> CoreProfiles {
        let nCells = mesh.nCells

        // Generate parabolic profiles from boundary values
        // Ti(r) = Ti_edge + (Ti_core - Ti_edge) * (1 - (r/a)^2)^2
        var rNorm = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            rNorm[i] = Float(i) / Float(nCells - 1)
        }

        // Temperature profiles [eV]
        let tiEdge = boundaries.ionTemperature
        let tiCore = tiEdge * 10.0  // Core ~10× edge
        var ti = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            let factor = pow(1.0 - rNorm[i] * rNorm[i], 2.0)
            ti[i] = tiEdge + (tiCore - tiEdge) * factor
        }

        let teEdge = boundaries.electronTemperature
        let teCore = teEdge * 10.0
        var te = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            let factor = pow(1.0 - rNorm[i] * rNorm[i], 2.0)
            te[i] = teEdge + (teCore - teEdge) * factor
        }

        // Density profile [m^-3]
        let neEdge = boundaries.density
        let neCore = neEdge * 3.0  // Core ~3× edge
        var ne = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            let factor = pow(1.0 - rNorm[i] * rNorm[i], 1.5)
            ne[i] = neEdge + (neCore - neEdge) * factor
        }

        // Poloidal flux (initially zero)
        let psi = [Float](repeating: 0.0, count: nCells)

        // Create evaluated arrays
        let evaluated = EvaluatedArray.evaluatingBatch([
            MLXArray(ti),
            MLXArray(te),
            MLXArray(ne),
            MLXArray(psi)
        ])

        return CoreProfiles(
            ionTemperature: evaluated[0],
            electronTemperature: evaluated[1],
            electronDensity: evaluated[2],
            poloidalFlux: evaluated[3]
        )
    }

    /// Adapt timestep based on stability criteria
    private func adaptTimestep(
        currentDt: Float,
        minDt: Float,
        maxDt: Float,
        safetyFactor: Float
    ) -> Float {
        // Simple adaptive scheme: could be enhanced with error estimation
        var newDt = currentDt * 1.1  // Increase by 10%

        // Apply safety factor
        newDt *= safetyFactor

        // Clamp to limits
        newDt = max(minDt, min(maxDt, newDt))

        return newDt
    }
}

/// Simulation errors with user-friendly descriptions
///
/// **App Integration**: Conforms to `LocalizedError` for user-friendly error messages
/// and recovery suggestions in the UI.
///
/// **Design Note**: This is a high-level error type for app integration.
/// Internal errors (like `SolverError`) are thrown directly by lower-level components.
/// Apps should catch both `SimulationError` and `SolverError`.
///
/// ## Example
///
/// ```swift
/// do {
///     try await runner.run()
/// } catch let error as SimulationError {
///     // High-level errors (initialization, configuration, validation)
///     print(error.localizedDescription)
///     if let suggestion = error.recoverySuggestion {
///         print("Suggestion: \(suggestion)")
///     }
/// } catch let error as SolverError {
///     // Low-level solver errors (convergence, numerical instability)
///     print("Solver error: \(error)")
/// }
/// ```
public enum SimulationError: Error, LocalizedError {
    case notInitialized
    case invalidConfiguration(String)
    case executionFailed(String)

    // MARK: - Specific Errors

    /// Model initialization failed
    case modelInitializationFailed(modelName: String, reason: String)

    /// Numeric instability detected during simulation
    case numericInstability(time: Float, variable: String, value: Float)

    /// Solver failed to converge
    case convergenceFailure(iterations: Int, residual: Float)

    /// Invalid boundary conditions
    case invalidBoundaryConditions(String)

    /// Mesh resolution too coarse
    case meshTooCoarse(nCells: Int, minimum: Int)

    /// Time step too small
    case timeStepTooSmall(dt: Float, minimum: Float)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Simulation not initialized. Call initialize() first."

        case .invalidConfiguration(let msg):
            return "Invalid configuration: \(msg)"

        case .executionFailed(let msg):
            return "Simulation execution failed: \(msg)"

        case .modelInitializationFailed(let model, let reason):
            return "Failed to initialize \(model): \(reason)"

        case .numericInstability(let time, let variable, let value):
            return "Numeric instability detected at t=\(time)s: \(variable) = \(value)"

        case .convergenceFailure(let iters, let residual):
            return "Solver failed to converge after \(iters) iterations (residual: \(residual))"

        case .invalidBoundaryConditions(let msg):
            return "Invalid boundary conditions: \(msg)"

        case .meshTooCoarse(let nCells, let minimum):
            return "Mesh too coarse: \(nCells) cells (minimum: \(minimum))"

        case .timeStepTooSmall(let dt, let minimum):
            return "Time step too small: \(dt)s (minimum: \(minimum))"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .meshTooCoarse(_, let minimum):
            return "Increase mesh resolution to at least \(minimum) cells"

        case .timeStepTooSmall:
            return "Increase initial time step or check for numerical instabilities"

        case .convergenceFailure:
            return "Try reducing time step or using a more robust solver"

        case .invalidBoundaryConditions:
            return "Check that temperature and density values are positive and realistic"

        case .modelInitializationFailed:
            return "Check model configuration and ensure all required parameters are provided"

        default:
            return nil
        }
    }
}
