import MLX
import Foundation

#if os(macOS)
import FusionSurrogates
#endif

// MARK: - QLKNN Transport Model

/// QLKNN neural network transport model wrapper
///
/// **QuaLiKiz Neural Network (QLKNN)**: Fast surrogate for QuaLiKiz turbulent transport code.
///
/// **Physics**: Predicts turbulent heat and particle fluxes from local plasma parameters:
/// - Normalized gradients (a/L_Ti, a/L_Te, a/L_ne)
/// - Magnetic geometry (q, s, x = r/R)
/// - Collisionality (log10(ν*))
/// - Temperature ratio (Ti/Te)
///
/// **Performance**: 4-6 orders of magnitude faster than QuaLiKiz:
/// - QuaLiKiz: ~1 second per radial point
/// - QLKNN: ~1 millisecond per radial point (on GPU)
///
/// **Accuracy**: Trained on 300M QuaLiKiz simulations
/// - R² > 0.96 for all transport channels
/// - Valid for tokamak core plasmas (ITG, TEM, ETG turbulence)
///
/// **Reference**: https://github.com/1amageek/swift-fusion-surrogates
#if os(macOS)
public struct QLKNNTransportModel: TransportModel {
    // MARK: - Properties

    public let name = "qlknn"

    /// QLKNN predictor wrapper (Sendable-safe)
    ///
    /// Note: QLKNN is a Python bridge (PythonKit-based) which is not Sendable by design.
    /// We wrap it in a Sendable container because:
    /// 1. TransportModel methods are called synchronously from simulation orchestrator
    /// 2. No concurrent access occurs (actor-isolated usage)
    /// 3. Python GIL provides thread-safety for the underlying Python objects
    private let qlknn: SendableQLKNN

    /// Sendable wrapper for QLKNN
    private struct SendableQLKNN: @unchecked Sendable {
        let model: QLKNN

        init(_ model: QLKNN) {
            self.model = model
        }
    }

    /// Effective charge Z_eff (for collisionality calculation)
    public let Zeff: Float

    /// Minimum transport coefficient floor [m²/s]
    ///
    /// Prevents numerical issues when QLKNN predicts very low transport
    public let minChi: Float

    // MARK: - Initialization

    /// Initialize QLKNN transport model
    ///
    /// - Parameters:
    ///   - Zeff: Effective charge (default: 1.0 for pure deuterium)
    ///   - minChi: Minimum transport coefficient floor (default: 0.01 m²/s)
    /// - Throws: If QLKNN model fails to load
    public init(Zeff: Float = 1.0, minChi: Float = 0.01) throws {
        self.qlknn = SendableQLKNN(try QLKNN())
        self.Zeff = Zeff
        self.minChi = minChi
    }

    public init(params: TransportParameters) throws {
        self.qlknn = SendableQLKNN(try QLKNN())
        self.Zeff = params.params["Zeff"] ?? 1.0
        self.minChi = params.params["min_chi"] ?? 0.01
    }

    // MARK: - TransportModel Protocol

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        let nCells = profiles.ionTemperature.shape[0]

        // Extract profiles as MLXArrays
        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value
        let radii = geometry.radii.value
        let q = geometry.safetyFactor.value

        // Compute QLKNN input features
        let inputs = computeQLKNNInputs(
            Ti: Ti,
            Te: Te,
            ne: ne,
            radii: radii,
            q: q,
            geometry: geometry
        )

        // Predict transport fluxes using QLKNN
        guard let outputs = try? qlknn.model.predict(inputs) else {
            // Fallback to simple Bohm-GyroBohm if QLKNN fails
            return fallbackTransport(profiles: profiles, geometry: geometry)
        }

        // Convert QLKNN outputs to transport coefficients with proper GyroBohm normalization
        let chiIon = computeIonDiffusivity(
            outputs: outputs,
            Ti: Ti,
            Te: Te,
            radii: radii,
            geometry: geometry
        )
        let chiElectron = computeElectronDiffusivity(
            outputs: outputs,
            Te: Te,
            radii: radii,
            geometry: geometry
        )
        let particleDiffusivity = computeParticleDiffusivity(
            outputs: outputs,
            ne: ne,
            Te: Te,
            radii: radii,
            geometry: geometry
        )
        let convectionVelocity = computeConvectionVelocity(outputs: outputs, ne: ne)

