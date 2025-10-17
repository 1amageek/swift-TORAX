import Foundation
import MLX

// MARK: - Geometry Extensions

extension Geometry {
    /// Number of radial cells
    ///
    /// Derived from g0 shape. g0 is defined on cell faces, so:
    /// - g0.shape = [nFaces]
    /// - nFaces = nCells + 1
    /// - Therefore: nCells = g0.shape[0] - 1
    public var nCells: Int {
        // g0 is on faces (boundaries between cells)
        let nFaces = g0.value.shape[0]
        return nFaces - 1
    }

    /// Radial grid spacing (for uniform grids only)
    ///
    /// **MEDIUM #7 WARNING**: This property assumes **uniform grid spacing**.
    ///
    /// - For uniform grids: Returns constant Δr = a / nCells
    /// - For non-uniform grids: **This is incorrect** - use GeometricFactors.cellDistances instead
    ///
    /// **Recommendation**: Avoid using this property. Instead:
    /// 1. Use `GeometricFactors.cellDistances` for actual cell-to-cell distances
    /// 2. Use `GeometricFactors.rCell` and `GeometricFactors.rFace` for radial coordinates
    ///
    /// This property is kept for backward compatibility with uniform grid configurations,
    /// but should be deprecated in favor of explicit grid specification in `Geometry`.
    public var dr: Float {
        guard nCells > 0 else { return 0.0 }
        return minorRadius / Float(nCells)
    }
}
