import Foundation

// MARK: - Transport Coefficients

/// Transport coefficients for heat and particle transport
public struct TransportCoefficients: Sendable, Equatable {
    /// Ion heat diffusivity [m^2/s]
    public let chiIon: EvaluatedArray

    /// Electron heat diffusivity [m^2/s]
    public let chiElectron: EvaluatedArray

    /// Particle diffusivity [m^2/s]
    public let particleDiffusivity: EvaluatedArray

    /// Convection velocity [m/s]
    public let convectionVelocity: EvaluatedArray

    public init(
        chiIon: EvaluatedArray,
        chiElectron: EvaluatedArray,
        particleDiffusivity: EvaluatedArray,
        convectionVelocity: EvaluatedArray
    ) {
        self.chiIon = chiIon
        self.chiElectron = chiElectron
        self.particleDiffusivity = particleDiffusivity
        self.convectionVelocity = convectionVelocity
    }
}
