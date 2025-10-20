// SawtoothModel.swift
// Sawtooth crash model for tokamak MHD instabilities

import Foundation
import MLX

/// Sawtooth crash model
///
/// Sawteeth are periodic MHD instabilities that occur when the safety factor q(0) < 1.
/// They cause rapid redistribution (flattening) of core profiles within the inversion radius.
///
/// References:
/// - Kadomtsev reconnection model
/// - Porcelli model for sawtooth trigger
public struct SawtoothModel: MHDModel {
    public let params: SawtoothParameters

    public init(params: SawtoothParameters) {
        self.params = params
    }

    public func apply(
        to profiles: CoreProfiles,
        geometry: Geometry,
        time: Float,
        dt: Float
    ) -> CoreProfiles {
        // Check if sawtooth crash should occur
        guard shouldTriggerCrash(profiles: profiles, geometry: geometry, dt: dt) else {
            return profiles
        }

        // Apply crash
        return applyCrash(to: profiles, geometry: geometry, dt: dt)
    }

    /// Determine if sawtooth crash should occur
    ///
    /// Crash occurs when:
    /// 1. q(0) < q_critical (typically 1.0)
    /// 2. Timestep is large enough to resolve crash interval
    ///
    /// ## Rate Limiting
    ///
    /// Since we cannot track state between calls (Sendable requirement),
    /// we use a deterministic rate limit: only allow crashes when
    /// dt ≥ minCrashInterval. This prevents unphysical rapid crashes
    /// when using small timesteps.
    ///
    /// ## Physical Justification
    ///
    /// - Sawtooth period: ~10-100 ms (experimental)
    /// - Crash duration: ~100 μs (fast MHD)
    /// - If dt < minCrashInterval, the timestep doesn't resolve
    ///   the crash cycle → skip crash application
    private func shouldTriggerCrash(
        profiles: CoreProfiles,
        geometry: Geometry,
        dt: Float
    ) -> Bool {
        // Compute safety factor q on axis
        // For now, use simplified model based on current and temperature
        // Future: integrate full q = (r B_phi) / (R B_theta) from equilibrium

        // Simplified q(0) estimate from plasma current and temperature gradient
        // High central current + peaked temperature → low q(0)

        // Placeholder: trigger randomly for demonstration
        // Real implementation requires q-profile calculation from current diffusion
        let qOnAxis = estimateQOnAxis(profiles: profiles, geometry: geometry)

        // Physical condition: q(0) < q_critical
        guard qOnAxis < params.qCritical else {
            return false
        }

        // Rate limiting: only crash if timestep resolves the crash interval
        // This prevents unphysical rapid crashes when dt << minCrashInterval
        return dt >= params.minCrashInterval
    }

    /// Apply sawtooth crash to profiles
    ///
    /// The crash flattens profiles within the inversion radius:
    /// - Temperature profiles are averaged
    /// - Density profiles are averaged
    /// - Process occurs on fast MHD timescale (~ mixing_time)
    private func applyCrash(
        to profiles: CoreProfiles,
        geometry: Geometry,
        dt: Float
    ) -> CoreProfiles {
        // Compute normalized radial coordinate: rho_norm = r / a
        let rhoNorm = geometry.radii.value / geometry.minorRadius

        // Find inversion radius index
        let inversionIndex = findInversionIndex(rhoNorm: rhoNorm)

        // Flatten profiles within inversion radius
        let Ti_flattened = flattenProfile(
            profiles.ionTemperature.value,
            upToIndex: inversionIndex,
            mixingFraction: dt / params.mixingTime
        )

        let Te_flattened = flattenProfile(
            profiles.electronTemperature.value,
            upToIndex: inversionIndex,
            mixingFraction: dt / params.mixingTime
        )

        let ne_flattened = flattenProfile(
            profiles.electronDensity.value,
            upToIndex: inversionIndex,
            mixingFraction: dt / params.mixingTime
        )

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti_flattened),
            electronTemperature: EvaluatedArray(evaluating: Te_flattened),
            electronDensity: EvaluatedArray(evaluating: ne_flattened),
            poloidalFlux: profiles.poloidalFlux  // Flux not affected by sawteeth
        )
    }

    /// Find grid index corresponding to inversion radius
    private func findInversionIndex(rhoNorm: MLXArray) -> Int {
        let rhoArray = rhoNorm.asArray(Float.self)

        for (index, rho) in rhoArray.enumerated() {
            if rho > params.inversionRadius {
                return max(1, index)  // At least 1 to have a region
            }
        }

        return rhoArray.count / 3  // Fallback: inner 1/3
    }

    /// Flatten profile within specified index
    ///
    /// Profiles are gradually mixed toward their volume-averaged value
    /// with a timescale given by mixing_time.
    private func flattenProfile(
        _ profile: MLXArray,
        upToIndex: Int,
        mixingFraction: Float
    ) -> MLXArray {
        // Extract inner region
        let innerRegion = profile[..<upToIndex]

        // Compute volume-averaged value
        let averageValue = innerRegion.mean()

        // Clamp mixing fraction to [0, 1] to prevent overshoot
        let clampedFraction = min(1.0, max(0.0, mixingFraction))

        // Mix toward average: profile_new = profile + mixing_fraction * (avg - profile)
        let innerFlattened = innerRegion + clampedFraction * (averageValue - innerRegion)

        // Reconstruct full profile
        let outerRegion = profile[upToIndex...]

        return concatenated([innerFlattened, outerRegion], axis: 0)
    }

    /// Estimate safety factor on axis
    ///
    /// Simplified model: q(0) ~ B_phi R / (r B_theta) ~ 1 / (j_parallel R / B_phi)
    ///
    /// For peaked current profile (high j_parallel at center), q(0) is low.
    /// Trigger based on temperature peaking as a proxy.
    private func estimateQOnAxis(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> Float {
        // Temperature peaking factor: T(0) / <T>
        let Ti = profiles.ionTemperature.value
        let TiCore = Ti[0].item(Float.self)
        let TiAvg = Ti.mean().item(Float.self)

        let peakingFactor = TiCore / (TiAvg + 1e-10)

        // High peaking → low q(0)
        // Roughly: q(0) ~ 1 / peaking_factor
        let qEstimate = 1.0 / (peakingFactor + 0.1)

        return qEstimate
    }
}

// MARK: - Helper Functions

extension SawtoothModel {
    /// Check if sawtooth model is active
    public var isActive: Bool {
        return true  // Always active if model is created
    }
}
