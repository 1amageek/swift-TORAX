import Foundation
import MLX
import GotenxCore

/// Fusion power model for D-T reactions
///
/// Computes alpha particle heating power from D-T fusion reactions:
/// D + T → He⁴ (3.5 MeV) + n (14.1 MeV)
///
/// Physical equation:
/// P_fusion = n_D * n_T * ⟨σv⟩(T_i) * E_alpha
///
/// Uses Bosch-Hale parameterization for reactivity ⟨σv⟩(T_i).
///
/// Reference: Bosch & Hale, Nuclear Fusion 32(4), 611-631 (1992)
///
/// Units:
/// - Input: n_e [m⁻³], T_i [eV]
/// - Output: P_fusion [W/m³]
public struct FusionPower: Sendable {

    /// Fuel mixture configuration
    public enum FuelMixture: Sendable {
        /// Equal 50-50 D-T mixture
        case equalDT
        /// Custom fuel fractions (must sum to ≤ 1)
        case custom(nD_frac: Float, nT_frac: Float)
    }

    /// Fuel mixture configuration
    public let fuelMix: FuelMixture

    /// Alpha particle energy [MeV]
    public let alphaEnergy: Float

    // MARK: - Bosch-Hale Coefficients for D-T

    /// Bosch-Hale coefficient C1 [m³/s]
    /// Original value from paper: 1.17302e-9 [cm³/s]
    /// Converted to m³/s: 1.17302e-9 * 10^-6 = 1.17302e-15 [m³/s]
    private let C1: Float = 1.17302e-15

    /// Bosch-Hale coefficient C2
    private let C2: Float = 1.51361e-2

    /// Bosch-Hale coefficient C3
    private let C3: Float = 7.51886e-2

    /// Bosch-Hale coefficient C4
    private let C4: Float = 4.60643e-3

    /// Bosch-Hale coefficient C5
    private let C5: Float = 1.35000e-2

    /// Bosch-Hale coefficient C6
    private let C6: Float = -1.06750e-4

    /// Bosch-Hale coefficient C7
    private let C7: Float = 1.36600e-5

    /// Gamow constant for D-T [keV]
    private let BG: Float = 34.3827

    /// Reduced mass times c² [keV]
    private let mrc2: Float = 1124656.0

    /// Impurity dilution factor: fraction of n_e that is fuel ions
    /// - 1.0 = no impurities (pure D-T)
    /// - 0.8 = 20% impurity dilution
    public let fuelDilution: Float

    /// Physical thresholds for validation
    public let thresholds: PhysicalThresholds

    /// Create fusion power model
    ///
    /// - Parameters:
    ///   - fuelMix: Fuel mixture configuration (default: equal D-T)
    ///   - alphaEnergy: Alpha particle energy in MeV (default: 3.5 MeV)
    ///   - fuelDilution: Fraction of n_e from fuel ions (default: 0.9 for ~10% impurities)
    ///   - thresholds: Physical thresholds (default: .default)
    /// - Throws: PhysicsError if parameters are out of valid range
    public init(
        fuelMix: FuelMixture = .equalDT,
        alphaEnergy: Float = 3.5,
        fuelDilution: Float = 0.9,
        thresholds: PhysicalThresholds = .default
    ) throws {
        // Validate fuelDilution range
        guard fuelDilution > 0.0 && fuelDilution <= 1.0 else {
            throw PhysicsError.parameterOutOfRange(
                "fuelDilution must be in range (0, 1], got \(fuelDilution)"
            )
        }

        // Validate custom fuel mixture fractions
        if case .custom(let fD, let fT) = fuelMix {
            guard fD >= 0.0 && fT >= 0.0 else {
                throw PhysicsError.parameterOutOfRange(
                    "Fuel fractions must be non-negative, got fD=\(fD), fT=\(fT)"
                )
            }
            let total = fD + fT
            guard total > thresholds.fuelFractionTolerance else {
                throw PhysicsError.parameterOutOfRange(
                    "Sum of fuel fractions must be positive, got \(total)"
                )
            }
        }

        self.fuelMix = fuelMix
        self.alphaEnergy = alphaEnergy
        self.fuelDilution = fuelDilution
        self.thresholds = thresholds
    }

