import MLX
import Foundation

// MARK: - Simulation State

/// Internal simulation state (actor-isolated)
public struct SimulationState: Sendable {
    /// Current plasma profiles
    public let profiles: CoreProfiles

    /// Current simulation time [s]
    public let time: Float

    /// Current timestep [s]
    public let dt: Float

    /// Step number
    public let step: Int

    /// Statistics
    public var statistics: SimulationStatistics

    public init(
        profiles: CoreProfiles,
        time: Float = 0.0,
        dt: Float = 1e-4,
        step: Int = 0,
        statistics: SimulationStatistics = SimulationStatistics()
    ) {
        self.profiles = profiles
        self.time = time
        self.dt = dt
        self.step = step
        self.statistics = statistics
    }

    /// Create updated state
    public func updated(
        profiles: CoreProfiles? = nil,
        time: Float? = nil,
        dt: Float? = nil,
        step: Int? = nil,
        statistics: SimulationStatistics? = nil
    ) -> SimulationState {
        SimulationState(
            profiles: profiles ?? self.profiles,
            time: time ?? self.time,
            dt: dt ?? self.dt,
            step: step ?? self.step,
            statistics: statistics ?? self.statistics
        )
    }
}

// MARK: - Simulation Statistics

/// Statistics tracked during simulation
public struct SimulationStatistics: Sendable, Codable {
    /// Total number of solver iterations
    public var totalIterations: Int

    /// Number of timesteps
    public var totalSteps: Int

    /// Whether simulation converged
    public var converged: Bool

    /// Maximum residual norm encountered
    public var maxResidualNorm: Float

    /// Total wall time [s]
    public var wallTime: Float

    public init(
        totalIterations: Int = 0,
        totalSteps: Int = 0,
        converged: Bool = true,
        maxResidualNorm: Float = 0.0,
        wallTime: Float = 0.0
    ) {
        self.totalIterations = totalIterations
        self.totalSteps = totalSteps
        self.converged = converged
        self.maxResidualNorm = maxResidualNorm
        self.wallTime = wallTime
    }
}

// MARK: - Serializable Profiles

/// Serializable profiles for crossing actor boundaries
public struct SerializableProfiles: Sendable, Codable {
    public let ionTemperature: [Float]
    public let electronTemperature: [Float]
    public let electronDensity: [Float]
    public let poloidalFlux: [Float]

    public init(
        ionTemperature: [Float],
        electronTemperature: [Float],
        electronDensity: [Float],
        poloidalFlux: [Float]
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }
}

// MARK: - CoreProfiles Conversion

extension CoreProfiles {
    /// Convert to serializable format
    public func toSerializable() -> SerializableProfiles {
        SerializableProfiles(
            ionTemperature: ionTemperature.value.asArray(Float.self),
            electronTemperature: electronTemperature.value.asArray(Float.self),
            electronDensity: electronDensity.value.asArray(Float.self),
            poloidalFlux: poloidalFlux.value.asArray(Float.self)
        )
    }

    /// Create from serializable format
    public init(from serializable: SerializableProfiles) {
        self.init(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(serializable.ionTemperature)),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(serializable.electronTemperature)),
            electronDensity: EvaluatedArray(evaluating: MLXArray(serializable.electronDensity)),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray(serializable.poloidalFlux))
        )
    }
}

// MARK: - Simulation Result

/// Result from simulation run
public struct SimulationResult: Sendable, Codable {
    /// Final profiles
    public let finalProfiles: SerializableProfiles

    /// Simulation statistics
    public let statistics: SimulationStatistics

    /// Time series (optional, for post-processing)
    public let timeSeries: [TimePoint]?

    public init(
        finalProfiles: SerializableProfiles,
        statistics: SimulationStatistics,
        timeSeries: [TimePoint]? = nil
    ) {
        self.finalProfiles = finalProfiles
        self.statistics = statistics
        self.timeSeries = timeSeries
    }
}

// MARK: - Time Point

/// Single time point in simulation
public struct TimePoint: Sendable, Codable {
    public let time: Float
    public let profiles: SerializableProfiles

    public init(time: Float, profiles: SerializableProfiles) {
        self.time = time
        self.profiles = profiles
    }
}

// MARK: - Progress Info

/// Progress information for monitoring
public struct ProgressInfo: Sendable {
    public let currentTime: Float
    public let totalSteps: Int
    public let lastDt: Float
    public let converged: Bool

    public init(
        currentTime: Float,
        totalSteps: Int,
        lastDt: Float,
        converged: Bool
    ) {
        self.currentTime = currentTime
        self.totalSteps = totalSteps
        self.lastDt = lastDt
        self.converged = converged
    }
}
