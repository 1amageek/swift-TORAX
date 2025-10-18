import Testing
import MLX
@testable import TORAX

/// Tests for Block1DCoeffsBuilder functionality
@Suite("Block1DCoeffsBuilder Tests")
struct Block1DCoeffsBuilderTests {

    // MARK: - Harmonic Mean with Large Density Tests

    /// Test that harmonic mean interpolation handles large density values without overflow
    ///
    /// Verifies the fix for Float32 overflow with realistic plasma densities (n_e ~ 1e20 m⁻³)
    /// See IMPLEMENTATION_NOTES.md Section 4 for context.
    @Test("Harmonic mean with large density (1e20 m⁻³) does not produce NaN or inf")
    func testHarmonicMeanLargeDensity() throws {
        // Typical ITER-scale plasma density
        let nCells = 25
        let densityValue: Float = 1e20  // [m⁻³] - realistic plasma density

        // Create uniform density profile
        let densityArray = MLXArray(Array(repeating: densityValue, count: nCells))
        let density = EvaluatedArray(evaluating: densityArray)

        // Create minimal profiles for testing
        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronDensity: density,
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Create geometry using MeshConfig
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.3,
            geometryType: .circular
        )
        let geometry = Geometry(config: meshConfig)

        // Create minimal transport coefficients
        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            chiElectron: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Create minimal sources
        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Create static params
        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: true,
            evolveElectronHeat: true,
            evolveDensity: false,
            evolveCurrent: false,
            solverType: .linear,
            theta: 1.0,
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )

        // Build coefficients - this should not produce NaN or inf
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify no NaN in ion coefficients
        let ionDFace = coeffs.ionCoeffs.dFace.value.asArray(Float.self)
        for (i, value) in ionDFace.enumerated() {
            #expect(!value.isNaN, "Ion dFace[\(i)] is NaN")
            #expect(!value.isInfinite, "Ion dFace[\(i)] is infinite")
        }

        // Verify no NaN in electron coefficients
        let electronDFace = coeffs.electronCoeffs.dFace.value.asArray(Float.self)
        for (i, value) in electronDFace.enumerated() {
            #expect(!value.isNaN, "Electron dFace[\(i)] is NaN")
            #expect(!value.isInfinite, "Electron dFace[\(i)] is infinite")
        }

        // Verify no NaN in transient coefficients
        let ionTransient = coeffs.ionCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in ionTransient.enumerated() {
            #expect(!value.isNaN, "Ion transientCoeff[\(i)] is NaN")
            #expect(!value.isInfinite, "Ion transientCoeff[\(i)] is infinite")
        }

        let electronTransient = coeffs.electronCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in electronTransient.enumerated() {
            #expect(!value.isNaN, "Electron transientCoeff[\(i)] is NaN")
            #expect(!value.isInfinite, "Electron transientCoeff[\(i)] is infinite")
        }
    }

    /// Test density floor is applied correctly
    ///
    /// Verifies that very low density values are clamped to the floor (1e18 m⁻³)
    @Test("Density floor prevents division by zero")
    func testDensityFloor() throws {
        let nCells = 25

        // Create very low density profile (below physical minimum)
        let lowDensityValue: Float = 1e10  // Much below floor of 1e18
        let densityArray = MLXArray(Array(repeating: lowDensityValue, count: nCells))
        let density = EvaluatedArray(evaluating: densityArray)

        // Create minimal profiles
        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronDensity: density,
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Create geometry using MeshConfig
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.3,
            geometryType: .circular
        )
        let geometry = Geometry(config: meshConfig)

        // Create transport and sources
        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            chiElectron: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: true,
            evolveElectronHeat: true,
            evolveDensity: false,
            evolveCurrent: false,
            solverType: .linear,
            theta: 1.0,
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )

        // Build coefficients
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify transient coefficients are at or above the floor
        let densityFloor: Float = 1e18
        let ionTransient = coeffs.ionCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in ionTransient.enumerated() {
            #expect(value >= densityFloor, "Ion transientCoeff[\(i)] = \(value) is below floor \(densityFloor)")
        }

        let electronTransient = coeffs.electronCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in electronTransient.enumerated() {
            #expect(value >= densityFloor, "Electron transientCoeff[\(i)] = \(value) is below floor \(densityFloor)")
        }
    }

    // MARK: - Source Term Unit Conversion Tests

    /// Test that source term unit conversion is correct
    ///
    /// Verifies MW/m³ → eV/(m³·s) conversion for temperature equation consistency
    @Test("Source term unit conversion MW/m³ → eV/(m³·s)")
    func testSourceTermUnitConversion() throws {
        // Test scalar conversion
        let Q_MW: Float = 1.0  // [MW/m³]
        let Q_eV = UnitConversions.megawattsToEvDensity(Q_MW)

        // Expected: 1 MW/m³ = 6.2415090744×10²⁴ eV/(m³·s)
        let expected: Float = 6.2415090744e24
        let relativeError = abs(Q_eV - expected) / expected

        #expect(relativeError < 1e-6, "Power density unit conversion error: \(Q_eV) vs \(expected)")
    }

    /// Test dimensional consistency of temperature equation
    ///
    /// Verifies that all terms in n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i have matching dimensions
    @Test("Temperature equation dimensional consistency")
    func testTemperatureEquationDimensions() throws {
        // Setup typical ITER plasma parameters
        let ne: Float = 1e20      // [m⁻³]
        let chi: Float = 1.0      // [m²/s]
        let gradT: Float = 1000.0 // [eV/m]
        let Q_MW: Float = 0.5     // [MW/m³]

        // Diffusion term: ∇·(n_e χ ∇T) [eV/(m³·s)]
        // Approximation for order-of-magnitude: n_e χ gradT / dr
        let dr: Float = 0.08  // [m] typical cell size for 25-cell ITER mesh
        let diffusionTerm = ne * chi * gradT / dr
        // [m⁻³] × [m²/s] × [eV/m] × [1/m] = [eV/(m³·s)] ✓

        // Source term: Q [eV/(m³·s)] after conversion
        let sourceTerm = UnitConversions.megawattsToEvDensity(Q_MW)

        // Both terms must have same dimension and comparable magnitude
        let ratio = sourceTerm / diffusionTerm

        // For typical ITER: heating power and transport losses are comparable
        // Expect ratio O(1) to O(10) for realistic scenarios
        #expect(ratio > 0.1 && ratio < 100,
                "Source and diffusion terms have inconsistent magnitude (ratio = \(ratio))")
    }

    /// Test that normal density values are not affected by the floor
    @Test("Normal density values unchanged by floor")
    func testNormalDensityUnchanged() throws {
        let nCells = 25

        // Create normal density profile (well above floor)
        let normalDensityValue: Float = 5e19  // Typical plasma density
        let densityArray = MLXArray(Array(repeating: normalDensityValue, count: nCells))
        let density = EvaluatedArray(evaluating: densityArray)

        // Create profiles
        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(10000.0), count: nCells))),
            electronDensity: density,
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Create geometry using MeshConfig
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.3,
            geometryType: .circular
        )
        let geometry = Geometry(config: meshConfig)

        // Create transport and sources
        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            chiElectron: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray(Array(repeating: Float(1.0), count: nCells))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: true,
            evolveElectronHeat: true,
            evolveDensity: false,
            evolveCurrent: false,
            solverType: .linear,
            theta: 1.0,
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )

        // Build coefficients
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify transient coefficients match the input density (within tolerance)
        let ionTransient = coeffs.ionCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in ionTransient.enumerated() {
            let relativeError = abs(value - normalDensityValue) / normalDensityValue
            #expect(relativeError < 1e-6, "Ion transientCoeff[\(i)] = \(value) differs from input \(normalDensityValue)")
        }

        let electronTransient = coeffs.electronCoeffs.transientCoeff.value.asArray(Float.self)
        for (i, value) in electronTransient.enumerated() {
            let relativeError = abs(value - normalDensityValue) / normalDensityValue
            #expect(relativeError < 1e-6, "Electron transientCoeff[\(i)] = \(value) differs from input \(normalDensityValue)")
        }
    }
}
