import MLX
import Foundation

// MARK: - Block 1D Coefficients Builder

/// Build block-structured coefficients from physics models
///
/// Constructs per-equation coefficients for the 4 coupled transport equations in **non-conservation form**:
///
/// - Ion temperature: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + ∇·(n_e V_i T_i) + Q_i - Q_exchange
/// - Electron temperature: n_e ∂T_e/∂t = ∇·(n_e χ_e ∇T_e) + ∇·(n_e V_e T_e) + Q_e + Q_exchange + Q_ohmic
/// - Electron density: ∂n_e/∂t = ∇·(D ∇n_e) + ∇·(V n_e) + S_n
/// - Poloidal flux: ∂ψ/∂t = η_∥ j_∥ (from Ohm's law)
///
/// **Implementation Note (Conservation Form):**
/// This implementation uses **non-conservation form** (following Python TORAX), where the time derivative
/// is `n_e ∂T_i/∂t` rather than the conservation form `∂(n_e T_i)/∂t`.
///
/// - Conservation form: ∂(n_e T_i)/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
///   - Expands to: n_e ∂T_i/∂t + T_i ∂n_e/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
///   - **Pro**: Better energy conservation when density changes rapidly (pellets, gas puff)
///   - **Con**: More complex to implement
///
/// - Non-conservation form: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i (current implementation)
///   - **Pro**: Simpler, matches Python TORAX, adequate for slow density evolution
///   - **Con**: May have small energy conservation errors during rapid density changes
///
/// The `transientCoeff` field in `EquationCoeffs` contains n_e(r) to properly weight the time derivative.
///
/// - Parameters:
///   - transport: Transport coefficients (chi, D, V)
///   - sources: Source terms (heating, particles, current)
///   - geometry: Tokamak geometry
///   - staticParams: Static runtime parameters
///   - profiles: Current core profiles (CRITICAL FIX #3: for actual density)
/// - Returns: Block coefficients with per-equation structure
public func buildBlock1DCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> Block1DCoeffs {
    // Build geometric factors (shared across equations)
    let geoFactors = GeometricFactors.from(geometry: geometry)

    // Build per-equation coefficients (with actual profiles)
    let ionCoeffs = buildIonEquationCoeffs(
        transport: transport,
        sources: sources,
        geometry: geometry,
        staticParams: staticParams,
        profiles: profiles
    )

    let electronCoeffs = buildElectronEquationCoeffs(
        transport: transport,
        sources: sources,
        geometry: geometry,
        staticParams: staticParams,
        profiles: profiles
    )

    let densityCoeffs = buildDensityEquationCoeffs(
        transport: transport,
        sources: sources,
        geometry: geometry,
        staticParams: staticParams,
        profiles: profiles
    )

    let fluxCoeffs = buildFluxEquationCoeffs(
        transport: transport,
        sources: sources,
        geometry: geometry,
        staticParams: staticParams,
        profiles: profiles
    )

    return Block1DCoeffs(
        ionCoeffs: ionCoeffs,
        electronCoeffs: electronCoeffs,
        densityCoeffs: densityCoeffs,
        fluxCoeffs: fluxCoeffs,
        geometry: geoFactors
    )
}

// MARK: - Per-Equation Coefficient Builders

/// Build coefficients for ion temperature equation
///
/// Equation: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + ∇·(n_e V_i T_i) + Q_i - Q_exchange
///
/// - Returns: Coefficients for Ti equation
private func buildIonEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    let nCells = geometry.nCells
    let nFaces = nCells + 1

    // Interpolate transport coefficients to faces
    let chiIonFaces = interpolateToFaces(transport.chiIon.value, mode: .harmonic)  // [nFaces]

    // CRITICAL FIX #3: Use actual density profile
    let ne_cell = profiles.electronDensity.value  // [nCells] - actual spatial profile
    let ne_face = interpolateToFaces(ne_cell, mode: .harmonic)  // [nFaces]

    // Diffusion coefficient: d = n_e * χ_i (with spatial variation!)
    let dFace = chiIonFaces * ne_face  // [nFaces]

    // Convection velocity: v = n_e * V_i
    // For now, assume no ion heat convection (V_i = 0)
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // Source term: Q_i - Q_exchange
    let sourceCell = sources.ionHeating.value  // [nCells]
    // Q_exchange is implicit coupling term (handled via sourceMatCell)

    // Source matrix coefficient: -Q_exchange coupling
    // For now, assume decoupled (explicit exchange in source)
    let sourceMatCell = MLXArray.zeros([nCells])  // [nCells]

    // Transient coefficient: n_e (with spatial variation!)
    let transientCoeff = ne_cell  // [nCells] - actual density profile

    return EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray(evaluating: vFace),
        sourceCell: EvaluatedArray(evaluating: sourceCell),
        sourceMatCell: EvaluatedArray(evaluating: sourceMatCell),
        transientCoeff: EvaluatedArray(evaluating: transientCoeff)
    )
}

