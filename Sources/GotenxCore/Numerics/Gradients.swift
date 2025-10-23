// Gradients.swift
// Numerical gradient computation utilities for FVM grids

import Foundation
import MLX

/// Gradient computation utilities for radial profiles on FVM grids
///
/// All functions use finite difference schemes appropriate for the FVM grid structure.
/// Boundary conditions are handled with zero-gradient assumptions at both ends.
public struct GradientComputation {

    /// Compute gradient of a radial profile using central differences
    ///
    /// Uses second-order accurate central differences:
    /// ∇f[i] ≈ (f[i+1] - f[i-1]) / (2Δr)
    ///
    /// **Boundary conditions**:
    /// - At r=0: Forward difference
    /// - At r=a: Backward difference
    ///
    /// **Parameters**:
    /// - variable: Profile to differentiate [nCells]
    /// - radii: Radial coordinate array [nCells] in meters
    ///
    /// **Returns**: Gradient ∇f [nCells] in units of variable/m
    public static func computeGradient(
        variable: MLXArray,
        radii: MLXArray
    ) -> MLXArray {
        let nCells = variable.shape[0]
        var gradArray = [Float](repeating: 0.0, count: nCells)

        let varArray = variable.asArray(Float.self)
        let radiiArray = radii.asArray(Float.self)

        // Forward difference at r=0 (i=0)
        if nCells > 1 {
            let dr = radiiArray[1] - radiiArray[0]
            gradArray[0] = (varArray[1] - varArray[0]) / dr
        }

        // Central differences for interior points
        for i in 1..<(nCells - 1) {
            let dr = radiiArray[i + 1] - radiiArray[i - 1]
            gradArray[i] = (varArray[i + 1] - varArray[i - 1]) / dr
        }

        // Backward difference at r=a (i=nCells-1)
        if nCells > 1 {
            let dr = radiiArray[nCells - 1] - radiiArray[nCells - 2]
            gradArray[nCells - 1] = (varArray[nCells - 1] - varArray[nCells - 2]) / dr
        }

        let grad = MLXArray(gradArray)
        eval(grad)
        return grad
    }

    /// Compute gradient scale length L = |f| / |∇f|
    ///
    /// The gradient scale length characterizes the spatial scale over which
    /// a profile varies significantly.
    ///
    /// **Parameters**:
    /// - variable: Profile [nCells]
    /// - radii: Radial coordinates [nCells] in meters
    /// - epsilon: Regularization to prevent division by zero (default: 1e-10)
    ///
    /// **Returns**: Gradient scale length L [nCells] in meters
    ///
    /// **Example**:
    /// ```swift
    /// let L_T = computeGradientLength(
    ///     variable: profiles.ionTemperature.value,
    ///     radii: geometry.radii.value
    /// )
    /// ```
    public static func computeGradientLength(
        variable: MLXArray,
        radii: MLXArray,
        epsilon: Float = 1e-10
    ) -> MLXArray {
        // Compute gradient
        let gradVar = computeGradient(variable: variable, radii: radii)

        // L = |f| / |∇f|
        let L = abs(variable) / (abs(gradVar) + epsilon)
        eval(L)
        return L
    }

    /// Compute normalized gradient R/L_n = (R₀/n)(dn/dr)
    ///
    /// This is the dimensionless gradient commonly used in turbulence theory.
    ///
    /// **Parameters**:
    /// - variable: Profile (e.g., density, temperature) [nCells]
    /// - radii: Radial coordinates [nCells] in meters
    /// - majorRadius: Major radius R₀ in meters
    /// - epsilon: Regularization (default: 1e-10)
    ///
    /// **Returns**: Normalized gradient R/L [nCells] (dimensionless)
    public static func computeNormalizedGradient(
        variable: MLXArray,
        radii: MLXArray,
        majorRadius: Float,
        epsilon: Float = 1e-10
    ) -> MLXArray {
        let gradVar = computeGradient(variable: variable, radii: radii)

        // R/L = -(R₀/f)(df/dr) = -R₀ × (1/f)(df/dr)
        // Note: Negative sign because L_n typically defined with - sign
        let R_over_L = -(majorRadius / (variable + epsilon)) * gradVar
        eval(R_over_L)
        return R_over_L
    }

    /// Compute pressure gradient scale length for RI turbulence
    ///
    /// Pressure: p = n_e × (T_e + T_i) in SI units [Pa]
    ///
    /// **Parameters**:
    /// - profiles: Core plasma profiles
    /// - radii: Radial coordinates [nCells] in meters
    /// - epsilon: Regularization (default: 1e-10)
    ///
    /// **Returns**: Pressure gradient scale length L_p [nCells] in meters
    ///
    /// **Units**:
    /// - n_e: m⁻³
    /// - T_e, T_i: eV
    /// - Conversion: 1 eV = 1.602e-19 J
    /// - p = n × T × e_charge [Pa]
    public static func computePressureGradientLength(
        profiles: CoreProfiles,
        radii: MLXArray,
        epsilon: Float = 1e-10
    ) -> MLXArray {
        let eV_to_Joule: Float = 1.602e-19  // J/eV

        // Pressure in Pascals: p = n_e × (T_e + T_i) × e
        let n_e = profiles.electronDensity.value
        let T_e = profiles.electronTemperature.value
        let T_i = profiles.ionTemperature.value

        let pressure = n_e * (T_e + T_i) * eV_to_Joule

        // Gradient scale length (eval() called inside computeGradientLength)
        let L_p = computeGradientLength(variable: pressure, radii: radii, epsilon: epsilon)
        return L_p
    }

    /// Compute density gradient scale length
    ///
    /// **Parameters**:
    /// - density: Electron density [nCells] in m⁻³
    /// - radii: Radial coordinates [nCells] in meters
    /// - epsilon: Regularization (default: 1e-10)
    ///
    /// **Returns**: Density gradient scale length L_n [nCells] in meters
    public static func computeDensityGradientLength(
        density: MLXArray,
        radii: MLXArray,
        epsilon: Float = 1e-10
    ) -> MLXArray {
        return computeGradientLength(variable: density, radii: radii, epsilon: epsilon)
    }

    /// Compute temperature gradient scale length
    ///
    /// **Parameters**:
    /// - temperature: Temperature [nCells] in eV
    /// - radii: Radial coordinates [nCells] in meters
    /// - epsilon: Regularization (default: 1e-10)
    ///
    /// **Returns**: Temperature gradient scale length L_T [nCells] in meters
    public static func computeTemperatureGradientLength(
        temperature: MLXArray,
        radii: MLXArray,
        epsilon: Float = 1e-10
    ) -> MLXArray {
        return computeGradientLength(variable: temperature, radii: radii, epsilon: epsilon)
    }
}