    /// Compute fusion power density
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³], shape [nCells]
    ///   - Ti: Ion temperature [eV], shape [nCells]
    /// - Returns: Fusion power [W/m³], shape [nCells]
    /// - Throws: PhysicsError if inputs are invalid
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func compute(ne: MLXArray, Ti: MLXArray) throws -> MLXArray {

        // Validate inputs (CRITICAL FIX #3)
        try PhysicsValidation.validateDensity(ne, name: "ne")
        try PhysicsValidation.validateTemperature(Ti, name: "Ti")
        try PhysicsValidation.validateShapes([ne, Ti], names: ["ne", "Ti"])

        // Convert temperature to keV
        let Ti_keV = Ti / Float(1000.0)

        // Compute Bosch-Hale reactivity ⟨σv⟩ with bounds (MEDIUM FIX #3)
        let sigma_v = computeReactivity(Ti_keV: Ti_keV)

        // Compute fuel densities with impurity dilution
        let (nD, nT) = computeFuelDensities(ne: ne)

        // Fusion power [W/m³]
        // P_fusion = n_D * n_T * ⟨σv⟩ * E_alpha
        // CRITICAL: Multiply small values first to prevent Float32 overflow
        // nD ≈ 10^20, nT ≈ 10^20, sigma_v ≈ 10^-22, E_alpha_J ≈ 5.6e-13
        // Order: (nD * sigma_v) * nT * E_alpha_J avoids 10^40 overflow
        let E_alpha_J = PhysicsConstants.MeVToJoules(alphaEnergy)
        let P_fusion_watts = nD * sigma_v * nT * E_alpha_J

        // Return lazy MLXArray - caller will eval() when needed
        return P_fusion_watts
    }

    /// Compute D-T reactivity using Bosch-Hale parameterization
    ///
    /// - Parameter Ti_keV: Ion temperature [keV]
    /// - Returns: Reactivity ⟨σv⟩ [m³/s]
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func computeReactivity(Ti_keV: MLXArray) -> MLXArray {

        // Bosch-Hale formula:
        // θ = T / (1 - (T*(C2 + T*(C4 + T*C6))) / (1 + T*(C3 + T*(C5 + T*C7))))
        // ξ = (B_G² / (4θ))^(1/3)
        // ⟨σv⟩ = C1 * θ * √(ξ/(m_rc²*T)) * exp(-3ξ)

        // Clamp temperature to valid range (MEDIUM FIX #3)
        // Valid range: 0.2 keV < Ti < 1000 keV
        let T = MLX.clip(Ti_keV, min: Float(0.2), max: Float(1000.0))

        let numerator = T * (C2 + T * (C4 + T * C6))
        let denominator = Float(1.0) + T * (C3 + T * (C5 + T * C7))

        // Compute ratio without clipping to preserve Bosch-Hale fit accuracy
        // At the D-T peak (~70 keV), (1 - ratio) can be as small as 10^-8 to 10^-10
        // Add tiny epsilon to prevent division by zero while preserving the real value
        let ratio = numerator / denominator
        let denom = (Float(1.0) - ratio) + Float(1e-12)
        let theta = T / denom

        let xi = pow(BG * BG / (Float(4.0) * theta), Float(1.0)/Float(3.0))

        // sqrt(xi / (mrc2 * T^3)) = sqrt(xi) / sqrt(mrc2 * T^3)
        let sigma_v = C1 * theta * sqrt(xi / (mrc2 * T * T * T)) * exp(Float(-3.0) * xi)

        // Return lazy MLXArray - caller will eval() when needed
        return sigma_v
    }

    /// Compute fuel densities from electron density with impurity dilution
    ///
    /// Assumes quasi-neutrality: n_e = n_D + n_T + Σ(Z_i * n_i)
    /// For pure D-T (no impurities): n_e = n_D + n_T
    /// With impurities: (n_D + n_T) = fuelDilution * n_e
    ///
    /// Example:
    /// - fuelDilution = 1.0 → no impurities, (n_D + n_T) = n_e
    /// - fuelDilution = 0.9 → 10% impurities, (n_D + n_T) = 0.9 * n_e
    ///
    /// - Parameter ne: Electron density [m⁻³]
    /// - Returns: (n_D, n_T) fuel densities [m⁻³]
    private func computeFuelDensities(ne: MLXArray) -> (MLXArray, MLXArray) {
        let nD: MLXArray
        let nT: MLXArray

        // Total fuel ion density accounting for impurities
        let n_fuel_total = ne * fuelDilution

        switch fuelMix {
        case .equalDT:
            // 50-50 D-T mixture
            nD = n_fuel_total / Float(2.0)
            nT = n_fuel_total / Float(2.0)

        case .custom(let fD, let fT):
            // Custom mixture
            // Note: total_fraction validation is done in init()
            // This ensures (fD + fT) > 1e-6, preventing division by zero
            let total_fraction = fD + fT
            nD = n_fuel_total * (fD / total_fraction)
            nT = n_fuel_total * (fT / total_fraction)
        }

        return (nD, nT)
    }

    /// Find peak reactivity temperature
    ///
    /// D-T fusion reactivity peaks around 70 keV.
    ///
    /// - Returns: Temperature at peak reactivity [eV]
    public func findPeakReactivityTemperature() -> Float {
        // Peak is around 70 keV for D-T
        return 70000.0  // eV
    }

    /// Compute fusion triple product
    ///
    /// n * T * τ_E criterion for ignition.
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Ti: Ion temperature [eV]
    ///   - tauE: Energy confinement time [s]
    /// - Returns: Triple product [m⁻³ · eV · s]
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func computeTripleProduct(
        ne: MLXArray,
        Ti: MLXArray,
        tauE: Float
    ) -> MLXArray {
        return ne * Ti * tauE
    }

    /// Compute fraction of alpha energy going to ions (HIGH FIX #2)
    ///
    /// Based on alpha slowing-down physics. Critical energy:
    /// E_crit = 14.8 * Te [keV] * (A_i/Z_i²)^(1/3)
    ///
    /// For D-T plasma: A_i ≈ 2.5 (average), Z_i = 1
    /// E_crit ≈ 18 * Te [keV]
    ///
    /// Simplified model:
    /// - f_e = E_alpha / (E_alpha + E_crit)
    /// - f_i = E_crit / (E_alpha + E_crit)
    ///
    /// - Parameter Te: Electron temperature [eV]
    /// - Returns: Fraction of alpha power to ions [0, 1]
    ///
    /// - Note: Returns a lazy MLXArray. Call `eval()` before using `.item()` to extract values.
    ///   When used with `EvaluatedArray(evaluating:)`, evaluation is automatic.
    public func computeAlphaIonFraction(Te: MLXArray) -> MLXArray {
        // Convert Te to keV
        let Te_keV = Te / Float(1000.0)

        // Critical energy for D-T plasma
        // E_crit ≈ 18 * Te [keV]
        let E_crit = Float(18.0) * Te_keV

        // Alpha energy in keV
        let E_alpha_keV = alphaEnergy * Float(1000.0)  // MeV → keV

        // Ion fraction using slowing-down formula
        // At low Te: E_crit small → f_i ≈ 0 → more to electrons (fast slowing-down)
        // At high Te: E_crit large → f_i ≈ E_crit/(E_alpha+E_crit) → more to ions
        let f_i = E_crit / (E_alpha_keV + E_crit)

        // Clamp to reasonable range [0.05, 0.5]
        // (alphas can't deposit >50% to ions in realistic conditions)
        let result = MLX.clip(f_i, min: Float(0.05), max: Float(0.5))
        // Return lazy MLXArray - caller will eval() when needed
        return result
    }
}

