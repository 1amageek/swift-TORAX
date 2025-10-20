import Foundation

// MARK: - Mesh Configuration

/// Mesh configuration for spatial discretization
public struct MeshConfig: Sendable, Codable, Equatable, Hashable {
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
        // NOTE: we intentionally avoid preconditions here so configuration
        // values coming from files can be validated explicitly via
        // `validate()`.  This keeps construction lightweight even for
        // obviously invalid inputs, which mirrors the configuration
        // loading flow exercised by the tests.
        self.nCells = nCells
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.toroidalField = toroidalField
        self.geometryType = geometryType
    }

    /// Grid spacing [m]
    public var dr: Float {
        guard nCells > 0 else { return .infinity }
        return minorRadius / Float(nCells)
    }

    /// Aspect ratio (R/a)
    public var aspectRatio: Float {
        guard minorRadius != 0 else { return .infinity }
        return majorRadius / minorRadius
    }
}

// MARK: - Physics Validation

extension MeshConfig {
    /// Validate physics constraints
    public func validate() throws {
        guard nCells > 0 else {
            throw ConfigurationError.invalidValue(
                key: "mesh.nCells",
                value: "\(nCells)",
                reason: "Must be positive"
            )
        }

        guard nCells >= 10 else {
            throw ConfigurationError.physicsWarning(
                key: "mesh.nCells",
                value: "\(nCells)",
                reason: "Fewer than 10 cells may produce inaccurate results"
            )
        }

        guard majorRadius > 0, minorRadius > 0 else {
            throw ConfigurationError.invalidValue(
                key: "mesh.radius",
                value: "R=\(majorRadius), a=\(minorRadius)",
                reason: "Radii must be positive"
            )
        }

        let aspectRatio = aspectRatio
        guard aspectRatio >= 1.5 else {
            throw ConfigurationError.physicsWarning(
                key: "mesh.aspectRatio",
                value: "\(aspectRatio)",
                reason: "Aspect ratio < 1.5 is unrealistic for tokamaks"
            )
        }

        guard toroidalField > 0 else {
            throw ConfigurationError.invalidValue(
                key: "mesh.toroidalField",
                value: "\(toroidalField)",
                reason: "Magnetic field must be positive"
            )
        }
    }
}
