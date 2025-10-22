import Foundation

// MARK: - ITER Baseline Data

/// ITER Baseline Scenario reference data
///
/// Provides reference parameters from ITER Physics Basis (Nuclear Fusion 39(12), 1999)
/// for validation of global quantities and profile shapes.
///
/// ## Purpose
///
/// - Sanity checks for global quantities (Q, βN, τE)
/// - Qualitative profile shape validation
/// - Order-of-magnitude verification
///
/// ## Usage
///
/// ```swift
/// let baseline = ITERBaselineData.load()
///
/// // Check global quantities
/// print("Expected Q: \(baseline.globalQuantities.Q_fusion)")
/// print("Expected βN: \(baseline.globalQuantities.beta_N)")
///
/// // Compare profile shapes
/// let refTi = baseline.profiles.Ti
/// let gotenxTi = // ... from simulation
///
/// let result = ProfileComparator.compare(
///     quantity: "ion_temperature",
///     predicted: gotenxTi,
///     reference: refTi,
///     time: 2.0,
///     thresholds: .experimental  // Relaxed for design data
/// )
/// ```
///
/// ## Note
///
/// ITER Baseline data is **design values**, not simulation outputs.
/// For detailed validation, use ToraxReferenceData instead.
public struct ITERBaselineData: Sendable {
    /// Tokamak geometry parameters
    public let geometry: GeometryParams

    /// Reference profiles at steady state (t = 2s)
    public let profiles: ReferenceProfiles

    /// Global performance quantities
    public let globalQuantities: GlobalQuantities

    public init(
        geometry: GeometryParams,
        profiles: ReferenceProfiles,
        globalQuantities: GlobalQuantities
    ) {
        self.geometry = geometry
        self.profiles = profiles
        self.globalQuantities = globalQuantities
    }

    /// Load ITER Baseline Scenario data
    ///
    /// Data source: ITER Physics Basis, Nuclear Fusion 39(12), 1999, Table II
    ///
    /// ## Plasma Parameters
    ///
    /// - Major radius: R₀ = 6.2 m
    /// - Minor radius: a = 2.0 m
    /// - Plasma current: Ip = 15 MA
    /// - Toroidal field: B₀ = 5.3 T
    /// - Fusion gain: Q = 10
    ///
    /// ## Profile Assumptions
    ///
    /// - Ti, Te: Parabolic profiles peaked at core
    ///   - Ti_core = Te_core = 20 keV
    ///   - Ti_edge = Te_edge = 100 eV
    ///   - Shape: T(r) = T_edge + (T_core - T_edge) × (1 - (r/a)²)²
    ///
    /// - ne: Linear profile
    ///   - ne_core = 1.0 × 10²⁰ m⁻³
    ///   - ne_edge = 0.2 × 10²⁰ m⁻³
    ///   - Shape: ne(r) = ne_edge + (ne_core - ne_edge) × (1 - r/a)
    ///
    /// - Returns: ITER Baseline data structure
    public static func load() -> ITERBaselineData {
        // ITER geometry from Physics Basis Table II
        let geometry = GeometryParams(
            majorRadius: 6.2,      // [m]
            minorRadius: 2.0,      // [m]
            elongation: 1.7,       // Plasma elongation
            triangularity: 0.33,   // Plasma triangularity
            plasmaCurrent: 15.0,   // [MA]
            toroidalField: 5.3     // [T]
        )

        // Generate parabolic profiles on uniform grid
        let nPoints = 50
        let rho = stride(from: 0.0, through: 1.0, by: 1.0/Float(nPoints-1)).map { Float($0) }

        // Ion temperature: Parabolic profile
        // Ti(r) = Ti_edge + (Ti_core - Ti_edge) × (1 - r²)²
        let Ti_core: Float = 20000.0  // 20 keV = 20,000 eV
        let Ti_edge: Float = 100.0    // 100 eV
        let Ti = rho.map { r in
            Ti_edge + (Ti_core - Ti_edge) * pow(1.0 - r*r, 2.0)
        }

        // Electron temperature: Same as ion temperature
        let Te = Ti

        // Electron density: Linear profile
        // ne(r) = ne_edge + (ne_core - ne_edge) × (1 - r)
        let ne_core: Float = 1.0e20   // 1.0 × 10²⁰ m⁻³
        let ne_edge: Float = 0.2e20   // 0.2 × 10²⁰ m⁻³
        let ne = rho.map { r in
            ne_edge + (ne_core - ne_edge) * (1.0 - r)
        }

        // Global quantities from ITER Physics Basis
        let global = GlobalQuantities(
            P_fusion: 400.0,     // [MW] - ITER Q=10 design (50 MW → 500 MW)
            P_alpha: 80.0,       // [MW] - 20% of fusion power (400 × 0.2)
            tau_E: 3.7,          // [s] - H98(y,2) = 1.0 scaling
            beta_N: 1.8,         // Normalized beta (typical ITER value)
            Q_fusion: 10.0       // Fusion gain (design goal)
        )

        // Steady state time point
        let steadyStateTime: Float = 2.0  // [s]

        return ITERBaselineData(
            geometry: geometry,
            profiles: ReferenceProfiles(
                rho: rho,
                Ti: Ti,
                Te: Te,
                ne: ne,
                time: steadyStateTime
            ),
            globalQuantities: global
        )
    }

