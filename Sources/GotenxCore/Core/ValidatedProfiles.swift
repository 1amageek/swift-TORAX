import MLX

/// Validated wrapper for CoreProfiles (Sprint 1: Minimal Implementation)
///
/// Ensures all physics models receive valid input data with critical checks:
/// - All values finite (no NaN, no Inf)
/// - Temperatures positive (T > 0 eV)
/// - Density positive (n > 0 m⁻³)
///
/// Deferred to Sprint 3:
/// - Bounds checking (T ∈ [1 eV, 100 keV], n ∈ [1e17, 1e21 m⁻³])
/// - Shape consistency validation
/// - Detailed error messages
///
/// Usage:
/// ```swift
/// guard let validated = ValidatedProfiles.validateMinimal(profiles) else {
///     print("[WARNING] Invalid profiles, using fallback")
///     return fallbackBehavior()
/// }
/// let Ti = validated.ionTemperature.value  // Guaranteed valid
/// ```
public struct ValidatedProfiles {
    /// Validated ion temperature [eV]
    public let ionTemperature: EvaluatedArray

    /// Validated electron temperature [eV]
    public let electronTemperature: EvaluatedArray

    /// Validated electron density [m⁻³]
    public let electronDensity: EvaluatedArray

    /// Validated normalized poloidal flux [0, 1]
    public let poloidalFlux: EvaluatedArray

    /// Private initializer - only accessible via validateMinimal()
    private init(
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

    /// Minimal validation (Sprint 1): finite + positive checks only
    ///
    /// Critical checks:
    /// 1. All values are finite (no NaN, no Inf)
    /// 2. Temperatures are positive (Ti > 0, Te > 0)
    /// 3. Density is positive (ne > 0)
    ///
    /// Returns nil if any check fails, allowing caller to handle gracefully.
    ///
    /// - Parameter profiles: Input profiles to validate
    /// - Returns: ValidatedProfiles if all checks pass, nil otherwise
    public static func validateMinimal(_ profiles: CoreProfiles) -> ValidatedProfiles? {
        let Ti = profiles.ionTemperature.value
        let Te = profiles.electronTemperature.value
        let ne = profiles.electronDensity.value
        let psi = profiles.poloidalFlux.value

        // Check 1: Finite values (critical - prevents NaN propagation)
        // Note: MLX doesn't have isfinite, so we check min/max for NaN/Inf
        let Ti_min = Ti.min().item(Float.self)
        let Ti_max = Ti.max().item(Float.self)
        guard !Ti_min.isNaN && !Ti_min.isInfinite && !Ti_max.isNaN && !Ti_max.isInfinite else {
            print("[VALIDATION-FAIL] ionTemperature contains non-finite values: min=\(Ti_min), max=\(Ti_max)")
            return nil
        }

        let Te_min = Te.min().item(Float.self)
        let Te_max = Te.max().item(Float.self)
        guard !Te_min.isNaN && !Te_min.isInfinite && !Te_max.isNaN && !Te_max.isInfinite else {
            print("[VALIDATION-FAIL] electronTemperature contains non-finite values: min=\(Te_min), max=\(Te_max)")
            return nil
        }

        let ne_min = ne.min().item(Float.self)
        let ne_max = ne.max().item(Float.self)
        guard !ne_min.isNaN && !ne_min.isInfinite && !ne_max.isNaN && !ne_max.isInfinite else {
            print("[VALIDATION-FAIL] electronDensity contains non-finite values: min=\(ne_min), max=\(ne_max)")
            return nil
        }

        let psi_min = psi.min().item(Float.self)
        let psi_max = psi.max().item(Float.self)
        guard !psi_min.isNaN && !psi_min.isInfinite && !psi_max.isNaN && !psi_max.isInfinite else {
            print("[VALIDATION-FAIL] poloidalFlux contains non-finite values: min=\(psi_min), max=\(psi_max)")
            return nil
        }

        // Check 2: Positive temperatures (critical - prevents division by zero)
        // Ti_min, Te_min, ne_min already computed above in Check 1
        guard Ti_min > 0 else {
            print("[VALIDATION-FAIL] ionTemperature not positive: min=\(Ti_min) eV (expected > 0)")
            return nil
        }

        guard Te_min > 0 else {
            print("[VALIDATION-FAIL] electronTemperature not positive: min=\(Te_min) eV (expected > 0)")
            return nil
        }

        // Check 3: Positive density (critical)
        // ne_min already computed above
        guard ne_min > 0 else {
            print("[VALIDATION-FAIL] electronDensity not positive: min=\(ne_min) m⁻³ (expected > 0)")
            return nil
        }

        // All checks passed
        return ValidatedProfiles(
            ionTemperature: profiles.ionTemperature,
            electronTemperature: profiles.electronTemperature,
            electronDensity: profiles.electronDensity,
            poloidalFlux: profiles.poloidalFlux
        )
    }

    /// Convert back to CoreProfiles (for solver interface compatibility)
    ///
    /// This allows validated profiles to be passed to interfaces expecting CoreProfiles.
    ///
    /// - Returns: CoreProfiles with same data
    public func toCoreProfiles() -> CoreProfiles {
        return CoreProfiles(
            ionTemperature: ionTemperature,
            electronTemperature: electronTemperature,
            electronDensity: electronDensity,
            poloidalFlux: poloidalFlux
        )
    }
}

// MARK: - Future Extensions (Sprint 3)

extension ValidatedProfiles {
    /// Physical bounds for complete validation (Sprint 3)
    ///
    /// These will be used in Sprint 3 for full bounds checking.
    private enum PhysicalBounds {
        static let T_min: Float = 1.0       // 1 eV (cold plasma limit)
        static let T_max: Float = 1e5       // 100 keV (thermonuclear regime)
        static let n_min: Float = 1e17      // m⁻³ (low-density tokamak limit)
        static let n_max: Float = 1e21      // m⁻³ (Greenwald density limit)
        static let psi_min: Float = 0.0     // Normalized flux lower bound
        static let psi_max: Float = 1.0     // Normalized flux upper bound
    }

    // Sprint 3 will add:
    // - public static func validate(_ profiles: CoreProfiles) throws -> ValidatedProfiles
    // - Bounds checking with detailed error messages
    // - Shape consistency validation
    // - Performance optimization (caching, vectorization)
}
