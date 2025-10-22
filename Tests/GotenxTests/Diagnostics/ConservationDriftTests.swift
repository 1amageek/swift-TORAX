// ConservationDriftTests.swift
// Unit tests for conservation drift monitoring
//
// Phase 3 Implementation: Conservation law validation

import Testing
import Foundation
import MLX
@testable import GotenxCore

@Suite("Conservation Drift Tests")
struct ConservationDriftTests {

    // MARK: - Test Helpers

    /// Create simple test geometry (circular, 10 cells)
    ///
    /// Uses the production `createGeometry(from:)` helper to ensure consistency
    /// with the implementation. This guarantees:
    /// - g0/g1/g2/g3: [nCells + 1] elements (face-centered)
    /// - radii, safetyFactor: [nCells] elements (cell-centered)
    private func createTestGeometry() -> Geometry {
        let mesh = MeshConfig(
            nCells: 10,
            majorRadius: 6.2,   // [m]
            minorRadius: 2.0,   // [m]
            toroidalField: 5.3, // [T]
            geometryType: .circular
        )

        return createGeometry(from: mesh, q0: 1.0, qEdge: 3.5)
    }

    /// Create test profiles
    private func createProfiles(nCells: Int, Ti: Float, Te: Float, ne: Float, psi: Float = 0.0) -> CoreProfiles {
        let Ti_array = [Float](repeating: Ti, count: nCells)
        let Te_array = [Float](repeating: Te, count: nCells)
        let ne_array = [Float](repeating: ne, count: nCells)
        let psi_array = [Float](repeating: psi, count: nCells)

        return CoreProfiles(
            ionTemperature: EvaluatedArray(evaluating: MLXArray(Ti_array)),
            electronTemperature: EvaluatedArray(evaluating: MLXArray(Te_array)),
            electronDensity: EvaluatedArray(evaluating: MLXArray(ne_array)),
            poloidalFlux: EvaluatedArray(evaluating: MLXArray(psi_array))
        )
    }

    // MARK: - Perfect Conservation Tests

    @Test("Zero drift for identical profiles")
    func testZeroDriftIdenticalProfiles() {
        let geometry = createTestGeometry()
        let profiles = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)

