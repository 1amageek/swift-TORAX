import MLX
import Foundation

// MARK: - Block 1D Coefficients Builder

/// Build Block1DCoeffs from transport coefficients and source terms
///
/// This function constructs the coefficient arrays needed for FVM discretization:
/// - transientInCell: ∂(x*coeff)/∂t terms
/// - transientOutCell: coeff*∂(...)/∂t terms
/// - dFace: Diffusion coefficients on faces
/// - vFace: Convection velocities on faces
/// - sourceMatCell: Implicit source matrix coefficients
/// - sourceCell: Explicit source terms
public func buildBlock1DCoeffs(
    transport: TransportCoefficients,
    sources: SourceTerms,
    geometry: Geometry,
    staticParams: StaticRuntimeParams
) -> Block1DCoeffs {
    let nCells = transport.chiIon.shape[0]

    // Geometric coefficients for FVM
    let g0 = geometry.g0.value
    let g1 = geometry.g1.value

    // Transient terms (time derivatives)
    // transientInCell: ∂(ρ*V)/∂t = V * ∂ρ/∂t (volume factors)
    let transientInCell = geometry.volume.value

    // transientOutCell: for implicit time-stepping
    let transientOutCell = MLXArray.ones([nCells])

    // Diffusion coefficients on faces
    // For heat transport: D_face = χ * (geometric factors)
    let chiIonFaces = interpolateToFaces(transport.chiIon.value)
    let chiElectronFaces = interpolateToFaces(transport.chiElectron.value)

    // Use ion chi for simplicity (in full implementation, handle per-equation)
    let dFace = chiIonFaces * g1[0..<(nCells + 1)] / g0[0..<(nCells + 1)]

    // Convection on faces
    let particleDiffFaces = interpolateToFaces(transport.particleDiffusivity.value)
    let convectionFaces = interpolateToFaces(transport.convectionVelocity.value)
    let vFace = convectionFaces * g1[0..<(nCells + 1)] / g0[0..<(nCells + 1)]

    // Source terms
    // sourceMatCell: implicit source coefficients (e.g., for electron-ion exchange)
    let sourceMatCell = MLXArray.zeros([nCells])  // No implicit sources for now

    // sourceCell: explicit sources (heating, particles, etc.)
    let ionHeating = sources.ionHeating.value
    let electronHeating = sources.electronHeating.value
    let particleSource = sources.particleSource.value

    // Combine sources (weighted by geometry)
    let sourceCell = (ionHeating + electronHeating + particleSource) / geometry.volume.value

    return Block1DCoeffs(
        transientInCell: EvaluatedArray(evaluating: transientInCell),
        transientOutCell: EvaluatedArray(evaluating: transientOutCell),
        dFace: EvaluatedArray(evaluating: dFace),
        vFace: EvaluatedArray(evaluating: vFace),
        sourceMatCell: EvaluatedArray(evaluating: sourceMatCell),
        sourceCell: EvaluatedArray(evaluating: sourceCell)
    )
}

/// Interpolate cell-centered values to faces
///
/// Uses linear interpolation: face[i+1/2] = (cell[i] + cell[i+1]) / 2
/// Boundary faces use extrapolation
private func interpolateToFaces(_ cellValues: MLXArray) -> MLXArray {
    let nCells = cellValues.shape[0]

    // Left boundary face (extrapolate)
    let leftFace = cellValues[0..<1]

    // Inner faces (average)
    let leftCells = cellValues[0..<(nCells - 1)]
    let rightCells = cellValues[1..<nCells]
    let innerFaces = (leftCells + rightCells) / 2.0

    // Right boundary face (extrapolate)
    let rightFace = cellValues[(nCells - 1)..<nCells]

    // Concatenate: [left, inner..., right]
    return concatenated([leftFace, innerFaces, rightFace], axis: 0)
}
