// PowerBalanceComputer.swift
// Phase 4a: Power balance computation with metadata support
//
// Replaces fixed-ratio estimation with accurate tracking of individual
// source contributions when metadata is available.

import Foundation
import MLX

/// Power balance computation results
///
/// Phase 4a: Tracks individual power components for accurate balance analysis.
///
/// Units: All powers in [W] (Watts)
public struct PowerBalance: Sendable {
    /// Total fusion power [W]
    public let fusionPower: Float

    /// Alpha particle heating power [W]
    public let alphaPower: Float

    /// Auxiliary heating power [W]
    public let auxiliaryPower: Float

    /// Ohmic heating power [W]
    public let ohmicPower: Float

    /// Total radiation losses [W] (negative)
    public let radiationPower: Float

    /// Total heating power (input) [W]
    public var totalHeating: Float {
        fusionPower + auxiliaryPower + ohmicPower
    }

    /// Net power (heating - radiation) [W]
    public var netPower: Float {
        totalHeating + radiationPower  // radiationPower is negative
    }

    public init(
        fusionPower: Float,
        alphaPower: Float,
        auxiliaryPower: Float,
        ohmicPower: Float,
        radiationPower: Float
    ) {
        self.fusionPower = fusionPower
        self.alphaPower = alphaPower
        self.auxiliaryPower = auxiliaryPower
        self.ohmicPower = ohmicPower
        self.radiationPower = radiationPower
    }
}

/// Power balance computation with metadata support
///
/// Phase 4a: Two computation paths:
/// 1. **Metadata-based** (accurate): Uses SourceMetadataCollection when available
/// 2. **Estimation-based** (Phase 3 fallback): Fixed-ratio estimation
///
/// Example:
/// ```swift
/// // Phase 4a: With metadata
/// let balance = PowerBalanceComputer.compute(
///     sources: sourceTermsWithMetadata,
///     profiles: profiles,
///     geometry: geometry
/// )
///
/// // Phase 3: Without metadata (fallback)
/// let balance = PowerBalanceComputer.compute(
///     sources: sourceTermsWithoutMetadata,
///     profiles: profiles,
///     geometry: geometry
/// )
/// ```
public enum PowerBalanceComputer {

    /// Compute power balance from source terms
    ///
    /// - Parameters:
    ///   - sources: Source terms (with or without metadata)
    ///   - profiles: Current plasma profiles
    ///   - geometry: Geometry for volume integration
    ///
    /// - Returns: Power balance with categorized components
    public static func compute(
        sources: SourceTerms,
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> PowerBalance {
        // Check if metadata is available
        if let metadata = sources.metadata {
            return computeFromMetadata(metadata)
        } else {
            return computeFromEstimation(sources, profiles, geometry)
        }
    }

    // MARK: - Phase 4a: Metadata-Based Computation (Accurate)

    /// Compute power balance from metadata (accurate)
    ///
    /// Phase 4a: Direct summation of tracked power components.
    /// No estimation needed.
    private static func computeFromMetadata(
        _ metadata: SourceMetadataCollection
    ) -> PowerBalance {
        PowerBalance(
            fusionPower: metadata.fusionPower,
            alphaPower: metadata.alphaPower,
            auxiliaryPower: metadata.auxiliaryPower,
            ohmicPower: metadata.ohmicPower,
            radiationPower: metadata.radiationPower
        )
    }

    // MARK: - Phase 3: Estimation-Based Computation (Fallback)

    /// Compute power balance from profiles (estimation fallback)
    ///
    /// Phase 3 compatibility: Fixed-ratio estimation when metadata unavailable.
    ///
    /// ⚠️ Limitations:
    /// - Assumes fusion produces 50% of total heating
    /// - Alpha power estimated as 20% of fusion power
    /// - Ohmic power estimated as 10% of total
    /// - Auxiliary power as residual
    ///
    /// Accuracy: ±20-50% (acceptable for engineering estimates)
    private static func computeFromEstimation(
        _ sources: SourceTerms,
        _ profiles: CoreProfiles,
        _ geometry: Geometry
    ) -> PowerBalance {
        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value

        // Total heating power density [MW/m^3]
        let ionHeating = sources.ionHeating.value
        let electronHeating = sources.electronHeating.value
        let totalHeatingDensity = ionHeating + electronHeating

        // Volume integral: ∫ P dV → [MW/m^3] × [m^3] = [MW]
        let totalHeatingMW = (totalHeatingDensity * volumes).sum()
        eval(totalHeatingMW)
        let P_total = totalHeatingMW.item(Float.self) * 1e6  // [MW] → [W]

        // Phase 3: Fixed-ratio estimation
        // Calculate fusion fraction from temperature (heuristic)
        let Ti_avg = profiles.ionTemperature.value.mean()
        let Te_avg = profiles.electronTemperature.value.mean()
        eval(Ti_avg, Te_avg)

        let T_avg = (Ti_avg.item(Float.self) + Te_avg.item(Float.self)) / 2.0  // [eV]

        // Fusion becomes significant above ~5 keV
        let fusionFraction: Float
        if T_avg > 5000 {  // > 5 keV
            fusionFraction = 0.5  // 50% fusion
        } else if T_avg > 2000 {  // 2-5 keV
            fusionFraction = 0.2  // 20% fusion
        } else {
            fusionFraction = 0.0  // No fusion
        }

        let P_fusion = P_total * fusionFraction
        let P_alpha = P_fusion * 0.2             // 20% of fusion power
        let P_ohmic = P_total * 0.1              // 10% ohmic
        let P_auxiliary = P_total - P_fusion - P_ohmic

        // Radiation losses (negative, rough estimate)
        // Bremsstrahlung ∝ n_e^2 * sqrt(T_e)
        let ne_avg = profiles.electronDensity.value.mean()
        eval(ne_avg)
        let ne = ne_avg.item(Float.self)  // [m^-3]

        // Rough bremsstrahlung estimate [W]
        let P_radiation = -1e-37 * ne * ne * Foundation.sqrt(T_avg)

        return PowerBalance(
            fusionPower: P_fusion,
            alphaPower: P_alpha,
            auxiliaryPower: P_auxiliary,
            ohmicPower: P_ohmic,
            radiationPower: P_radiation
        )
    }
}
