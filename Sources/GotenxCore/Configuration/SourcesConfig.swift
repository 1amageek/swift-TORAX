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

    /// ECRH configuration (optional)
    public let ecrh: ECRHConfig?

    /// Gas puff configuration (optional)
    public let gasPuff: GasPuffConfig?

    /// Impurity radiation configuration (optional)
    public let impurityRadiation: ImpurityRadiationConfig?

    public static let `default` = SourcesConfig(
        ohmicHeating: true,
        fusionPower: true,
        ionElectronExchange: true,
        bremsstrahlung: true,
        fusionConfig: .default,
        ecrh: nil,
        gasPuff: nil,
        impurityRadiation: nil
    )

    public init(
        ohmicHeating: Bool = true,
        fusionPower: Bool = true,
        ionElectronExchange: Bool = true,
        bremsstrahlung: Bool = true,
        fusionConfig: FusionConfig? = .default,
        ecrh: ECRHConfig? = nil,
        gasPuff: GasPuffConfig? = nil,
        impurityRadiation: ImpurityRadiationConfig? = nil
    ) {
        self.ohmicHeating = ohmicHeating
        self.fusionPower = fusionPower
        self.ionElectronExchange = ionElectronExchange
        self.bremsstrahlung = bremsstrahlung
        self.fusionConfig = fusionConfig
        self.ecrh = ecrh
        self.gasPuff = gasPuff
        self.impurityRadiation = impurityRadiation
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

/// ECRH (Electron Cyclotron Resonance Heating) configuration
public struct ECRHConfig: Codable, Sendable, Equatable {
    /// Total injected power [W]
    public let totalPower: Float

    /// Deposition location (normalized radius ρ)
    /// Typical range: 0.0 (core) - 0.9 (near edge)
    public let depositionRho: Float

    /// Deposition width (3σ width of Gaussian profile)
    /// Typical range: 0.05 - 0.15
    ///
    /// Full width containing 99.7% of power (3-sigma convention)
    public let depositionWidth: Float

    /// Launch angle [degrees] (for future ray tracing)
    public let launchAngle: Float?

    /// Microwave frequency [Hz] (e.g., 170 GHz for ITER)
    public let frequency: Float?

    /// Enable current drive calculation
    public let currentDriveEnabled: Bool

    public static let `default` = ECRHConfig(
        totalPower: 20e6,          // 20 MW
        depositionRho: 0.5,        // Mid-radius
        depositionWidth: 0.1,      // Moderately focused
        launchAngle: nil,
        frequency: nil,
        currentDriveEnabled: false
    )

    public init(
        totalPower: Float = 20e6,
        depositionRho: Float = 0.5,
        depositionWidth: Float = 0.1,
        launchAngle: Float? = nil,
        frequency: Float? = nil,
        currentDriveEnabled: Bool = false
    ) {
        self.totalPower = totalPower
        self.depositionRho = depositionRho
        self.depositionWidth = depositionWidth
        self.launchAngle = launchAngle
        self.frequency = frequency
        self.currentDriveEnabled = currentDriveEnabled
    }
}

/// Gas puff (particle fueling) configuration
public struct GasPuffConfig: Codable, Sendable, Equatable {
    /// Total particle puff rate [particles/s]
    /// Typical range for ITER: 1e21 - 1e22 particles/s
    public let puffRate: Float

    /// Penetration depth (λ_n in normalized coordinates)
    /// Typical range: 0.05 - 0.2
    public let penetrationDepth: Float

    public static let `default` = GasPuffConfig(
        puffRate: 1e21,           // 1e21 particles/s
        penetrationDepth: 0.1     // Moderate penetration
    )

    public init(
        puffRate: Float = 1e21,
        penetrationDepth: Float = 0.1
    ) {
        self.puffRate = puffRate
        self.penetrationDepth = penetrationDepth
    }
}

/// Impurity radiation configuration
public struct ImpurityRadiationConfig: Codable, Sendable, Equatable {
    /// Impurity fraction (n_imp / n_e)
    /// Typical range: 1e-4 (0.01%) - 1e-2 (1%)
    public let impurityFraction: Float

    /// Impurity species name
    /// Valid values: "carbon", "neon", "argon", "tungsten"
    public let species: String

    public static let `default` = ImpurityRadiationConfig(
        impurityFraction: 0.001,  // 0.1%
        species: "argon"
    )

    public init(
        impurityFraction: Float = 0.001,
        species: String = "argon"
    ) {
        self.impurityFraction = impurityFraction
        self.species = species
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
    /// - "ecrh": Electron Cyclotron Resonance Heating
    /// - "gasPuff": Gas puff particle source
    /// - "impurityRadiation": Impurity radiation loss
    public func toSourceParams() -> [String: SourceParameters] {
        var params: [String: SourceParameters] = [:]

        // Add "composite" entry for CompositeSourceModel
        // (CompositeSourceModel doesn't use params, but orchestrator requires it)
        params["composite"] = SourceParameters(
            modelType: "composite",
            params: [:],
            timeDependent: false
        )

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

        if let ecrhConfig = ecrh {
            params["ecrh"] = SourceParameters(
                modelType: "ecrh",
                params: [
                    "total_power": ecrhConfig.totalPower,
                    "deposition_rho": ecrhConfig.depositionRho,
                    "deposition_width": ecrhConfig.depositionWidth,
                    "launch_angle": ecrhConfig.launchAngle ?? 0.0,
                    "frequency": ecrhConfig.frequency ?? 0.0,
                    "current_drive": ecrhConfig.currentDriveEnabled ? 1.0 : 0.0
                ],
                timeDependent: false
            )
        }

        if let gasPuffConfig = gasPuff {
            params["gasPuff"] = SourceParameters(
                modelType: "gasPuff",
                params: [
                    "puff_rate": gasPuffConfig.puffRate,
                    "penetration_depth": gasPuffConfig.penetrationDepth
                ],
                timeDependent: false
            )
        }

        if let impurityConfig = impurityRadiation {
            // Encode species as atomic number
            let atomicNumber: Float
            switch impurityConfig.species.lowercased() {
            case "carbon": atomicNumber = 6
            case "neon": atomicNumber = 10
            case "argon": atomicNumber = 18
            case "tungsten": atomicNumber = 74
            default: atomicNumber = 18  // Default to argon
            }

            params["impurityRadiation"] = SourceParameters(
                modelType: "impurityRadiation",
                params: [
                    "impurity_fraction": impurityConfig.impurityFraction,
                    "atomic_number": atomicNumber
                ],
                timeDependent: false
            )
        }

        return params
    }
}
