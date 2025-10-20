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

    // CRITICAL FIX #3: Use actual density profile with floor
    // Density floor prevents division by zero in non-conservation form (∂T/∂t = rhs/n_e)
    // Physical minimum: n_e ≥ 1e18 m⁻³ (below this, plasma is unphysical)
    let ne_floor: Float = 1e18  // [m⁻³]
    let ne_cell = maximum(profiles.electronDensity.value, MLXArray(ne_floor))  // [nCells] - actual spatial profile with floor
    let ne_face = interpolateToFaces(ne_cell, mode: .harmonic)  // [nFaces]

    // Diffusion coefficient: d = n_e * χ_i (with spatial variation!)
    let dFace = chiIonFaces * ne_face  // [nFaces]

    // Convection velocity: v = n_e * V_i
    // For now, assume no ion heat convection (V_i = 0)
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // Source term: Q_i - Q_exchange
    // CRITICAL UNIT CONVERSION: SourceTerms provides heating in [MW/m³]
    // Temperature equation requires [eV/(m³·s)] to match left side: n_e ∂T_i/∂t [eV/(m³·s)]
    //
    // Dimensional analysis:
    //   Left side:  [m⁻³] × [eV/s] = [eV/(m³·s)]
    //   Diffusion:  ∇·([m⁻³] × [m²/s] × [eV/m]) = [eV/(m³·s)]
    //   Source:     Must be [eV/(m³·s)]
    //
    // Conversion: 1 MW/m³ = 6.2415090744×10²⁴ eV/(m³·s)
    let sourceCell = UnitConversions.megawattsToEvDensity(sources.ionHeating.value)  // [eV/(m³·s)]
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

    // CRITICAL FIX #3: Use actual density profile with floor
    // Density floor prevents division by zero in non-conservation form (∂T/∂t = rhs/n_e)
    // Physical minimum: n_e ≥ 1e18 m⁻³ (below this, plasma is unphysical)
    let ne_floor: Float = 1e18  // [m⁻³]
    let ne_cell = maximum(profiles.electronDensity.value, MLXArray(ne_floor))  // [nCells] - actual spatial profile with floor
    let ne_face = interpolateToFaces(ne_cell, mode: .harmonic)  // [nFaces]

    // Diffusion coefficient: d = n_e * χ_e (with spatial variation!)
    let dFace = chiElectronFaces * ne_face  // [nFaces]

    // Convection velocity: v = n_e * V_e
    // For now, assume no electron heat convection (V_e = 0)
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // Source term: Q_e + Q_ohmic (Q_exchange handled via coupling)
    // CRITICAL UNIT CONVERSION: SourceTerms provides heating in [MW/m³]
    // Temperature equation requires [eV/(m³·s)] to match left side: n_e ∂T_e/∂t [eV/(m³·s)]
    //
    // Dimensional analysis:
    //   Left side:  [m⁻³] × [eV/s] = [eV/(m³·s)]
    //   Diffusion:  ∇·([m⁻³] × [m²/s] × [eV/m]) = [eV/(m³·s)]
    //   Source:     Must be [eV/(m³·s)]
    //
    // Conversion: 1 MW/m³ = 6.2415090744×10²⁴ eV/(m³·s)
    let sourceCell = UnitConversions.megawattsToEvDensity(sources.electronHeating.value)  // [eV/(m³·s)]

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
/// **Implementation Update**: Now uses temperature-dependent Spitzer resistivity
/// and bootstrap current from pressure gradients.
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

    // 1. Temperature-dependent resistivity (Spitzer formula with neoclassical correction)
    let eta_cell = computeSpitzerResistivity(
        Te: profiles.electronTemperature.value,
        geometry: geometry
    )
    let dFace = interpolateToFaces(eta_cell, mode: .harmonic)  // [nFaces]

    // No convection for flux
    let vFace = MLXArray.zeros([nFaces])  // [nFaces]

    // 2. Bootstrap current from pressure gradients
    let J_bootstrap = computeBootstrapCurrent(
        profiles: profiles,
        geometry: geometry
    )

    // 3. Total current source: bootstrap + external
    let J_external = sources.currentSource.value  // [nCells]
    let sourceCell = J_bootstrap + J_external  // [nCells]

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
///
/// **Design Decision**: Different interpolation methods for different physical quantities
///
/// - `arithmetic`: Simple average (a + b) / 2
///   - Used for: convection velocity (standard central differencing)
///   - LinearSolver uses this for variable interpolation
///
/// - `harmonic`: Harmonic mean 2ab / (a + b) = 2 / (1/a + 1/b)
///   - Used for: transport coefficients (χ, D) and electron density in coefficients
///   - Preserves flux continuity across cell boundaries
///   - Reciprocal form prevents Float32 overflow for large values (n_e ~ 1e20)
///
/// See IMPLEMENTATION_NOTES.md Section 1 for detailed rationale.
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
        // Harmonic mean: 2ab/(a+b) = 2 / (1/a + 1/b)
        // **CRITICAL**: Use reciprocal form to avoid Float32 overflow
        //
        // ❌ WRONG: 2 * a * b / (a + b)
        //    With n_e ~ 1e20: 2 * 1e20 * 1e20 = 2e40 > Float32.max (3.4e38) → inf
        //
        // ✅ CORRECT: 2 / (1/a + 1/b)
        //    With n_e ~ 1e20: 1/1e20 = 1e-20 (safe)
        //
        // See IMPLEMENTATION_NOTES.md Section 4 for history of this fix.
        let reciprocalSum = 1.0 / (leftCells + 1e-30) + 1.0 / (rightCells + 1e-30)
        interiorFaces = 2.0 / (reciprocalSum + 1e-30)  // [nCells-1]
    }

    // Boundary faces: use adjacent cell value (no neighbor to interpolate with)
    // Face indexing: [0] | cell 0 | [1] | cell 1 | ... | cell N-1 | [N]
    // See IMPLEMENTATION_NOTES.md Section 2 for face numbering convention.

    // CRITICAL: Force evaluation before calling .item()
    // cellValues[0] and cellValues[nCells-1] are lazy array slices
    let leftBoundary = cellValues[0]
    let rightBoundary = cellValues[nCells - 1]
    eval(leftBoundary, rightBoundary)

    let leftBoundaryValue = leftBoundary.item(Float.self)
    let rightBoundaryValue = rightBoundary.item(Float.self)

    // Build result array manually to avoid concatenation issues
    let nFaces = nCells + 1
    var faceValues = [Float](repeating: 0.0, count: nFaces)

    // Left boundary
    faceValues[0] = leftBoundaryValue

    // Interior faces
    // CRITICAL: Force evaluation before calling .asArray()
    // interiorFaces is a lazy MLXArray (result of arithmetic/harmonic mean computation)
    eval(interiorFaces)
    let interiorArray = interiorFaces.asArray(Float.self)
    for i in 0..<interiorArray.count {
        faceValues[i + 1] = interiorArray[i]
    }

    // Right boundary
    faceValues[nFaces - 1] = rightBoundaryValue

    let result = MLXArray(faceValues)

    return result
}

