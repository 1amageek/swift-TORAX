import MLX
import Foundation

// MARK: - Bohm-GyroBohm Transport Model

/// Bohm-GyroBohm transport model
///
/// Empirical transport model using Bohm and GyroBohm scaling:
/// χ = C_Bohm * χ_Bohm + C_GB * χ_GB
public struct BohmGyroBohmTransportModel: TransportModel {
    // MARK: - Properties

    public let name = "bohm-gyrobohm"

    /// Bohm coefficient
    public let bohmCoeff: Float

    /// GyroBohm coefficient
    public let gyroBhohmCoeff: Float

    // MARK: - Initialization

    public init(bohmCoeff: Float = 1.0, gyroBhohmCoeff: Float = 1.0) {
        self.bohmCoeff = bohmCoeff
        self.gyroBhohmCoeff = gyroBhohmCoeff
    }

    public init(params: TransportParameters) {
        self.bohmCoeff = params.params["bohm_coeff"] ?? 1.0
        self.gyroBhohmCoeff = params.params["gyrobohm_coeff"] ?? 1.0
    }

    // MARK: - TransportModel Protocol

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        let nCells = profiles.ionTemperature.shape[0]

        // Extract temperature profiles
        let te = profiles.electronTemperature.value

        // Bohm diffusivity: χ_Bohm = (1/16) * (c * T_e) / (e * B)
        let electronCharge: Float = 1.602e-19  // C
        let speedOfLight: Float = 3.0e8  // m/s
        let B = geometry.toroidalField

        let chiBohmElectron = (1.0 / 16.0) * (speedOfLight * te) / (electronCharge * B)

        // GyroBohm diffusivity: χ_GB = (ρ_s / a)^2 * χ_Bohm
        // where ρ_s = (m_i * T_e)^0.5 / (e * B) is ion sound radius
        let ionMass: Float = 1.67e-27  // kg (proton mass)
        let rhoS = sqrt(ionMass * te) / (electronCharge * B)
        let minorRadius = geometry.minorRadius
        let chiGyroBohm = pow(rhoS / minorRadius, 2) * chiBohmElectron

        // Combined diffusivity
        let chiElectron = bohmCoeff * chiBohmElectron + gyroBhohmCoeff * chiGyroBohm
        let chiIon = chiElectron  // Assume same for ions

        return TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: chiIon),
            chiElectron: EvaluatedArray(evaluating: chiElectron),
            particleDiffusivity: EvaluatedArray(evaluating: chiElectron * 0.5),  // D = 0.5 * χ
            convectionVelocity: EvaluatedArray.zeros([nCells])
        )
    }
}
