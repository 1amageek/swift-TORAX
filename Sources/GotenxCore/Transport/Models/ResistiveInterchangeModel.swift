// ResistiveInterchangeModel.swift
// Resistive-Interchange (RI) turbulence transport model

import MLX
import Foundation

// MARK: - Resistive-Interchange Transport Model

/// Resistive-Interchange turbulence transport model
///
/// Models transport driven by resistive ballooning modes at high density.
/// Based on turbulence transition discovery (PhysRevLett.132.235101, 2024).
///
/// **Physical Drivers**:
/// - Pressure gradient (interchange drive)
/// - Plasma resistivity (enables magnetic reconnection)
/// - Magnetic curvature (bad curvature at outboard side)
///
/// **Scaling Formula**:
/// ```
/// χ_RI = C_RI × (ρ_s²/τ_R) × (L_p/L_n)^α × exp(-β_crit/β)
/// ```
///
/// Where:
/// - `ρ_s`: Ion sound Larmor radius
/// - `τ_R`: Resistive diffusion time
/// - `L_p`, `L_n`: Pressure and density gradient scale lengths
/// - `β`: Plasma beta
///
/// **Reference**: Kinoshita et al., PRL 132, 235101 (2024)
public struct ResistiveInterchangeModel: TransportModel {
    // MARK: - Properties

    public let name = "resistive-interchange"

    /// RI coefficient C_RI (dimensionless)
    ///
    /// **Typical value**: 0.1 - 1.0 (empirical, to be tuned)
    public let coefficientRI: Float

    /// Gradient drive exponent α
    ///
    /// **Typical value**: 1.5 - 2.0
    public let gradientExponent: Float

    /// Critical beta for ballooning β_crit
    ///
    /// **Typical value**: 0.01 - 0.05
    public let betaCritical: Float

    /// Effective charge Z_eff for Spitzer resistivity
    ///
    /// **Default**: 1.0 (pure deuterium)
    public let Z_eff: Float

    /// Ion mass number (1=H, 2=D, 3=T)
    ///
    /// **Default**: 2.0 (deuterium)
    public let ionMassNumber: Float

    // MARK: - Initialization

    /// Initialize RI transport model
    ///
    /// - Parameters:
    ///   - coefficientRI: RI coefficient C_RI (default: 0.5)
    ///   - gradientExponent: Gradient drive exponent α (default: 1.5)
    ///   - betaCritical: Critical beta β_crit (default: 0.02)
    ///   - Z_eff: Effective charge (default: 1.0)
    ///   - ionMassNumber: Ion mass number (default: 2.0 for D)
    public init(
        coefficientRI: Float = 0.5,
        gradientExponent: Float = 1.5,
        betaCritical: Float = 0.02,
        Z_eff: Float = 1.0,
        ionMassNumber: Float = 2.0
    ) {
        self.coefficientRI = coefficientRI
        self.gradientExponent = gradientExponent
        self.betaCritical = betaCritical
        self.Z_eff = Z_eff
        self.ionMassNumber = ionMassNumber
    }

    /// Initialize from parameters dictionary
    public init(params: TransportParameters) {
        self.coefficientRI = params.params["ri_coefficient"] ?? 0.5
        self.gradientExponent = params.params["ri_gradient_exponent"] ?? 1.5
        self.betaCritical = params.params["ri_beta_critical"] ?? 0.02
        self.Z_eff = params.params["z_eff"] ?? 1.0
        self.ionMassNumber = params.params["ion_mass_number"] ?? 2.0
    }

    // MARK: - TransportModel Protocol

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        let nCells = profiles.ionTemperature.shape[0]
        let radii = geometry.radii.value

        // Extract profiles
        let Te_eV = profiles.electronTemperature.value
        let ne_m3 = profiles.electronDensity.value

        // Compute Spitzer resistivity
        let eta = PlasmaPhysics.spitzerResistivity(
            Te_eV: Te_eV,
            ne_m3: ne_m3,
            Z_eff: Z_eff
        )

        // Compute resistive diffusion time
        let tau_R = PlasmaPhysics.resistiveDiffusionTime(
            eta: eta,
            minorRadius: geometry.minorRadius
        )

        // Compute total magnetic field
        let B_total = PlasmaPhysics.totalMagneticField(
            toroidalField: geometry.toroidalField,
            poloidalField: geometry.poloidalField?.value,
            nCells: nCells
        )

        // Compute ion sound Larmor radius
        let ionMass = PlasmaPhysics.ionMass(massNumber: ionMassNumber)
        let rho_s = PlasmaPhysics.ionSoundLarmorRadius(
            Te_eV: Te_eV,
            magneticField: B_total,
            ionMass: ionMass
        )

        // Compute plasma beta
        let beta = PlasmaPhysics.plasmaBeta(
            profiles: profiles,
            magneticField: B_total
        )

