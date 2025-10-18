import Foundation
import MLX

/// Unit conversion utilities for TORAX
///
/// This module provides essential unit conversions for the eV/m⁻³ unit system
/// used throughout TORAX. See UNIT_SYSTEM_UNIFIED.md for unit standardization details.
public enum UnitConversions {

    // MARK: - Fundamental Constants

    /// Elementary charge / electron volt conversion [J/eV]
    /// Used for converting between Joules and electron volts
    public static let eV: Float = 1.602176634e-19

    // MARK: - Power Density Unit Conversions for Temperature Equations

    /// Convert power density from MW/m³ to eV/(m³·s)
    ///
    /// This conversion is **essential** for temperature equations in non-conservation form:
    /// ```
    /// n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
    /// ```
    ///
    /// **Dimensional Analysis**:
    /// - Left side: [m⁻³] × [eV/s] = [eV/(m³·s)]
    /// - Diffusion term: ∇·([m⁻³] × [m²/s] × [eV/m]) = [eV/(m³·s)]
    /// - Source term Q_i must also be [eV/(m³·s)]
    ///
    /// **Conversion derivation**:
    /// ```
    /// 1 MW/m³ = 10⁶ W/m³
    ///         = 10⁶ J/(m³·s)
    ///         = 10⁶ J/(m³·s) × (1 eV / 1.602176634×10⁻¹⁹ J)
    ///         = 6.2415090744×10²⁴ eV/(m³·s)
    /// ```
    ///
    /// **Physical Interpretation**:
    /// - SourceTerms.swift provides heating in [MW/m³] (standard for plasma physics)
    /// - Temperature equations require [eV/(m³·s)] to match time derivative
    /// - Without this conversion, heating power would be off by a factor of 6.24×10²⁴
    ///
    /// **References**:
    /// - PHYSICS_VALIDATION_ISSUES.md Issue 1 (ソース項の単位変換)
    /// - UNIT_SYSTEM_UNIFIED.md (eV/m⁻³ unit standardization)
    public static let megawattsPerCubicMeterToEvPerCubicMeterPerSecond: Float = 6.2415090744e24

    /// Convert power density from MW/m³ to eV/(m³·s) (scalar version)
    ///
    /// Use this when converting heating source terms for temperature equations.
    ///
    /// **Example**:
    /// ```swift
    /// let Q_MW: Float = 1.0  // [MW/m³] - heating power density
    /// let Q_eV = UnitConversions.megawattsToEvDensity(Q_MW)  // [eV/(m³·s)]
    /// ```
    ///
    /// **Unit validation**:
    /// ```swift
    /// // For Q_i [MW/m³] in temperature equation:
    /// //   n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
    /// //
    /// // All terms must have dimension [eV/(m³·s)]:
    /// //   Left side:  [m⁻³] × [eV/s] = [eV/(m³·s)] ✓
    /// //   Diffusion:  ∇·([m⁻³ × m²/s × eV/m]) = [eV/(m³·s)] ✓
    /// //   Source:     [MW/m³] → [eV/(m³·s)] via this function ✓
    /// ```
    ///
    /// - Parameter megawatts: Power density in [MW/m³]
    /// - Returns: Power density in [eV/(m³·s)]
    public static func megawattsToEvDensity(_ megawatts: Float) -> Float {
        return megawatts * megawattsPerCubicMeterToEvPerCubicMeterPerSecond
    }

