import Testing
import MLX
import FusionSurrogates
@testable import Gotenx

/// Tests for QLKNN Transport Model integration (MLX-native)
@Suite("QLKNN Transport Model Tests")
struct QLKNNTransportModelTests {

    // MARK: - Initialization Tests

    @Test("QLKNN model initialization")
    func testQLKNNInitialization() throws {
        // This test verifies that QLKNN network can be loaded
        do {
            let model = try QLKNNTransportModel()
            #expect(model.name == "qlknn")
        } catch {
            Issue.record("QLKNN initialization failed: \(error)")
            throw error
        }
    }

    @Test("QLKNN compute coefficients")
    func testQLKNNComputeCoefficients() throws {
        let nCells = 25
        let majorRadius: Float = 6.2  // ITER-like [m]
        let minorRadius: Float = 2.0  // ITER-like [m]

        // Create test geometry
        let config = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.3  // ITER-like [T]
        )
        let geometry = Geometry(config: config)

        // Create test profiles (realistic ITER-like values)
        let Ti = MLXArray(Array(repeating: Float(10000.0), count: nCells))  // 10 keV
        let Te = MLXArray(Array(repeating: Float(10000.0), count: nCells))  // 10 keV
        let ne = MLXArray(Array(repeating: Float(1e20), count: nCells))     // 10^20 m^-3
        let psi = MLXArray(Array(repeating: Float(0.0), count: nCells))     // Dummy

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let params = TransportParameters(modelType: "qlknn")

        // Try to initialize QLKNN
        do {
            let model = try QLKNNTransportModel()

            // Compute coefficients
            let coeffs = model.computeCoefficients(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            // Verify output structure
            #expect(coeffs.chiIon.shape[0] == nCells)
            #expect(coeffs.chiElectron.shape[0] == nCells)
            #expect(coeffs.particleDiffusivity.shape[0] == nCells)
            #expect(coeffs.convectionVelocity.shape[0] == nCells)

            // Verify values are positive (or zero)
            eval(coeffs.chiIon.value, coeffs.chiElectron.value)
            let chiIonArray = coeffs.chiIon.value.asArray(Float.self)
            let chiElectronArray = coeffs.chiElectron.value.asArray(Float.self)

            for value in chiIonArray {
                #expect(value >= 0.0, "Ion diffusivity should be non-negative")
            }
            for value in chiElectronArray {
                #expect(value >= 0.0, "Electron diffusivity should be non-negative")
            }

            print("[QLKNNTransportModelTests] Successfully computed transport coefficients")

        } catch {
            Issue.record("QLKNN test failed: \(error)")
            throw error
        }
    }

    @Test("QLKNN gradient profiles")
    func testQLKNNGradientProfiles() throws {
        let nCells = 25
        let majorRadius: Float = 6.2
        let minorRadius: Float = 2.0

        let config = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.3
        )
        let geometry = Geometry(config: config)

        // Create profiles with gradients (linear decay)
        var Ti_values: [Float] = []
        var Te_values: [Float] = []
        var ne_values: [Float] = []

        for i in 0..<nCells {
            let rho = Float(i) / Float(nCells - 1)  // Normalized radius 0 → 1
            Ti_values.append(15000.0 * (1.0 - 0.9 * rho))  // 15 keV → 1.5 keV
            Te_values.append(15000.0 * (1.0 - 0.9 * rho))  // 15 keV → 1.5 keV
            ne_values.append(1.2e20 * (1.0 - 0.8 * rho))   // 1.2e20 → 0.24e20
        }

        let Ti = MLXArray(Ti_values, [nCells])
        let Te = MLXArray(Te_values, [nCells])
        let ne = MLXArray(ne_values, [nCells])
        let psi = MLXArray(Array(repeating: Float(0.0), count: nCells))

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let params = TransportParameters(modelType: "qlknn")

        do {
            let model = try QLKNNTransportModel()
            let coeffs = model.computeCoefficients(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            // With gradients, transport should be non-zero
            eval(coeffs.chiIon.value)
            let chiIonArray = coeffs.chiIon.value.asArray(Float.self)

            // Check that at least some cells have non-trivial transport
            let nonZeroCount = chiIonArray.filter { $0 > 0.01 }.count
            #expect(nonZeroCount > 0, "QLKNN should predict non-zero transport with gradients")

            print("[QLKNNTransportModelTests] Gradient profile test passed")

        } catch {
            Issue.record("QLKNN gradient test failed: \(error)")
            throw error
        }
    }

    @Test("QLKNN fallback on error")
    func testQLKNNFallback() throws {
        // This test verifies that fallback to Bohm-GyroBohm works
        let nCells = 25
        let majorRadius: Float = 6.2
        let minorRadius: Float = 2.0

        let config = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.3
        )
        let geometry = Geometry(config: config)

        // Create edge-case profiles (very low temperature, might trigger fallback)
        let Ti = MLXArray(Array(repeating: Float(10.0), count: nCells))  // 10 eV (very low!)
        let Te = MLXArray(Array(repeating: Float(10.0), count: nCells))
        let ne = MLXArray(Array(repeating: Float(1e18), count: nCells))  // Low density
        let psi = MLXArray(Array(repeating: Float(0.0), count: nCells))

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let params = TransportParameters(modelType: "qlknn")

        do {
            let model = try QLKNNTransportModel()

            // Should not crash even with edge-case profiles
            let coeffs = model.computeCoefficients(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            // Verify we get valid output (either from QLKNN or fallback)
            #expect(coeffs.chiIon.shape[0] == nCells)
            #expect(coeffs.chiElectron.shape[0] == nCells)

            print("[QLKNNTransportModelTests] Fallback test passed")

        } catch {
            Issue.record("QLKNN fallback test failed: \(error)")
            throw error
        }
    }
}
