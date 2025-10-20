import Foundation
import MLX

// MARK: - Source Terms

/// Source and sink terms for plasma equations
///
/// Phase 4a: Added optional metadata field for power balance tracking.
/// Metadata enables accurate separation of fusion, auxiliary, ohmic, and
/// radiation contributions without fixed-ratio estimation.
public struct SourceTerms: Sendable, Equatable {
    /// Ion heating [MW/m^3]
    public let ionHeating: EvaluatedArray

    /// Electron heating [MW/m^3]
    public let electronHeating: EvaluatedArray

    /// Particle source [10^20/m^3/s]
    public let particleSource: EvaluatedArray

    /// Current source [MA/m^2]
    public let currentSource: EvaluatedArray

    /// Phase 4a: Source metadata for power balance (optional)
    ///
    /// When present, enables accurate power categorization.
    /// When nil, falls back to Phase 3 fixed-ratio estimation.
    public let metadata: SourceMetadataCollection?

    public init(
        ionHeating: EvaluatedArray,
        electronHeating: EvaluatedArray,
        particleSource: EvaluatedArray,
        currentSource: EvaluatedArray,
        metadata: SourceMetadataCollection? = nil
    ) {
        self.ionHeating = ionHeating
        self.electronHeating = electronHeating
        self.particleSource = particleSource
        self.currentSource = currentSource
        self.metadata = metadata
    }

    /// Equatable conformance (metadata ignored for array comparison)
    public static func == (lhs: SourceTerms, rhs: SourceTerms) -> Bool {
        lhs.ionHeating == rhs.ionHeating &&
        lhs.electronHeating == rhs.electronHeating &&
        lhs.particleSource == rhs.particleSource &&
        lhs.currentSource == rhs.currentSource
        // Note: metadata intentionally excluded from equality check
    }

    /// Zero source terms
    public static func zero(nCells: Int) -> SourceTerms {
        SourceTerms(
            ionHeating: .zeros([nCells]),
            electronHeating: .zeros([nCells]),
            particleSource: .zeros([nCells]),
            currentSource: .zeros([nCells])
        )
    }

    /// Add two source terms
    ///
    /// Phase 4a: Merges metadata collections when both are present
    public static func + (lhs: SourceTerms, rhs: SourceTerms) -> SourceTerms {
        // Merge metadata collections
        let mergedMetadata: SourceMetadataCollection?
        switch (lhs.metadata, rhs.metadata) {
        case (let lm?, let rm?):
            mergedMetadata = SourceMetadataCollection(entries: lm.entries + rm.entries)
        case (let lm?, nil):
            mergedMetadata = lm
        case (nil, let rm?):
            mergedMetadata = rm
        case (nil, nil):
            mergedMetadata = nil
        }

        return SourceTerms(
            ionHeating: EvaluatedArray(evaluating: lhs.ionHeating.value + rhs.ionHeating.value),
            electronHeating: EvaluatedArray(evaluating: lhs.electronHeating.value + rhs.electronHeating.value),
            particleSource: EvaluatedArray(evaluating: lhs.particleSource.value + rhs.particleSource.value),
            currentSource: EvaluatedArray(evaluating: lhs.currentSource.value + rhs.currentSource.value),
            metadata: mergedMetadata
        )
    }
}
