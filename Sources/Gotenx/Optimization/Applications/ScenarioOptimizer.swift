// ScenarioOptimizer.swift
// High-level optimization scenarios for tokamak operation
//
// Use cases:
// 1. Maximize Q_fusion (fusion gain)
// 2. Match experimental target profiles
// 3. Optimize ramp-up/ramp-down trajectories

import Foundation
import MLX

/// Scenario optimizer for tokamak operation optimization
///
/// **Purpose**: High-level interface for common optimization scenarios
///
/// **Example 1: Maximize Q_fusion**
/// ```swift
/// let result = try await ScenarioOptimizer.maximizeQFusion(
///     initialProfiles: profiles,
///     geometry: geometry,
///     staticParams: staticParams,
///     dynamicParams: dynamicParams,
///     timeHorizon: 2.0,
///     dt: 0.01,
///     constraints: .iter
/// )
///
/// print("Optimized Q_fusion: \(result.Q_fusion)")
/// ```
///
/// **Example 2: Match target profiles**
/// ```swift
/// let result = try ScenarioOptimizer.matchTargetProfiles(
///     initialProfiles: profiles,
///     targetProfiles: experimentalData,
///     ...
/// )
/// ```
public struct ScenarioOptimizer {

    // MARK: - Q_fusion Maximization

    /// Optimize actuator trajectory to maximize fusion gain (Q_fusion)
    ///
    /// **Objective**: Maximize Q = P_fusion / (P_auxiliary + P_ohmic)
    ///
    /// **Method**: Adam optimizer with gradient-based search
    ///
    /// - Parameters:
    ///   - initialProfiles: Initial plasma profiles
    ///   - geometry: Tokamak geometry
    ///   - staticParams: Static runtime parameters
    ///   - dynamicParams: Dynamic runtime parameters (initial guess)
    ///   - timeHorizon: Simulation time [s]
    ///   - dt: Fixed timestep [s]
    ///   - constraints: Actuator constraints (power limits, etc.)
    ///   - optimizerConfig: Adam optimizer configuration
    ///
    /// - Returns: Optimization result with optimal actuators and achieved Q_fusion
    public static func maximizeQFusion(
        initialProfiles: CoreProfiles,
        geometry: Geometry,
        staticParams: StaticRuntimeParams,
        dynamicParams: DynamicRuntimeParams,
        timeHorizon: Float,
        dt: Float,
        constraints: ActuatorConstraints = .iter,
        optimizerConfig: AdamConfig = .default
    ) throws -> ScenarioOptimizationResult {
        let nSteps = Int(timeHorizon / dt)

        // Initial guess: constant baseline actuators
        let initialActuators = ActuatorTimeSeries.constant(
            P_ECRH: 15.0,   // 15 MW ECRH
            P_ICRH: 7.5,    // 7.5 MW ICRH
            gas_puff: 5e20, // 5×10²⁰ particles/s
            I_plasma: 15.0, // 15 MA
            nSteps: nSteps
        )

        // Create differentiable simulation
        let simulation = DifferentiableSimulation(
            staticParams: staticParams,
            transport: createTransportModel(from: dynamicParams),
            sources: createSourceModels(from: dynamicParams),
            geometry: geometry
        )

        // Define optimization problem (maximize Q_fusion)
        let problem = QFusionMaximization(
            simulation: simulation,
            initialProfiles: initialProfiles,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )

        // Create optimizer
        let optimizer = Adam(
            learningRate: optimizerConfig.learningRate,
            maxIterations: optimizerConfig.maxIterations,
            tolerance: optimizerConfig.tolerance,
            logInterval: optimizerConfig.logInterval
        )

        // Run optimization
        print("🎯 Optimizing for maximum Q_fusion...")
        let result = optimizer.optimize(
            problem: problem,
            initialParams: initialActuators,
            constraints: constraints
        )

        // Compute final Q_fusion
        let (finalProfiles, _) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: result.actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )

        let derived = DerivedQuantitiesComputer.compute(
            profiles: finalProfiles,
            geometry: geometry
        )

