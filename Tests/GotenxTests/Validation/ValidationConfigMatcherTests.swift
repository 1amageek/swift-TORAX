// ValidationConfigMatcherTests.swift
// Tests for validation configuration matching

import Testing
import Foundation
@testable import Gotenx

@Suite("Validation Config Matcher Tests")
struct ValidationConfigMatcherTests {

    @Test("Match configuration to ITER Baseline")
    func matchToITERBaseline() throws {
        let config = ValidationConfigMatcher.matchToITERBaseline()

        // Verify mesh configuration
        #expect(config.runtime.static.mesh.nCells == 50, "Should use 50 cells")
        #expect(config.runtime.static.mesh.majorRadius == 6.2, "Major radius should be 6.2 m")
        #expect(config.runtime.static.mesh.minorRadius == 2.0, "Minor radius should be 2.0 m")
        #expect(config.runtime.static.mesh.toroidalField == 5.3, "Toroidal field should be 5.3 T")

        // Verify evolution configuration
        #expect(config.runtime.static.evolution.ionHeat, "Ion heat should evolve")
        #expect(config.runtime.static.evolution.electronHeat, "Electron heat should evolve")
        #expect(config.runtime.static.evolution.density, "Density should evolve")
        #expect(!config.runtime.static.evolution.current, "Current should not evolve")

        // Verify solver configuration
        #expect(config.runtime.static.solver.type == "newton_raphson", "Should use Newton-Raphson solver")
        #expect(config.runtime.static.solver.tolerance == 1e-6, "Tolerance should be 1e-6")

        // Verify time configuration
        #expect(config.time.start == 0.0, "Start time should be 0")
        #expect(config.time.end == 2.0, "End time should be 2s")

        // Verify transport model
        #expect(config.runtime.dynamic.transport.modelType == .bohmGyrobohm, "Should use Bohm-GyroBohm")

        // Verify sources
        #expect(config.runtime.dynamic.sources.ohmicHeating, "Ohmic heating should be enabled")
        #expect(config.runtime.dynamic.sources.fusionPower, "Fusion power should be enabled")
        #expect(config.runtime.dynamic.sources.ionElectronExchange, "Ion-electron exchange should be enabled")
        #expect(config.runtime.dynamic.sources.bremsstrahlung, "Bremsstrahlung should be enabled")
    }

    @Test("Match configuration to TORAX reference data")
    func matchToTorax() throws {
        // Create mock TORAX data
        let time: [Float] = Array(stride(from: 0.0, through: 2.0, by: 0.02))  // 101 points
        let rho: [Float] = Array(stride(from: 0.0, through: 1.0, by: 0.01))   // 101 points

        let nTime = time.count
        let nRho = rho.count

        // Create mock profiles
        let profiles = (0..<nTime).map { _ in
            Array(repeating: Float(1000), count: nRho)
        }

        let toraxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: profiles,
            Te: profiles,
            ne: profiles
        )

        let config = try ValidationConfigMatcher.matchToTorax(toraxData)

        // Verify mesh matches TORAX
        #expect(config.runtime.static.mesh.nCells == nRho, "Mesh size should match TORAX rho grid")

        // Verify time range matches TORAX
        #expect(config.time.start == 0.0, "Start time should match TORAX")
        #expect(config.time.end == 2.0, "End time should match TORAX")

