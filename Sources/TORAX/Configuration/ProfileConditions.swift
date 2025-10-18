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
///
/// **Units**: eV for temperature, m^-3 for density
///
/// ProfileConditions uses the same units as CoreProfiles and BoundaryConditions:
/// - Temperature: eV (electron volts)
/// - Density: m^-3 (particles per cubic meter)
///
/// This ensures consistency throughout the runtime system and eliminates
/// the need for unit conversions when materializing profiles.
///
/// **Note**: While tokamak literature often uses keV and 10^20 m^-3,
/// this implementation uses eV and m^-3 for consistency with physics models
/// and to match the original TORAX (Python) design.
public struct ProfileConditions: Sendable, Codable, Equatable {
    /// Ion temperature profile [eV]
    public var ionTemperature: ProfileSpec

    /// Electron temperature profile [eV]
    public var electronTemperature: ProfileSpec

    /// Electron density profile [m^-3]
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