        return ScenarioOptimizationResult(
            actuators: result.actuators,
            finalProfiles: finalProfiles,
            Q_fusion: derived.Q_fusion,
            tau_E: derived.tau_E,
            beta_N: derived.beta_N,
            iterations: result.iterations,
            converged: result.converged,
            lossHistory: result.lossHistory
        )
    }

    // MARK: - Profile Matching

    /// Optimize actuators to match experimental target profiles
    ///
    /// **Objective**: Minimize L2 error between simulated and target profiles
    ///
    /// **Use case**: Reproduce experimental scenarios
    ///
    /// - Parameters:
    ///   - initialProfiles: Initial plasma profiles
    ///   - targetProfiles: Experimental target profiles to match
    ///   - geometry: Tokamak geometry
    ///   - staticParams: Static runtime parameters
    ///   - dynamicParams: Dynamic runtime parameters
    ///   - timeHorizon: Simulation time [s]
    ///   - dt: Fixed timestep [s]
    ///   - constraints: Actuator constraints
    ///   - optimizerConfig: Adam optimizer configuration
    ///
    /// - Returns: Optimization result with matched profiles
    public static func matchTargetProfiles(
        initialProfiles: CoreProfiles,
        targetProfiles: TargetProfiles,
        geometry: Geometry,
        staticParams: StaticRuntimeParams,
        dynamicParams: DynamicRuntimeParams,
        timeHorizon: Float,
        dt: Float,
        constraints: ActuatorConstraints = .iter,
        optimizerConfig: AdamConfig = .default
    ) throws -> ScenarioOptimizationResult {
        let nSteps = Int(timeHorizon / dt)

        // Initial guess
        let initialActuators = ActuatorTimeSeries.constant(
            P_ECRH: 10.0,
            P_ICRH: 5.0,
            gas_puff: 1e20,
            I_plasma: 15.0,
            nSteps: nSteps
        )

        // Create simulation
        let simulation = DifferentiableSimulation(
            staticParams: staticParams,
            transport: createTransportModel(from: dynamicParams),
            sources: createSourceModels(from: dynamicParams),
            geometry: geometry
        )

        // Define problem (minimize profile mismatch)
        let problem = ProfileMatching(
            simulation: simulation,
            initialProfiles: initialProfiles,
            targetProfiles: targetProfiles,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )

        // Optimize
        let optimizer = Adam(
            learningRate: optimizerConfig.learningRate,
            maxIterations: optimizerConfig.maxIterations,
            tolerance: optimizerConfig.tolerance
        )

        print("🎯 Optimizing to match target profiles...")
        let result = optimizer.optimize(
            problem: problem,
            initialParams: initialActuators,
            constraints: constraints
        )

        // Get final profiles
        let (finalProfiles, _) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: result.actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )

        let derived = DerivedQuantitiesComputer.compute(
            profiles: finalProfiles,
            geometry: geometry
        )

        return ScenarioOptimizationResult(
            actuators: result.actuators,
            finalProfiles: finalProfiles,
            Q_fusion: derived.Q_fusion,
            tau_E: derived.tau_E,
            beta_N: derived.beta_N,
            iterations: result.iterations,
            converged: result.converged,
            lossHistory: result.lossHistory
        )
    }

    // MARK: - Helper Functions

    /// Create transport model from dynamic params
    private static func createTransportModel(from params: DynamicRuntimeParams) -> any TransportModel {
        // Use transport model from params
        // For now, return Bohm-GyroBohm as default
        return BohmGyroBohmTransportModel()
    }

    /// Create source models from dynamic params
    private static func createSourceModels(from params: DynamicRuntimeParams) -> [any SourceModel] {
        // Import required: GotenxPhysics module for source adapters
        // For now, return empty array (TODO: wire up source models)
        // This requires importing GotenxPhysics which provides:
        // - FusionPowerSource
        // - OhmicHeatingSource
        // - BremsstrahlungSource
        // - IonElectronExchangeSource

        // Return empty for now to avoid circular dependency
        return []
    }
}

// MARK: - Optimization Problems

/// Q_fusion maximization problem
struct QFusionMaximization: OptimizationProblem {
    let simulation: DifferentiableSimulation
    let initialProfiles: CoreProfiles
    let dynamicParams: DynamicRuntimeParams
    let timeHorizon: Float
    let dt: Float

