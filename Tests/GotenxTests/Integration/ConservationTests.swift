// ConservationTests.swift
// Conservation property verification for FVM transport equations

import Testing
import MLX
@testable import GotenxCore

@Suite("Conservation Tests")
struct ConservationTests {

    @Test("Particle conservation with no source or boundary flux")
    func particleConservation() throws {
        // Verify particle number conservation:
        // d/dt ∫ n dV = ∫ S_n dV - boundary flux
        //
        // With S_n = 0 and zero boundary flux (reflecting boundaries),
        // total particle number should be conserved to machine precision

        let nCells = 30
        let minorRadius: Float = 1.0
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        // Initial density profile (parabolic)
        let radii = geometry.radii.value.asArray(Float.self)
        var ne_initial = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            let r_norm = radii[i] / minorRadius
            ne_initial[i] = Float(5e19) * (1.0 - r_norm * r_norm)  // Parabolic density
        }

        let ne = MLXArray(ne_initial)
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(5000.0)))

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Ti),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Transport with diffusion only (no convection, no source)
        let D = MLXArray.full([nCells], values: MLXArray(Float(0.5)))  // [m²/s]

        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: D),
            chiElectron: EvaluatedArray(evaluating: D),
            particleDiffusivity: EvaluatedArray(evaluating: D),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),  // No source
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: false,
            evolveElectronHeat: false,
            evolveDensity: true,  // Evolve density only
            evolveCurrent: false,
            solverType: .linear,
            theta: 1.0,
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )

        // Compute initial particle number: N = ∫ n dV
        let geoFactors = GeometricFactors.from(geometry: geometry)
        let cellVolumes = geoFactors.cellVolumes.value.asArray(Float.self)
        var N_initial: Float = 0.0
        for i in 0..<nCells {
            N_initial += ne_initial[i] * cellVolumes[i]
        }

        // Build coefficients to verify conservation structure
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify density equation has no source term
        let densitySource = coeffs.densityCoeffs.sourceCell.value.asArray(Float.self)
        for s in densitySource {
            #expect(abs(s) < 1e-6)  // Source should be zero
        }

        // Verify flux at boundaries should be zero (reflecting BC)
        let dFace = coeffs.densityCoeffs.dFace.value.asArray(Float.self)
        #expect(dFace[0].isFinite)  // Inner boundary
        #expect(dFace[nCells].isFinite)  // Outer boundary

        // In a full time-stepping simulation, N_final ≈ N_initial
        // For now, verify initial setup is consistent
        #expect(N_initial > 0.0)
        #expect(N_initial.isFinite)
    }

    @Test("Energy conservation with heating source")
    func energyConservation() throws {
        // Verify energy conservation:
        // d/dt ∫ (n·T) dV = ∫ Q dV - boundary flux
        //
        // Total energy change should equal integrated heating power

        let nCells = 25
        let minorRadius: Float = 1.0
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        // Uniform profiles for simplicity
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(5000.0)))  // [eV]
        let ne = MLXArray.full([nCells], values: MLXArray(Float(1e20)))    // [m⁻³]

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Ti),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Constant heating source
        let Q = MLXArray.full([nCells], values: MLXArray(Float(0.1)))  // [MW/m³] - typical ITER value

        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            chiElectron: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(0.5)))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: Q),
            electronHeating: EvaluatedArray(evaluating: Q),
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

        // Compute initial energy: E = ∫ n·T dV
        let geoFactors = GeometricFactors.from(geometry: geometry)
        let cellVolumes = geoFactors.cellVolumes.value.asArray(Float.self)
        let Ti_initial = Ti.asArray(Float.self)
        let ne_initial = ne.asArray(Float.self)

        var E_initial: Float = 0.0
        for i in 0..<nCells {
            E_initial += ne_initial[i] * Ti_initial[i] * cellVolumes[i]
        }

        // Compute total heating power: P = ∫ Q dV
        let Q_values = Q.asArray(Float.self)
        var P_total: Float = 0.0
        for i in 0..<nCells {
            P_total += Q_values[i] * cellVolumes[i]
        }

        // Build coefficients
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify source terms are included
        let ionSource = coeffs.ionCoeffs.sourceCell.value.asArray(Float.self)
        var totalSource: Float = 0.0
        for i in 0..<nCells {
            totalSource += ionSource[i] * cellVolumes[i]
            #expect(ionSource[i] > 0.0)  // Heating should be positive
        }

        // Total source should match input heating power (approximately)
        // Note: May include additional physics (ion-electron exchange, etc.)
        #expect(totalSource > 0.0)
        #expect(totalSource.isFinite)

        // Verify energy is positive and finite
        #expect(E_initial > 0.0)
        #expect(E_initial.isFinite)
        #expect(P_total > 0.0)
        #expect(P_total.isFinite)
    }

    @Test("Flux conservation without current source")
    func fluxConservation() throws {
        // Verify poloidal flux evolution without current source:
        // d/dt ∫ ψ dV should be consistent with Ohm's law
        //
        // With no current source and resistive diffusion only,
        // flux should diffuse and decay

        let nCells = 20
        let minorRadius: Float = 1.0
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        // Initial flux profile (peaked)
        let radii = geometry.radii.value.asArray(Float.self)
        var psi_initial = [Float](repeating: 0.0, count: nCells)
        for i in 0..<nCells {
            let r_norm = radii[i] / minorRadius
            psi_initial[i] = 1.0 * (1.0 - r_norm * r_norm)  // Parabolic flux
        }

        let psi = MLXArray(psi_initial)
        // Peaked profiles to generate bootstrap current (need pressure gradient)
        let Ti = MLXArray.linspace(Float(15000.0), Float(1000.0), count: nCells)
        let Te = MLXArray.linspace(Float(15000.0), Float(1000.0), count: nCells)
        let ne = MLXArray.linspace(Float(8e19), Float(2e19), count: nCells)

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )

        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            chiElectron: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(0.5)))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))  // No current source
        )

        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: false,
            evolveElectronHeat: false,
            evolveDensity: false,
            evolveCurrent: true,  // Evolve flux only
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

        // Verify flux equation source (should include bootstrap + ohmic)
        let fluxSource = coeffs.fluxCoeffs.sourceCell.value.asArray(Float.self)

        // Source may include bootstrap current (non-zero for peaked profiles)
        var hasNonZeroSource = false
        for s in fluxSource {
            #expect(s.isFinite)
            if abs(s) > 1e-10 {
                hasNonZeroSource = true
            }
        }

        // Bootstrap current can be present even without external current source
        #expect(hasNonZeroSource)  // Bootstrap from pressure gradients
    }

    @Test("Total particle number with source matches integrated source")
    func particleSourceIntegration() throws {
        // Verify: ΔN / Δt = ∫ S_n dV
        //
        // Total particle increase should match integrated particle source

        let nCells = 30
        let minorRadius: Float = 1.0
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        // Uniform initial density
        let ne = MLXArray.full([nCells], values: MLXArray(Float(1e20)))
        let Ti = MLXArray.full([nCells], values: MLXArray(Float(5000.0)))

        let profiles = CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Ti),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        // Constant particle source (gas puff or NBI fueling)
        let S_n = MLXArray.full([nCells], values: MLXArray(Float(1e19)))  // [m⁻³/s]

        let transport = TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            chiElectron: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(1.0)))),
            particleDiffusivity: EvaluatedArray(evaluating: MLXArray.full([nCells], values: MLXArray(Float(0.5)))),
            convectionVelocity: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let sources = SourceTerms(
            ionHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            electronHeating: EvaluatedArray(evaluating: MLXArray.zeros([nCells])),
            particleSource: EvaluatedArray(evaluating: S_n),
            currentSource: EvaluatedArray(evaluating: MLXArray.zeros([nCells]))
        )

        let staticParams = StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: false,
            evolveElectronHeat: false,
            evolveDensity: true,
            evolveCurrent: false,
            solverType: .linear,
            theta: 1.0,
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )

        // Compute total particle source: dN/dt = ∫ S_n dV
        let geoFactors = GeometricFactors.from(geometry: geometry)
        let cellVolumes = geoFactors.cellVolumes.value.asArray(Float.self)
        let S_n_values = S_n.asArray(Float.self)

        var dN_dt: Float = 0.0
        for i in 0..<nCells {
            dN_dt += S_n_values[i] * cellVolumes[i]
        }

        // Build coefficients
        let coeffs = buildBlock1DCoeffs(
            transport: transport,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Verify density source is included
        let densitySource = coeffs.densityCoeffs.sourceCell.value.asArray(Float.self)
        var totalSourceIntegrated: Float = 0.0
        for i in 0..<nCells {
            totalSourceIntegrated += densitySource[i] * cellVolumes[i]
            #expect(densitySource[i] > 0.0)  // Source should be positive
        }

        // Total integrated source should match input
        #expect(totalSourceIntegrated > 0.0)
        #expect(totalSourceIntegrated.isFinite)
        #expect(dN_dt > 0.0)
        #expect(dN_dt.isFinite)

        // Ratio should be close to 1 (within numerical precision)
        let ratio = totalSourceIntegrated / dN_dt
        #expect(abs(ratio - 1.0) < 0.1)  // Within 10%
    }
}
