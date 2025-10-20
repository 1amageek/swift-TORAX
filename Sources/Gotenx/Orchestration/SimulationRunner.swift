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
public actor SimulationRunner {
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
    /// - Throws: ConfigurationError if initialization fails
    public func initialize(
        transportModel: any TransportModel,
        sourceModels: [any SourceModel]
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

        // Initialize orchestrator with provided models
        self.orchestrator = await SimulationOrchestrator(
            staticParams: staticParams,
            initialProfiles: serializableProfiles,
            transport: transportModel,
            sources: sourceModels
        )

        print("✓ Simulation initialized")
        print("  Mesh: \(staticParams.mesh.nCells) cells")
        print("  Solver: \(staticParams.solverType)")
        print("  Transport: \(config.runtime.dynamic.transport.modelType)")
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

/// Simulation errors
public enum SimulationError: Error {
    case notInitialized
    case invalidConfiguration(String)
    case executionFailed(String)
}