// MARK: - Source Model Protocol Conformance

extension FusionPower {

    /// Apply fusion heating to source terms with alpha slowing-down model
    ///
    /// HIGH FIX #2: Alpha particles (3.5 MeV) heat ions and electrons through collisions.
    /// The split depends on electron temperature via critical energy.
    ///
    /// Physics: E_crit ≈ 14.8 * Te [keV] * (A_i/Z_i²)^(1/3)
    /// - Low Te → E_alpha >> E_crit → More power to ions
    /// - High Te → E_alpha < E_crit → More power to electrons
    ///
    /// - Parameters:
    ///   - sources: Source terms to modify
    ///   - profiles: Current plasma profiles
    /// - Returns: Modified source terms with fusion heating
    /// - Throws: PhysicsError if computation fails
    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles
    ) throws -> SourceTerms {

        let P_fusion_watts = try compute(
            ne: profiles.electronDensity.value,
            Ti: profiles.ionTemperature.value
        )

        // Convert to MW/m³ for SourceTerms
        let P_fusion = PhysicsConstants.wattsToMegawatts(P_fusion_watts)

        // Compute alpha energy deposition split based on electron temperature
        let Te = profiles.electronTemperature.value
        let ionFraction = computeAlphaIonFraction(Te: Te)

        // Split fusion power between ions and electrons
        let P_ion = P_fusion * ionFraction
        let P_electron = P_fusion * (Float(1.0) - ionFraction)

        // Create new SourceTerms with updated heating
        return SourceTerms(
            ionHeating: EvaluatedArray(
                evaluating: sources.ionHeating.value + P_ion
            ),
            electronHeating: EvaluatedArray(
                evaluating: sources.electronHeating.value + P_electron
            ),
            particleSource: sources.particleSource,
            currentSource: sources.currentSource
        )
    }
}

