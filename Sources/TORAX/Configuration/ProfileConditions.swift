import Foundation

// MARK: - Profile Specification

/// Profile specification
public enum ProfileSpec: Sendable, Codable, Equatable {
    /// Constant value
    case constant(Float)

    /// Linear profile (core, edge)
    case linear(core: Float, edge: Float)

    /// Parabolic profile (peak, edge, exponent)
    case parabolic(peak: Float, edge: Float, exponent: Float)

    /// Custom array of values
    case array([Float])
}

// MARK: - Profile Conditions

/// Initial and prescribed profile conditions
public struct ProfileConditions: Sendable, Codable, Equatable {
    /// Ion temperature profile [keV]
    public var ionTemperature: ProfileSpec

    /// Electron temperature profile [keV]
    public var electronTemperature: ProfileSpec

    /// Electron density profile [10^20 m^-3]
    public var electronDensity: ProfileSpec

    /// Current profile [MA/m^2]
    public var currentDensity: ProfileSpec

    public init(
        ionTemperature: ProfileSpec,
        electronTemperature: ProfileSpec,
        electronDensity: ProfileSpec,
        currentDensity: ProfileSpec
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.currentDensity = currentDensity
    }
}