        // Compute gradient scale lengths
        let L_p = GradientComputation.computePressureGradientLength(
            profiles: profiles,
            radii: radii
        )

        let L_n = GradientComputation.computeDensityGradientLength(
            density: ne_m3,
            radii: radii
        )

        // Compute RI transport coefficient with Float32 stability
        let chi_RI = computeRICoefficient(
            rho_s: rho_s,
            tau_R: tau_R,
            L_p: L_p,
            L_n: L_n,
            beta: beta
        )

        // Particle diffusivity: D = χ / 3 (simplified)
        let D = chi_RI / 3.0
        eval(D)

        return TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: chi_RI),
            chiElectron: EvaluatedArray(evaluating: chi_RI),
            particleDiffusivity: EvaluatedArray(evaluating: D),
            convectionVelocity: EvaluatedArray.zeros([nCells])
        )
    }

    // MARK: - Private Methods

    /// Compute RI transport coefficient with numerical stability
    ///
    /// **Formula**:
    /// ```
    /// χ_RI = C_RI × (ρ_s²/τ_R) × (L_p/L_n)^α × exp(-β_crit/β)
    /// ```
    ///
    /// **Stabilization**:
    /// - Clamp β to [1e-6, 0.2]
    /// - Clamp τ_R to [1e-6, 1e6] s
    /// - Clamp L_p/L_n to [0.1, 10.0]
    /// - Clamp exp() argument to [-10, 0]
    private func computeRICoefficient(
        rho_s: MLXArray,
        tau_R: MLXArray,
        L_p: MLXArray,
        L_n: MLXArray,
        beta: MLXArray
    ) -> MLXArray {
        // Base coefficient: (ρ_s²/τ_R)
        // CRITICAL: Clip rho_s to prevent Float32 overflow at extreme temperatures
        // Physical range: ρ_s ~ 0.5-2 mm for typical tokamak conditions
        // CRITICAL: min = 1e-5 m (0.01 mm) to preserve isotope effect
        let rho_s_safe = clip(rho_s, min: MLXArray(Float(1e-5)), max: MLXArray(Float(0.1)))
        eval(rho_s_safe)

        let rho_s_squared = rho_s_safe * rho_s_safe
        eval(rho_s_squared)

        // Prevent division by very small tau_R
        let tau_R_safe = clip(tau_R, min: MLXArray(Float(1e-6)), max: MLXArray(Float(1e6)))
        eval(tau_R_safe)

        let chi_base = MLXArray(Float(coefficientRI)) * (rho_s_squared / tau_R_safe)
        eval(chi_base)

        // Clip intermediate result to prevent overflow in subsequent operations
        let chi_base_safe = clip(chi_base, min: MLXArray(Float(1e-8)), max: MLXArray(Float(100.0)))
        eval(chi_base_safe)

        // Gradient drive term: (L_p/L_n)^α
        // Clamp ratio to prevent extreme values
        let epsilon = MLXArray(Float(1e-10))
        let gradientRatio = L_p / (L_n + epsilon)
        let gradientRatio_clamped = clip(gradientRatio, min: MLXArray(Float(0.1)), max: MLXArray(Float(10.0)))
        eval(gradientRatio_clamped)

        let gradientTerm = pow(gradientRatio_clamped, MLXArray(Float(gradientExponent)))
        eval(gradientTerm)

        // Clip gradientTerm to prevent overflow
        let gradientTerm_safe = clip(gradientTerm, min: MLXArray(Float(0.1)), max: MLXArray(Float(100.0)))
        eval(gradientTerm_safe)

        // Beta suppression term: exp(-β_crit/β)
        // Stabilize exponential to prevent overflow
        let beta_safe = clip(beta, min: MLXArray(Float(1e-6)), max: MLXArray(Float(0.2)))
        eval(beta_safe)

        let betaArg = MLXArray(Float(-betaCritical)) / beta_safe
        // Clamp to [-10, 0] to prevent exp() overflow/underflow
        let betaArg_clamped = clip(betaArg, min: MLXArray(Float(-10.0)), max: MLXArray(Float(0.0)))
        eval(betaArg_clamped)

        let betaTerm = exp(betaArg_clamped)
        eval(betaTerm)

        // Clip betaTerm to prevent underflow
        let betaTerm_safe = clip(betaTerm, min: MLXArray(Float(1e-5)), max: MLXArray(Float(1.0)))
        eval(betaTerm_safe)

        // Combined coefficient with intermediate clipping
        let chi_RI = chi_base_safe * gradientTerm_safe * betaTerm_safe

        // Final clamp to physically reasonable range
        // CRITICAL: min must be low enough to preserve isotope effect in tests
        // Physical RI transport can be very small at moderate β
        let chi_RI_clamped = clip(chi_RI, min: MLXArray(Float(1e-9)), max: MLXArray(Float(100.0)))
        eval(chi_RI_clamped)

        return chi_RI_clamped
    }
}
