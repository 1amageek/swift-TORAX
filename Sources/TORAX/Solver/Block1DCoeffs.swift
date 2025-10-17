import Foundation
import MLX

/// Block-structured coefficients for coupled 1D transport equations
///
/// Manages coefficients for 4 coupled PDEs representing tokamak core transport:
/// - Ti: Ion temperature (eV)
/// - Te: Electron temperature (eV)
/// - ne: Electron density (m⁻³)
/// - psi: Poloidal flux (Wb)
///
/// Each equation has its own set of coefficients (EquationCoeffs), allowing
/// for different diffusion, convection, and source terms per variable.
public struct Block1DCoeffs: Sendable {
    /// Coefficients for ion temperature equation
    ///
    /// Equation: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + ∇·(n_e V_i T_i) + Q_i - Q_exchange
    public let ionCoeffs: EquationCoeffs

    /// Coefficients for electron temperature equation
    ///
    /// Equation: n_e ∂T_e/∂t = ∇·(n_e χ_e ∇T_e) + ∇·(n_e V_e T_e) + Q_e + Q_exchange + Q_ohmic
    public let electronCoeffs: EquationCoeffs

    /// Coefficients for electron density equation
    ///
    /// Equation: ∂n_e/∂t = ∇·(D ∇n_e) + ∇·(V n_e) + S_n
    public let densityCoeffs: EquationCoeffs

    /// Coefficients for poloidal flux equation
    ///
    /// Equation: ∂ψ/∂t = η_∥ j_∥ (Ohm's law)
    public let fluxCoeffs: EquationCoeffs

    /// Geometric factors (shared across all equations)
    public let geometry: GeometricFactors

    /// Create block-structured coefficients
    ///
    /// - Parameters:
    ///   - ionCoeffs: Coefficients for Ti equation
    ///   - electronCoeffs: Coefficients for Te equation
    ///   - densityCoeffs: Coefficients for ne equation
    ///   - fluxCoeffs: Coefficients for psi equation
    ///   - geometry: Geometric factors
    public init(
        ionCoeffs: EquationCoeffs,
        electronCoeffs: EquationCoeffs,
        densityCoeffs: EquationCoeffs,
        fluxCoeffs: EquationCoeffs,
        geometry: GeometricFactors
    ) {
        self.ionCoeffs = ionCoeffs
        self.electronCoeffs = electronCoeffs
        self.densityCoeffs = densityCoeffs
        self.fluxCoeffs = fluxCoeffs
        self.geometry = geometry
    }
}

// MARK: - Geometric Factors

/// Geometric factors for finite volume discretization in 1D cylindrical geometry
///
/// Encapsulates all geometric information needed for spatial discretization:
/// - Cell volumes and face areas
/// - Distances between cell centers
/// - Radial coordinates
public struct GeometricFactors: Sendable {
    /// Cell volumes [nCells]
    ///
    /// For cylindrical geometry: V_i = 2π R₀ Δr_i
    /// where R₀ is major radius, Δr_i is radial cell width
    public let cellVolumes: EvaluatedArray

    /// Face areas [nFaces]
    ///
    /// For cylindrical geometry: A_j = 2π R₀
    /// (constant for 1D slab approximation)
    public let faceAreas: EvaluatedArray

    /// Distance between adjacent cell centers [nCells-1]
    ///
    /// Δx_j = r_{i+1} - r_i (for face j between cells i and i+1)
    public let cellDistances: EvaluatedArray

    /// Radial coordinate at cell centers [nCells]
    ///
    /// Normalized radial coordinate: r/a where a is minor radius
    public let rCell: EvaluatedArray

    /// Radial coordinate at cell faces [nFaces]
    ///
    /// Normalized radial coordinate at faces (boundaries between cells)
    public let rFace: EvaluatedArray

