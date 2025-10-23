// SawtoothTriggerTests.swift
// Tests for sawtooth crash trigger model

import Testing
import Foundation
import MLX
@testable import GotenxCore

/// Tests for SimpleSawtoothTrigger
@Suite("Sawtooth Trigger Tests")
struct SawtoothTriggerTests {

    /// Test that crash is triggered when q < 1 and all conditions are met
    @Test("Crash triggered when q < 1 and conditions met")
    func triggerWhenQBelowOne() throws {
        let trigger = SimpleSawtoothTrigger(
            minimumRadius: 0.2,
            sCritical: 0.2,
            minCrashInterval: 0.01
        )

        // Create profiles with q < 1 in the core
        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createProfilesWithLowQ(nCells: nCells, geometry: geometry)

        // Use timestep that passes rate limiting
        let dt: Float = 0.02  // > minCrashInterval

        let (triggered, rhoQ1) = trigger.shouldTrigger(
            profiles: profiles,
            geometry: geometry,
            dt: dt
        )

        #expect(triggered, "Crash should be triggered when q < 1")
        #expect(rhoQ1 != nil, "q=1 surface location should be returned")
        if let rhoQ1 = rhoQ1 {
            #expect(rhoQ1 > 0.2, "q=1 surface should be beyond minimum radius")
            #expect(rhoQ1 < 1.0, "q=1 surface should be inside plasma")
        }
    }

    /// Test that crash is NOT triggered when q > 1 everywhere
    @Test("No crash when q > 1 everywhere")
    func noTriggerWhenQAboveOne() throws {
        let trigger = SimpleSawtoothTrigger()

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createProfilesWithHighQ(nCells: nCells, geometry: geometry)

        let dt: Float = 0.02

        let (triggered, _) = trigger.shouldTrigger(
            profiles: profiles,
            geometry: geometry,
            dt: dt
        )

        #expect(!triggered, "Crash should NOT be triggered when q > 1 everywhere")
    }

    /// Test rate limiting: crash should NOT occur if dt < minCrashInterval
    @Test("Rate limiting prevents rapid crashes")
    func rateLimiting() throws {
        let trigger = SimpleSawtoothTrigger(
            minimumRadius: 0.2,
            sCritical: 0.2,
            minCrashInterval: 0.01
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createProfilesWithLowQ(nCells: nCells, geometry: geometry)

        // Use timestep smaller than minCrashInterval
        let dt: Float = 0.005  // < minCrashInterval

        let (triggered, _) = trigger.shouldTrigger(
            profiles: profiles,
            geometry: geometry,
            dt: dt
        )

        #expect(!triggered, "Crash should NOT be triggered when dt < minCrashInterval")
    }

    /// Test minimum radius condition: crash should NOT occur if q=1 surface is too close to axis
    @Test("Minimum radius condition prevents crashes near axis")
    func minimumRadiusCondition() throws {
        let trigger = SimpleSawtoothTrigger(
            minimumRadius: 0.8,  // Very large minimum radius
            sCritical: 0.0,       // No shear requirement
            minCrashInterval: 0.01
        )

        let nCells = 50
        let geometry = createTestGeometry(nCells: nCells)
        let profiles = createProfilesWithLowQ(nCells: nCells, geometry: geometry)

        let dt: Float = 0.02

        let (triggered, rhoQ1) = trigger.shouldTrigger(
            profiles: profiles,
            geometry: geometry,
            dt: dt
        )

        #expect(!triggered, "Crash should NOT be triggered when q=1 surface is below minimum radius")
        #expect(rhoQ1 != nil, "q=1 surface location should still be returned")
    }

    // MARK: - Helper Functions

    /// Create simple circular geometry for testing
    private func createTestGeometry(nCells: Int) -> Geometry {
        let majorRadius: Float = 6.2  // ITER-like
        let minorRadius: Float = 2.0

        // Simple radial grid
        let radii = MLXArray.linspace(Float(0.0), minorRadius, count: nCells)

        // Simple volume: V(r) ∝ r²
        let volume = radii * radii * Float.pi * majorRadius

        // Simple safety factor profile: q(r) = q0 + (qEdge - q0) * (r/a)²
        let rhoNorm = radii / minorRadius
        let q0: Float = 0.8  // q < 1 on axis
        let qEdge: Float = 3.5
        let safetyFactor = q0 + (qEdge - q0) * rhoNorm * rhoNorm

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

    /// Create profiles that result in q < 1 (peaked current)
    private func createProfilesWithLowQ(nCells: Int, geometry: Geometry) -> CoreProfiles {
        // Create peaked profiles
        let rhoNorm = geometry.radii.value / geometry.minorRadius

        // Parabolic temperature profile
        let Ti = 10000.0 * (1.0 - rhoNorm * rhoNorm)  // 10 keV on axis
        let Te = Ti  // Same for simplicity

        // Parabolic density profile
        let ne = 1e20 * (1.0 - 0.5 * rhoNorm * rhoNorm)  // 10²⁰ m⁻³

        // Create poloidal flux with high central current (q < 1)
        // ψ(ρ) chosen such that dψ/dr gives high B_θ at center
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )
    }

    /// Create profiles that result in q > 1 everywhere
    private func createProfilesWithHighQ(nCells: Int, geometry: Geometry) -> CoreProfiles {
        // Create less peaked profiles
        let rhoNorm = geometry.radii.value / geometry.minorRadius

        let Ti = 5000.0 * (1.0 - 0.5 * rhoNorm * rhoNorm)
        let Te = Ti
        let ne = 5e19 * (1.0 - 0.3 * rhoNorm * rhoNorm)

        // Lower central current (q > 1)
        let psi = 0.5 * rhoNorm * rhoNorm

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )
    }
}
