import Foundation

// MARK: - Solver Type

/// Solver type enumeration
public enum SolverType: String, Sendable, Codable {
    case linear
    case newtonRaphson
    case optimizer
}

// MARK: - Static Runtime Parameters

/// Static runtime parameters (trigger recompilation when changed)
public struct StaticRuntimeParams: Sendable, Codable, Equatable {
    /// Mesh configuration
    public let mesh: MeshConfig

    /// Evolve ion heat transport equation
    public let evolveIonHeat: Bool

    /// Evolve electron heat transport equation
    public let evolveElectronHeat: Bool

    /// Evolve particle density equation
    public let evolveDensity: Bool

    /// Evolve current diffusion equation
    public let evolveCurrent: Bool

    /// Solver type
    public let solverType: SolverType

    /// Theta parameter for time discretization (0: explicit, 0.5: Crank-Nicolson, 1: implicit)
    public let theta: Float

    /// Solver tolerance
    public let solverTolerance: Float

    /// Maximum solver iterations
    public let solverMaxIterations: Int

    public init(
        mesh: MeshConfig,
        evolveIonHeat: Bool = true,
        evolveElectronHeat: Bool = true,
        evolveDensity: Bool = true,
        evolveCurrent: Bool = true,
        solverType: SolverType = .newtonRaphson,
        theta: Float = 0.5,
        solverTolerance: Float = 1e-6,
        solverMaxIterations: Int = 30
    ) {
        self.mesh = mesh
        self.evolveIonHeat = evolveIonHeat
        self.evolveElectronHeat = evolveElectronHeat
        self.evolveDensity = evolveDensity
        self.evolveCurrent = evolveCurrent
        self.solverType = solverType
        self.theta = theta
        self.solverTolerance = solverTolerance
        self.solverMaxIterations = solverMaxIterations
    }
}

// MARK: - Dynamic Runtime Parameters

/// Dynamic runtime parameters (can change without recompilation)
public struct DynamicRuntimeParams: Sendable, Codable, Equatable {
    /// Time step [s]
    public var dt: Float

    /// Boundary conditions
    public var boundaryConditions: BoundaryConditions

    /// Profile conditions
    public var profileConditions: ProfileConditions

    /// Source parameters by source name
    public var sourceParams: [String: SourceParameters]

    /// Transport parameters
    public var transportParams: TransportParameters

    public init(
        dt: Float,
        boundaryConditions: BoundaryConditions,
        profileConditions: ProfileConditions,
        sourceParams: [String: SourceParameters] = [:],
        transportParams: TransportParameters
    ) {
        self.dt = dt
        self.boundaryConditions = boundaryConditions
        self.profileConditions = profileConditions
        self.sourceParams = sourceParams
        self.transportParams = transportParams
    }
}