    func objective(_ actuators: ActuatorTimeSeries) -> Float {
        let (_, loss) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )
        return loss.item(Float.self)
    }

    func gradient(_ actuators: ActuatorTimeSeries) -> ActuatorTimeSeries {
        let sensitivity = ForwardSensitivity(simulation: simulation)
        return sensitivity.computeGradient(
            initialProfiles: initialProfiles,
            actuators: actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )
    }
}

/// Profile matching problem
struct ProfileMatching: OptimizationProblem {
    let simulation: DifferentiableSimulation
    let initialProfiles: CoreProfiles
    let targetProfiles: TargetProfiles
    let dynamicParams: DynamicRuntimeParams
    let timeHorizon: Float
    let dt: Float

    func objective(_ actuators: ActuatorTimeSeries) -> Float {
        let (finalProfiles, _) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt
        )

        // Compute L2 error
        let loss = simulation.computeProfileMatchingLoss(
            profiles: finalProfiles,
            target: targetProfiles
        )

        return loss.item(Float.self)
    }

    func gradient(_ actuators: ActuatorTimeSeries) -> ActuatorTimeSeries {
        let sensitivity = ForwardSensitivity(simulation: simulation)

        // Custom objective for profile matching
        let objectiveFn: (CoreProfiles) -> MLXArray = { profiles in
            return self.simulation.computeProfileMatchingLoss(
                profiles: profiles,
                target: self.targetProfiles
            )
        }

        return sensitivity.computeGradientWithCustomObjective(
            initialProfiles: initialProfiles,
            actuators: actuators,
            dynamicParams: dynamicParams,
            timeHorizon: timeHorizon,
            dt: dt,
            objectiveFn: objectiveFn
        )
    }
}

// MARK: - Configuration

/// Adam optimizer configuration
public struct AdamConfig: Sendable {
    public let learningRate: Float
    public let maxIterations: Int
    public let tolerance: Float
    public let logInterval: Int

    public init(
        learningRate: Float,
        maxIterations: Int,
        tolerance: Float,
        logInterval: Int = 10
    ) {
        self.learningRate = learningRate
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.logInterval = logInterval
    }

    /// Default configuration for Q_fusion optimization
    public static let `default` = AdamConfig(
        learningRate: 0.001,
        maxIterations: 100,
        tolerance: 1e-4
    )

    /// Fast configuration (fewer iterations)
    public static let fast = AdamConfig(
        learningRate: 0.01,
        maxIterations: 50,
        tolerance: 1e-3
    )

    /// Precise configuration (more iterations, tighter tolerance)
    public static let precise = AdamConfig(
        learningRate: 0.0005,
        maxIterations: 200,
        tolerance: 1e-5
    )
}

// MARK: - Result

/// Scenario optimization result
public struct ScenarioOptimizationResult {
    /// Optimized actuator trajectory
    public let actuators: ActuatorTimeSeries

    /// Final plasma profiles
    public let finalProfiles: CoreProfiles

    /// Achieved fusion gain
    public let Q_fusion: Float

    /// Energy confinement time [s]
    public let tau_E: Float

    /// Normalized beta
    public let beta_N: Float

    /// Number of optimization iterations
    public let iterations: Int

    /// Whether optimization converged
    public let converged: Bool

    /// Loss history
    public let lossHistory: [Float]

    public init(
        actuators: ActuatorTimeSeries,
        finalProfiles: CoreProfiles,
        Q_fusion: Float,
        tau_E: Float,
        beta_N: Float,
        iterations: Int,
        converged: Bool,
        lossHistory: [Float]
    ) {
        self.actuators = actuators
        self.finalProfiles = finalProfiles
        self.Q_fusion = Q_fusion
        self.tau_E = tau_E
        self.beta_N = beta_N
        self.iterations = iterations
        self.converged = converged
        self.lossHistory = lossHistory
    }

    /// Summary description
    public func summary() -> String {
        let status = converged ? "✅ Converged" : "⚠️ Max iterations"
        return """
        Scenario Optimization Result: \(status)
          Q_fusion: \(Q_fusion)
          τE: \(tau_E) s
          βN: \(beta_N)
          Iterations: \(iterations)
        """
    }
}
