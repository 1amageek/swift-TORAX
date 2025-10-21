import Foundation
import MLX

// MARK: - Core Profiles

/// Core plasma profiles with type-safe evaluation guarantees
///
/// Contains the primary variables evolved by the transport equations:
/// - Ion temperature (Ti)
/// - Electron temperature (Te)
/// - Electron density (ne)
/// - Poloidal flux (psi)
public struct CoreProfiles: Sendable, Equatable {
    /// Ion temperature [eV]
    public let ionTemperature: EvaluatedArray

    /// Electron temperature [eV]
    public let electronTemperature: EvaluatedArray

    /// Electron density [m^-3]
    public let electronDensity: EvaluatedArray

    /// Poloidal flux [Wb]
    public let poloidalFlux: EvaluatedArray

    public init(
        ionTemperature: EvaluatedArray,
        electronTemperature: EvaluatedArray,
        electronDensity: EvaluatedArray,
        poloidalFlux: EvaluatedArray
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }
}

// MARK: - Safety Factor Calculation

extension CoreProfiles {
    /// Compute safety factor profile from poloidal flux
    ///
    /// **Physics**: Safety factor q(ρ) determines MHD stability.
    ///
    /// **Formula**:
    /// ```
    /// q(ρ) = (r B_φ) / (R₀ B_θ)
    /// where B_θ = (1/r) ∂ψ/∂r
    /// ```
    ///
    /// **Critical Values**:
    /// - q(0) < 1: Sawteeth MHD instability occurs
    /// - q(edge) > 3: Good MHD stability
    ///
    /// **Parameters**:
    /// - geometry: Tokamak geometry
    ///
    /// **Returns**: Safety factor profile, shape [nCells]
    ///
    /// **References**:
    /// - Wesson, "Tokamak Physics" (1987), Chapter 3
    ///
    /// **Implementation Note**:
    /// Result is clamped to physical range [0.3, 20] to prevent
    /// numerical issues when poloidal flux gradient is very small.
    public func safetyFactor(geometry: Geometry) -> MLXArray {
        let r = geometry.radii.value
        let R0 = geometry.majorRadius
        let Bphi = geometry.toroidalField
        let psi = poloidalFlux.value

        // Use MLXGradient for robust gradient computation with central differencing
        let dPsi_dr = MLXGradient.radialGradient(field: psi, radii: r)

        // Compute poloidal magnetic field: B_θ = (1/r) ∂ψ/∂r
        let Btheta = dPsi_dr / (r + 1e-10)

        // Compute safety factor: q = (r B_φ) / (R₀ B_θ)
        let q = (r * Bphi) / (R0 * Btheta + 1e-10)

        // Clamp to physical range [0.3, 20]
        // - Lower bound: q < 0.3 indicates severe MHD instability (unphysical)
        // - Upper bound: q > 20 is rare in tokamaks
        let q_clamped = minimum(maximum(q, MLXArray(0.3)), MLXArray(20.0))

        return q_clamped
    }

    /// Compute magnetic shear from safety factor
    ///
    /// **Physics**: Magnetic shear ŝ measures the twist rate of field lines.
    ///
    /// **Formula**:
    /// ```
    /// ŝ = (r/q) dq/dr
    /// ```
    ///
    /// **Parameters**:
    /// - geometry: Tokamak geometry
    ///
    /// **Returns**: Magnetic shear profile, shape [nCells]
    ///
    /// **References**:
    /// - Wesson, "Tokamak Physics" (1987)
    public func magneticShear(geometry: Geometry) -> MLXArray {
        let q = safetyFactor(geometry: geometry)
        let r = geometry.radii.value

        // Use MLXGradient for robust gradient computation with central differencing
        let shear = MLXGradient.magneticShear(q: q, radii: r)

        // Clamp to reasonable range [-5, 5]
        let shear_clamped = minimum(maximum(shear, MLXArray(-5.0)), MLXArray(5.0))

        return shear_clamped
    }

    /// Compute flux gradient with central differencing
    ///
    /// **Implementation**: Similar to computeGradient() in Block1DCoeffsBuilder.swift
    /// but included here to avoid circular dependencies.
    ///
    /// **Parameters**:
    /// - psi: Flux or any profile [nCells]
    /// - radii: Radial grid points [nCells]
    /// - cellDistances: Distance between cell centers [nCells-1]
    ///
    /// **Returns**: Gradient at cell centers [nCells]
    private func computeFluxGradient(psi: MLXArray, radii: MLXArray, cellDistances: MLXArray) -> MLXArray {
        let nCells = psi.shape[0]

        // Compute differences: Δψ = ψ[i+1] - ψ[i]
        let dPsi = psi[1...] - psi[..<(nCells - 1)]  // [nCells-1]

        // Add epsilon to prevent division by zero
        let dr_safe = cellDistances + 1e-10  // [nCells-1]

        // Gradient at interior faces
        let gradFaces = dPsi / dr_safe  // [nCells-1]

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
}
