// RuntimeConfiguration.swift
// Runtime configuration (static + dynamic split)

import Foundation

/// Runtime configuration (static + dynamic split)
public struct RuntimeConfiguration: Codable, Sendable, Equatable {
    /// Static parameters: trigger recompilation when changed
    public let `static`: StaticConfig

    /// Dynamic parameters: no recompilation needed
    public let dynamic: DynamicConfig

    public init(static: StaticConfig, dynamic: DynamicConfig) {
        self.static = `static`
        self.dynamic = dynamic
    }
}