        return TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: chiIon),
            chiElectron: EvaluatedArray(evaluating: chiElectron),
            particleDiffusivity: EvaluatedArray(evaluating: particleDiffusivity),
            convectionVelocity: EvaluatedArray(evaluating: convectionVelocity)
        )
    }

    // MARK: - QLKNN Input Computation

    /// Compute QLKNN input dictionary from plasma profiles
    ///
    /// **QLKNN Inputs** (10 parameters per radial point):
    /// - Ati: R/L_Ti - Normalized ion temperature gradient
    /// - Ate: R/L_Te - Normalized electron temperature gradient
    /// - Ane: R/L_ne - Normalized electron density gradient
    /// - Ani: R/L_ni - Normalized ion density gradient
    /// - q: Safety factor
    /// - smag: Magnetic shear (s_hat)
    /// - x: r/R - Inverse aspect ratio
    /// - Ti_Te: Ion-electron temperature ratio
    /// - LogNuStar: Logarithmic normalized collisionality
    /// - normni: Normalized ion density (ni/ne)
    ///
    /// - Parameters:
    ///   - Ti: Ion temperature [eV]
    ///   - Te: Electron temperature [eV]
    ///   - ne: Electron density [m^-3]
    ///   - radii: Radial coordinates [m]
    ///   - q: Safety factor profile
    ///   - geometry: Tokamak geometry
    /// - Returns: Dictionary of QLKNN inputs
    private func computeQLKNNInputs(
        Ti: MLXArray,
        Te: MLXArray,
        ne: MLXArray,
        radii: MLXArray,
        q: MLXArray,
        geometry: Geometry
    ) -> [String: MLXArray] {
        // Normalized gradients: R/L_T for QLKNN (uses major radius R, not minor radius a)
        let Ati = MLXGradient.normalizedGradient(
            profile: Ti,
            radii: radii,
            normalizationLength: geometry.majorRadius  // R/L_Ti
        )
        let Ate = MLXGradient.normalizedGradient(
            profile: Te,
            radii: radii,
            normalizationLength: geometry.majorRadius  // R/L_Te
        )
        let Ane = MLXGradient.normalizedGradient(
            profile: ne,
            radii: radii,
            normalizationLength: geometry.majorRadius  // R/L_ne
        )

        // Assume ni = ne for now (quasi-neutrality)
        let Ani = Ane

        // Temperature ratio
        let Ti_Te = MLXGradient.temperatureRatio(Ti: Ti, Te: Te)

        // Magnetic shear
        let smag = MLXGradient.magneticShear(q: q, radii: radii)

        // Inverse aspect ratio
        let x = MLXGradient.inverseAspectRatio(radii: radii, majorRadius: geometry.majorRadius)

        // Collisionality
        let LogNuStar = MLXGradient.collisionality(
            ne: ne,
            Te: Te,
            q: q,
            radii: radii,
            majorRadius: geometry.majorRadius,
            Zeff: Zeff
        )

        // Normalized ion density (ni/ne ≈ 1 for quasi-neutrality)
        let normni = broadcast(MLXArray(1.0), to: radii.shape)

        return [
            "Ati": Ati,
            "Ate": Ate,
            "Ane": Ane,
            "Ani": Ani,
            "q": q,
            "smag": smag,
            "x": x,
            "Ti_Te": Ti_Te,
            "LogNuStar": LogNuStar,
            "normni": normni
        ]
    }

    // MARK: - Transport Coefficient Computation

    /// Compute GyroBohm thermal diffusivity normalization
    ///
    /// **GyroBohm Diffusivity**:
    /// ```
    /// χ_GB = ρ_s² * c_s / a
    /// ```
    ///
    /// where:
    /// - ρ_s = sqrt(m_i * T_e) / (e * B): Ion sound gyroradius [m]
    /// - c_s = sqrt(T_e / m_i): Sound speed [m/s]
    /// - a: Minor radius [m]
    ///
    /// **Derivation**:
    /// ```
    /// χ_GB = ρ_s² * c_s / a
    ///      = [sqrt(m_i T_e) / (e B)]² * sqrt(T_e / m_i) / a
    ///      = (m_i T_e) / (e B)² * sqrt(T_e / m_i) / a
    ///      = T_e^(3/2) * sqrt(m_i) / [(e B)² * a]
    /// ```
    ///
    /// **Units**:
    /// - T_e [eV] → need conversion to Joules
    /// - Result: [m²/s]
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV]
    ///   - geometry: Tokamak geometry
    /// - Returns: GyroBohm diffusivity [m²/s]
    private func computeGyrBohmDiffusivity(
        Te: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        // Physical constants
        let electronCharge: Float = 1.602e-19  // [C]
        let protonMass: Float = 1.673e-27      // [kg] (use deuterium ≈ 2 * proton)
        let ionMass = 2.0 * protonMass         // Deuterium
        let eV_to_J: Float = 1.602e-19         // [J/eV]

        let B = geometry.toroidalField          // [T]
        let a = geometry.minorRadius            // [m]

        // Convert Te from eV to Joules for SI calculation
        let Te_J = Te * eV_to_J

        // χ_GB = T_e^(3/2) * sqrt(m_i) / [(e B)² * a]
        // Note: Te is in Joules here
        let numerator = pow(Te_J, 1.5) * sqrt(ionMass)
        let denominator = (electronCharge * B) * (electronCharge * B) * a

        return numerator / denominator
    }

    /// Compute ion thermal diffusivity from QLKNN outputs
    ///
    /// **QLKNN Output**: Normalized flux in GyroBohm units
    /// **Conversion**: χ_i = eff_i * χ_GB
    ///
    /// where eff_i is the effective diffusivity in GB units from QLKNN
    ///
    /// - Parameters:
    ///   - outputs: QLKNN prediction outputs (GyroBohm normalized)
    ///   - Ti: Ion temperature [eV]
    ///   - Te: Electron temperature [eV] (for GB normalization)
    ///   - radii: Radial coordinates [m]
    ///   - geometry: Tokamak geometry
    /// - Returns: Ion thermal diffusivity [m²/s]
    private func computeIonDiffusivity(
        outputs: [String: MLXArray],
        Ti: MLXArray,
        Te: MLXArray,
        radii: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        // QLKNN outputs in GyroBohm units
        let efiITG = outputs["efiITG"] ?? MLXArray.zeros(Ti.shape)
        let efiTEM = outputs["efiTEM"] ?? MLXArray.zeros(Ti.shape)

        // Total effective diffusivity in GB units
        let eff_i_GB = efiITG + efiTEM

        // GyroBohm normalization factor
        let chi_GB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)

        // Convert to physical units: χ_i = eff_i * χ_GB
        let chi = abs(eff_i_GB) * chi_GB

        return maximum(chi, MLXArray(minChi))
    }

    /// Compute electron thermal diffusivity from QLKNN outputs
    ///
    /// **QLKNN Output**: Normalized flux in GyroBohm units
    /// **Conversion**: χ_e = eff_e * χ_GB
    ///
    /// - Parameters:
    ///   - outputs: QLKNN prediction outputs (GyroBohm normalized)
    ///   - Te: Electron temperature [eV]
    ///   - radii: Radial coordinates [m]
    ///   - geometry: Tokamak geometry
    /// - Returns: Electron thermal diffusivity [m²/s]
    private func computeElectronDiffusivity(
        outputs: [String: MLXArray],
        Te: MLXArray,
        radii: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        let efeITG = outputs["efeITG"] ?? MLXArray.zeros(Te.shape)
        let efeTEM = outputs["efeTEM"] ?? MLXArray.zeros(Te.shape)
        let efeETG = outputs["efeETG"] ?? MLXArray.zeros(Te.shape)

        // Total effective diffusivity in GB units
        let eff_e_GB = efeITG + efeTEM + efeETG

        // GyroBohm normalization factor
        let chi_GB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)

        // Convert to physical units
        let chi = abs(eff_e_GB) * chi_GB

        return maximum(chi, MLXArray(minChi))
    }

    /// Compute particle diffusivity from QLKNN outputs
    ///
    /// **QLKNN Output**: Normalized particle flux in GyroBohm units
    /// **Conversion**: D = pf * χ_GB
    ///
    /// Note: Particle diffusivity uses the same GyroBohm normalization
    ///
    /// - Parameters:
    ///   - outputs: QLKNN prediction outputs (GyroBohm normalized)
    ///   - ne: Electron density [m^-3]
    ///   - Te: Electron temperature [eV] (for GB normalization)
    ///   - radii: Radial coordinates [m]
    ///   - geometry: Tokamak geometry
    /// - Returns: Particle diffusivity [m²/s]
    private func computeParticleDiffusivity(
        outputs: [String: MLXArray],
        ne: MLXArray,
        Te: MLXArray,
        radii: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        let pfeITG = outputs["pfeITG"] ?? MLXArray.zeros(ne.shape)
        let pfeTEM = outputs["pfeTEM"] ?? MLXArray.zeros(ne.shape)

        // Total effective particle diffusivity in GB units
        let pf_GB = pfeITG + pfeTEM

        // GyroBohm normalization factor
        let chi_GB = computeGyrBohmDiffusivity(Te: Te, geometry: geometry)

        // Convert to physical units
        let D = abs(pf_GB) * chi_GB

        return maximum(D, MLXArray(minChi))
    }

    /// Compute convection velocity from particle flux
    ///
    /// **Note**: QLKNN outputs normalized particle flux in GyroBohm units.
    /// Direct conversion to velocity requires additional physics context.
    /// For now, we set convection velocity to zero (diffusion-only transport).
    ///
    /// **Future Implementation**: If QLKNN provides pinch coefficients,
    /// compute as: V = Vpinch * χ_GB / a
    ///
    /// - Parameters:
    ///   - outputs: QLKNN prediction outputs
    ///   - ne: Electron density [m^-3]
    /// - Returns: Convection velocity [m/s]
    private func computeConvectionVelocity(
        outputs: [String: MLXArray],
        ne: MLXArray
    ) -> MLXArray {
        // TODO: Implement proper pinch velocity from QLKNN outputs
        // For now, return zero (diffusion-only transport)
        return MLXArray.zeros(ne.shape)
    }

    // MARK: - Fallback Transport

    /// Fallback to simple Bohm-GyroBohm if QLKNN fails
    private func fallbackTransport(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> TransportCoefficients {
        let nCells = profiles.ionTemperature.shape[0]
        let te = profiles.electronTemperature.value

        // Bohm diffusivity: χ_Bohm = T_e / (16 e B)
        // Units: [eV] / ([C] * [T]) * [J/eV] = [J] / ([C] * [T]) = [m²/s]
        let electronCharge: Float = 1.602e-19  // [C]
        let eV_to_J: Float = 1.602e-19         // [J/eV]
        let B = geometry.toroidalField          // [T]

        // Convert Te from eV to Joules for SI calculation
        let te_J = te * eV_to_J

        // χ_Bohm = T_e / (16 e B)
        let chiBohm = te_J / (16.0 * electronCharge * B)

        return TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: chiBohm),
            chiElectron: EvaluatedArray(evaluating: chiBohm),
            particleDiffusivity: EvaluatedArray(evaluating: chiBohm * 0.5),
            convectionVelocity: EvaluatedArray.zeros([nCells])
        )
    }
}

#else
// Fallback for non-macOS platforms: QLKNN not available
public struct QLKNNTransportModel: TransportModel {
    public let name = "qlknn"

    public init() throws {
        throw TransportModelError.unsupportedPlatform("QLKNN requires macOS with FusionSurrogates")
    }

    public init(params: TransportParameters) throws {
        throw TransportModelError.unsupportedPlatform("QLKNN requires macOS with FusionSurrogates")
    }

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        fatalError("QLKNN not available on this platform")
    }
}
#endif

// MARK: - Errors

public enum TransportModelError: Error, CustomStringConvertible {
    case unsupportedPlatform(String)
    case modelLoadFailure(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let message):
            return "Unsupported platform: \(message)"
        case .modelLoadFailure(let message):
            return "Model load failure: \(message)"
        }
    }
}
