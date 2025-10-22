// EmptySourceConfigurationTests.swift
// Tests for empty source configuration (zero active sources)

import Testing
import MLX
@testable import GotenxCore
@testable import GotenxPhysics

/// Empty Source Configuration Tests
///
/// Verifies that the metadata pipeline handles configurations with:
/// - Zero active sources
/// - All sources disabled
/// - Error in all source computations
///
/// Without crashing in DEBUG builds.
@Suite("Empty Source Configuration Tests")
struct EmptySourceConfigurationTests {

    // MARK: - Test Helpers

    private func createTestGeometry() -> Geometry {
        let mesh = MeshConfig(
            nCells: 10,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.3,
            geometryType: .circular
        )
        return createGeometry(from: mesh, q0: 1.0, qEdge: 3.5)
    }

    private func createTestProfiles(nCells: Int) -> CoreProfiles {
        let Ti = [Float](repeating: 10000, count: nCells)
        let Te = [Float](repeating: 10000, count: nCells)
        let ne = [Float](repeating: 1e20, count: nCells)
        let psi = [Float](repeating: 0.0, count: nCells)

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(Ti)),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(Te)),
            electronDensity: EvaluatedArray(evaluating: MLXArray(ne)),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray(psi))
        )
    }

    // MARK: - Empty Source Configuration Tests

    @Test("Composite source with zero sources")
    func testCompositeWithZeroSources() {
        let geometry = createTestGeometry()
        let profiles = createTestProfiles(nCells: 10)

        // Create composite with empty source dict
        let composite = CompositeSourceModel(sources: [:])

        let params = SourceParameters(modelType: "composite", params: [:])
        let terms = composite.computeTerms(
            profiles: profiles,
            geometry: geometry,
            params: params
        )

        // Verify metadata is not nil (should be .empty)
        #expect(terms.metadata != nil, "Metadata should not be nil for zero sources")

        // Verify metadata is empty
        guard let metadata = terms.metadata else {
            Issue.record("Metadata is nil!")
            return
        }

        #expect(metadata.entries.isEmpty, "Metadata entries should be empty")

        // Verify all powers are zero
        #expect(metadata.fusionPower == 0)
        #expect(metadata.ohmicPower == 0)
        #expect(metadata.auxiliaryPower == 0)
        #expect(metadata.radiationPower == 0)
        #expect(metadata.alphaPower == 0)

        print("✅ Composite with zero sources test passed")
    }

    @Test("DerivedQuantities with empty source metadata")
    func testDerivedQuantitiesWithEmptyMetadata() {
        let geometry = createTestGeometry()
        let profiles = createTestProfiles(nCells: 10)

        // Create source terms with empty metadata
        let nCells = 10
        let zeros = EvaluatedArray.zeros([nCells])
        let sources = SourceTerms(
            ionHeating: zeros,
            electronHeating: zeros,
            particleSource: zeros,
            currentSource: zeros,
            metadata: SourceMetadataCollection.empty  // Empty metadata (no sources)
        )

        // This should NOT crash in DEBUG builds
        let derived = DerivedQuantitiesComputer.compute(
            profiles: profiles,
            geometry: geometry,
            transport: nil,
            sources: sources
        )

        // Verify power values are zero
        #expect(derived.P_fusion == 0, "Fusion power should be 0 with empty metadata")
        #expect(derived.P_ohmic == 0, "Ohmic power should be 0 with empty metadata")
        #expect(derived.P_auxiliary == 0, "Auxiliary power should be 0 with empty metadata")
        #expect(derived.P_alpha == 0, "Alpha power should be 0 with empty metadata")

        // Verify Q_fusion is 0 (no heating)
        #expect(derived.Q_fusion == 0, "Q_fusion should be 0 with no sources")

        print("✅ DerivedQuantities with empty metadata test passed")
    }

    @Test("Adapter error recovery with metadata")
    func testAdapterErrorRecovery() {
        // This test verifies that when a source model throws an error,
        // the adapter returns emptySourceTerms with SourceMetadataCollection.empty,
        // not nil metadata

        let nCells = 10
        let geometry = createTestGeometry()
        let profiles = createTestProfiles(nCells: nCells)

        // Test with OhmicHeatingSource (which can throw errors)
        let ohmicSource = OhmicHeatingSource()
        let params = SourceParameters(modelType: "ohmic", params: [:])

        let terms = ohmicSource.computeTerms(
            profiles: profiles,
            geometry: geometry,
            params: params
        )

        // Even if an error occurs, metadata should not be nil
        #expect(terms.metadata != nil, "Metadata should not be nil even on error")

        // This ensures DerivedQuantitiesComputer will not crash
        let derived = DerivedQuantitiesComputer.compute(
            profiles: profiles,
            geometry: geometry,
            sources: terms
        )

        // Powers should be >= 0 (either actual values or zero on error)
        #expect(derived.P_ohmic >= 0)

        print("✅ Adapter error recovery test passed")
    }

    @Test("Source-free simulation configuration")
    func testSourceFreeSimulation() {
        let geometry = createTestGeometry()
        let profiles = createTestProfiles(nCells: 10)

        // Simulate a source-free run (only transport, no sources)
        // This is a valid configuration for testing transport models

        let derived = DerivedQuantitiesComputer.compute(
            profiles: profiles,
            geometry: geometry,
            transport: nil,
            sources: nil  // No sources provided
        )

        // All power values should be zero
        #expect(derived.P_fusion == 0)
        #expect(derived.P_ohmic == 0)
        #expect(derived.P_auxiliary == 0)
        #expect(derived.P_alpha == 0)

        // Q_fusion should be 0
        #expect(derived.Q_fusion == 0)

        // Thermal energy should still be > 0 (from profiles)
        #expect(derived.W_thermal > 0)

        print("✅ Source-free simulation test passed")
    }

    @Test("Power balance with empty metadata")
    func testPowerBalanceWithEmptyMetadata() {
        let geometry = createTestGeometry()
        let profiles = createTestProfiles(nCells: 10)

        // Create sources with empty metadata
        let sources = SourceTerms(
            ionHeating: EvaluatedArray.zeros([10]),
            electronHeating: EvaluatedArray.zeros([10]),
            particleSource: EvaluatedArray.zeros([10]),
            currentSource: EvaluatedArray.zeros([10]),
            metadata: SourceMetadataCollection.empty
        )

        // Compute derived quantities
        let derived = DerivedQuantitiesComputer.compute(
            profiles: profiles,
            geometry: geometry,
            sources: sources
        )

        // Verify all computed powers are zero
        let totalPower = derived.P_fusion + derived.P_auxiliary + derived.P_ohmic

        #expect(totalPower == 0, "Total power should be 0 with empty metadata")
        #expect(derived.Q_fusion == 0, "Q should be 0 with no sources")

        print("✅ Power balance with empty metadata test passed")
        print("   P_fusion: \(derived.P_fusion) MW")
        print("   P_auxiliary: \(derived.P_auxiliary) MW")
        print("   P_ohmic: \(derived.P_ohmic) MW")
        print("   Q_fusion: \(derived.Q_fusion)")
    }
}
