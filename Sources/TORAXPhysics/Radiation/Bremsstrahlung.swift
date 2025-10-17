import Foundation
import MLX
import TORAX

/// Bremsstrahlung radiation model
///
/// Free electrons radiating when deflected by ions.
/// Always a loss term (negative power).
///
/// Physical equation:
/// P_brems = -C_brems * n_e² * Z_eff * √T_e * (1 + f_rel)
///
/// Where:
/// - C_brems = 5.35 × 10⁻³⁷ [W·m³·eV^(-1/2)]
/// - f_rel = (T_e/511000) * (4√2 - 1) / π (relativistic correction)
///
/// Units:
/// - Input: n_e [m⁻³], T_e [eV]
/// - Output: P_brems [W/m³] (negative = loss)
public struct Bremsstrahlung: Sendable {

    /// Effective charge number
    public let Zeff: Float

    /// Include relativistic correction for high temperatures
    public let includeRelativistic: Bool

    /// Bremsstrahlung coefficient [W·m³·eV^(-1/2)]
    private let C_brems: Float = PhysicsConstants.bremsCoefficient

    /// Electron rest mass energy [eV]
    private let m_e_c2: Float = PhysicsConstants.electronRestMass

    /// Create Bremsstrahlung radiation model
    ///
    /// - Parameters:
    ///   - Zeff: Effective charge (default: 1.5)
    ///   - includeRelativistic: Apply relativistic correction (default: true)
    public init(Zeff: Float = 1.5, includeRelativistic: Bool = true) {
        self.Zeff = Zeff
        self.includeRelativistic = includeRelativistic
    }

    /// Compute Bremsstrahlung radiation power
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³], shape [nCells]
    ///   - Te: Electron temperature [eV], shape [nCells]
    /// - Returns: Radiation power [W/m³] (negative = loss), shape [nCells]
    /// - Throws: PhysicsError if inputs are invalid
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func compute(ne: MLXArray, Te: MLXArray) throws -> MLXArray {

        // Validate inputs (CRITICAL FIX #3)
        try PhysicsValidation.validateDensity(ne, name: "ne")
        try PhysicsValidation.validateTemperature(Te, name: "Te")
        try PhysicsValidation.validateShapes([ne, Te], names: ["ne", "Te"])

        var f_rel = MLXArray.zeros(like: Te)

        if includeRelativistic {
            // Relativistic correction: only significant for Te > 1 keV
            // f_rel = (T_e / m_e c²) * (4√2 - 1) / π
            let mask = MLX.greater(Te, Float(1000.0))  // Only apply for Te > 1 keV
            let mask_float = mask.asType(.float32)  // Convert Bool to 0/1

            let relativistic_factor = (Te / m_e_c2) * (Float(4.0) * sqrt(Float(2.0)) - Float(1.0)) / Float.pi
            f_rel = mask_float * relativistic_factor
        }

        // Bremsstrahlung power (negative = energy loss) [W/m³]
        // P_brems = -C * n_e² * Z_eff * √T_e * (1 + f_rel)
        // CRITICAL: Multiply small values first to prevent Float32 overflow
        // ne ≈ 10^20, C_brems ≈ 5.35e-37, sqrt(Te) ≈ 100
        // Order: (-C_brems * ne) * sqrt(Te) * ne * Zeff avoids 10^40 overflow
        let P_brems_watts = -C_brems * ne * sqrt(Te) * ne * Zeff * (Float(1.0) + f_rel)

        // Return lazy MLXArray - caller will eval() when needed
        return P_brems_watts
    }

    /// Compute classical Bremsstrahlung (no relativistic correction)
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Te: Electron temperature [eV]
    /// - Returns: Classical Bremsstrahlung power [W/m³]
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func computeClassical(ne: MLXArray, Te: MLXArray) -> MLXArray {
        // CRITICAL: Multiply small values first to prevent Float32 overflow
        // Order: (-C_brems * ne) * sqrt(Te) * ne * Zeff avoids 10^40 overflow
        return -C_brems * ne * sqrt(Te) * ne * Zeff
    }

    /// Compute relativistic correction factor
    ///
    /// - Parameter Te: Electron temperature [eV]
    /// - Returns: Relativistic correction factor f_rel (dimensionless)
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func computeRelativisticCorrection(Te: MLXArray) -> MLXArray {
        let mask = MLX.greater(Te, Float(1000.0))
        let mask_float = mask.asType(.float32)  // Convert Bool to 0/1
        let factor = (Te / m_e_c2) * (Float(4.0) * sqrt(Float(2.0)) - Float(1.0)) / Float.pi
        let result = mask_float * factor
        // Return lazy MLXArray - caller will eval() when needed
        return result
    }

    /// Check if relativistic effects are significant
    ///
    /// - Parameter Te: Electron temperature [eV]
    /// - Returns: True if relativistic correction > 1%
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func isRelativisticSignificant(Te: MLXArray) -> MLXArray {
        let f_rel = computeRelativisticCorrection(Te: Te)
        let result = MLX.greater(f_rel, Float(0.01))
        // Return lazy MLXArray - caller will eval() when needed
        return result
    }
}

// MARK: - Source Model Protocol Conformance

extension Bremsstrahlung {

    /// Apply Bremsstrahlung radiation to source terms
    ///
    /// Subtracts radiation losses from electron heating.
    ///
    /// - Parameters:
    ///   - sources: Source terms to modify
    ///   - profiles: Current plasma profiles
    /// - Returns: Modified source terms with radiation losses
    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles
    ) throws -> SourceTerms {

        let P_brems_watts = try compute(
            ne: profiles.electronDensity.value,
            Te: profiles.electronTemperature.value
        )

        // Convert to MW/m³ for SourceTerms
        let P_brems = PhysicsConstants.wattsToMegawatts(P_brems_watts)

        // Create new SourceTerms with updated electron heating
        return SourceTerms(
            ionHeating: sources.ionHeating,
            electronHeating: EvaluatedArray(
                evaluating: sources.electronHeating.value + P_brems
            ),
            particleSource: sources.particleSource,
            currentSource: sources.currentSource
        )
    }
}

// MARK: - Diagnostic Output

extension Bremsstrahlung {

    /// Compute total radiated power
    ///
    /// Integrates Bremsstrahlung power over plasma volume.
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Te: Electron temperature [eV]
    ///   - geometry: Tokamak geometry
    /// - Returns: Total radiated power [W]
    public func computeTotalPower(
        ne: MLXArray,
        Te: MLXArray,
        geometry: Geometry
    ) throws -> Float {

        let P_brems_density = try compute(ne: ne, Te: Te)

        // Integrate over volume: P_total = Σ P_brems * V_cell
        let cellVolumes = GeometricFactors.from(geometry: geometry).cellVolumes.value
        let P_total = (P_brems_density * cellVolumes).sum()

        return P_total.item(Float.self)
    }

    /// Compute radiation fraction (P_rad / P_input)
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Te: Electron temperature [eV]
    ///   - geometry: Tokamak geometry
    ///   - inputPower: Total input power [W]
    /// - Returns: Radiation fraction (dimensionless)
    public func computeRadiationFraction(
        ne: MLXArray,
        Te: MLXArray,
        geometry: Geometry,
        inputPower: Float
    ) throws -> Float {

        let P_rad = abs(try computeTotalPower(ne: ne, Te: Te, geometry: geometry))
        return P_rad / (inputPower + 1e-10)
    }
}