// MARK: - Phase 4a: Metadata Computation

extension FusionPower {

    /// Phase 4a: Compute source metadata for power balance tracking
    ///
    /// - Parameters:
    ///   - profiles: Current plasma profiles
    ///   - geometry: Geometry for volume integration
    /// - Returns: Source metadata with fusion power components
    /// - Throws: PhysicsError if computation fails
    public func computeMetadata(
        profiles: CoreProfiles,
        geometry: Geometry
    ) throws -> SourceMetadata {

        let P_fusion_watts = try compute(
            ne: profiles.electronDensity.value,
            Ti: profiles.ionTemperature.value
        )

        // Compute alpha energy deposition split based on electron temperature
        let Te = profiles.electronTemperature.value
        let ionFraction = computeAlphaIonFraction(Te: Te)

        // Split fusion power between ions and electrons [W/m^3]
        let P_ion_density = P_fusion_watts * ionFraction
        let P_electron_density = P_fusion_watts * (Float(1.0) - ionFraction)

        // Volume integration: ∫ P dV → [W/m^3] × [m^3] = [W]
        let cellVolumes = GeometricFactors.from(geometry: geometry).cellVolumes.value

        let P_ion_total = (P_ion_density * cellVolumes).sum()
        let P_electron_total = (P_electron_density * cellVolumes).sum()
        let P_fusion_total = (P_fusion_watts * cellVolumes).sum()
        eval(P_ion_total, P_electron_total, P_fusion_total)

        let ionPower = P_ion_total.item(Float.self)
        let electronPower = P_electron_total.item(Float.self)
        let fusionPower = P_fusion_total.item(Float.self)

        // Alpha power is 20% of total fusion power (D-T: 3.5 MeV / 17.6 MeV)
        let alphaPower = fusionPower * 0.2

        return SourceMetadata(
            modelName: "fusion_power",
            category: .fusion,
            ionPower: ionPower,
            electronPower: electronPower,
            alphaPower: alphaPower
        )
    }
}

// MARK: - Diagnostic Output

extension FusionPower {

    /// Compute total fusion power
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Ti: Ion temperature [eV]
    ///   - geometry: Tokamak geometry
    /// - Returns: Total fusion power [W]
    public func computeTotalPower(
        ne: MLXArray,
        Ti: MLXArray,
        geometry: Geometry
    ) throws -> Float {

        let P_fusion_density = try compute(ne: ne, Ti: Ti)

        // Integrate over volume
        let cellVolumes = GeometricFactors.from(geometry: geometry).cellVolumes.value
        let P_total = (P_fusion_density * cellVolumes).sum()

        return P_total.item(Float.self)
    }

    /// Compute fusion gain Q = P_fusion / P_input
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Ti: Ion temperature [eV]
    ///   - geometry: Tokamak geometry
    ///   - inputPower: Total input power [W]
    /// - Returns: Fusion gain Q (dimensionless)
    public func computeFusionGain(
        ne: MLXArray,
        Ti: MLXArray,
        geometry: Geometry,
        inputPower: Float
    ) throws -> Float {

        let P_fusion = try computeTotalPower(ne: ne, Ti: Ti, geometry: geometry)
        return P_fusion / (inputPower + 1e-10)
    }

    /// Check if plasma is ignited (Q > 1)
    ///
    /// - Parameters:
    ///   - ne: Electron density [m⁻³]
    ///   - Ti: Ion temperature [eV]
    ///   - geometry: Tokamak geometry
    ///   - inputPower: Total input power [W]
    /// - Returns: True if fusion gain Q > 1
    public func isIgnited(
        ne: MLXArray,
        Ti: MLXArray,
        geometry: Geometry,
        inputPower: Float
    ) throws -> Bool {

        let Q = try computeFusionGain(ne: ne, Ti: Ti, geometry: geometry, inputPower: inputPower)
        return Q > 1.0
    }
}
