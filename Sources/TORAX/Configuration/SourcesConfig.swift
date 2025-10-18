// SourcesConfig.swift
// Sources configuration

import Foundation

/// Sources configuration
public struct SourcesConfig: Codable, Sendable, Equatable {
    /// Enable Ohmic heating
    public let ohmicHeating: Bool

    /// Enable fusion power
    public let fusionPower: Bool

    /// Enable ion-electron exchange
    public let ionElectronExchange: Bool

    /// Enable Bremsstrahlung radiation
    public let bremsstrahlung: Bool

    /// Fusion power configuration
    public let fusionConfig: FusionConfig?

    public static let `default` = SourcesConfig(
        ohmicHeating: true,
        fusionPower: true,
        ionElectronExchange: true,
        bremsstrahlung: true,
        fusionConfig: .default
    )

    public init(
        ohmicHeating: Bool = true,
        fusionPower: Bool = true,
        ionElectronExchange: Bool = true,
        bremsstrahlung: Bool = true,
        fusionConfig: FusionConfig? = .default
    ) {
        self.ohmicHeating = ohmicHeating
        self.fusionPower = fusionPower
        self.ionElectronExchange = ionElectronExchange
        self.bremsstrahlung = bremsstrahlung
        self.fusionConfig = fusionConfig
    }
}

/// Fusion power configuration
public struct FusionConfig: Codable, Sendable, Equatable {
    /// Deuterium fraction in fuel
    public let deuteriumFraction: Float

    /// Tritium fraction in fuel
    public let tritiumFraction: Float

    /// Fuel dilution (impurity fraction)
    public let dilution: Float

    public static let `default` = FusionConfig(
        deuteriumFraction: 0.5,
        tritiumFraction: 0.5,
        dilution: 0.9
    )

    public init(
        deuteriumFraction: Float = 0.5,
        tritiumFraction: Float = 0.5,
        dilution: Float = 0.9
    ) {
        self.deuteriumFraction = deuteriumFraction
        self.tritiumFraction = tritiumFraction
        self.dilution = dilution
    }
}

// MARK: - Conversion to Runtime Parameters

extension SourcesConfig {
    /// Convert to source parameters dictionary for runtime
    ///
    /// Creates SourceParameters entries for each enabled source.
    /// Source names match those expected by the physics models:
    /// - "fusion": Fusion power with D-T fuel configuration
    /// - "ohmic": Ohmic heating
    /// - "ionElectronExchange": Ion-electron heat exchange
    /// - "bremsstrahlung": Bremsstrahlung radiation
    public func toSourceParams() -> [String: SourceParameters] {
        var params: [String: SourceParameters] = [:]

        if fusionPower, let fusionConfig = fusionConfig {
            params["fusion"] = SourceParameters(
                modelType: "fusion",
                params: [
                    "deuteriumFraction": fusionConfig.deuteriumFraction,
                    "tritiumFraction": fusionConfig.tritiumFraction,
                    "dilution": fusionConfig.dilution
                ],
                timeDependent: false
            )
        }

        if ohmicHeating {
            params["ohmic"] = SourceParameters(
                modelType: "ohmic",
                params: [:],
                timeDependent: false
            )
        }

        if ionElectronExchange {
            params["ionElectronExchange"] = SourceParameters(
                modelType: "ionElectronExchange",
                params: [:],
                timeDependent: false
            )
        }

        if bremsstrahlung {
            params["bremsstrahlung"] = SourceParameters(
                modelType: "bremsstrahlung",
                params: [:],
                timeDependent: false
            )
        }

        return params
    }
}
