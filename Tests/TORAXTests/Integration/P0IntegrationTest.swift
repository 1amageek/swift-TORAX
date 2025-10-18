// P0IntegrationTest.swift
// Integration test for P0 configuration (minimal physics)

import XCTest
import MLX
@testable import TORAX
@testable import TORAXPhysics

/// P0 Integration Test
///
/// Tests the minimal physics configuration (P0):
/// - Constant transport model
/// - Ohmic heating only
/// - Linear solver with predictor-corrector
/// - 2 evolved quantities: Ti, Te (fixed density and current)
final class P0IntegrationTest: XCTestCase {

    // MARK: - Test Configuration

    /// Create P0 static configuration
    func makeP0StaticConfig() -> StaticRuntimeParams {
        let meshConfig = MeshConfig(
            nCells: 25,
            majorRadius: 6.2,
            minorRadius: 2.0,
            toroidalField: 5.3,
            geometryType: .circular
        )

        return StaticRuntimeParams(
            mesh: meshConfig,
            evolveIonHeat: true,
            evolveElectronHeat: true,
            evolveDensity: false,   // P0: fix density
            evolveCurrent: false,    // P0: fix current
            solverType: .linear,
            theta: 1.0,             // Fully implicit
            solverTolerance: 1e-6,
            solverMaxIterations: 100
        )
    }

    /// Create P0 dynamic configuration
    func makeP0DynamicConfig() -> DynamicRuntimeParams {
        let transportParams = TransportParameters(
            modelType: "constant",
            params: [
                "chi_ion": 1.0,
                "chi_electron": 1.0
            ]
        )

        let boundaryConditions = BoundaryConditions(
            ionTemperature: BoundaryCondition(
                left: .gradient(0.0),   // Zero gradient at core
                right: .value(100.0)     // 100 eV at edge
            ),
            electronTemperature: BoundaryCondition(
                left: .gradient(0.0),
                right: .value(100.0)
            ),
            electronDensity: BoundaryCondition(
                left: .gradient(0.0),
                right: .value(1e19)
            ),
            poloidalFlux: BoundaryCondition(
                left: .value(0.0),
                right: .gradient(0.0)
            )
        )

        let profileConditions = ProfileConditions(
            ionTemperature: .parabolic(peak: 10000.0, edge: 100.0, exponent: 2.0),
            electronTemperature: .parabolic(peak: 10000.0, edge: 100.0, exponent: 2.0),
            electronDensity: .parabolic(peak: 1e20, edge: 1e19, exponent: 2.0),
            currentDensity: .constant(0.0)
        )

        return DynamicRuntimeParams(
            dt: 1e-4,  // 0.1 ms
            boundaryConditions: boundaryConditions,
            profileConditions: profileConditions,
            sourceParams: [:],
            transportParams: transportParams
        )
    }

