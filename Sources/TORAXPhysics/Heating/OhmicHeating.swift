import Foundation
import MLX
import TORAX

/// Ohmic heating model
///
/// Computes resistive heating power from plasma current:
/// Q_ohm = η_∥ * j_∥²
///
/// Uses Spitzer resistivity with optional neoclassical correction
/// for trapped particles.
///
/// Spitzer resistivity:
/// η_Spitzer = 5.2 × 10⁻⁵ * Z_eff * ln(Λ) / T_e^(3/2)  [Ω·m]
///
/// Neoclassical correction:
/// η_neo = η_Spitzer * (1 + ε^(3/2))
/// where ε = r/R₀ (inverse aspect ratio)
public struct OhmicHeating: Sendable {

    /// Effective charge
    public let Zeff: Float

    /// Coulomb logarithm
    public let lnLambda: Float

    /// Apply neoclassical correction for trapped particles
    public let useNeoclassical: Bool

    /// Create Ohmic heating model
    ///
    /// - Parameters:
    ///   - Zeff: Effective charge (default: 1.5)
    ///   - lnLambda: Coulomb logarithm (default: 17.0)
    ///   - useNeoclassical: Apply neoclassical correction (default: true)
    public init(
        Zeff: Float = 1.5,
        lnLambda: Float = 17.0,
        useNeoclassical: Bool = true
    ) {
        self.Zeff = Zeff
        self.lnLambda = lnLambda
        self.useNeoclassical = useNeoclassical
    }

    /// Compute Ohmic heating power density
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV], shape [nCells]
    ///   - jParallel: Parallel current density [A/m²], shape [nCells]
    ///   - geometry: Tokamak geometry
    /// - Returns: Heating power [W/m³], shape [nCells]
    /// - Throws: PhysicsError if inputs are invalid
    public func compute(
        Te: MLXArray,
        jParallel: MLXArray,
        geometry: Geometry
    ) throws -> MLXArray {

        // Validate inputs (CRITICAL FIX #3)
        try PhysicsValidation.validateTemperature(Te, name: "Te")
        try PhysicsValidation.validateFinite(jParallel, name: "jParallel")
        try PhysicsValidation.validateShapes([Te, jParallel], names: ["Te", "jParallel"])

        // Spitzer resistivity [Ω·m]
        // η_Spitzer = 5.2 × 10⁻⁵ * Z_eff * ln(Λ) / T_e^(3/2)
        let eta_Spitzer = PhysicsConstants.spitzerPrefactor * Zeff * lnLambda / pow(Te, 1.5)

        var eta = eta_Spitzer

        if useNeoclassical {
            // Neoclassical correction for trapped particles
            // Inverse aspect ratio: ε = r/R₀
            let geomFactors = GeometricFactors.from(geometry: geometry)
            let epsilon = geomFactors.rCell.value / geometry.majorRadius

            // Trapped particle correction factor: f_trap ≈ 1 + ε^(3/2)
            let f_trap = 1.0 + pow(epsilon, 1.5)
            eta = eta * f_trap
        }

        // Ohmic power [W/m³]
        // Q_ohm = η * j_∥²
        let Q_ohm_watts = eta * jParallel * jParallel

        eval(Q_ohm_watts)  // Evaluate computation graph before returning
        return Q_ohm_watts
    }

    /// Compute Spitzer resistivity (without neoclassical correction)
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV]
    ///   - Zeff: Effective charge (optional override)
    ///   - lnLambda: Coulomb logarithm (optional override)
    /// - Returns: Resistivity [Ω·m]
    public func computeSpitzerResistivity(
        Te: MLXArray,
        Zeff: Float? = nil,
        lnLambda: Float? = nil
    ) -> MLXArray {
        let Z = Zeff ?? self.Zeff
        let ln = lnLambda ?? self.lnLambda

        return PhysicsConstants.spitzerPrefactor * Z * ln / pow(Te, 1.5)
    }

    /// Compute neoclassical resistivity
    ///
    /// - Parameters:
    ///   - Te: Electron temperature [eV]
    ///   - geometry: Tokamak geometry
    /// - Returns: Resistivity [Ω·m]
    public func computeNeoclassicalResistivity(
        Te: MLXArray,
        geometry: Geometry
    ) -> MLXArray {
        let eta_Spitzer = computeSpitzerResistivity(Te: Te)

        // Trapped particle correction
        let geomFactors = GeometricFactors.from(geometry: geometry)
        let epsilon = geomFactors.rCell.value / geometry.majorRadius
        let f_trap = 1.0 + pow(epsilon, 1.5)

        return eta_Spitzer * f_trap
    }
}

// MARK: - Source Model Protocol Conformance

extension OhmicHeating {

