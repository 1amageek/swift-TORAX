import Foundation

// MARK: - Mesh Configuration

/// Mesh configuration for spatial discretization
public struct MeshConfig: Sendable, Codable, Equatable {
    /// Number of cells in radial direction
    public let nCells: Int

    /// Major radius [m]
    public let majorRadius: Float

    /// Minor radius [m]
    public let minorRadius: Float

    /// Toroidal magnetic field at major radius [T]
    public let toroidalField: Float

    /// Geometry type
    public let geometryType: GeometryType

    public init(
        nCells: Int,
        majorRadius: Float,
        minorRadius: Float,
        toroidalField: Float,
        geometryType: GeometryType = .circular
    ) {
        self.nCells = nCells
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.toroidalField = toroidalField
        self.geometryType = geometryType
    }

    /// Grid spacing [m]
    public var dr: Float {
        minorRadius / Float(nCells)
    }
}
