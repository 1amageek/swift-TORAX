import Testing
import MLX
@testable import GotenxCore
@testable import GotenxPhysics

/// Integration tests for IonElectronExchange robustness (Sprint 1)
///
/// Tests verify the crash prevention fixes from NUMERICAL_ROBUSTNESS_DESIGN.md:
/// 1. Input validation with ValidatedProfiles
/// 2. Output validation (NaN/Inf detection)
/// 3. Fail-safe behavior (return current sources on failure)
/// 4. Metadata preservation in fail-safe path
///
/// Critical crash scenario reproduced from production log:
/// - Missing electron temperature initialization → NaN in Q_ie → crash
@Suite("IonElectronExchange Robustness Tests (Sprint 1)")
struct IonElectronExchangeRobustnessTests {

    // MARK: - Test Helpers

    /// Create valid test profiles
    func createValidProfiles(nCells: Int = 100) -> CoreProfiles {
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )
    }

    /// Create test source terms
    func createTestSources(nCells: Int = 100) -> SourceTerms {
        let zeros = MLXArray.zeros([nCells])
        return SourceTerms(
            ionHeating: EvaluatedArray(evaluating: zeros),
            electronHeating: EvaluatedArray(evaluating: zeros),
            particleSource: EvaluatedArray(evaluating: zeros),
            currentSource: EvaluatedArray(evaluating: zeros),
            metadata: nil
        )
    }

    /// Create test geometry
    func createTestGeometry(nCells: Int = 100) -> Geometry {
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.0
        )
        return Geometry(config: meshConfig)
    }

    // MARK: - Normal Operation Tests

    @Test("IonElectronExchange processes valid profiles normally")
    func testValidProfilesNormalOperation() throws {
        let model = IonElectronExchange()
        let profiles = createValidProfiles()
        let sources = createTestSources()
        let geometry = createTestGeometry()

        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Should produce valid output
        let ionHeating_min = result.ionHeating.value.min().item(Float.self)
        let ionHeating_max = result.ionHeating.value.max().item(Float.self)

        #expect(!ionHeating_min.isNaN)
        #expect(!ionHeating_min.isInfinite)
        #expect(!ionHeating_max.isNaN)
        #expect(!ionHeating_max.isInfinite)

        // Metadata should be present
        #expect(result.metadata != nil)
        #expect(result.metadata?.entries.count == 1)
        #expect(result.metadata?.entries[0].modelName == "ion_electron_exchange")
    }

    // MARK: - Crash Scenario Reproduction (Production Bug)

    @Test("IonElectronExchange handles NaN electron temperature gracefully")
    func testNaNElectronTemperature() throws {
        let model = IonElectronExchange()
        let nCells = 100

        // Reproduce production crash: Te = NaN (missing initialization)
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ Production crash scenario
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let sources = createTestSources(nCells: nCells)
        let geometry = createTestGeometry(nCells: nCells)

        // Phase 1b fix: Should NOT crash, should return current sources unchanged
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Verify fail-safe behavior: sources unchanged
        let ionHeating_sum = result.ionHeating.value.sum().item(Float.self)
        #expect(ionHeating_sum == 0.0)  // Original sources were zero, should remain zero

        let electronHeating_sum = result.electronHeating.value.sum().item(Float.self)
        #expect(electronHeating_sum == 0.0)

        // Metadata should be preserved (no crash)
        // Note: In fail-safe path, we don't add new metadata
        #expect(result.metadata == nil)  // Original sources had no metadata
    }

    @Test("IonElectronExchange handles Inf ion temperature gracefully")
    func testInfIonTemperature() throws {
        let model = IonElectronExchange()
        let nCells = 100

        let Ti = MLXArray.full([nCells], values: MLXArray(Float.infinity))  // ❌ Inf
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let sources = createTestSources(nCells: nCells)
        let geometry = createTestGeometry(nCells: nCells)

        // Should NOT crash, should return current sources unchanged
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Verify fail-safe behavior
        let ionHeating_sum = result.ionHeating.value.sum().item(Float.self)
        #expect(ionHeating_sum == 0.0)
    }

    @Test("IonElectronExchange handles zero electron density gracefully")
    func testZeroElectronDensity() throws {
        let model = IonElectronExchange()
        let nCells = 100

        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(0.0)))  // ❌ Zero (invalid)
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let sources = createTestSources(nCells: nCells)
        let geometry = createTestGeometry(nCells: nCells)

        // Should NOT crash, should return current sources unchanged
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Verify fail-safe behavior
        let ionHeating_sum = result.ionHeating.value.sum().item(Float.self)
        #expect(ionHeating_sum == 0.0)
    }

    // MARK: - Fail-Safe Metadata Preservation

    @Test("IonElectronExchange preserves existing metadata on fail-safe")
    func testFailSafePreservesMetadata() throws {
        let model = IonElectronExchange()
        let nCells = 100

        // Create invalid profiles (NaN Te)
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float.nan))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        // Create sources with existing metadata
        let existingMetadata = SourceMetadata(
            modelName: "fusion",
            category: .fusion,
            ionPower: 100.0,
            electronPower: 200.0
        )

        let zeros = MLXArray.zeros([nCells])
        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: zeros),
            electronHeating: EvaluatedArray(evaluating: zeros),
            particleSource: EvaluatedArray(evaluating: zeros),
            currentSource: EvaluatedArray(evaluating: zeros),
            metadata: SourceMetadataCollection(entries: [existingMetadata])
        )

        let geometry = createTestGeometry(nCells: nCells)

        // Apply with invalid profiles (should fail-safe)
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Verify metadata preserved
        #expect(result.metadata != nil)
        #expect(result.metadata?.entries.count == 1)
        #expect(result.metadata?.entries[0].modelName == "fusion")
        #expect(result.metadata?.entries[0].ionPower == 100.0)
    }

    // MARK: - Edge Cases

    @Test("IonElectronExchange handles mixed valid/invalid cells")
    func testMixedValidInvalidCells() throws {
        let model = IonElectronExchange()
        let nCells = 100

        var Ti_array = [Float](repeating: 1000.0, count: nCells)
        Ti_array[50] = Float.nan  // One NaN cell

        let Ti = MLXArray(Ti_array)
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let sources = createTestSources(nCells: nCells)
        let geometry = createTestGeometry(nCells: nCells)

        // Should fail-safe even if only one cell is invalid
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Verify fail-safe behavior
        let ionHeating_sum = result.ionHeating.value.sum().item(Float.self)
        #expect(ionHeating_sum == 0.0)
    }

    // MARK: - Performance (Validation Overhead)

    @Test("IonElectronExchange validation adds minimal overhead")
    func testValidationPerformanceOverhead() throws {
        let model = IonElectronExchange()
        let profiles = createValidProfiles(nCells: 200)  // Larger grid
        let sources = createTestSources(nCells: 200)
        let geometry = createTestGeometry(nCells: 200)

        // Validation should complete quickly (< 1ms for 200 cells)
        // Note: This is a smoke test, not a precise benchmark
        let result = try model.applyToSources(sources, profiles: profiles, geometry: geometry)

        // Just verify it completes without crash
        #expect(result.metadata != nil)
    }
}
