// RestartConfig.swift
// Configuration for simulation restart functionality

import Foundation

/// Restart configuration
///
/// Allows restarting simulations from previously saved checkpoints.
/// Compatible with Gotenx's restart functionality.
public struct RestartConfig: Codable, Sendable, Equatable {
    /// NetCDF file path to restart from
    ///
    /// If provided and `doRestart` is true, the simulation will load
    /// initial conditions from this checkpoint file.
    public var filename: String?

    /// Time to restart at (in seconds)
    ///
    /// If nil, restarts from the latest time in the checkpoint file.
    /// If specified, finds the closest timestep to this value.
    public var time: Float?

    /// Enable restart
    ///
    /// When true and `filename` is provided, load initial state from checkpoint.
    /// When false, run from initial conditions defined in configuration.
    public var doRestart: Bool

    /// Stitch with original history
    ///
    /// When true, the restart simulation's output will be appended to
    /// the original checkpoint's history, creating a continuous timeline.
    /// When false, output starts from t=0 relative to restart time.
    public var stitch: Bool

    public init(
        filename: String? = nil,
        time: Float? = nil,
        doRestart: Bool = false,
        stitch: Bool = true
    ) {
        self.filename = filename
        self.time = time
        self.doRestart = doRestart
        self.stitch = stitch
    }

    /// Default configuration (restart disabled)
    public static let `default` = RestartConfig()
}

// MARK: - Validation

extension RestartConfig {
    /// Validate restart configuration
    ///
    /// Throws if configuration is inconsistent (e.g., doRestart=true but no filename)
    public func validate() throws {
        if doRestart {
            guard let path = filename, !path.isEmpty else {
                throw ConfigurationError.invalidValue(
                    key: "restart.filename",
                    value: "nil",
                    reason: "Filename must be provided when doRestart=true"
                )
            }

            // Check if file exists
            guard FileManager.default.fileExists(atPath: path) else {
                throw ConfigurationError.invalidValue(
                    key: "restart.filename",
                    value: path,
                    reason: "Checkpoint file not found"
                )
            }

            // Validate time is non-negative if specified
            if let t = time, t < 0 {
                throw ConfigurationError.invalidValue(
                    key: "restart.time",
                    value: String(t),
                    reason: "Restart time must be non-negative"
                )
            }
        }
    }
}
