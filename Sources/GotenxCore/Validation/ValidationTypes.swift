import Foundation

// MARK: - Validation Types

/// Geometry parameters for tokamak configuration
public struct GeometryParams: Sendable, Codable {
    /// Major radius [m]
    public let majorRadius: Float

    /// Minor radius [m]
    public let minorRadius: Float

    /// Plasma elongation (optional)
    public let elongation: Float?

    /// Plasma triangularity (optional)
    public let triangularity: Float?

    /// Plasma current [MA]
    public let plasmaCurrent: Float

    /// Toroidal magnetic field [T]
    public let toroidalField: Float

    public init(
        majorRadius: Float,
        minorRadius: Float,
        elongation: Float? = nil,
        triangularity: Float? = nil,
        plasmaCurrent: Float,
        toroidalField: Float
    ) {
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.elongation = elongation
        self.triangularity = triangularity
        self.plasmaCurrent = plasmaCurrent
        self.toroidalField = toroidalField
    }
}

/// Reference profiles at a specific time point
public struct ReferenceProfiles: Sendable, Codable {
    /// Normalized toroidal flux coordinate [dimensionless]
    public let rho: [Float]

    /// Ion temperature [eV]
    public let Ti: [Float]

    /// Electron temperature [eV]
    public let Te: [Float]

    /// Electron density [m⁻³]
    public let ne: [Float]

    /// Time point [s]
    public let time: Float

    public init(rho: [Float], Ti: [Float], Te: [Float], ne: [Float], time: Float) {
        self.rho = rho
        self.Ti = Ti
        self.Te = Te
        self.ne = ne
        self.time = time
    }
}

/// Global quantities (volume-integrated)
public struct GlobalQuantities: Sendable, Codable {
    /// Fusion power [MW]
    public let P_fusion: Float

    /// Alpha power [MW]
    public let P_alpha: Float

    /// Energy confinement time [s]
    public let tau_E: Float

    /// Normalized beta
    public let beta_N: Float

    /// Fusion gain Q = P_fusion / P_input
    public let Q_fusion: Float

    public init(P_fusion: Float, P_alpha: Float, tau_E: Float, beta_N: Float, Q_fusion: Float) {
        self.P_fusion = P_fusion
        self.P_alpha = P_alpha
        self.tau_E = tau_E
        self.beta_N = beta_N
        self.Q_fusion = Q_fusion
    }
}

/// Comparison result between predicted and reference data
public struct ComparisonResult: Sendable {
    /// Quantity being compared (e.g., "ion_temperature")
    public let quantity: String

    /// L2 relative error
    public let l2Error: Float

    /// Mean absolute percentage error (%)
    public let mape: Float

    /// Pearson correlation coefficient
    public let correlation: Float

    /// Time point [s]
    public let time: Float

    /// Pass/fail status (based on thresholds)
    public let passed: Bool

    public init(
        quantity: String,
        l2Error: Float,
        mape: Float,
        correlation: Float,
        time: Float,
        passed: Bool
    ) {
        self.quantity = quantity
        self.l2Error = l2Error
        self.mape = mape
        self.correlation = correlation
        self.time = time
        self.passed = passed
    }
}

/// Validation thresholds for comparison metrics
public struct ValidationThresholds: Sendable {
    /// Maximum acceptable L2 relative error
    public let maxL2Error: Float

    /// Maximum acceptable MAPE (%)
    public let maxMAPE: Float

    /// Minimum acceptable Pearson correlation
    public let minCorrelation: Float

    public init(
        maxL2Error: Float = 0.1,      // 10%
        maxMAPE: Float = 20.0,         // 20%
        minCorrelation: Float = 0.95   // r > 0.95
    ) {
        self.maxL2Error = maxL2Error
        self.maxMAPE = maxMAPE
        self.minCorrelation = minCorrelation
    }

    /// Standard thresholds for TORAX comparison
    public static let torax = ValidationThresholds(
        maxL2Error: 0.1,
        maxMAPE: 15.0,
        minCorrelation: 0.95
    )

    /// Relaxed thresholds for experimental data
    public static let experimental = ValidationThresholds(
        maxL2Error: 0.2,
        maxMAPE: 25.0,
        minCorrelation: 0.90
    )
}