    /// Create initial profiles for P0
    func makeInitialProfiles(nCells: Int) -> CoreProfiles {
        // Parabolic temperature profiles
        let rho = MLXArray(0..<nCells).asType(.float32) / Float(nCells - 1)

        let T0_ion: Float = 10000.0
        let T0_electron: Float = 10000.0
        let Ti = T0_ion * (1.0 - rho * rho)
        let Te = T0_electron * (1.0 - rho * rho)

        // Fixed density profile
        let n0: Float = 1e20
        let ne = n0 * (1.0 - 0.9 * rho * rho)

        // Fixed poloidal flux
        let psi = MLXArray.zeros([nCells])

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: Ti),
            electronTemperature: EvaluatedArray(evaluating: Te),
            electronDensity: EvaluatedArray(evaluating: ne),
            poloidalFlux: EvaluatedArray(evaluating: psi)
        )
    }

    // MARK: - Tests

    func testP0SingleTimeStep() throws {
        // Setup
        let staticParams = makeP0StaticConfig()
        let dynamicParams = makeP0DynamicConfig()
        let geometry = try Geometry(config: staticParams.mesh)

        let initialProfiles = makeInitialProfiles(nCells: staticParams.mesh.nCells)

        // Create physics models
        let transportModel = ConstantTransportModel(
            chiIon: 1.0,
            chiElectron: 1.0
        )

        let sourceModel = OhmicHeatingSource()

        // Create solver
        let solver = LinearSolver(
            nCorrectorSteps: 3,
            usePereversevCorrector: true,
            theta: staticParams.theta
        )

        // Define coefficients callback
        let coeffsCallback: CoeffsCallback = { profiles, geom in
            let transport = transportModel.computeCoefficients(
                profiles: profiles,
                geometry: geom,
                params: dynamicParams.transportParams
            )

            let sources = sourceModel.computeTerms(
                profiles: profiles,
                geometry: geom,
                params: SourceParameters(modelType: "ohmic", params: [:])
            )

            return buildBlock1DCoeffs(
                transport: transport,
                sources: sources,
                geometry: geom,
                staticParams: staticParams,
                profiles: profiles
            )
        }

        // Extract boundary conditions
        let tiBC = dynamicParams.boundaryConditions.ionTemperature
        let teBC = dynamicParams.boundaryConditions.electronTemperature
        let neBC = dynamicParams.boundaryConditions.electronDensity
        let psiBC = dynamicParams.boundaryConditions.poloidalFlux

        // Create CellVariable tuple
        let xOld = (
            CellVariable(
                value: initialProfiles.ionTemperature.value,
                dr: staticParams.mesh.dr,
                leftFaceGradConstraint: extractGradient(tiBC.left),
                rightFaceConstraint: extractValue(tiBC.right)
            ),
            CellVariable(
                value: initialProfiles.electronTemperature.value,
                dr: staticParams.mesh.dr,
                leftFaceGradConstraint: extractGradient(teBC.left),
                rightFaceConstraint: extractValue(teBC.right)
            ),
            CellVariable(
                value: initialProfiles.electronDensity.value,
                dr: staticParams.mesh.dr,
                leftFaceGradConstraint: extractGradient(neBC.left),
                rightFaceConstraint: extractValue(neBC.right)
            ),
            CellVariable(
                value: initialProfiles.poloidalFlux.value,
                dr: staticParams.mesh.dr,
                leftFaceConstraint: extractValue(psiBC.left),
                rightFaceGradConstraint: extractGradient(psiBC.right)
            )
        )

        // Execute single time step
        let result = solver.solve(
            dt: dynamicParams.dt,
            staticParams: staticParams,
            dynamicParamsT: dynamicParams,
            dynamicParamsTplusDt: dynamicParams,
            geometryT: geometry,
            geometryTplusDt: geometry,
            xOld: xOld,
            coreProfilesT: initialProfiles,
            coreProfilesTplusDt: initialProfiles,
            coeffsCallback: coeffsCallback
        )

        // Verify results
        XCTAssertTrue(result.converged, "Solver should converge for P0 configuration")
        XCTAssertLessThan(result.residualNorm, 1e-5, "Residual should be small")

        // Check physical constraints
        let updatedProfiles = result.updatedProfiles

        let Ti_min = updatedProfiles.ionTemperature.value.min().item(Float.self)
        let Te_min = updatedProfiles.electronTemperature.value.min().item(Float.self)
        XCTAssertGreaterThan(Ti_min, 0.0, "Ion temperature should be positive")
        XCTAssertGreaterThan(Te_min, 0.0, "Electron temperature should be positive")

        let Ti_max = updatedProfiles.ionTemperature.value.max().item(Float.self)
        let Te_max = updatedProfiles.electronTemperature.value.max().item(Float.self)
        XCTAssertLessThan(Ti_max, 20000.0, "Ion temperature should be bounded")
        XCTAssertLessThan(Te_max, 20000.0, "Electron temperature should be bounded")

        print("✅ P0 single time step test passed")
        print("   Residual norm: \(result.residualNorm)")
        print("   Ti range: [\(Ti_min), \(Ti_max)] eV")
        print("   Te range: [\(Te_min), \(Te_max)] eV")
    }

    // MARK: - Helper Functions

    /// Extract value from FaceConstraint (must be .value)
    private func extractValue(_ constraint: FaceConstraint) -> Float {
        switch constraint {
        case .value(let v):
            return v
        case .gradient:
            fatalError("Expected value constraint, got gradient")
        }
    }

    /// Extract gradient from FaceConstraint (must be .gradient)
    private func extractGradient(_ constraint: FaceConstraint) -> Float {
        switch constraint {
        case .gradient(let g):
            return g
        case .value:
            fatalError("Expected gradient constraint, got value")
        }
    }
}
