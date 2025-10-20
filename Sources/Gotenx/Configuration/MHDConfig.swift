// MHDConfig.swift
// Configuration for MHD models (sawteeth, NTMs, etc.)

import Foundation

/// Configuration for MHD models
public struct MHDConfig: Codable, Sendable, Equatable {
    /// Enable/disable sawtooth model
    public var sawtoothEnabled: Bool

    /// Sawtooth model parameters
    public var sawtoothParams: SawtoothParameters

    /// Enable/disable neoclassical tearing modes (future)
    public var ntmEnabled: Bool

    public init(
        sawtoothEnabled: Bool = false,
        sawtoothParams: SawtoothParameters = SawtoothParameters(),
        ntmEnabled: Bool = false
    ) {
        self.sawtoothEnabled = sawtoothEnabled
        self.sawtoothParams = sawtoothParams
        self.ntmEnabled = ntmEnabled
    }

    /// Default configuration (all MHD disabled)
    public static let `default` = MHDConfig()
}

/// Parameters for sawtooth crash model
///
/// Sawteeth are periodic MHD instabilities that flatten the central core profiles
/// when the safety factor q(0) drops below 1.
public struct SawtoothParameters: Codable, Sendable, Equatable {
    /// Critical q value for sawtooth trigger
    /// Default: 1.0 (physical threshold)
    public var qCritical: Float

    /// Inversion radius (normalized)
    /// Profiles are flattened between r=0 and r=r_inv
    /// Default: 0.3 (typical experimental value)
    public var inversionRadius: Float

    /// Mixing time scale (seconds)
    /// How fast the profile flattening occurs
    /// Default: 1e-4 s (fast MHD timescale)
    public var mixingTime: Float

    /// Minimum time between crashes (seconds)
    /// Prevents unphysically rapid crash sequences
    /// Default: 0.01 s
    public var minCrashInterval: Float

    public init(
        qCritical: Float = 1.0,
        inversionRadius: Float = 0.3,
        mixingTime: Float = 1e-4,
        minCrashInterval: Float = 0.01
    ) {
        self.qCritical = qCritical
        self.inversionRadius = inversionRadius
        self.mixingTime = mixingTime
        self.minCrashInterval = minCrashInterval
    }
}

/// MHD model protocol for different instability types
public protocol MHDModel: Sendable {
    /// Apply MHD effects to core profiles
    /// - Parameters:
    ///   - profiles: Current core profiles
    ///   - geometry: Simulation geometry
    ///   - time: Current simulation time
    ///   - dt: Timestep
    /// - Returns: Modified profiles after MHD effects
    func apply(
        to profiles: CoreProfiles,
        geometry: Geometry,
        time: Float,
        dt: Float
    ) -> CoreProfiles
}

/// Factory for creating MHD models from configuration
public struct MHDModelFactory {
    /// Create sawtooth model if enabled
    public static func createSawtoothModel(
        config: MHDConfig
    ) -> (any MHDModel)? {
        guard config.sawtoothEnabled else {
            return nil
        }

        return SawtoothModel(params: config.sawtoothParams)
    }

    /// Create all enabled MHD models
    public static func createAllModels(
        config: MHDConfig
    ) -> [any MHDModel] {
        var models: [any MHDModel] = []

        if let sawtoothModel = createSawtoothModel(config: config) {
            models.append(sawtoothModel)
        }

        // Future: NTM models, etc.

        return models
    }
}
