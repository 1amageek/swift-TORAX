// ITERBaselineDataTests.swift
// Tests for ITER Baseline reference data

import Testing
import Foundation
@testable import GotenxCore

@Suite("ITER Baseline Data Tests")
struct ITERBaselineDataTests {

    @Test("Load ITER Baseline data successfully")
    func loadBaseline() throws {
        let baseline = ITERBaselineData.load()

        // Verify geometry parameters
        #expect(baseline.geometry.majorRadius == 6.2, "Major radius should be 6.2 m")
        #expect(baseline.geometry.minorRadius == 2.0, "Minor radius should be 2.0 m")
        #expect(baseline.geometry.plasmaCurrent == 15.0, "Plasma current should be 15 MA")
        #expect(baseline.geometry.toroidalField == 5.3, "Toroidal field should be 5.3 T")
        #expect(baseline.geometry.elongation == 1.7, "Elongation should be 1.7")
        #expect(baseline.geometry.triangularity == 0.33, "Triangularity should be 0.33")
    }

    @Test("ITER Baseline profiles have correct shape")
    func profilesShape() throws {
        let baseline = ITERBaselineData.load()

        let nPoints = baseline.profiles.rho.count
        #expect(nPoints == 50, "Should have 50 radial points")
        #expect(baseline.profiles.Ti.count == nPoints, "Ti should have same length as rho")
        #expect(baseline.profiles.Te.count == nPoints, "Te should have same length as rho")
        #expect(baseline.profiles.ne.count == nPoints, "ne should have same length as rho")
    }

    @Test("ITER Baseline rho grid is normalized and monotonic")
    func rhoGrid() throws {
        let baseline = ITERBaselineData.load()
        let rho = baseline.profiles.rho

        // First point should be 0
        #expect(abs(rho[0] - 0.0) < 1e-6, "First rho should be 0")

        // Last point should be 1
        #expect(abs(rho[rho.count-1] - 1.0) < 1e-6, "Last rho should be 1")

        // Should be monotonically increasing
        for i in 1..<rho.count {
            #expect(rho[i] > rho[i-1], "rho should be monotonically increasing")
        }
    }

    @Test("ITER Baseline temperature profiles are peaked at core")
    func temperatureProfiles() throws {
        let baseline = ITERBaselineData.load()

        let Ti = baseline.profiles.Ti
        let Te = baseline.profiles.Te

        // Core temperature should be highest
        let Ti_core = Ti[0]
        let Ti_edge = Ti[Ti.count-1]
        #expect(Ti_core > Ti_edge, "Core temperature should be higher than edge")

        // Core should be ~20 keV = 20,000 eV
        #expect(abs(Ti_core - 20000.0) < 100.0, "Core Ti should be ~20 keV")

        // Edge should be ~100 eV
        #expect(abs(Ti_edge - 100.0) < 10.0, "Edge Ti should be ~100 eV")

        // Ti and Te should be equal (assumption)
        for i in 0..<Ti.count {
            #expect(abs(Ti[i] - Te[i]) < 1.0, "Ti and Te should be equal")
        }

        // Temperature should decrease monotonically
        for i in 1..<Ti.count {
            #expect(Ti[i] <= Ti[i-1], "Temperature should decrease outward")
        }
    }

    @Test("ITER Baseline density profiles are peaked at core")
    func densityProfiles() throws {
        let baseline = ITERBaselineData.load()

        let ne = baseline.profiles.ne

        // Core density should be highest
        let ne_core = ne[0]
        let ne_edge = ne[ne.count-1]
        #expect(ne_core > ne_edge, "Core density should be higher than edge")

        // Core should be ~1.0 × 10²⁰ m⁻³
        #expect(abs(ne_core - 1.0e20) < 1e19, "Core ne should be ~1.0×10²⁰ m⁻³")

        // Edge should be ~0.2 × 10²⁰ m⁻³
        #expect(abs(ne_edge - 0.2e20) < 1e18, "Edge ne should be ~0.2×10²⁰ m⁻³")

        // Density should decrease monotonically
        for i in 1..<ne.count {
            #expect(ne[i] <= ne[i-1], "Density should decrease outward")
        }
    }