        // Compute conservation drifts (same initial and current)
        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: profiles,
            initial: profiles,
            geometry: geometry
        )

        // Expect zero drift (within numerical precision)
        #expect(abs(drifts.particle) < 1e-6)
        #expect(abs(drifts.energy) < 1e-6)
        #expect(abs(drifts.current) < 1e-6)
    }

    // MARK: - Particle Conservation Tests

    @Test("Particle drift detection: 10% increase")
    func testParticleDriftIncrease() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1.1e20)  // 10% increase

        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: current,
            initial: initial,
            geometry: geometry
        )

        // Expect ~10% particle drift
        #expect(abs(drifts.particle - 0.1) < 0.01)  // Within 1%
    }

    @Test("Particle drift detection: 5% decrease")
    func testParticleDriftDecrease() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 0.95e20)  // 5% decrease

        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: current,
            initial: initial,
            geometry: geometry
        )

        // Expect ~-5% particle drift
        #expect(abs(drifts.particle - (-0.05)) < 0.01)
    }

    // MARK: - Energy Conservation Tests

    @Test("Energy drift detection: Temperature change")
    func testEnergyDriftTemperatureChange() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 12000, Te: 12000, ne: 1e20)  // 20% temperature increase

        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: current,
            initial: initial,
            geometry: geometry
        )

        // Energy ∝ n*T, so 20% temperature increase → 20% energy increase
        #expect(abs(drifts.energy - 0.2) < 0.01)
    }

    @Test("Energy drift detection: Combined changes")
    func testEnergyDriftCombined() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        // Both density and temperature increase by 10% → energy increases by ~21%
        let current = createProfiles(nCells: 10, Ti: 11000, Te: 11000, ne: 1.1e20)

        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: current,
            initial: initial,
            geometry: geometry
        )

        // W ∝ n*(Ti+Te), so (1.1 * 1.1 * 2) / 2 - 1 ≈ 0.21
        #expect(abs(drifts.energy - 0.21) < 0.02)
    }

    // MARK: - Current Conservation Tests

    @Test("Current drift detection: Flux change")
    func testCurrentDriftFluxChange() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20, psi: 1.0)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20, psi: 1.2)  // 20% increase

        let drifts = NumericalDiagnosticsCollector.computeConservationDrifts(
            current: current,
            initial: initial,
            geometry: geometry
        )

        // Current proxy (∫ψ dV) increases by 20%
        #expect(abs(drifts.current - 0.2) < 0.01)
    }

    // MARK: - Diagnostics Integration Tests

    @Test("Diagnostics collection without conservation")
    func testDiagnosticsWithoutConservation() {
        // Create mock solver result
        let solverResult = SolverResult(
            updatedProfiles: createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20),
            iterations: 5,
            residualNorm: 1e-7,
            converged: true,
            metadata: [:]
        )

        // Collect diagnostics without conservation monitoring
        let diagnostics = NumericalDiagnosticsCollector.collect(
            from: solverResult,
            dt: 1e-4,
            wallTime: 0.01
        )

        // Expect zero conservation drifts (not computed)
        #expect(diagnostics.particle_drift == 0)
        #expect(diagnostics.energy_drift == 0)
        #expect(diagnostics.current_drift == 0)

        // But solver metrics should be populated
        #expect(diagnostics.newton_iterations == 5)
        #expect(diagnostics.converged == true)
        #expect(diagnostics.residual_norm == 1e-7)
    }

    @Test("Diagnostics collection with conservation")
    func testDiagnosticsWithConservation() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1.05e20)  // 5% drift

        let solverResult = SolverResult(
            updatedProfiles: current,
            iterations: 5,
            residualNorm: 1e-7,
            converged: true,
            metadata: [:]
        )

        // Collect diagnostics with conservation monitoring
        let diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: 1e-4,
            wallTime: 0.01,
            currentProfiles: current,
            initialProfiles: initial,
            geometry: geometry
        )

        // Expect non-zero particle drift
        #expect(abs(diagnostics.particle_drift - 0.05) < 0.01)

        // Energy drift should also be present (T unchanged, n increased 5%)
        #expect(abs(diagnostics.energy_drift - 0.05) < 0.01)

        // Solver metrics should still be populated
        #expect(diagnostics.newton_iterations == 5)
        #expect(diagnostics.converged == true)
    }

    // MARK: - Health Monitoring Tests

    @Test("Health check: Healthy simulation")
    func testHealthCheckHealthy() {
        let geometry = createTestGeometry()
        let profiles = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)

        let solverResult = SolverResult(
            updatedProfiles: profiles,
            iterations: 5,
            residualNorm: 1e-7,
            converged: true,
            metadata: [:]
        )

        let diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: 1e-4,
            currentProfiles: profiles,
            initialProfiles: profiles,
            geometry: geometry
        )

        // Should be healthy (zero drift, converged)
        #expect(diagnostics.isHealthy == true)
        #expect(diagnostics.warningLevel == 0)
    }

    @Test("Health check: Minor drift warning")
    func testHealthCheckMinorDrift() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1.02e20)  // 2% drift

        let solverResult = SolverResult(
            updatedProfiles: current,
            iterations: 5,
            residualNorm: 1e-7,
            converged: true,
            metadata: [:]
        )

        let diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: 1e-4,
            currentProfiles: current,
            initialProfiles: initial,
            geometry: geometry
        )

        // Should trigger warning level 1 (1-5% drift)
        #expect(diagnostics.warningLevel == 1)
        #expect(diagnostics.isHealthy == false)
    }

    @Test("Health check: Critical drift")
    func testHealthCheckCriticalDrift() {
        let geometry = createTestGeometry()
        let initial = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)
        let current = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1.08e20)  // 8% drift

        let solverResult = SolverResult(
            updatedProfiles: current,
            iterations: 5,
            residualNorm: 1e-7,
            converged: true,
            metadata: [:]
        )

        let diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: 1e-4,
            currentProfiles: current,
            initialProfiles: initial,
            geometry: geometry
        )

        // Should trigger warning level 2 (>5% drift)
        #expect(diagnostics.warningLevel == 2)
        #expect(diagnostics.isHealthy == false)
    }

    @Test("Health check: Non-convergence")
    func testHealthCheckNonConvergence() {
        let geometry = createTestGeometry()
        let profiles = createProfiles(nCells: 10, Ti: 10000, Te: 10000, ne: 1e20)

        let solverResult = SolverResult(
            updatedProfiles: profiles,
            iterations: 100,
            residualNorm: 1e-3,
            converged: false,  // Didn't converge
            metadata: [:]
        )

        let diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: 1e-4,
            currentProfiles: profiles,
            initialProfiles: profiles,
            geometry: geometry
        )

        // Should be unhealthy (non-convergence)
        #expect(diagnostics.isHealthy == false)
        #expect(diagnostics.converged == false)
    }
}
