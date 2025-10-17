import Testing
import MLX
@testable import TORAX
@testable import TORAXPhysics

@Test("Ion-electron exchange equilibration")
func testEquilibration() {
    let exchange = IonElectronExchange(Zeff: 1.5, ionMass: 2.014)

    let ne = MLXArray.full([100], values: MLXArray(Float(5e19)))
    var Te = MLXArray.full([100], values: MLXArray(Float(10000.0)))  // 10 keV
    var Ti = MLXArray.full([100], values: MLXArray(Float(5000.0)))   // 5 keV

    // Use much smaller time step for numerical stability
    // Characteristic equilibration time ~ microseconds
    let dt: Float = 1e-7  // 0.1 microseconds
    let nSteps = 10000

    // Simulate equilibration using forward Euler
    for _ in 0..<nSteps {
        let Q_ie = try! exchange.compute(ne: ne, Te: Te, Ti: Ti)

        // Energy balance: dE/dt = Q
        // E = (3/2) * n * k_B * T
        // dT/dt = Q / ((3/2) * n * k_B)
        // Fixed: Added missing (3/2) factor
        Te = Te - dt * Q_ie / ((3.0/2.0) * ne * PhysicsConstants.eV)
        Ti = Ti + dt * Q_ie / ((3.0/2.0) * ne * PhysicsConstants.eV)
    }

    // Should equilibrate within 100 eV
    let diff = abs(Te - Ti).mean().item(Float.self)
    #expect(diff < 100.0, "Temperatures should equilibrate: ΔT = \(diff) eV")
}

@Test("Collision frequency scaling with density")
func testCollisionFrequencyDensityScaling() {
    let exchange = IonElectronExchange()

    // ν_ei ∝ n_e
    let ne1 = MLXArray([Float(1e19)])
    let ne2 = MLXArray([Float(2e19)])
    let Te = MLXArray([Float(1000.0)])

    let nu1 = exchange.computeCollisionFrequency(ne: ne1, Te: Te)
    let nu2 = exchange.computeCollisionFrequency(ne: ne2, Te: Te)

    let ratio = (nu2 / nu1).item(Float.self)
    #expect(abs(ratio - 2.0) < 0.01, "Collision frequency should scale linearly with density")
}

@Test("Collision frequency scaling with temperature")
func testCollisionFrequencyTemperatureScaling() {
    let exchange = IonElectronExchange()

    // ν_ei ∝ T_e^(-3/2)
    let ne = MLXArray([Float(1e19)])
    let Te1 = MLXArray([Float(1000.0)])
    let Te2 = MLXArray([Float(2000.0)])

    let nu1 = exchange.computeCollisionFrequency(ne: ne, Te: Te1)
    let nu2 = exchange.computeCollisionFrequency(ne: ne, Te: Te2)

    let ratio = (nu2 / nu1).item(Float.self)
    let expected: Float = 0.35355339  // pow(0.5, 1.5) = 0.5^(3/2) ≈ 0.35355

    #expect(abs(ratio - expected) < 0.01, "Collision frequency should scale as T^(-3/2)")
}

@Test("Energy conservation")
func testEnergyConservation() {
    let exchange = IonElectronExchange()

    let ne = MLXArray([Float(5e19)])
    let Te = MLXArray([Float(8000.0)])
    let Ti = MLXArray([Float(6000.0)])

    let Q_ie = try! exchange.compute(ne: ne, Te: Te, Ti: Ti)

    // Q_ie should be positive (heating ions) when Te > Ti
    #expect(Q_ie.item(Float.self) > 0, "Power should flow from electrons to ions when Te > Ti")

    // Test opposite case
    let Q_ie_reverse = try! exchange.compute(ne: ne, Te: Ti, Ti: Te)
    #expect(Q_ie_reverse.item(Float.self) < 0, "Power should flow from ions to electrons when Ti > Te")

    // Magnitudes should be equal
    let ratio = abs(Q_ie.item(Float.self) / Q_ie_reverse.item(Float.self))
    #expect(abs(ratio - 1.0) < 0.01, "Energy exchange should be symmetric")
}

@Test("Coulomb logarithm reasonable values")
func testCoulombLogarithm() {
    let exchange = IonElectronExchange()

    // Typical plasma parameters
    let ne = MLXArray([Float(1e20)])
    let Te = MLXArray([Float(10000.0)])  // 10 keV

    let lnLambda = exchange.computeCoulombLogarithm(ne: ne, Te: Te)
    let value = lnLambda.item(Float.self)

    // Coulomb logarithm should be in range [10, 20] for typical plasmas
    #expect(value > 10.0 && value < 20.0, "Coulomb logarithm should be reasonable: ln(Λ) = \(value)")
}

@Test("Zero temperature difference gives zero exchange")
func testZeroExchange() {
    let exchange = IonElectronExchange()

    let ne = MLXArray([Float(1e20)])
    let T = MLXArray([Float(5000.0)])

    let Q_ie = try! exchange.compute(ne: ne, Te: T, Ti: T)

    #expect(abs(Q_ie.item(Float.self)) < 1e-6, "No exchange when temperatures are equal")
}
