import Foundation
import MLX

// MARK: - Geometry Extensions

extension Geometry {
    /// Convenience initializer from MeshConfig
    ///
    /// Creates a Geometry instance by computing all geometric coefficients from
    /// the mesh configuration. This is a convenience wrapper around
    /// `createGeometry(from:)` from GeometryHelpers.swift.
    ///
    /// **Geometric Coefficients (for circular geometry):**
    /// - g0 = (R₀ + r)² - flux surface area metric
    /// - g1 = R₀ + r - major radius at flux surface
    /// - g2 = 1 - shape factor (constant for circular)
    /// - g3 = r - minor radius coordinate
    ///
    /// - Parameters:
    ///   - config: Mesh configuration
    ///   - q0: Safety factor at axis (default: 1.0)
    ///   - qEdge: Safety factor at edge (default: 3.5)
    public init(
        config: MeshConfig,
        q0: Float = 1.0,
        qEdge: Float = 3.5
    ) {
        let geometry = createGeometry(from: config, q0: q0, qEdge: qEdge)
        self.init(
            majorRadius: geometry.majorRadius,
            minorRadius: geometry.minorRadius,
            toroidalField: geometry.toroidalField,
            volume: geometry.volume,
            g0: geometry.g0,
            g1: geometry.g1,
            g2: geometry.g2,
            g3: geometry.g3,
            radii: geometry.radii,
            safetyFactor: geometry.safetyFactor,
            poloidalField: geometry.poloidalField,
            currentDensity: geometry.currentDensity,
            type: geometry.type
        )
    }

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
