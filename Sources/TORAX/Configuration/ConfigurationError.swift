// ConfigurationError.swift
// Configuration validation errors

import Foundation

/// Configuration errors with detailed context
public enum ConfigurationError: Error, LocalizedError, Equatable {
    case invalidValue(key: String, value: String, reason: String)
    case physicsWarning(key: String, value: String, reason: String)
    case inconsistency(reason: String)
    case missingRequired(key: String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let key, let value, let reason):
            return "❌ Invalid value for '\(key)': \(value). \(reason)"
        case .physicsWarning(let key, let value, let reason):
            return "⚠️  Warning for '\(key)': \(value). \(reason)"
        case .inconsistency(let reason):
            return "❌ Configuration inconsistency: \(reason)"
        case .missingRequired(let key):
            return "❌ Missing required configuration: '\(key)'"
        }
    }
}
