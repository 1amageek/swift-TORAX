// SchemeConfig.swift
// Numerical scheme configuration

import Foundation

/// Numerical scheme configuration
public struct SchemeConfig: Codable, Sendable, Equatable, Hashable {
    /// Theta parameter for time discretization
    /// - 0.0: Explicit Euler
    /// - 0.5: Crank-Nicolson (2nd order)
    /// - 1.0: Implicit Euler (unconditionally stable)
    public let theta: Float

    /// Use Pereverzev-Corrigan terms for stiff transport
    public let usePereverzev: Bool

    public static let `default` = SchemeConfig(
        theta: 1.0,  // Fully implicit
        usePereverzev: true
    )

    public init(theta: Float = 1.0, usePereverzev: Bool = true) {
        self.theta = theta
        self.usePereverzev = usePereverzev
    }
}

extension SchemeConfig {
    public func validate() throws {
        guard theta >= 0.0 && theta <= 1.0 else {
            throw ConfigurationError.invalidValue(
                key: "scheme.theta",
                value: "\(theta)",
                reason: "Must be in [0, 1]"
            )
        }
    }
}
