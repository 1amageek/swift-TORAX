// OutputConfiguration.swift
// Output configuration

import Foundation

/// Output configuration
public struct OutputConfiguration: Codable, Sendable, Equatable {
    /// Save interval [s] (nil = only final state)
    public let saveInterval: Float?

    /// Output directory
    public let directory: String

    /// Output format
    public let format: OutputFormat

    public static let `default` = OutputConfiguration(
        saveInterval: nil,
        directory: "/tmp/gotenx_results",
        format: .json
    )

    public init(
        saveInterval: Float? = nil,
        directory: String = "/tmp/gotenx_results",
        format: OutputFormat = .json
    ) {
        self.saveInterval = saveInterval
        self.directory = directory
        self.format = format
    }
}

/// Output format
public enum OutputFormat: String, Codable, Sendable {
    case json
    case hdf5
    case netcdf
}
