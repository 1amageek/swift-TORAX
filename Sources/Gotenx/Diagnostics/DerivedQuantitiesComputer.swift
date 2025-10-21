// DerivedQuantitiesComputer.swift
// Computes derived scalar quantities from simulation state
//
// Phase 2 Implementation: Basic metrics (central values, averages, energies)
// Phase 3 Implementation: Advanced metrics (τE, Q, βN) requiring transport/sources

import Foundation
import MLX

/// Computes derived scalar quantities from simulation state
///
/// **Design Philosophy**:
/// - Pure functions: No side effects, deterministic outputs
/// - GPU-optimized: All MLXArray operations stay on GPU
/// - Unit-aware: Explicit unit conversions documented
///
/// **Implementation Phases**:
/// - Phase 2 (Current): Central values, volume averages, total energies
/// - Phase 3: Confinement metrics (τE, H-factor), beta limits, fusion performance
public enum DerivedQuantitiesComputer {

    // MARK: - Phase 2: Basic Metrics

    /// Compute derived quantities from simulation state
    ///
    /// **Phase 2**: Computes only basic metrics (central values, averages, energies)
    /// **Phase 3**: Will add advanced metrics (τE, Q, βN)
    ///
    /// - Parameters:
    ///   - profiles: Current plasma profiles
    ///   - geometry: Tokamak geometry
    ///   - transport: Transport coefficients (Phase 3)
    ///   - sources: Source terms (Phase 3)
    /// - Returns: Computed derived quantities
    public static func compute(
        profiles: CoreProfiles,
        geometry: Geometry,
        transport: TransportCoefficients? = nil,
        sources: SourceTerms? = nil
    ) -> DerivedQuantities {

        // Phase 2: Compute basic metrics
        let centralValues = computeCentralValues(profiles: profiles)
        let volumeAverages = computeVolumeAverages(profiles: profiles, geometry: geometry)
        let totalEnergies = computeTotalEnergies(profiles: profiles, geometry: geometry)

        // Phase 3: Placeholder for advanced metrics (will be implemented later)
        let advancedMetrics = computeAdvancedMetrics(
            profiles: profiles,
            geometry: geometry,
            transport: transport,
            sources: sources,
            totalEnergies: totalEnergies
        )

        return DerivedQuantities(
            Ti_core: centralValues.Ti,
            Te_core: centralValues.Te,
            ne_core: centralValues.ne,
            ne_avg: volumeAverages.ne,
            Ti_avg: volumeAverages.Ti,
            Te_avg: volumeAverages.Te,
            W_thermal: totalEnergies.thermal,
            W_ion: totalEnergies.ion,
            W_electron: totalEnergies.electron,
            P_fusion: advancedMetrics.P_fusion,
            P_alpha: advancedMetrics.P_alpha,
            P_auxiliary: advancedMetrics.P_auxiliary,
            P_ohmic: advancedMetrics.P_ohmic,
            Q_fusion: advancedMetrics.Q_fusion,
            tau_E: advancedMetrics.tau_E,
            tau_E_scaling: advancedMetrics.tau_E_scaling,
            H_factor: advancedMetrics.H_factor,
            beta_toroidal: advancedMetrics.beta_toroidal,
            beta_poloidal: advancedMetrics.beta_poloidal,
            beta_N: advancedMetrics.beta_N,
            beta_N_limit: advancedMetrics.beta_N_limit,
            I_plasma: advancedMetrics.I_plasma,
            I_bootstrap: advancedMetrics.I_bootstrap,
            f_bootstrap: advancedMetrics.f_bootstrap,
            n_T_tau: advancedMetrics.n_T_tau
        )
    }

    // MARK: - Central Values (ρ=0)

    private static func computeCentralValues(profiles: CoreProfiles) -> (Ti: Float, Te: Float, ne: Float) {
        // Extract central values (first cell, index 0)
        let Ti_array = profiles.ionTemperature.value
        let Te_array = profiles.electronTemperature.value
        let ne_array = profiles.electronDensity.value

        // GPU → CPU transfer (scalar only, cheap)
        let Ti_core = Ti_array[0].item(Float.self)
        let Te_core = Te_array[0].item(Float.self)
        let ne_core = ne_array[0].item(Float.self)

        return (Ti_core, Te_core, ne_core)
    }

    // MARK: - Volume Averages