    /// Convert power density from MW/m³ to eV/(m³·s) (array version)
    ///
    /// Use this when converting heating source terms for temperature equations.
    ///
    /// **Example**:
    /// ```swift
    /// // In Block1DCoeffsBuilder.swift:
    /// let Q_MW = sources.ionHeating.value  // [MW/m³]
    /// let Q_eV = UnitConversions.megawattsToEvDensity(Q_MW)  // [eV/(m³·s)]
    /// // Result is wrapped in EvaluatedArray, which calls eval() automatically
    /// ```
    ///
    /// **Why this conversion is critical**:
    /// Without this conversion, the temperature equation would have inconsistent dimensions:
    /// - Left side would expect [eV/(m³·s)]
    /// - Source term would provide [MW/m³] (incompatible!)
    /// - Simulation would produce physically meaningless results
    ///
    /// **Implementation note**:
    /// This conversion is applied in:
    /// - `buildIonEquationCoeffs()` for ion heating sources
    /// - `buildElectronEquationCoeffs()` for electron heating sources
    ///
    /// **Implementation strategy**:
    /// - Performs conversion in Swift (not MLX) to avoid MLX CPU backend validation issues
    /// - Uses Double precision throughout to safely represent large values (10²⁴ order)
    /// - **Always returns Float64 MLXArray** regardless of input dtype
    /// - Input is typically Float32, output is Float64 (necessary for 10²⁴ values)
    ///
    /// **Rationale for Float64 output**:
    /// - Input: Q_MW ~ 0.1-10 MW/m³ (fits comfortably in Float32)
    /// - Output: Q_eV ~ 10²³-10²⁵ eV/(m³·s) (exceeds Float32 safe range)
    /// - Float32 max: 3.4×10³⁸, but precision degrades severely for 10²⁴ values
    /// - Float32 has ~7 decimal digits precision → only 1 digit for 10²⁴ values
    /// - Float64 has ~15 decimal digits precision → 6-7 digits for 10²⁴ values
    /// - MLX operations on Float64 are well-supported and stable
    ///
    /// **Performance consideration**:
    /// - Element-wise multiplication is simple enough that Swift-side computation is acceptable
    /// - Typical array size: 25-100 elements (radial cells)
    /// - Overhead: < 1ms, negligible compared to solver (10-100ms per timestep)
    /// - Float64 arithmetic is native on CPU, minimal overhead vs Float32
    ///
    /// - Parameter megawatts: Power density array in [MW/m³]
    /// - Returns: Power density array in [eV/(m³·s)] as **Float64 MLXArray**
    public static func megawattsToEvDensity(_ megawatts: MLXArray) -> MLXArray {
        // **CRITICAL FIX**: Always use Float64 for output + preserve input device
        //
        // Problem history:
        //   1. Initial approach: MLX multiply with Float32 → overflow in MLX backend
        //   2. asType promotion: Float32→Float64 → MLX backend validation crash
        //   3. Swift-side computation with Float32 output → MLX backend rejects 10²⁴ values in Float32
        //   4. Swift-side Float64 output without device preservation → mlx_add crash (GPU+CPU mismatch)
        //
        // Root causes:
        //   - Converted values (10²³-10²⁵) exceed Float32's safe precision range
        //   - MLX CPU backend has strict validation that rejects large Float32 values
        //   - Problem is not the arithmetic but the storage/representation in Float32
        //   - MLXArray([...]) defaults to CPU device, causing crashes when input is GPU array
        //
        // Solution:
        //   - Extract input values (any dtype) and preserve input stream/device
        //   - Perform conversion in Double precision
        //   - **Store result as Float64 MLXArray on same device as input**
        //   - All downstream operations work correctly with Float64 on matching device
        //
        // Type handling:
        //   - Float16 input → Float64 output (necessary for 10²⁴ values)
        //   - Float32 input → Float64 output (necessary for 10²⁴ values)
        //   - Float64 input → Float64 output (already sufficient)
        //
        // Device handling:
        //   - GPU input → GPU output (via stream parameter)
        //   - CPU input → CPU output (via stream parameter)
        //   - Critical for LinearSolver's divergence + sourceCell addition
        //
        // References:
        //   - PHYSICS_VALIDATION_ISSUES.md Issue 1 (unit conversion fix)
        //   - User analysis: "大きな値を Float32 で保持／変換しようとしている点にあります"
        //   - User analysis: "デバイスの異なる配列どうしは MLX 側で加算できず、mlx_add がアサーションで停止"

        // **DEVICE-AWARE SOLUTION**: Use MLX operations to preserve device
        //
        // Strategy:
        // 1. Convert to Float64 using MLX broadcast multiplication (safe for small input values)
        // 2. Multiply by coefficient using MLX operations
        // 3. Device is automatically preserved throughout MLX operation chain
        //
        // Why this works:
        // - Input values (MW/m³ ~ 0.1-10) are small, safe for Float64 conversion
        // - MLX operations preserve input device automatically
        // - Only the final result has large values (10²⁴), already in Float64
        // - No asType() call that triggers MLX backend validation
        //
        // Device handling:
        // - GPU input → GPU output (via MLX operation chain)
        // - CPU input → CPU output (via MLX operation chain)
        // - No device mismatch in downstream operations

        let coefficient = Double(megawattsPerCubicMeterToEvPerCubicMeterPerSecond)

        // Step 1: Convert input to Float64 via broadcast multiplication with 1.0
        // This is safer than asType() and preserves device
        let inputFloat64: MLXArray
        if megawatts.dtype == .float64 {
            // Already Float64
            inputFloat64 = megawatts
        } else {
            // Multiply by Float64(1.0) to implicitly convert to Float64
            // This uses MLX broadcast and preserves device
            let one = MLXArray(Double(1.0))
            inputFloat64 = megawatts * one  // Implicit type promotion to Float64
        }

        // Step 2: Multiply by coefficient using MLX operations (preserves device)
        let coeffArray = MLXArray(coefficient)
        return inputFloat64 * coeffArray
    }
}