        // Verify save interval matches TORAX sampling
        let expectedInterval = 2.0 / Float(nTime - 1)
        #expect(abs(config.output.saveInterval! - expectedInterval) < 1e-6, "Save interval should match TORAX")
    }

    @Test("ValidationConfigError for invalid mesh size")
    func invalidMeshSize() throws {
        // Create TORAX data with too few cells
        let time: [Float] = [0.0, 1.0, 2.0]
        let rho: [Float] = [0.0, 0.5, 1.0]  // Only 3 cells (< 10 minimum)

        let profiles = (0..<3).map { _ in [Float(1000), 500, 100] }

        let toraxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: profiles,
            Te: profiles,
            ne: profiles
        )

        #expect(throws: ValidationConfigError.self) {
            try ValidationConfigMatcher.matchToTorax(toraxData)
        }
    }

    @Test("ValidationConfigError for empty time array")
    func emptyTimeArray() throws {
        // Create TORAX data with empty time array
        let time: [Float] = []
        let rho: [Float] = [0.0, 1.0]

        let toraxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: [],
            Te: [],
            ne: []
        )

        #expect(throws: ValidationConfigError.self) {
            try ValidationConfigMatcher.matchToTorax(toraxData)
        }
    }

    @Test("Compare with TORAX reference data")
    func compareWithTorax() throws {
        // Create mock reference data with sufficient points (10) for correlation
        let time: [Float] = [0.0, 1.0, 2.0]
        let rho: [Float] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]  // 11 points

        // Temperature profiles (parabolic)
        let Ti_ref: [[Float]] = [
            [10000, 9500, 8500, 7000, 5500, 4000, 2800, 1800, 1000, 500, 100],
            [12000, 11400, 10200, 8400, 6600, 4800, 3360, 2160, 1200, 600, 120],
            [15000, 14250, 12750, 10500, 8250, 6000, 4200, 2700, 1500, 750, 150]
        ]

        let Te_ref = Ti_ref

        // Density profiles (linear)
        let ne_ref: [[Float]] = [
            [1.0e20, 0.9e20, 0.8e20, 0.7e20, 0.6e20, 0.5e20, 0.4e20, 0.3e20, 0.2e20, 0.15e20, 0.1e20],
            [1.1e20, 0.99e20, 0.88e20, 0.77e20, 0.66e20, 0.55e20, 0.44e20, 0.33e20, 0.22e20, 0.165e20, 0.11e20],
            [1.2e20, 1.08e20, 0.96e20, 0.84e20, 0.72e20, 0.6e20, 0.48e20, 0.36e20, 0.24e20, 0.18e20, 0.12e20]
        ]

        let toraxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: Ti_ref,
            Te: Te_ref,
            ne: ne_ref
        )

        // Create mock Gotenx output (0.5% difference)
        let Ti_gotenx: [[Float]] = Ti_ref.map { profile in
            profile.map { $0 * 1.005 }  // 0.5% higher
        }

        let Te_gotenx = Ti_gotenx

        let ne_gotenx: [[Float]] = ne_ref.map { profile in
            profile.map { $0 * 1.01 }  // 1% higher
        }

        let gotenxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: Ti_gotenx,
            Te: Te_gotenx,
            ne: ne_gotenx
        )

        // Compare
        let results = ValidationConfigMatcher.compareWithTorax(
            gotenx: gotenxData,
            torax: toraxData,
            thresholds: .torax
        )

        // Should have 9 results (3 quantities × 3 time points)
        #expect(results.count == 9, "Should have 9 comparison results")

        // All should pass (small differences)
        let allPassed = results.allSatisfy { $0.passed }
        #expect(allPassed, "All comparisons should pass with small differences")
    }

    @Test("Compare with large differences fails validation")
    func compareWithLargeDifferences() throws {
        // Create mock reference data
        let time: [Float] = [0.0, 1.0]
        let rho: [Float] = [0.0, 1.0]

        let Ti_ref: [[Float]] = [
            [10000, 100],
            [12000, 120]
        ]

        let Te_ref = Ti_ref
        let ne_ref: [[Float]] = [
            [1e20, 1e19],
            [1.1e20, 1.1e19]
        ]

        let toraxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: Ti_ref,
            Te: Te_ref,
            ne: ne_ref
        )

        // Create Gotenx output with large differences (50% higher)
        let Ti_gotenx: [[Float]] = [
            [15000, 150],
            [18000, 180]
        ]

        let Te_gotenx = Ti_gotenx
        let ne_gotenx: [[Float]] = [
            [1.5e20, 1.5e19],
            [1.65e20, 1.65e19]
        ]

        let gotenxData = ToraxReferenceData(
            time: time,
            rho: rho,
            Ti: Ti_gotenx,
            Te: Te_gotenx,
            ne: ne_gotenx
        )

        // Compare
        let results = ValidationConfigMatcher.compareWithTorax(
            gotenx: gotenxData,
            torax: toraxData,
            thresholds: .torax
        )

        // Should have 6 results (3 quantities × 2 time points)
        #expect(results.count == 6, "Should have 6 comparison results")

        // All should fail (large differences)
        let anyPassed = results.contains { $0.passed }
        #expect(!anyPassed, "No comparisons should pass with 50% differences")
    }

    @Test("ValidationConfigError descriptions")
    func validationConfigErrorDescriptions() throws {
        let error1 = ValidationConfigError.invalidMeshSize(5)
        #expect(error1.description.contains("5"))
        #expect(error1.description.contains("10-200"))

        let error2 = ValidationConfigError.emptyTimeArray
        #expect(error2.description.contains("empty"))

        let error3 = ValidationConfigError.incompatibleTimeRanges("test message")
        #expect(error3.description.contains("test message"))
    }
}