// MARK: - Current Diffusion Helpers

/// Compute Spitzer resistivity with neoclassical correction
///
/// **Formula**:
/// ```
/// η_Spitzer = 5.2 × 10⁻⁵ * Z_eff * ln(Λ) / T_e^(3/2)  [Ω·m]
/// η_neo = η_Spitzer * (1 + 1.46 * √ε)  [neoclassical correction]
/// ```
///
/// **Parameters**:
/// - Te: Electron temperature [eV], shape [nCells]
/// - geometry: Tokamak geometry
///
/// **Returns**: Resistivity [Ω·m], shape [nCells]
///
/// **References**:
/// - Spitzer & Härm, "Transport Phenomena in a Completely Ionized Gas", Phys. Rev. 89, 977 (1953)
/// - NRL Plasma Formulary (2019)
///
/// **Implementation Note**:
/// Uses default Zeff = 1.5 (typical for ITER with low-Z impurities).
/// Future enhancement: extract Zeff from TransportParameters.params if available.
private func computeSpitzerResistivity(
    Te: MLXArray,
    geometry: Geometry
) -> MLXArray {
    // Default parameters (consistent with OhmicHeating.swift)
    let Zeff: Float = 1.5        // Effective charge (deuterium + low-Z impurities)
    let coulombLog: Float = 17.0  // Coulomb logarithm (typical for tokamak core)

    // Spitzer resistivity: η = 5.2e-5 * Zeff * ln(Λ) / T_e^(3/2)
    let eta_spitzer = 5.2e-5 * Zeff * coulombLog / pow(Te, 1.5)

    // Neoclassical correction for trapped particles
    // Inverse aspect ratio: ε = r/R₀
    let epsilon = geometry.radii.value / geometry.majorRadius

    // Trapped particle correction factor: f_trap ≈ 1 + 1.46 * √ε
    let ft = 1.0 + 1.46 * sqrt(epsilon)

    // Neoclassical resistivity
    let eta_neo = eta_spitzer * ft

    return eta_neo
}