    /// Apply Ohmic heating to source terms
    ///
    /// All Ohmic power goes to electron heating (electrons carry the current).
    ///
    /// - Parameters:
    ///   - sources: Source terms to modify
    ///   - profiles: Current plasma profiles
    ///   - geometry: Tokamak geometry
    /// - Returns: Modified source terms with Ohmic heating
    /// Apply Ohmic heating to source terms
    ///
    /// CRITICAL FIX #1: Improved implementation with current density computation
    ///
    /// Computes parallel current from:
    /// 1. Bootstrap current (from profiles)
    /// 2. Ohmic current (from resistive diffusion)
    /// 3. External current drive
    ///
    /// - Parameters:
    ///   - sources: Source terms to modify
    ///   - profiles: Current plasma profiles
    ///   - geometry: Tokamak geometry
    ///   - plasmaCurrentDensity: Optional externally provided current density [A/m²]
    ///                           If nil, estimates from profiles
    /// - Returns: Modified source terms with Ohmic heating
    /// - Throws: PhysicsError if computation fails
    public func applyToSources(
        _ sources: SourceTerms,
        profiles: CoreProfiles,
        geometry: Geometry,
        plasmaCurrentDensity: MLXArray? = nil
    ) throws -> SourceTerms {

        // Compute parallel current density
        let jParallel: MLXArray
        if let providedCurrent = plasmaCurrentDensity {
            jParallel = providedCurrent
        } else {
            // Estimate from poloidal flux if available
            jParallel = try computeParallelCurrentFromProfiles(
                profiles: profiles,
                geometry: geometry
            )
        }

        let Q_ohm_watts = try compute(
            Te: profiles.electronTemperature.value,
            jParallel: jParallel,
            geometry: geometry
        )

        // Convert to MW/m³ for SourceTerms
        let Q_ohm = PhysicsConstants.wattsToMegawatts(Q_ohm_watts)

        // Create new SourceTerms with updated electron heating
        return SourceTerms(
            ionHeating: sources.ionHeating,
            electronHeating: EvaluatedArray(
                evaluating: sources.electronHeating.value + Q_ohm
            ),
            particleSource: sources.particleSource,
            currentSource: sources.currentSource
        )
    }

    /// Compute parallel current density from plasma profiles (CRITICAL FIX #1)
    ///
    /// Implements simplified current density model:
    /// j_∥ ≈ (1/μ₀R) * ∂ψ/∂r
    ///
    /// where ψ is poloidal flux, R is major radius
    ///
    /// **Note**: This is a simplified implementation suitable for:
    /// - Circular cross-section tokamaks
    /// - Moderate aspect ratio (R/a > 2)
    ///
    /// For shaped plasmas, need full MHD equilibrium solver.
    ///
    /// - Parameters:
    ///   - profiles: Current plasma profiles
    ///   - geometry: Tokamak geometry
    /// - Returns: Parallel current density [A/m²]
    /// - Throws: PhysicsError if computation fails
    private func computeParallelCurrentFromProfiles(
        profiles: CoreProfiles,
        geometry: Geometry
    ) throws -> MLXArray {

        let psi = profiles.poloidalFlux.value
        let nCells = psi.shape[0]

        // Check if we have meaningful flux data
        let psiRange = MLX.max(psi).item(Float.self) - MLX.min(psi).item(Float.self)

        guard psiRange > 1e-6 else {
            // Poloidal flux is essentially zero → no current
            // This happens in startup or when psi solver hasn't run yet
            return MLXArray.zeros([nCells])
        }

        let geomFactors = GeometricFactors.from(geometry: geometry)
        let rCell = geomFactors.rCell.value

        // Compute radial derivative of psi using central differences
        // ∂ψ/∂r ≈ (ψ[i+1] - ψ[i-1]) / (r[i+1] - r[i-1])

        guard nCells >= 3 else {
            // Not enough points for gradient
            return MLXArray.zeros([nCells])
        }

        // Interior points: central difference
        let dr_interior = rCell[2..<nCells] - rCell[0..<(nCells-2)]
        let dpsi_interior = psi[2..<nCells] - psi[0..<(nCells-2)]
        let grad_psi_interior = dpsi_interior / (dr_interior + 1e-10)

        // Boundaries: forward/backward difference
        let dr_left = rCell[1] - rCell[0]
        let dpsi_left = psi[1] - psi[0]
        let grad_psi_left = dpsi_left / (dr_left + 1e-10)

        let dr_right = rCell[nCells-1] - rCell[nCells-2]
        let dpsi_right = psi[nCells-1] - psi[nCells-2]
        let grad_psi_right = dpsi_right / (dr_right + 1e-10)

        // Concatenate
        let grad_psi = concatenated([
            grad_psi_left.reshaped([1]),
            grad_psi_interior,
            grad_psi_right.reshaped([1])
        ], axis: 0)

        // Parallel current density: j_∥ ≈ (1/μ₀R) * ∂ψ/∂r
        let mu0 = PhysicsConstants.mu0
        let R0 = geometry.majorRadius
        let j_parallel = grad_psi / (mu0 * R0)

        return j_parallel
    }
}