    // MARK: - Validation Helpers

    /// Check if global quantities are physically reasonable
    ///
    /// Verifies:
    /// - Q > 5 (fusion relevant)
    /// - 1.0 < βN < 3.5 (MHD stable)
    /// - τE > 1.0 s (good confinement)
    ///
    /// - Parameter actual: Actual global quantities from simulation
    /// - Returns: True if all quantities are reasonable
    public static func validateGlobalQuantities(_ actual: GlobalQuantities) -> Bool {
        // Q should be > 5 for fusion-relevant regime
        guard actual.Q_fusion > 5.0 else {
            print("⚠️ Q = \(actual.Q_fusion) < 5 (not fusion-relevant)")
            return false
        }

        // βN should be in MHD-stable range
        guard actual.beta_N > 1.0 && actual.beta_N < 3.5 else {
            print("⚠️ βN = \(actual.beta_N) outside [1.0, 3.5] (MHD limits)")
            return false
        }

        // τE should be > 1s for good confinement
        guard actual.tau_E > 1.0 else {
            print("⚠️ τE = \(actual.tau_E) < 1s (poor confinement)")
            return false
        }

        return true
    }

    /// Print comparison summary
    ///
    /// - Parameters:
    ///   - predicted: Predicted global quantities
    ///   - reference: Reference (baseline) global quantities
    public static func printComparison(
        predicted: GlobalQuantities,
        reference: GlobalQuantities
    ) {
        print("\n[ITER Baseline Comparison]")
        print("                  Predicted    Reference    Ratio")
        print("  Q_fusion:       \(String(format: "%8.2f", predicted.Q_fusion))     \(String(format: "%8.2f", reference.Q_fusion))     \(String(format: "%6.2f", predicted.Q_fusion / reference.Q_fusion))×")
        print("  β_N:            \(String(format: "%8.2f", predicted.beta_N))     \(String(format: "%8.2f", reference.beta_N))     \(String(format: "%6.2f", predicted.beta_N / reference.beta_N))×")
        print("  τ_E [s]:        \(String(format: "%8.2f", predicted.tau_E))     \(String(format: "%8.2f", reference.tau_E))     \(String(format: "%6.2f", predicted.tau_E / reference.tau_E))×")
        print("  P_fusion [MW]:  \(String(format: "%8.1f", predicted.P_fusion))     \(String(format: "%8.1f", reference.P_fusion))     \(String(format: "%6.2f", predicted.P_fusion / reference.P_fusion))×")
        print("")
    }
}
