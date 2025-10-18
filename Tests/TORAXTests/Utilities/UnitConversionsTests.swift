import Testing
import MLX
@testable import TORAX

/// Tests for UnitConversions utilities
@Suite("UnitConversions Tests")
struct UnitConversionsTests {

    // MARK: - Test Setup

    /// Force CPU backend for tests (avoids Metal library issues in CI/test environments)
    init() {
        // Set default device to CPU to avoid Metal library loading issues
        MLX.GPU.set(cacheLimit: 0)
    }

    // MARK: - Constants Tests

    /// Test that eV constant matches the fundamental constant
    @Test("eV constant is correct")
    func testEvConstant() {
        let expected: Float = 1.602176634e-19  // [J/eV]
        #expect(UnitConversions.eV == expected, "eV constant mismatch")
    }

    /// Test that conversion constant is correct
    @Test("MW/m³ to eV/(m³·s) conversion constant")
    func testConversionConstant() {
        // Derivation:
        // 1 MW/m³ = 10⁶ W/m³
        //         = 10⁶ J/(m³·s)
        //         = 10⁶ J/(m³·s) × (1 eV / 1.602176634×10⁻¹⁹ J)
        //         = 6.2415090744×10²⁴ eV/(m³·s)
        let expected: Float = 6.2415090744e24
        #expect(UnitConversions.megawattsPerCubicMeterToEvPerCubicMeterPerSecond == expected,
                "Conversion constant mismatch")
    }

    /// Test conversion constant derivation from first principles
    @Test("Conversion constant matches derivation from eV")
    func testConversionDerivation() {
        // 1 MW = 10⁶ W = 10⁶ J/s
        let megawatt: Float = 1e6  // [W]

        // Convert J to eV: J / (J/eV) = eV
        let evPerJoule = 1.0 / UnitConversions.eV  // [eV/J]
        let evPerSecond = megawatt * evPerJoule  // [eV/s]

        // For power density: [MW/m³] → [eV/(m³·s)]
        let derived = evPerSecond  // Same as MW * (eV/J)

        let expected = UnitConversions.megawattsPerCubicMeterToEvPerCubicMeterPerSecond
        let relativeError = abs(derived - expected) / expected

        #expect(relativeError < 1e-6,
                "Derived conversion constant (\(derived)) differs from defined constant (\(expected))")
    }

    // MARK: - Scalar Conversion Tests

    /// Test scalar conversion with typical value
    @Test("Scalar conversion: 1 MW/m³ → eV/(m³·s)")
    func testScalarConversionUnity() {
        let input: Float = 1.0  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        let expected: Float = 6.2415090744e24  // [eV/(m³·s)]
        let relativeError = abs(output - expected) / expected

        #expect(relativeError < 1e-6, "Conversion error for 1 MW/m³")
    }

    /// Test scalar conversion with realistic ITER heating power
    @Test("Scalar conversion: 0.5 MW/m³ (typical ITER heating)")
    func testScalarConversionRealistic() {
        let input: Float = 0.5  // [MW/m³] - typical fusion heating
        let output = UnitConversions.megawattsToEvDensity(input)

        let expected: Float = 0.5 * 6.2415090744e24  // [eV/(m³·s)]
        let relativeError = abs(output - expected) / expected

        #expect(relativeError < 1e-6, "Conversion error for 0.5 MW/m³")
    }

    /// Test scalar conversion with zero
    @Test("Scalar conversion: 0 MW/m³")
    func testScalarConversionZero() {
        let input: Float = 0.0  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        #expect(output == 0.0, "Zero input should give zero output")
    }

    /// Test scalar conversion with negative value (cooling)
    @Test("Scalar conversion: negative value (cooling)")
    func testScalarConversionNegative() {
        let input: Float = -0.1  // [MW/m³] - cooling/loss term
        let output = UnitConversions.megawattsToEvDensity(input)

        let expected: Float = -0.1 * 6.2415090744e24  // [eV/(m³·s)]
        let relativeError = abs(output - expected) / abs(expected)

        #expect(relativeError < 1e-6, "Conversion error for negative value")
    }

    // MARK: - Array Conversion Tests

    /// Test array conversion with uniform values
    @Test("Array conversion: uniform heating profile")
    func testArrayConversionUniform() {
        let nCells = 25
        let input = MLXArray(Array(repeating: Float(1.0), count: nCells))  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        // Verify output is Float64 (required for 10²⁴ values)
        #expect(output.dtype == .float64, "Output should be Float64 for large values")

        // CRITICAL: eval() forces computation before extracting values
        eval(output)

        let expected: Double = 6.2415090744e24  // [eV/(m³·s)]
        let outputArray = output.asArray(Double.self)

        for (i, value) in outputArray.enumerated() {
            let relativeError = abs(value - expected) / expected
            #expect(relativeError < 1e-6, "Conversion error at cell \(i)")
        }
    }

    /// Test array conversion with profile (core-to-edge gradient)
    @Test("Array conversion: realistic heating profile")
    func testArrayConversionProfile() {
        let nCells = 25

        // Realistic heating profile: peaked in core, decaying to edge
        // Q(r) = Q0 * (1 - 0.9 * (r/a)²)
        var inputArray = [Float]()
        for i in 0..<nCells {
            let rho = Float(i) / Float(nCells - 1)  // Normalized radius
            let Q_MW = 1.0 * (1.0 - 0.9 * rho * rho)  // [MW/m³]
            inputArray.append(Q_MW)
        }

        let input = MLXArray(inputArray)
        let output = UnitConversions.megawattsToEvDensity(input)

        // Verify output is Float64
        #expect(output.dtype == .float64, "Output should be Float64 for large values")

        // CRITICAL: eval() forces computation before extracting values
        eval(output)

        let outputArray = output.asArray(Double.self)
        let conversionFactor: Double = 6.2415090744e24

        for (i, value) in outputArray.enumerated() {
            let expected = Double(inputArray[i]) * conversionFactor
            let relativeError = abs(value - expected) / (expected + 1e-30)  // Avoid division by zero at edge

            #expect(relativeError < 1e-6 || expected < 1e10,
                    "Conversion error at cell \(i): \(value) vs \(expected)")
        }
    }

    /// Test array conversion with zeros
    @Test("Array conversion: zero heating")
    func testArrayConversionZeros() {
        let nCells = 25
        let input = MLXArray.zeros([nCells])  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        // Verify output is Float64
        #expect(output.dtype == .float64, "Output should be Float64")

        // CRITICAL: eval() forces computation before extracting values
        eval(output)

        let outputArray = output.asArray(Double.self)

        for (i, value) in outputArray.enumerated() {
            #expect(value == 0.0, "Zero input should give zero output at cell \(i)")
        }
    }

    /// Test array conversion with mixed positive/negative values
    @Test("Array conversion: mixed heating/cooling")
    func testArrayConversionMixed() {
        let input = MLXArray([1.0, -0.5, 0.0, 0.3, -0.1])  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        // Verify output is Float64
        #expect(output.dtype == .float64, "Output should be Float64")

        // CRITICAL: eval() forces computation of lazy MLXArray before extracting values
        eval(output)

        let expectedArray: [Double] = [
            1.0 * 6.2415090744e24,
            -0.5 * 6.2415090744e24,
            0.0,
            0.3 * 6.2415090744e24,
            -0.1 * 6.2415090744e24
        ]

        let outputArray = output.asArray(Double.self)

        for (i, value) in outputArray.enumerated() {
            let expected = expectedArray[i]
            if expected == 0.0 {
                #expect(value == 0.0, "Zero mismatch at index \(i)")
            } else {
                let relativeError = abs(value - expected) / abs(expected)
                #expect(relativeError < 1e-6, "Conversion error at index \(i)")
            }
        }
    }

    // MARK: - Dimensional Consistency Tests

    /// Test that conversion maintains dimensional consistency in temperature equation
    @Test("Temperature equation dimensional consistency with conversion")
    func testTemperatureEquationDimensions() {
        // Setup typical ITER plasma parameters
        let ne: Float = 1e20      // [m⁻³]
        let chi: Float = 1.0      // [m²/s]
        let gradT: Float = 1000.0 // [eV/m]
        let Q_MW: Float = 0.5     // [MW/m³]

        // Left side: n_e ∂T/∂t
        // Dimension: [m⁻³] × [eV/s] = [eV/(m³·s)]
        // (We don't compute actual value, just verify units)

        // Diffusion term: ∇·(n_e χ ∇T)
        // Dimension: ∇·([m⁻³] × [m²/s] × [eV/m]) = [eV/(m³·s)]
        let dr: Float = 0.08  // [m] typical cell size
        let diffusionTerm = ne * chi * gradT / dr
        // [m⁻³] × [m²/s] × [eV/m] × [1/m] = [eV/(m³·s)] ✓

        // Source term: Q after conversion
        // Must have dimension [eV/(m³·s)]
        let sourceTerm = UnitConversions.megawattsToEvDensity(Q_MW)

        // Verify both terms are comparable in magnitude
        // (same dimension means they can be added/subtracted)
        let ratio = sourceTerm / diffusionTerm

        // For typical ITER: heating and transport are comparable
        #expect(ratio > 0.1 && ratio < 100,
                "Source and diffusion terms have inconsistent magnitude (ratio = \(ratio))")
    }

    /// Test numerical precision of conversion
    @Test("Conversion maintains Float32 precision")
    func testConversionPrecision() {
        // Test that conversion doesn't lose precision for typical values
        let input: Float = 0.123456789  // [MW/m³]
        let output = UnitConversions.megawattsToEvDensity(input)

        // Verify at least 6 significant figures preserved
        let expected = input * 6.2415090744e24
        let relativeError = abs(output - expected) / expected

        // Float32 has ~7 decimal digits precision
        #expect(relativeError < 1e-6, "Precision loss in conversion")
    }

    /// Test conversion with very small values (edge case)
    @Test("Conversion with very small values")
    func testConversionVerySmall() {
        let input: Float = 1e-6  // [MW/m³] - very small heating
        let output = UnitConversions.megawattsToEvDensity(input)

        let expected = input * 6.2415090744e24
        let relativeError = abs(output - expected) / expected

        #expect(relativeError < 1e-6, "Conversion error for very small value")
    }

    /// Test conversion with very large values (edge case)
    @Test("Conversion with very large values")
    func testConversionVeryLarge() {
        let input: Float = 100.0  // [MW/m³] - very large heating
        let output = UnitConversions.megawattsToEvDensity(input)

        let expected = input * 6.2415090744e24

        // Check for overflow
        #expect(!output.isInfinite, "Conversion resulted in infinity")
        #expect(!output.isNaN, "Conversion resulted in NaN")

        let relativeError = abs(output - expected) / expected
        #expect(relativeError < 1e-6, "Conversion error for very large value")
    }

    // MARK: - Type Safety Tests

    /// Test that array version always returns Float64 for large values
    @Test("Array conversion always returns Float64")
    func testArrayConversionDtype() {
        // Test with different input dtypes
        let nCells = 10

        // Float32 input → Float64 output
        let float32Input = MLXArray(Array(repeating: Float(1.0), count: nCells))
        let float32Output = UnitConversions.megawattsToEvDensity(float32Input)
        #expect(float32Output.dtype == .float64, "Float32 input should produce Float64 output")

        // Float64 input → Float64 output
        let float64Input = MLXArray(Array(repeating: Double(1.0), count: nCells))
        let float64Output = UnitConversions.megawattsToEvDensity(float64Input)
        #expect(float64Output.dtype == .float64, "Float64 input should produce Float64 output")
    }

    /// Test no overflow with large values in Float64
    @Test("No overflow with large conversion coefficient in Float64")
    func testNoOverflowWithLargeCoefficient() {
        // Test scalar version (always safe with Float)
        let scalarValues: [Float] = [1.0, 10.0, 100.0]

        for (i, input) in scalarValues.enumerated() {
            let output = UnitConversions.megawattsToEvDensity(input)

            #expect(!output.isInfinite, "Scalar value at index \(i) overflowed to infinity")
            #expect(!output.isNaN, "Scalar value at index \(i) is NaN")

            let expected = input * 6.2415090744e24
            let relativeError = abs(output - expected) / expected
            #expect(relativeError < 1e-6, "Scalar conversion error at index \(i)")
        }

        // Test array version with Float64 output (safe for large values)
        let arrayInput = MLXArray([1.0, 10.0, 100.0])
        let arrayOutput = UnitConversions.megawattsToEvDensity(arrayInput)

        #expect(arrayOutput.dtype == .float64, "Array output should be Float64")

        eval(arrayOutput)
        let outputArray = arrayOutput.asArray(Double.self)

        for (i, value) in outputArray.enumerated() {
            #expect(!value.isInfinite, "Array value at index \(i) overflowed to infinity")
            #expect(!value.isNaN, "Array value at index \(i) is NaN")

            let expected = Double(scalarValues[i]) * 6.2415090744e24
            let relativeError = abs(value - expected) / expected
            #expect(relativeError < 1e-6, "Array conversion error at index \(i)")
        }
    }
}
