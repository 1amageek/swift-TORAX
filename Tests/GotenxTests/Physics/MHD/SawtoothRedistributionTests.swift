// SawtoothRedistributionTests.swift
// Tests for sawtooth profile redistribution with conservation

import Testing
import Foundation
import MLX
@testable import GotenxCore

/// Tests for SimpleSawtoothRedistribution
@Suite("Sawtooth Redistribution Tests")
struct SawtoothRedistributionTests {

    /// Test particle conservation during redistribution
    @Test("Particle number is conserved during crash")
    func particleConservation() throws {
        let redistribution = SimpleSawtoothRedistribution(
            flatteningFactor: 1.01,
            mixingRadiusMultiplier: 1.5
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createPeakedProfiles(nCells: nCells, geometry: geometry)
        let rhoQ1: Float = 0.4  // q=1 surface at 40% of minor radius

        // Compute total particles before crash
        let ne_before = profiles.electronDensity.value
        let volume = geometry.volume.value
        let N_before = sum(ne_before * volume).item(Float.self)

        // Apply redistribution
        let redistributed = redistribution.redistribute(
            profiles: profiles,
            geometry: geometry,
            rhoQ1: rhoQ1
        )

        // Compute total particles after crash
        let ne_after = redistributed.electronDensity.value
        let N_after = sum(ne_after * volume).item(Float.self)

        // Check conservation (within 1%)
        let relativeDifference = abs(N_after - N_before) / N_before
        #expect(relativeDifference < 0.01, "Particle number should be conserved within 1%")
    }

    /// Test ion energy conservation during redistribution
    @Test("Ion thermal energy is conserved during crash")
    func ionEnergyConservation() throws {
        let redistribution = SimpleSawtoothRedistribution(
            flatteningFactor: 1.01,
            mixingRadiusMultiplier: 1.5
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createPeakedProfiles(nCells: nCells, geometry: geometry)
        let rhoQ1: Float = 0.4

        // Compute total ion thermal energy before crash
        let Ti_before = profiles.ionTemperature.value
        let ne = profiles.electronDensity.value
        let volume = geometry.volume.value
        let W_i_before = sum(Ti_before * ne * volume).item(Float.self)

        // Apply redistribution
        let redistributed = redistribution.redistribute(
            profiles: profiles,
            geometry: geometry,
            rhoQ1: rhoQ1
        )

        // Compute total ion thermal energy after crash
        let Ti_after = redistributed.ionTemperature.value
        let W_i_after = sum(Ti_after * ne * volume).item(Float.self)

        // Check conservation (within 1%)
        let relativeDifference = abs(W_i_after - W_i_before) / W_i_before
        #expect(relativeDifference < 0.01, "Ion thermal energy should be conserved within 1%")
    }

    /// Test electron energy conservation during redistribution
    @Test("Electron thermal energy is conserved during crash")
    func electronEnergyConservation() throws {
        let redistribution = SimpleSawtoothRedistribution(
            flatteningFactor: 1.01,
            mixingRadiusMultiplier: 1.5
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createPeakedProfiles(nCells: nCells, geometry: geometry)
        let rhoQ1: Float = 0.4

        // Compute total electron thermal energy before crash
        let Te_before = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value
        let volume = geometry.volume.value
        let W_e_before = sum(Te_before * ne * volume).item(Float.self)

        // Apply redistribution
        let redistributed = redistribution.redistribute(
            profiles: profiles,
            geometry: geometry,
            rhoQ1: rhoQ1
        )

        // Compute total electron thermal energy after crash
        let Te_after = redistributed.electronTemperature.value
        let W_e_after = sum(Te_after * ne * volume).item(Float.self)

        // Check conservation (within 1%)
        let relativeDifference = abs(W_e_after - W_e_before) / W_e_before
        #expect(relativeDifference < 0.01, "Electron thermal energy should be conserved within 1%")
    }

    /// Test that profiles are flattened in the core
    @Test("Profiles are flattened within q=1 surface")
    func profileFlattening() throws {
        let redistribution = SimpleSawtoothRedistribution(
            flatteningFactor: 1.01,
            mixingRadiusMultiplier: 1.5
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createPeakedProfiles(nCells: nCells, geometry: geometry)
        let rhoQ1: Float = 0.4

        // Apply redistribution
        let redistributed = redistribution.redistribute(
            profiles: profiles,
            geometry: geometry,
            rhoQ1: rhoQ1
        )

        // Check that temperature profile is flatter in the core
        let Ti_before = profiles.ionTemperature.value.asArray(Float.self)
        let Ti_after = redistributed.ionTemperature.value.asArray(Float.self)

        // Temperature gradient should be reduced in the core
        let gradientBefore = abs(Ti_before[5] - Ti_before[0])
        let gradientAfter = abs(Ti_after[5] - Ti_after[0])

        #expect(gradientAfter < gradientBefore, "Temperature gradient should be reduced after crash")
    }

    /// Test that outer region is unchanged
    @Test("Profiles unchanged outside mixing radius")
    func outerRegionUnchanged() throws {
        let redistribution = SimpleSawtoothRedistribution(
            flatteningFactor: 1.01,
            mixingRadiusMultiplier: 1.5
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createPeakedProfiles(nCells: nCells, geometry: geometry)
        let rhoQ1: Float = 0.3  // Small q=1 surface

        // Apply redistribution
        let redistributed = redistribution.redistribute(
            profiles: profiles,
            geometry: geometry,
            rhoQ1: rhoQ1
        )

        // Check that outer region (beyond mixing radius) is unchanged
        let rhoNorm = geometry.radii.value.asArray(Float.self).map { $0 / geometry.minorRadius }
        let rhoMix = rhoQ1 * redistribution.mixingRadiusMultiplier

        let Ti_before = profiles.ionTemperature.value.asArray(Float.self)
        let Ti_after = redistributed.ionTemperature.value.asArray(Float.self)

        // Find index beyond mixing radius
        var outerIndex = nCells - 1
        for (i, rho) in rhoNorm.enumerated() {
            if rho > rhoMix {
                outerIndex = i
                break
            }
        }

        // Check that far outer region is unchanged (allowing small numerical errors)
        if outerIndex < nCells - 1 {
            let outerDifference = abs(Ti_after[nCells - 1] - Ti_before[nCells - 1])
            #expect(outerDifference < 1.0, "Outer region temperature should be nearly unchanged")
        }
    }

    // MARK: - Helper Functions

    /// Create simple circular geometry for testing
    private func createTestGeometry(nCells: Int) -> Geometry {
        let majorRadius: Float = 6.2  // ITER-like
        let minorRadius: Float = 2.0

        // Simple radial grid
        let radii = MLXArray.linspace(Float(0.0), minorRadius, count: nCells)

        // Simple volume: V(r) ∝ r² for circular cross-section
        let volume = radii * radii * Float.pi * majorRadius

        // Simple safety factor profile
        let rhoNorm = radii / minorRadius
        let safetyFactor = 1.0 + 2.5 * rhoNorm * rhoNorm

        // Geometry coefficients (simplified)
        let g0 = MLXArray.ones([nCells])
        let g1 = MLXArray.ones([nCells])
        let g2 = radii
        let g3 = radii * radii

        return Geometry(
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.3,
            volume: EvaluatedArray(evaluating: volume),
            g0: EvaluatedArray(evaluating: g0),
            g1: EvaluatedArray(evaluating: g1),
            g2: EvaluatedArray(evaluating: g2),
            g3: EvaluatedArray(evaluating: g3),
            radii: EvaluatedArray(evaluating: radii),
            safetyFactor: EvaluatedArray(evaluating: safetyFactor),
            type: .circular
        )
    }

    /// Create peaked profiles for testing
    private func createPeakedProfiles(nCells: Int, geometry: Geometry) -> CoreProfiles {
        let rhoNorm = geometry.radii.value / geometry.minorRadius

        // Highly peaked parabolic temperature profile
        let Ti = 15000.0 * (1.0 - rhoNorm * rhoNorm)  // 15 keV on axis
        let Te = Ti  // Same for simplicity

        // Peaked density profile
        let ne = 1.2e20 * (1.0 - 0.5 * rhoNorm * rhoNorm)  // 1.2×10²⁰ m⁻³ on axis

        // Parabolic poloidal flux
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )
    }
}
