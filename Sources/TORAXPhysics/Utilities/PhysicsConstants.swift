import Foundation
import MLX

/// Physical constants for plasma physics calculations
///
/// All constants use SI units unless otherwise specified.
public enum PhysicsConstants {

    // MARK: - Fundamental Constants

    /// Elementary charge [C]
    public static let elementaryCharge: Float = 1.602176634e-19

    /// Electron volt to Joules conversion [J/eV]
    public static let eV: Float = 1.602176634e-19

    /// Electron mass [kg]
    public static let electronMass: Float = 9.1093837015e-31

    /// Proton mass [kg]
    public static let protonMass: Float = 1.67262192369e-27

    /// Atomic mass unit [kg]
    public static let atomicMassUnit: Float = 1.66053906660e-27

    /// Boltzmann constant [J/K]
    public static let boltzmann: Float = 1.380649e-23

    /// Speed of light [m/s]
    public static let speedOfLight: Float = 2.99792458e8

    /// Vacuum permittivity [F/m]
    public static let epsilon0: Float = 8.8541878128e-12

    /// Vacuum permeability [H/m]
    public static let mu0: Float = 1.25663706212e-6

    // MARK: - Plasma-Specific Constants

    /// Bremsstrahlung radiation coefficient [W·m³·eV^(-1/2)]
    public static let bremsCoefficient: Float = 5.35e-37

    /// Rest mass energy of electron [eV]
    public static let electronRestMass: Float = 510998.95  // m_e c² in eV

    /// Spitzer resistivity prefactor [Ω·m·eV^(3/2)]
    public static let spitzerPrefactor: Float = 5.2e-5

    /// Collisional frequency prefactor [Hz·m³·eV^(-3/2)]
    public static let collisionFrequencyPrefactor: Float = 2.91e-6

    // MARK: - Common Ion Masses

    /// Deuterium mass [amu]
    public static let deuteriumMass: Float = 2.014

    /// Tritium mass [amu]
    public static let tritiumMass: Float = 3.016

    /// Helium-4 mass [amu]
    public static let helium4Mass: Float = 4.003

    // MARK: - Fusion-Specific Constants

    /// D-T fusion alpha particle energy [MeV]
    public static let dtAlphaEnergy: Float = 3.5

    /// D-T fusion neutron energy [MeV]
    public static let dtNeutronEnergy: Float = 14.1

    /// D-T fusion Q-value (total energy release) [MeV]
    public static let dtQValue: Float = 17.6

    // MARK: - Unit Conversions

    /// Convert eV to Joules
    public static func eVToJoules(_ eV: Float) -> Float {
        return eV * PhysicsConstants.eV
    }

    /// Convert Joules to eV
    public static func joulesToEV(_ joules: Float) -> Float {
        return joules / PhysicsConstants.eV
    }

    /// Convert keV to eV
    public static func keVToEV(_ keV: Float) -> Float {
        return keV * 1e3
    }

    /// Convert eV to keV
    public static func eVToKeV(_ eV: Float) -> Float {
        return eV / 1e3
    }

    /// Convert MeV to Joules
    public static func MeVToJoules(_ MeV: Float) -> Float {
        return MeV * 1e6 * PhysicsConstants.eV
    }

    /// Convert atomic mass units to kg
    public static func amuToKg(_ amu: Float) -> Float {
        return amu * atomicMassUnit
    }

    // MARK: - Power Unit Conversions

    /// Convert W/m³ to MW/m³
    public static func wattsToMegawatts(_ watts: Float) -> Float {
        return watts / 1e6
    }

    /// Convert MW/m³ to W/m³
    public static func megawattsToWatts(_ megawatts: Float) -> Float {
        return megawatts * 1e6
    }

    /// Convert W/m³ array to MW/m³ array
    public static func wattsToMegawatts(_ watts: MLXArray) -> MLXArray {
        return watts / 1e6
    }

    /// Convert MW/m³ array to W/m³ array
    public static func megawattsToWatts(_ megawatts: MLXArray) -> MLXArray {
        return megawatts * 1e6
    }
}
