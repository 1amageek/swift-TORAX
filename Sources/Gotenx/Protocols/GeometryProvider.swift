import Foundation

// MARK: - Geometry Provider Protocol

/// Protocol for providing geometry at a given time
public protocol GeometryProvider {
    /// Get geometry at specified time
    ///
    /// - Parameter time: Simulation time [s]
    /// - Returns: Geometry at the given time
    func geometry(at time: Float) -> Geometry
}
