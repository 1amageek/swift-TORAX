// EvolutionConfig.swift
// Evolution configuration (which equations to solve)

import Foundation

/// Evolution configuration (which equations to solve)
public struct EvolutionConfig: Codable, Sendable, Equatable, Hashable {
    /// Evolve ion heat transport equation
    public let ionHeat: Bool

    /// Evolve electron heat transport equation
    public let electronHeat: Bool

    /// Evolve electron density equation
    public let density: Bool

    /// Evolve poloidal flux (current diffusion) equation
    public let current: Bool

    public static let `default` = EvolutionConfig(
        ionHeat: true,
        electronHeat: true,
        density: true,
        current: false  // Often disabled for computational efficiency
    )

    public init(
        ionHeat: Bool = true,
        electronHeat: Bool = true,
        density: Bool = true,
        current: Bool = false
    ) {
        self.ionHeat = ionHeat
        self.electronHeat = electronHeat
        self.density = density
        self.current = current
    }

    /// Number of evolved equations
    public var count: Int {
        [ionHeat, electronHeat, density, current]
            .filter { $0 }
            .count
    }

    // MARK: - Codable (backward compatibility with JSON)

    enum CodingKeys: String, CodingKey {
        case ionHeat = "ionTemperature"  // JSON uses "ionTemperature"
        case electronHeat = "electronTemperature"  // JSON uses "electronTemperature"
        case density
        case current
    }
}
