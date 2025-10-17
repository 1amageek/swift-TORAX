import Foundation

// MARK: - Block1D Coefficients

/// Complete set of FVM coefficients for 1D block-tridiagonal system
///
/// These coefficients define the discretized PDE system for the finite volume method.
public struct Block1DCoeffs: Sendable, Equatable {
    /// Transient coefficient in cell [∂(x*coeff)/∂t]
    public let transientInCell: EvaluatedArray

    /// Transient coefficient out of cell [coeff*∂(...)/∂t]
    public let transientOutCell: EvaluatedArray

    /// Diffusion coefficient on faces
    public let dFace: EvaluatedArray

    /// Convection coefficient on faces
    public let vFace: EvaluatedArray

    /// Implicit source matrix coefficient in cells
    public let sourceMatCell: EvaluatedArray

    /// Explicit source in cells
    public let sourceCell: EvaluatedArray

    public init(
        transientInCell: EvaluatedArray,
        transientOutCell: EvaluatedArray,
        dFace: EvaluatedArray,
        vFace: EvaluatedArray,
        sourceMatCell: EvaluatedArray,
        sourceCell: EvaluatedArray
    ) {
        self.transientInCell = transientInCell
        self.transientOutCell = transientOutCell
        self.dFace = dFace
        self.vFace = vFace
        self.sourceMatCell = sourceMatCell
        self.sourceCell = sourceCell
    }
}