    /// Create geometric factors
    ///
    /// - Parameters:
    ///   - cellVolumes: Cell volumes [nCells]
    ///   - faceAreas: Face areas [nFaces]
    ///   - cellDistances: Distances between cell centers [nCells-1]
    ///   - rCell: Radial coordinates at cells [nCells]
    ///   - rFace: Radial coordinates at faces [nFaces]
    public init(
        cellVolumes: EvaluatedArray,
        faceAreas: EvaluatedArray,
        cellDistances: EvaluatedArray,
        rCell: EvaluatedArray,
        rFace: EvaluatedArray
    ) {
        self.cellVolumes = cellVolumes
        self.faceAreas = faceAreas
        self.cellDistances = cellDistances
        self.rCell = rCell
        self.rFace = rFace
    }

    /// Create geometric factors from Geometry (UNIFORM GRID ONLY)
    ///
    /// **MEDIUM #7 WARNING**: This method assumes **uniform grid spacing**.
    ///
    /// - For uniform grids: Generates correct geometric factors with constant Δr
    /// - For non-uniform grids: **Incorrect** - need to specify actual grid in Geometry
    ///
    /// **Future improvement**: Add explicit grid arrays (rFace, rCell) to `Geometry` struct
    /// to support non-uniform grids. Current implementation is adequate for:
    /// - Initial development and testing
    /// - Uniform grid configurations
    /// - Simple tokamak geometries
    ///
    /// For production simulations with edge-refined grids, consider:
    /// 1. Adding `rFace: EvaluatedArray` to `Geometry` struct
    /// 2. Computing geometric factors from actual grid coordinates
    ///
    /// - Parameter geometry: Tokamak geometry
    /// - Returns: Geometric factors for finite volume discretization
    public static func from(geometry: Geometry) -> GeometricFactors {
        let nCells = geometry.nCells
        let nFaces = nCells + 1
        let dr = geometry.dr  // Assumes uniform spacing

        // Radial coordinates (uniform grid assumption)
        let rCell = MLXArray(0..<nCells).asType(.float32) * dr + dr / 2.0  // [nCells]
        let rFace = MLXArray(0..<nFaces).asType(.float32) * dr              // [nFaces]

        // Cell volumes (2π R₀ Δr for cylindrical geometry)
        let cellVolumes = MLXArray.full([nCells], values: MLXArray(2.0 * Float.pi * geometry.majorRadius * dr))

        // Face areas (2π R₀ - constant)
        let faceAreas = MLXArray.full([nFaces], values: MLXArray(2.0 * Float.pi * geometry.majorRadius))

        // Cell distances (uniform grid: all equal to dr)
        let cellDistances = MLXArray.full([nCells - 1], values: MLXArray(dr))

        return GeometricFactors(
            cellVolumes: EvaluatedArray(evaluating: cellVolumes),
            faceAreas: EvaluatedArray(evaluating: faceAreas),
            cellDistances: EvaluatedArray(evaluating: cellDistances),
            rCell: EvaluatedArray(evaluating: rCell),
            rFace: EvaluatedArray(evaluating: rFace)
        )
    }
}

// MARK: - Validation

extension Block1DCoeffs {
    /// Validate all coefficient shapes for consistency
    ///
    /// - Throws: ValidationError if any coefficient has inconsistent shape
    public func validate() throws {
        let nCells = geometry.rCell.value.shape[0]

        try ionCoeffs.validate(nCells: nCells)
        try electronCoeffs.validate(nCells: nCells)
        try densityCoeffs.validate(nCells: nCells)
        try fluxCoeffs.validate(nCells: nCells)

        // Validate geometry
        let nFaces = nCells + 1

        guard geometry.cellVolumes.value.shape[0] == nCells else {
            throw ValidationError.inconsistentShape(
                field: "geometry.cellVolumes",
                expected: [nCells],
                actual: geometry.cellVolumes.value.shape
            )
        }

        guard geometry.faceAreas.value.shape[0] == nFaces else {
            throw ValidationError.inconsistentShape(
                field: "geometry.faceAreas",
                expected: [nFaces],
                actual: geometry.faceAreas.value.shape
            )
        }

        guard geometry.cellDistances.value.shape[0] == nCells - 1 else {
            throw ValidationError.inconsistentShape(
                field: "geometry.cellDistances",
                expected: [nCells - 1],
                actual: geometry.cellDistances.value.shape
            )
        }
    }
}
