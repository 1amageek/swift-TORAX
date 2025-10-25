import Foundation

/// Initial profile generation configuration
///
/// Controls the shape of initial plasma profiles generated from boundary conditions.
/// These parameters significantly affect numerical stability and physical realism.
///
/// ## Usage
///
/// ```swift
/// // Use default (numerically stable)
/// let config = InitialProfileConfig.default
///
/// // Use realistic tokamak profiles
/// let config = InitialProfileConfig.realistic
///
/// // Custom configuration
/// let config = InitialProfileConfig(
///     temperaturePeakRatio: 7.0,
///     densityPeakRatio: 2.5
/// )
/// ```
public struct InitialProfileConfig: Codable, Sendable, Equatable {
    /// Core/Edge temperature ratio
    ///
    /// **Physical range**: 3.0 - 10.0
    /// - Lower values (3.0-5.0): Better numerical stability, suitable for initial testing
    /// - Higher values (7.0-10.0): More realistic tokamak profiles
    ///
    /// **Default**: 5.0 (balanced)
    public let temperaturePeakRatio: Float

    /// Core/Edge density ratio
    ///
    /// **Physical range**: 1.5 - 3.0
    /// - Lower values (1.5-2.0): Better numerical stability, flatter profiles
    /// - Higher values (2.5-3.0): More realistic density peaking
    ///
    /// **Default**: 2.0 (conservative)
    public let densityPeakRatio: Float

    /// Temperature profile shape exponent
    ///
    /// Profile: T(r) = T_edge + (T_core - T_edge) * (1 - (r/a)^2)^exponent
    ///
    /// **Common values**:
    /// - 1.0: Linear
    /// - 2.0: Parabolic (standard)
    /// - 3.0: More peaked
    ///
    /// **Default**: 2.0
    public let temperatureExponent: Float

    /// Density profile shape exponent
    ///
    /// Profile: n(r) = n_edge + (n_core - n_edge) * (1 - (r/a)^2)^exponent
    ///
    /// **Common values**:
    /// - 1.0: Linear
    /// - 1.5: Typical tokamak (flatter than temperature)
    /// - 2.0: Parabolic
    ///
    /// **Default**: 1.5
    public let densityExponent: Float

    public init(
        temperaturePeakRatio: Float = 5.0,
        densityPeakRatio: Float = 2.0,
        temperatureExponent: Float = 2.0,
        densityExponent: Float = 1.5
    ) {
        self.temperaturePeakRatio = temperaturePeakRatio
        self.densityPeakRatio = densityPeakRatio
        self.temperatureExponent = temperatureExponent
        self.densityExponent = densityExponent
    }

    /// Default configuration for numerical stability
    ///
    /// Uses conservative ratios (5×, 2×) that have been tested for stability.
    public static let `default` = InitialProfileConfig()

    /// Realistic tokamak profiles (steeper gradients)
    ///
    /// Uses higher ratios (10×, 3×) typical of actual tokamak experiments.
    /// May require smaller timesteps for numerical stability.
    public static let realistic = InitialProfileConfig(
        temperaturePeakRatio: 10.0,
        densityPeakRatio: 3.0,
        temperatureExponent: 2.0,
        densityExponent: 1.5
    )

    /// Conservative profiles for numerical testing
    ///
    /// Uses very flat profiles (3×, 1.5×) for maximum stability.
    /// Useful for debugging and testing new physics models.
    public static let conservative = InitialProfileConfig(
        temperaturePeakRatio: 3.0,
        densityPeakRatio: 1.5,
        temperatureExponent: 1.5,
        densityExponent: 1.0
    )

    /// Completely flat profiles for plasma startup simulation
    ///
    /// Uses thermal equilibrium initial condition (core = edge).
    /// This represents the physical state before external heating begins.
    ///
    /// **Physics**: In tokamak startup:
    /// 1. Plasma starts at uniform temperature (thermal equilibrium)
    /// 2. External heating (NBI, ECRH) gradually creates profiles
    /// 3. Transport and sources reach steady-state balance
    ///
    /// **Numerical advantage**: Zero initial residual (steady-state solution)
    public static let flat = InitialProfileConfig(
        temperaturePeakRatio: 1.0,  // No gradient
        densityPeakRatio: 1.0,       // No gradient
        temperatureExponent: 0.0,    // Shape irrelevant when ratio = 1
        densityExponent: 0.0         // Shape irrelevant when ratio = 1
    )
}
