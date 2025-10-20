// SharedTypes.swift
// Shared types used across CLI commands

import ArgumentParser
import Foundation

// MARK: - Output Format

/// Output file format for simulation results
public enum OutputFormat: String, ExpressibleByArgument {
    case json
    case hdf5
    case netcdf

    public var fileExtension: String {
        switch self {
        case .json: return "json"
        case .hdf5: return "h5"
        case .netcdf: return "nc"
        }
    }

    public var description: String {
        switch self {
        case .json:
            return "JSON (JavaScript Object Notation)"
        case .hdf5:
            return "HDF5 (Hierarchical Data Format 5)"
        case .netcdf:
            return "NetCDF (Network Common Data Form)"
        }
    }
}

// MARK: - CLI Errors

/// Common CLI error types
public enum CLIError: LocalizedError {
    case configNotFound(String)
    case unsupportedFormat(String)
    case invalidOutputDirectory(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .configNotFound(let path):
            return "Configuration file not found: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format)"
        case .invalidOutputDirectory(let path):
            return "Invalid output directory: \(path)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}
