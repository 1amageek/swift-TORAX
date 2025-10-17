import Foundation

// MARK: - Core Profiles

/// Core plasma profiles with type-safe evaluation guarantees
///
/// Contains the primary variables evolved by the transport equations:
/// - Ion temperature (Ti)
/// - Electron temperature (Te)
/// - Electron density (ne)
/// - Poloidal flux (psi)
public struct CoreProfiles: Sendable, Equatable {
    /// Ion temperature [keV]
    public let ionTemperature: EvaluatedArray

    /// Electron temperature [keV]
    public let electronTemperature: EvaluatedArray

    /// Electron density [10^20 m^-3]
    public let electronDensity: EvaluatedArray

    /// Poloidal flux [Wb]
    public let poloidalFlux: EvaluatedArray

    public init(
        ionTemperature: EvaluatedArray,
        electronTemperature: EvaluatedArray,
        electronDensity: EvaluatedArray,
        poloidalFlux: EvaluatedArray
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }
}