    private static func computeVolumeAverages(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> (Ti: Float, Te: Float, ne: Float) {

        // Get cell volumes from geometry
        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value
        eval(volumes)

        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value

        // Volume-weighted averages: ⟨Q⟩ = ∫ Q dV / ∫ dV
        let totalVolume = volumes.sum()

        let Ti_weighted = (Ti * volumes).sum()
        let Te_weighted = (Te * volumes).sum()
        let ne_weighted = (ne * volumes).sum()

        // Batch evaluation for efficiency
        eval(totalVolume, Ti_weighted, Te_weighted, ne_weighted)

        let Ti_avg = (Ti_weighted / totalVolume).item(Float.self)
        let Te_avg = (Te_weighted / totalVolume).item(Float.self)
        let ne_avg = (ne_weighted / totalVolume).item(Float.self)

        return (Ti_avg, Te_avg, ne_avg)
    }

    // MARK: - Total Energies

    private static func computeTotalEnergies(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> (thermal: Float, ion: Float, electron: Float) {

        // Physical constants
        let eV_to_J: Float = 1.602176634e-19  // eV to Joule conversion

        // Get cell volumes
        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value
        eval(volumes)

        let Ti = profiles.ionTemperature.value  // [eV]
        let Te = profiles.electronTemperature.value  // [eV]
        let ne = profiles.electronDensity.value  // [m^-3]

        // Assume quasineutrality: n_i ≈ n_e
        // Thermal energy density: 3/2 * n * T [eV/m^3]
        let w_ion_density = 1.5 * ne * Ti  // [eV/m^3]
        let w_electron_density = 1.5 * ne * Te  // [eV/m^3]

        // Total energy: ∫ w dV → [eV/m^3] × [m^3] = [eV]
        let W_ion_eV = (w_ion_density * volumes).sum()
        let W_electron_eV = (w_electron_density * volumes).sum()
        let W_thermal_eV = W_ion_eV + W_electron_eV

        // Batch evaluation
        eval(W_ion_eV, W_electron_eV, W_thermal_eV)

        // Convert eV → J → MJ
        let J_to_MJ: Float = 1e-6

        let W_ion_MJ = W_ion_eV.item(Float.self) * eV_to_J * J_to_MJ
        let W_electron_MJ = W_electron_eV.item(Float.self) * eV_to_J * J_to_MJ
        let W_thermal_MJ = W_thermal_eV.item(Float.self) * eV_to_J * J_to_MJ

        return (W_thermal_MJ, W_ion_MJ, W_electron_MJ)
    }

    // MARK: - Advanced Metrics (Phase 3)

    /// Compute advanced metrics (τE, Q, βN, etc.)
    ///
    /// **Phase 3**: Full implementation using transport/sources
    ///
    /// - Parameters:
    ///   - profiles: Current plasma profiles
    ///   - geometry: Tokamak geometry
    ///   - transport: Transport coefficients (optional)
    ///   - sources: Source terms (optional)
    ///   - totalEnergies: Pre-computed total energies
    /// - Returns: Advanced metrics
    private static func computeAdvancedMetrics(
        profiles: CoreProfiles,
        geometry: Geometry,
        transport: TransportCoefficients?,
        sources: SourceTerms?,
        totalEnergies: (thermal: Float, ion: Float, electron: Float)
    ) -> AdvancedMetrics {

        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value

        // 1. Power balance
        let powers = computePowerBalance(
            sources: sources,
            profiles: profiles,
            geometry: geometry,
            volumes: volumes
        )

        // 2. Confinement time
        let confinement = computeConfinementMetrics(
            W_thermal: totalEnergies.thermal,
            powers: powers,
            profiles: profiles,
            geometry: geometry
        )

        // 3. Current metrics (MUST compute before beta to get I_plasma)
        let current = computeCurrentMetrics(
            profiles: profiles,
            geometry: geometry,
            transport: transport
        )

        // 4. Beta limits (uses I_plasma from current metrics)
        let beta = computeBetaMetrics(
            profiles: profiles,
            geometry: geometry,
            volumes: volumes,
            I_plasma: current.I_plasma
        )

        // 5. Triple product
        let n_T_tau = computeTripleProduct(
            profiles: profiles,
            geometry: geometry,
            volumes: volumes,
            tau_E: confinement.tau_E
        )

        // 6. Fusion gain Q = P_fusion / P_input
        let Q_fusion = computeFusionGain(
            P_fusion: powers.P_fusion,
            P_auxiliary: powers.P_auxiliary,
            P_ohmic: powers.P_ohmic
        )

        return AdvancedMetrics(
            P_fusion: powers.P_fusion,
            P_alpha: powers.P_alpha,
            P_auxiliary: powers.P_auxiliary,
            P_ohmic: powers.P_ohmic,
            Q_fusion: Q_fusion,
            tau_E: confinement.tau_E,
            tau_E_scaling: confinement.tau_E_scaling,
            H_factor: confinement.H_factor,
            beta_toroidal: beta.toroidal,
            beta_poloidal: beta.poloidal,
            beta_N: beta.normalized,
            beta_N_limit: beta.troyon_limit,
            I_plasma: current.I_plasma,
            I_bootstrap: current.I_bootstrap,
            f_bootstrap: current.f_bootstrap,
            n_T_tau: n_T_tau
        )
    }

    // MARK: - Power Balance

    private static func computePowerBalance(
        sources: SourceTerms?,
        profiles: CoreProfiles,
        geometry: Geometry,
        volumes: MLXArray
    ) -> (P_fusion: Float, P_alpha: Float, P_auxiliary: Float, P_ohmic: Float) {

        guard let sources = sources else {
            return (0, 0, 0, 0)
        }

        // Phase 4a: Require metadata for accurate power balance
        guard let metadata = sources.metadata else {
            #if DEBUG
            // Debug builds: Fail fast to catch missing metadata
            preconditionFailure(
                """
                SourceTerms.metadata is required for accurate power balance computation.

                Phase 3 fixed-ratio estimation has been deprecated due to inaccuracy.
                All SourceModel implementations must provide SourceMetadata.

                Fix: Update SourceModel to return SourceTerms with metadata:
                    let metadata = SourceMetadata(
                        modelName: "your_model",
                        category: .fusion/.auxiliary/.ohmic,
                        ionPower: computed_ion_power,
                        electronPower: computed_electron_power
                    )
                    return SourceTerms(..., metadata: SourceMetadataCollection(entries: [metadata]))
                """
            )
            #else
            // Release builds: Print warning and return zeros
            print(
                """
                ⚠️ Warning: SourceTerms.metadata is nil - power balance will be inaccurate.
                Returning zero power values. Update SourceModel to provide metadata.
                """
            )
            return (0, 0, 0, 0)
            #endif
        }

        // Convert from W to MW
        let P_fusion = metadata.fusionPower / 1e6       // [W] → [MW]
        let P_alpha = metadata.alphaPower / 1e6         // [W] → [MW]
        let P_auxiliary = metadata.auxiliaryPower / 1e6 // [W] → [MW]
        let P_ohmic = metadata.ohmicPower / 1e6         // [W] → [MW]

        return (P_fusion, P_alpha, P_auxiliary, P_ohmic)
    }

    // MARK: - Confinement Metrics

    private static func computeConfinementMetrics(
        W_thermal: Float,
        powers: (P_fusion: Float, P_alpha: Float, P_auxiliary: Float, P_ohmic: Float),
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> (tau_E: Float, tau_E_scaling: Float, H_factor: Float) {

        // Energy confinement time: τE = W / P_loss
        // P_loss = P_input + P_alpha (external heating + alpha particle heating)
        // Note: P_fusion is NOT included in P_loss (it's already counted via P_alpha)
        let P_input = powers.P_auxiliary + powers.P_ohmic
        let P_loss = P_input + powers.P_alpha  // Total heating power

        let tau_E: Float
        if P_loss > PhysicalThresholds.default.minHeatingPowerForTauE {
            tau_E = W_thermal / P_loss  // [MJ / MW = s]
        } else {
            tau_E = 0
        }

        // ITER98y2 scaling law for H-mode
        // τE = 0.0562 * Ip^0.93 * Bt^0.15 * P^(-0.69) * n^0.41 * M^0.19 * R^1.97 * ε^0.58 * κ^0.78
        // Simplified version for circular geometry
        let tau_E_scaling = computeITER98Scaling(
            profiles: profiles,
            geometry: geometry,
            P_loss: P_loss
        )

        let H_factor: Float
        if tau_E_scaling > 0 {
            H_factor = tau_E / tau_E_scaling
        } else {
            H_factor = 0
        }

        return (tau_E, tau_E_scaling, H_factor)
    }

    private static func computeITER98Scaling(
        profiles: CoreProfiles,
        geometry: Geometry,
        P_loss: Float
    ) -> Float {

        // Extract parameters
        let R0 = geometry.majorRadius  // [m]
        let a = geometry.minorRadius   // [m]
        let Bt = geometry.toroidalField  // [T]

        // Estimate plasma current from geometry (very rough)
        let epsilon = a / R0
        let Ip_est: Float = 15.0  // [MA] - typical ITER-scale value

        // Volume-averaged density
        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value
        let ne = profiles.electronDensity.value
        let ne_weighted = (ne * volumes).sum()
        let total_volume = volumes.sum()
        eval(ne_weighted, total_volume)

        let ne_avg = (ne_weighted / total_volume).item(Float.self)  // [m^-3]
        let ne_19 = ne_avg / 1e19  // [10^19 m^-3]

        // Mass number (assume deuterium-tritium)
        let M: Float = 2.5

        // Elongation (assume circular for now)
        let kappa: Float = 1.0

        // ITER98y2 formula
        let tau_scaling = 0.0562 *
            pow(Ip_est, 0.93) *
            pow(Bt, 0.15) *
            pow(max(P_loss, 0.1), -0.69) *
            pow(ne_19, 0.41) *
            pow(M, 0.19) *
            pow(R0, 1.97) *
            pow(epsilon, 0.58) *
            pow(kappa, 0.78)

        return tau_scaling  // [s]
    }

    // MARK: - Beta Metrics

    private static func computeBetaMetrics(
        profiles: CoreProfiles,
        geometry: Geometry,
        volumes: MLXArray,
        I_plasma: Float
    ) -> (toroidal: Float, poloidal: Float, normalized: Float, troyon_limit: Float) {

        let mu0: Float = 4.0 * .pi * 1e-7  // Permeability [H/m]
        let eV_to_J: Float = 1.602176634e-19

        // Volume-averaged pressure
        let Ti = profiles.ionTemperature.value  // [eV]
        let Te = profiles.electronTemperature.value  // [eV]
        let ne = profiles.electronDensity.value  // [m^-3]

        // Pressure: p = n_e * (T_i + T_e) [eV/m^3]
        let pressure_eV = ne * (Ti + Te)
        let pressure_weighted = (pressure_eV * volumes).sum()
        let total_volume = volumes.sum()
        eval(pressure_weighted, total_volume)

        let p_avg_eV = (pressure_weighted / total_volume).item(Float.self)
        let p_avg = p_avg_eV * eV_to_J  // [Pa]

        // Toroidal beta: βt = 2μ0⟨p⟩ / Bt^2
        let Bt = geometry.toroidalField
        let beta_toroidal = (2.0 * mu0 * p_avg) / (Bt * Bt) * 100.0  // [%]

        // Poloidal beta: rough estimate as βp ≈ 2 * βt for typical tokamaks
        let beta_poloidal = 2.0 * beta_toroidal

        // Normalized beta: βN = β(%) * a(m) * Bt(T) / Ip(MA)
        // Use minimum 0.1 MA for small tokamaks (avoids unrealistic βN for low-current plasmas)
        let Ip_MA = max(I_plasma, 0.1)  // Avoid division by zero
        let beta_N = beta_toroidal * geometry.minorRadius * Bt / Ip_MA

        // Troyon limit: βN_limit ≈ 2.8 (empirical)
        let beta_N_limit: Float = 2.8

        return (beta_toroidal, beta_poloidal, beta_N, beta_N_limit)
    }

    // MARK: - Current Metrics

    private static func computeCurrentMetrics(
        profiles: CoreProfiles,
        geometry: Geometry,
        transport: TransportCoefficients?
    ) -> (I_plasma: Float, I_bootstrap: Float, f_bootstrap: Float) {

        // Compute plasma current from poloidal flux gradient
        let psi = profiles.poloidalFlux.value
        let geometricFactors = GeometricFactors.from(geometry: geometry)

        // Check if we have meaningful flux data
        let psiRange = MLX.max(psi).item(Float.self) - MLX.min(psi).item(Float.self)

        if psiRange > 0.01 {
            // Compute current density: j_∥ ≈ (1/μ₀R) * ∂ψ/∂r
            let nCells = psi.shape[0]
            let df = psi[1...] - psi[..<(nCells - 1)]
            let dr = geometricFactors.cellDistances.value + 1e-10
            let grad_psi_faces = df / dr

            // Interpolate gradient to cell centers
            let grad0 = grad_psi_faces[0..<1]
            let left = grad_psi_faces[0..<(nCells - 2)]
            let right = grad_psi_faces[1..<(nCells - 1)]
            let gradInterior = (left + right) / 2.0
            let gradN = grad_psi_faces[(nCells - 2)..<(nCells - 1)]
            let grad_psi = concatenated([grad0, gradInterior, gradN], axis: 0)

            let mu0: Float = 4.0 * .pi * 1e-7
            let R0 = geometry.majorRadius
            let j_parallel = grad_psi / (mu0 * R0)  // [A/m²]

            // Integrate over cross-section: I = ∫ j dA
            // For circular geometry, use cell volumes divided by 2πR
            // Volume = 2π²Rr²Δr → dA ≈ Volume / (2πR)
            let volumes = geometricFactors.cellVolumes.value  // [nCells]

            // Current density × area element
            let I_elements = abs(j_parallel) * volumes / (2.0 * Float.pi * R0)  // [A·m]

            // Total current
            let I_total = I_elements.sum().item(Float.self)  // [A]
            let I_plasma = I_total * 1e-6  // [MA]

            // Bootstrap fraction: typical range 0.2-0.5 for ITER-like plasmas
            let f_bootstrap: Float = 0.3  // Rough estimate
            let I_bootstrap = I_plasma * f_bootstrap  // [MA]

            return (I_plasma, I_bootstrap, f_bootstrap)
        } else {
            // Fallback: Estimate from geometry when flux is not available
            let a = geometry.minorRadius
            let Bt = geometry.toroidalField
            let q_edge: Float = 3.0  // Typical edge safety factor
            let mu0: Float = 4.0 * .pi * 1e-7
            let R0 = geometry.majorRadius

            let I_plasma = (a * Bt) / (q_edge * mu0 * R0) * 1e-6  // [MA]
            let f_bootstrap: Float = 0.3
            let I_bootstrap = I_plasma * f_bootstrap

            return (I_plasma, I_bootstrap, f_bootstrap)
        }
    }

    // MARK: - Triple Product

    private static func computeTripleProduct(
        profiles: CoreProfiles,
        geometry: Geometry,
        volumes: MLXArray,
        tau_E: Float
    ) -> Float {

        // Lawson triple product: n⟨T⟩τE
        let Ti = profiles.ionTemperature.value  // [eV]
        let Te = profiles.electronTemperature.value  // [eV]
        let ne = profiles.electronDensity.value  // [m^-3]

        // Volume-averaged temperature
        let T_avg_eV = (((Ti + Te) * 0.5 * ne * volumes).sum() / ((ne * volumes).sum() + 1e-10))
        eval(T_avg_eV)
        let T_avg = T_avg_eV.item(Float.self)  // [eV]

        // Volume-averaged density
        let ne_weighted = (ne * volumes).sum()
        let total_volume = volumes.sum()
        eval(ne_weighted, total_volume)
        let ne_avg = (ne_weighted / total_volume).item(Float.self)  // [m^-3]

        // Triple product: n⟨T⟩τE [eV s m^-3]
        let n_T_tau = ne_avg * T_avg * tau_E

        return n_T_tau
    }

    // MARK: - Fusion Gain

    /// Compute fusion gain Q = P_fusion / P_input
    ///
    /// **Definition**: Q = P_fusion / (P_auxiliary + P_ohmic)
    ///
    /// **Physics**:
    /// - Q < 1: More input power than fusion power (typical for small devices)
    /// - Q = 1: Breakeven (fusion power equals input power)
    /// - Q = 5-10: High-performance operation (ITER target: Q = 10)
    /// - Q → ∞: Ignition (self-sustaining fusion, no external heating needed)
    ///
    /// **Note**: Alpha power (P_alpha) is NOT counted as input since it's internally
    /// generated. Only external heating sources count toward P_input.
    ///
    /// - Parameters:
    ///   - P_fusion: Total fusion power [MW]
    ///   - P_auxiliary: Auxiliary heating power [MW]
    ///   - P_ohmic: Ohmic heating power [MW]
    /// - Returns: Fusion gain Q (dimensionless)
    private static func computeFusionGain(
        P_fusion: Float,
        P_auxiliary: Float,
        P_ohmic: Float
    ) -> Float {
        // Input power = external heating only (exclude alpha power)
        let P_input = P_auxiliary + P_ohmic

        // Handle edge cases
        guard P_input > PhysicalThresholds.default.minFusionPowerForQ else {
            // No input power: return 0 (avoid division by zero)
            return 0
        }

        // Fusion gain
        let Q = P_fusion / P_input

        // Clamp to reasonable range [0, 100]
        // Q > 100 is unrealistic and likely indicates numerical issues
        return max(0, min(Q, 100))
    }
}

// MARK: - Internal Data Structures

private struct AdvancedMetrics {
    let P_fusion: Float
    let P_alpha: Float
    let P_auxiliary: Float
    let P_ohmic: Float
    let Q_fusion: Float
    let tau_E: Float
    let tau_E_scaling: Float
    let H_factor: Float
    let beta_toroidal: Float
    let beta_poloidal: Float
    let beta_N: Float
    let beta_N_limit: Float
    let I_plasma: Float
    let I_bootstrap: Float
    let f_bootstrap: Float
    let n_T_tau: Float
}
