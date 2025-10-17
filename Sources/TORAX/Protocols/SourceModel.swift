import Foundation

// MARK: - Source Model Protocol

/// Source model protocol for computing heating, particle, and current sources
public protocol SourceModel: PhysicsComponent, Sendable {
    /// Compute source terms
    ///
    /// - Parameters:
    ///   - profiles: Current core profiles
    ///   - geometry: Tokamak geometry
    ///   - params: Source model parameters
    /// - Returns: Source terms (heating, particles, current)
    func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParameters
    ) -> SourceTerms
}
