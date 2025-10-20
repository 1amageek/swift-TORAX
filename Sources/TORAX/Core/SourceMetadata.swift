// SourceMetadata.swift
// Phase 4a: Source term categorization and metadata tracking
//
// This file introduces the foundational types for tracking individual
// source contributions in power balance calculations.

import MLX

/// Source category classification
///
/// Categories align with standard tokamak physics nomenclature:
/// - Fusion heating (α-particles + neutrons)
/// - Auxiliary heating (external power injection)
/// - Ohmic heating (resistive heating from plasma current)
/// - Radiation losses (bremsstrahlung, line radiation, etc.)
public enum SourceCategory: String, Sendable, Codable {
    /// Fusion power (D-T, D-D reactions)
    case fusion

    /// Auxiliary heating (NBI, ECRH, ICRH, LH)
    case auxiliary

    /// Ohmic heating (resistive dissipation)
    case ohmic

    /// Radiation losses (negative source)
    case radiation

    /// Other sources (ion-electron exchange, etc.)
    case other
}

/// Metadata for a single source term contribution
///
/// Phase 4a design: Track category and power components for each source.
/// This enables accurate power balance separation without fixed-ratio estimation.
///
/// Example:
/// ```swift
/// let fusionMetadata = SourceMetadata(
///     modelName: "fusion_power",
///     category: .fusion,
///     ionPower: 10.5e6,      // [W] Total ion heating
///     electronPower: 8.2e6,  // [W] Total electron heating
///     alphaPower: 3.7e6      // [W] Alpha particle heating
/// )
/// ```
public struct SourceMetadata: Sendable, Codable {
    /// Model name (e.g., "fusion_power", "ohmic_heating")
    public let modelName: String

    /// Source category
    public let category: SourceCategory

    /// Total ion heating power [W]
    public let ionPower: Float

    /// Total electron heating power [W]
    public let electronPower: Float

    /// Alpha particle power (fusion only) [W]
    public let alphaPower: Float?

    /// Radiation power (losses, negative) [W]
    public let radiationPower: Float?

    public init(
        modelName: String,
        category: SourceCategory,
        ionPower: Float,
        electronPower: Float,
        alphaPower: Float? = nil,
        radiationPower: Float? = nil
    ) {
        self.modelName = modelName
        self.category = category
        self.ionPower = ionPower
        self.electronPower = electronPower
        self.alphaPower = alphaPower
        self.radiationPower = radiationPower
    }

    /// Total power (ion + electron)
    public var totalPower: Float {
        ionPower + electronPower
    }

    /// Create default metadata for backward compatibility
    ///
    /// Phase 3 models without metadata support return this default.
    /// Powers are set to zero, indicating "not tracked".
    public static func `default`(modelName: String) -> SourceMetadata {
        SourceMetadata(
            modelName: modelName,
            category: .other,
            ionPower: 0,
            electronPower: 0
        )
    }
}

/// Collection of source metadata for all active sources
///
/// Phase 4a: Replace fixed-ratio power estimation with tracked contributions.
///
/// Example:
/// ```swift
/// let metadata = SourceMetadataCollection(entries: [
///     fusionMetadata,
///     ohmicMetadata,
///     bremsstrahlungMetadata
/// ])
///
/// let powerBalance = metadata.computePowerBalance()
/// print("Fusion power: \(powerBalance.fusionPower / 1e6) MW")
/// ```
public struct SourceMetadataCollection: Sendable {
    public let entries: [SourceMetadata]

    public init(entries: [SourceMetadata]) {
        self.entries = entries
    }

    /// Compute total power by category
    public func totalPower(category: SourceCategory) -> Float {
        entries
            .filter { $0.category == category }
            .map { $0.totalPower }
            .reduce(0, +)
    }

    /// Total fusion power
    public var fusionPower: Float {
        totalPower(category: .fusion)
    }

    /// Total auxiliary power
    public var auxiliaryPower: Float {
        totalPower(category: .auxiliary)
    }

    /// Total ohmic power
    public var ohmicPower: Float {
        totalPower(category: .ohmic)
    }

    /// Total radiation losses (negative)
    public var radiationPower: Float {
        totalPower(category: .radiation)
    }

    /// Total alpha power (fusion only)
    public var alphaPower: Float {
        entries
            .compactMap { $0.alphaPower }
            .reduce(0, +)
    }

    /// Total ion heating
    public var totalIonHeating: Float {
        entries.map { $0.ionPower }.reduce(0, +)
    }

    /// Total electron heating
    public var totalElectronHeating: Float {
        entries.map { $0.electronPower }.reduce(0, +)
    }

    /// Empty collection for backward compatibility
    public static var empty: SourceMetadataCollection {
        SourceMetadataCollection(entries: [])
    }
}
