import Foundation

// MARK: - Pedestal Output

/// Pedestal model output
public struct PedestalOutput: Sendable, Equatable {
    /// Pedestal temperature [keV]
    public let temperature: Float

    /// Pedestal density [10^20 m^-3]
    public let density: Float

    /// Pedestal width [m]
    public let width: Float

    public init(temperature: Float, density: Float, width: Float) {
        self.temperature = temperature
        self.density = density
        self.width = width
    }
}

// MARK: - Pedestal Model Protocol

/// Pedestal model protocol for computing edge boundary conditions
public protocol PedestalModel: PhysicsComponent {
    /// Compute pedestal boundary conditions
    ///
    /// - Parameters:
    ///   - profiles: Current core profiles
    ///   - geometry: Tokamak geometry
    ///   - params: Pedestal model parameters
    /// - Returns: Pedestal output (boundary conditions)
    func computePedestal(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: [String: Float]
    ) -> PedestalOutput
}
