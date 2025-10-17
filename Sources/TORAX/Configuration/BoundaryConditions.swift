import Foundation

// MARK: - Face Constraint

/// Face boundary constraint type
public enum FaceConstraint: Sendable, Codable, Equatable {
    /// Fixed value (Dirichlet)
    case value(Float)

    /// Fixed gradient (Neumann)
    case gradient(Float)
}

// MARK: - Boundary Condition

/// Single boundary condition (left and right face)
public struct BoundaryCondition: Sendable, Codable, Equatable {
    /// Left face constraint (value or gradient)
    public var left: FaceConstraint

    /// Right face constraint (value or gradient)
    public var right: FaceConstraint

    public init(left: FaceConstraint, right: FaceConstraint) {
        self.left = left
        self.right = right
    }
}

// MARK: - Boundary Conditions

/// Boundary condition specification
public struct BoundaryConditions: Sendable, Codable, Equatable {
    /// Ion temperature boundary conditions
    public var ionTemperature: BoundaryCondition

    /// Electron temperature boundary conditions
    public var electronTemperature: BoundaryCondition

    /// Electron density boundary conditions
    public var electronDensity: BoundaryCondition

    /// Poloidal flux boundary conditions
    public var poloidalFlux: BoundaryCondition

    public init(
        ionTemperature: BoundaryCondition,
        electronTemperature: BoundaryCondition,
        electronDensity: BoundaryCondition,
        poloidalFlux: BoundaryCondition
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }
}