    @Test("ITER Baseline global quantities are physically reasonable")
    func globalQuantities() throws {
        let baseline = ITERBaselineData.load()
        let global = baseline.globalQuantities

        // Q_fusion should be 10 (design goal)
        #expect(abs(global.Q_fusion - 10.0) < 0.1, "Q should be ~10")

        // P_fusion should be 400 MW
        #expect(abs(global.P_fusion - 400.0) < 50.0, "P_fusion should be ~400 MW")

        // P_alpha should be ~20% of P_fusion
        #expect(abs(global.P_alpha - 80.0) < 20.0, "P_alpha should be ~80 MW")

        // τE should be ~3.7 s
        #expect(abs(global.tau_E - 3.7) < 0.5, "τE should be ~3.7 s")

        // βN should be ~1.8
        #expect(abs(global.beta_N - 1.8) < 0.3, "βN should be ~1.8")
    }

    @Test("Validate global quantities - passing case")
    func validateGlobalQuantitiesPassing() throws {
        // Create reasonable global quantities
        let global = GlobalQuantities(
            P_fusion: 400.0,
            P_alpha: 80.0,
            tau_E: 3.5,
            beta_N: 2.0,
            Q_fusion: 10.0
        )

        let isValid = ITERBaselineData.validateGlobalQuantities(global)
        #expect(isValid, "Reasonable quantities should pass validation")
    }

    @Test("Validate global quantities - low Q fails")
    func validateGlobalQuantitiesLowQ() throws {
        // Q = 3 (too low)
        let global = GlobalQuantities(
            P_fusion: 150.0,
            P_alpha: 30.0,
            tau_E: 2.0,
            beta_N: 1.5,
            Q_fusion: 3.0
        )

        let isValid = ITERBaselineData.validateGlobalQuantities(global)
        #expect(!isValid, "Low Q should fail validation")
    }

    @Test("Validate global quantities - high βN fails")
    func validateGlobalQuantitiesHighBetaN() throws {
        // βN = 4.0 (MHD unstable)
        let global = GlobalQuantities(
            P_fusion: 400.0,
            P_alpha: 80.0,
            tau_E: 3.5,
            beta_N: 4.0,
            Q_fusion: 10.0
        )

        let isValid = ITERBaselineData.validateGlobalQuantities(global)
        #expect(!isValid, "High βN should fail validation")
    }

    @Test("Validate global quantities - low confinement fails")
    func validateGlobalQuantitiesLowConfinement() throws {
        // τE = 0.5 s (poor confinement)
        let global = GlobalQuantities(
            P_fusion: 100.0,
            P_alpha: 20.0,
            tau_E: 0.5,
            beta_N: 1.5,
            Q_fusion: 8.0
        )

        let isValid = ITERBaselineData.validateGlobalQuantities(global)
        #expect(!isValid, "Poor confinement should fail validation")
    }

    @Test("Profile time is at steady state")
    func profileTime() throws {
        let baseline = ITERBaselineData.load()

        // Time should be 2.0 s (steady state)
        #expect(abs(baseline.profiles.time - 2.0) < 0.1, "Time should be ~2.0 s")
    }

    @Test("Temperature profile has correct parabolic shape")
    func parabolicShape() throws {
        let baseline = ITERBaselineData.load()

        let rho = baseline.profiles.rho
        let Ti = baseline.profiles.Ti

        // Extract parameters
        let Ti_core = Ti[0]
        let Ti_edge = Ti[Ti.count-1]

        // Verify parabolic shape: Ti(r) = Ti_edge + (Ti_core - Ti_edge) × (1 - r²)²
        for i in 0..<rho.count {
            let r = rho[i]
            let Ti_expected = Ti_edge + (Ti_core - Ti_edge) * pow(1.0 - r*r, 2.0)
            let relativeError = abs(Ti[i] - Ti_expected) / Ti_expected

            #expect(relativeError < 0.01, "Temperature should follow parabolic profile at r = \(r)")
        }
    }

    @Test("Density profile has correct linear shape")
    func linearShape() throws {
        let baseline = ITERBaselineData.load()

        let rho = baseline.profiles.rho
        let ne = baseline.profiles.ne

        // Extract parameters
        let ne_core = ne[0]
        let ne_edge = ne[ne.count-1]

        // Verify linear shape: ne(r) = ne_edge + (ne_core - ne_edge) × (1 - r)
        for i in 0..<rho.count {
            let r = rho[i]
            let ne_expected = ne_edge + (ne_core - ne_edge) * (1.0 - r)
            let relativeError = abs(ne[i] - ne_expected) / ne_expected

            #expect(relativeError < 0.01, "Density should follow linear profile at r = \(r)")
        }
    }
}