/// Build coefficients for electron temperature equation
///
/// Equation: n_e ∂T_e/∂t = ∇·(n_e χ_e ∇T_e) + ∇·(n_e V_e T_e) + Q_e + Q_exchange + Q_ohmic
///
/// - Returns: Coefficients for Te equation
private func buildElectronEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    let nCells = geometry.nCells
    let nFaces = nCells + 1

    // Interpolate transport coefficients to faces
    let chiElectronFaces = interpolateToFaces(transport.chiElectron.value, mode: .harmonic)  // [nFaces]

    // CRITICAL FIX #3: Use actual density profile
    let ne_cell = profiles.electronDensity.value  // [nCells] - actual spatial profile
    let ne_face = interpolateToFaces(ne_cell, mode: .harmonic)  // [nFaces]

    // Diffusion coefficient: d = n_e * χ_e (with spatial variation!)
    let dFace = chiElectronFaces * ne_face  // [nFaces]

    // Convection velocity: v = n_e * V_e
    // For now, assume no electron heat convection (V_e = 0)
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // Source term: Q_e + Q_ohmic (Q_exchange handled via coupling)
    let sourceCell = sources.electronHeating.value  // [nCells]

    // Source matrix coefficient
    let sourceMatCell = MLXArray.zeros([nCells])  // [nCells]

    // Transient coefficient: n_e (with spatial variation!)
    let transientCoeff = ne_cell  // [nCells] - actual density profile

    return EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray(evaluating: vFace),
        sourceCell: EvaluatedArray(evaluating: sourceCell),
        sourceMatCell: EvaluatedArray(evaluating: sourceMatCell),
        transientCoeff: EvaluatedArray(evaluating: transientCoeff)
    )
}

/// Build coefficients for electron density equation
///
/// Equation: ∂n_e/∂t = ∇·(D ∇n_e) + ∇·(V n_e) + S_n
///
/// - Returns: Coefficients for ne equation
private func buildDensityEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    let nCells = geometry.nCells
    let nFaces = nCells + 1

    // Interpolate particle diffusivity to faces
    let DFaces = interpolateToFaces(transport.particleDiffusivity.value, mode: .harmonic)  // [nFaces]

    // Diffusion coefficient
    let dFace = DFaces  // [nFaces]

    // Convection velocity
    let VFaces = interpolateToFaces(transport.convectionVelocity.value, mode: .arithmetic)  // [nFaces]
    let vFace = VFaces  // [nFaces]

    // Source term
    let sourceCell = sources.particleSource.value  // [nCells]

    // Source matrix coefficient
    let sourceMatCell = MLXArray.zeros([nCells])  // [nCells]

    // Transient coefficient: 1.0 (continuity equation)
    let transientCoeff = MLXArray.ones([nCells])  // [nCells]

    return EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray(evaluating: vFace),
        sourceCell: EvaluatedArray(evaluating: sourceCell),
        sourceMatCell: EvaluatedArray(evaluating: sourceMatCell),
        transientCoeff: EvaluatedArray(evaluating: transientCoeff)
    )
}

/// Build coefficients for poloidal flux equation
///
/// Equation: ∂ψ/∂t = η_∥ j_∥ (from Ohm's law)
///
/// This can be rewritten as a diffusion-like equation with current sources.
///
/// - Returns: Coefficients for psi equation
private func buildFluxEquationCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams,
    profiles: CoreProfiles
) -> EquationCoeffs {
    let nCells = geometry.nCells
    let nFaces = nCells + 1

    // For poloidal flux evolution, diffusion comes from resistivity
    // η_∥ is parallel resistivity
    let eta_parallel = Float(1e-7)  // Typical plasma resistivity (Ω·m)
    let dFace = MLXArray.full([nFaces], values: MLXArray(eta_parallel))  // [nFaces]

    // No convection for flux
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // Source: current drive (bootstrap + external)
    let sourceCell = sources.currentSource.value  // [nCells]

    // Source matrix coefficient
    let sourceMatCell = MLXArray.zeros([nCells])  // [nCells]

    // Transient coefficient: L_p (poloidal inductance)
    // For simplicity, use 1.0 (properly should be μ₀ R₀)
    let transientCoeff = MLXArray.ones([nCells])  // [nCells]

    return EquationCoeffs(
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray(evaluating: vFace),
        sourceCell: EvaluatedArray(evaluating: sourceCell),
        sourceMatCell: EvaluatedArray(evaluating: sourceMatCell),
        transientCoeff: EvaluatedArray(evaluating: transientCoeff)
    )
}

// MARK: - Interpolation Helpers

/// Interpolation mode for cell-to-face conversion
private enum InterpolationMode {
    case arithmetic  // Simple average: (a + b) / 2
    case harmonic    // Harmonic mean: 2ab / (a + b) - preserves flux continuity
}

/// Interpolate cell-centered values to faces
///
/// - Parameters:
///   - cellValues: Values at cell centers [nCells]
///   - mode: Interpolation mode (arithmetic or harmonic)
/// - Returns: Values at cell faces [nFaces]
private func interpolateToFaces(_ cellValues: MLXArray, mode: InterpolationMode) -> MLXArray {
    let nCells = cellValues.shape[0]

    // Interior faces
    let leftCells = cellValues[0..<(nCells - 1)]   // [nCells-1]
    let rightCells = cellValues[1..<nCells]        // [nCells-1]

    let interiorFaces: MLXArray
    switch mode {
    case .arithmetic:
        // Simple average
        interiorFaces = (leftCells + rightCells) / 2.0  // [nCells-1]

    case .harmonic:
        // Harmonic mean: 2ab/(a+b)
        // Add small epsilon to avoid division by zero
        interiorFaces = 2.0 * leftCells * rightCells / (leftCells + rightCells + 1e-10)  // [nCells-1]
    }

    // Boundary faces: use adjacent cell value
    let leftBoundary = cellValues[0..<1]           // [1]
    let rightBoundary = cellValues[(nCells - 1)..<nCells]  // [1]

    // Concatenate: [left_boundary, interior_faces, right_boundary]
    return concatenated([leftBoundary, interiorFaces, rightBoundary], axis: 0)  // [nFaces]
}
