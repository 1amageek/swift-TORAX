import Testing
import MLX
@testable import GotenxCore

/// Unit tests for ValidatedProfiles (Sprint 1: Minimal validation)
///
/// Tests cover:
/// 1. Valid profiles (should pass)
/// 2. NaN detection (should fail)
/// 3. Inf detection (should fail)
/// 4. Negative temperature detection (should fail)
/// 5. Zero temperature detection (should fail)
/// 6. Zero density detection (should fail)
@Suite("ValidatedProfiles Tests")
struct ValidatedProfilesTests {

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

    // MARK: - Valid Profiles Tests

    @Test("ValidatedProfiles accepts valid profiles")
    func testValidProfiles() throws {
        let profiles = createValidProfiles()

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated != nil)

        if let validated = validated {
            // Check values are preserved (with Float32 tolerance)
            let Ti_mean = validated.ionTemperature.value.mean().item(Float.self)
            let Te_mean = validated.electronTemperature.value.mean().item(Float.self)
            let ne_mean = validated.electronDensity.value.mean().item(Float.self)

            #expect(abs(Ti_mean - 1000.0) / 1000.0 < 1e-5)  // Relative error < 0.001%
            #expect(abs(Te_mean - 1000.0) / 1000.0 < 1e-5)
            #expect(abs(ne_mean - 2e19) / 2e19 < 1e-5)
        }
    }

    @Test("ValidatedProfiles converts back to CoreProfiles")
    func testToCoreProfiles() throws {
        let profiles = createValidProfiles()
        let validated = try #require(ValidatedProfiles.validateMinimal(profiles))

        let converted = validated.toCoreProfiles()

        // Check with Float32 tolerance
        let Ti_mean = converted.ionTemperature.value.mean().item(Float.self)
        let Te_mean = converted.electronTemperature.value.mean().item(Float.self)

        #expect(abs(Ti_mean - 1000.0) / 1000.0 < 1e-5)
        #expect(abs(Te_mean - 1000.0) / 1000.0 < 1e-5)
    }

    // MARK: - NaN Detection Tests

    @Test("ValidatedProfiles rejects NaN in ionTemperature")
    func testRejectsNaNIonTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ NaN
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    @Test("ValidatedProfiles rejects NaN in electronTemperature")
    func testRejectsNaNElectronTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ NaN
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    @Test("ValidatedProfiles rejects NaN in electronDensity")
    func testRejectsNaNElectronDensity() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float.nan))  // ❌ NaN
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    // MARK: - Inf Detection Tests

    @Test("ValidatedProfiles rejects Inf in ionTemperature")
    func testRejectsInfIonTemperature() {
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

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    // MARK: - Negative/Zero Temperature Tests

    @Test("ValidatedProfiles rejects zero ionTemperature")
    func testRejectsZeroIonTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(0.0)))  // ❌ Zero
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    @Test("ValidatedProfiles rejects negative electronTemperature")
    func testRejectsNegativeElectronTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float(-100.0)))  // ❌ Negative
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    @Test("ValidatedProfiles rejects zero electronDensity")
    func testRejectsZeroElectronDensity() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1000.0)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(0.0)))  // ❌ Zero
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        #expect(validated == nil)
    }

    // MARK: - Edge Cases

    @Test("ValidatedProfiles accepts very small positive temperature")
    func testAcceptsSmallPositiveTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(0.01)))  // ✅ Very small but positive
        let Te = MLXArray.full([nCells], values: MLXArray(Float(0.01)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(1e17)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        // Sprint 1: Accepts any positive value (bounds checking in Sprint 3)
        #expect(validated != nil)
    }

    @Test("ValidatedProfiles accepts very large temperature")
    func testAcceptsLargeTemperature() {
        let nCells = 100
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(1e6)))  // ✅ Very large but finite
        let Te = MLXArray.full([nCells], values: MLXArray(Float(1e6)))
        let ne = MLXArray.full([nCells], values: MLXArray(Float(2e19)))
        let psi = MLXArray.linspace(Float(0.0), Float(1.0), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let validated = ValidatedProfiles.validateMinimal(profiles)

        // Sprint 1: Accepts any finite positive value (bounds checking in Sprint 3)
        #expect(validated != nil)
    }

    @Test("ValidatedProfiles handles mixed valid/invalid cells")
    func testRejectsMixedValidInvalid() {
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

        let validated = ValidatedProfiles.validateMinimal(profiles)

        // Should reject if ANY cell is invalid
        #expect(validated == nil)
    }
}
