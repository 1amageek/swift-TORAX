import Foundation
import MLX

// MARK: - Source Terms

/// Source and sink terms for plasma equations
public struct SourceTerms: Sendable, Equatable {
    /// Ion heating [MW/m^3]
    public let ionHeating: EvaluatedArray

    /// Electron heating [MW/m^3]
    public let electronHeating: EvaluatedArray

    /// Particle source [10^20/m^3/s]
    public let particleSource: EvaluatedArray

    /// Current source [MA/m^2]
    public let currentSource: EvaluatedArray

    public init(
        ionHeating: EvaluatedArray,
        electronHeating: EvaluatedArray,
        particleSource: EvaluatedArray,
        currentSource: EvaluatedArray
    ) {
        self.ionHeating = ionHeating
        self.electronHeating = electronHeating
        self.particleSource = particleSource
        self.currentSource = currentSource
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
    public static func + (lhs: SourceTerms, rhs: SourceTerms) -> SourceTerms {
        SourceTerms(
            ionHeating: EvaluatedArray(evaluating: lhs.ionHeating.value + rhs.ionHeating.value),
            electronHeating: EvaluatedArray(evaluating: lhs.electronHeating.value + rhs.electronHeating.value),
            particleSource: EvaluatedArray(evaluating: lhs.particleSource.value + rhs.particleSource.value),
            currentSource: EvaluatedArray(evaluating: lhs.currentSource.value + rhs.currentSource.value)
        )
    }
}