/// Compute bootstrap current from pressure gradients
///
/// **Physics**: Bootstrap current is self-generated current from pressure gradients
/// and trapped particle effects. It's crucial for tokamak steady-state operation.
///
/// **Simplified Sauter Formula**:
/// ```
/// J_BS = C_BS * (∇P) / B_φ
/// where C_BS ≈ (1 - ε) [simplified coefficient]
/// ```
///
/// **Parameters**:
/// - profiles: Current core profiles
/// - geometry: Tokamak geometry
///
/// **Returns**: Bootstrap current density [A/m²], shape [nCells]
///
/// **References**:
/// - Sauter et al., "Neoclassical conductivity and bootstrap current formulas", PoP 6, 2834 (1999)
///
/// **Implementation Note**:
/// This is a simplified version of the full Sauter formula.
/// Full implementation requires collisionality and multiple ion species.
private func computeBootstrapCurrent(
    profiles: CoreProfiles,
    geometry: Geometry
) -> MLXArray {
    let Ti = profiles.ionTemperature.value
    let Te = profiles.electronTemperature.value
    let ne = profiles.electronDensity.value

    // Compute total pressure: P = n_e (T_i + T_e) * e
    // Units: [m⁻³] * [eV] * [1.602e-19 J/eV] = [Pa]
    let P = ne * (Ti + Te) * UnitConversions.eV

    // Compute pressure gradient: ∇P
    // Units: [Pa/m]
    let geoFactors = GeometricFactors.from(geometry: geometry)
    let gradP = computeGradient(P, cellDistances: geoFactors.cellDistances.value)

    // Simplified bootstrap coefficient
    // Full Sauter formula depends on collisionality, trapped fraction, etc.
    // Here we use: C_BS ≈ (1 - ε)
    let epsilon = geometry.radii.value / geometry.majorRadius
    let C_BS = 1.0 - epsilon

    // Bootstrap current density: J_BS = C_BS * (∇P) / B_φ
    // Units: [Pa/m] / [T] = [A/m²]
    let J_BS = C_BS * gradP / geometry.toroidalField

    // Clamp to physical range [0, 10 MA/m²]
    let J_BS_clamped = minimum(maximum(J_BS, MLXArray(0.0)), MLXArray(1e7))

    return J_BS_clamped
}

/// Compute gradient with epsilon regularization
///
/// **Formula**: ∇f ≈ (f[i+1] - f[i]) / Δr
///
/// **Parameters**:
/// - profile: Profile values [nCells]
/// - cellDistances: Distance between cell centers [nCells-1]
///
/// **Returns**: Gradient at cell centers [nCells]
///
/// **Implementation**:
/// - Interior cells: central differencing
/// - Boundary cells: one-sided differencing
/// - Epsilon regularization prevents division by zero
private func computeGradient(_ profile: MLXArray, cellDistances: MLXArray) -> MLXArray {
    let nCells = profile.shape[0]

    // Compute differences: Δf = f[i+1] - f[i]
    let df = profile[1...] - profile[..<(nCells - 1)]  // [nCells-1]

    // Add epsilon to prevent division by zero
    let dr_safe = cellDistances + 1e-10  // [nCells-1]

    // Gradient at interior faces
    let gradFaces = df / dr_safe  // [nCells-1]

    // Interpolate to cell centers (GPU-first, no CPU transfer)
    // - Boundary cells: use nearest face value
    // - Interior cells: average of adjacent faces

    // Left boundary cell (i=0): use gradFaces[0]
    let gradCell0 = gradFaces[0..<1]  // [1]

    // Interior cells (i=1...nCells-2): average of adjacent faces
    // gradCell[i] = (gradFaces[i-1] + gradFaces[i]) / 2
    let leftFaces = gradFaces[0..<(nCells - 2)]   // [nCells-2]
    let rightFaces = gradFaces[1..<(nCells - 1)]  // [nCells-2]
    let gradInterior = (leftFaces + rightFaces) / 2.0  // [nCells-2]

    // Right boundary cell (i=nCells-1): use gradFaces[nCells-2]
    let gradCellN = gradFaces[(nCells - 2)..<(nCells - 1)]  // [1]

    // Concatenate: [1] + [nCells-2] + [1] = [nCells]
    let gradCells = concatenated([gradCell0, gradInterior, gradCellN], axis: 0)

    return gradCells
}
