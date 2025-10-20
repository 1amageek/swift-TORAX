import Foundation

// MARK: - Geometry Type

/// Geometry type enumeration
public enum GeometryType: String, Sendable, Codable {
    case circular
    case chease
    case eqdsk
}

// MARK: - Geometry

/// Geometric configuration of the tokamak
public struct Geometry: Sendable, Equatable {
    /// Major radius [m]
    public let majorRadius: Float

    /// Minor radius [m]
    public let minorRadius: Float

    /// Toroidal magnetic field [T]
    public let toroidalField: Float

    /// Plasma volume [m^3]
    public let volume: EvaluatedArray

    /// Geometric coefficient g0 (for FVM)
    public let g0: EvaluatedArray

    /// Geometric coefficient g1 (for FVM)
    public let g1: EvaluatedArray

    /// Geometric coefficient g2 (for FVM)
    public let g2: EvaluatedArray

    /// Geometric coefficient g3 (for FVM)
    public let g3: EvaluatedArray

    /// Radial coordinates at cell centers [m]
    public let radii: EvaluatedArray

    /// Safety factor profile q(r)
    public let safetyFactor: EvaluatedArray

    /// Poloidal magnetic field profile Bp(r) [T] (optional)
    public let poloidalField: EvaluatedArray?

    /// Current density profile j(r) [MA/m^2] (optional)
    public let currentDensity: EvaluatedArray?

    /// Geometry type
    public let type: GeometryType

    public init(
        majorRadius: Float,
        minorRadius: Float,
        toroidalField: Float,
        volume: EvaluatedArray,
        g0: EvaluatedArray,
        g1: EvaluatedArray,
        g2: EvaluatedArray,
        g3: EvaluatedArray,
        radii: EvaluatedArray,
        safetyFactor: EvaluatedArray,
        poloidalField: EvaluatedArray? = nil,
        currentDensity: EvaluatedArray? = nil,
        type: GeometryType
    ) {
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.toroidalField = toroidalField
        self.volume = volume
        self.g0 = g0
        self.g1 = g1
        self.g2 = g2
        self.g3 = g3
        self.radii = radii
        self.safetyFactor = safetyFactor
        self.poloidalField = poloidalField
        self.currentDensity = currentDensity
        self.type = type
    }
}
