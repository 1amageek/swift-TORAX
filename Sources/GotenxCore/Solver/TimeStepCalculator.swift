import MLX
import Foundation

// MARK: - Time Step Calculator

/// Calculate adaptive timestep based on transport coefficients and grid spacing
///
/// Implements CFL (Courant-Friedrichs-Lewy) condition for stability:
/// dt < C * dr^2 / χ_max
///
/// where:
/// - C is the stability factor (typically 0.5-0.9)
/// - dr is the grid spacing
/// - χ_max is the maximum transport coefficient
public struct TimeStepCalculator {
    // MARK: - Properties

    /// Stability factor (CFL number)
    public let stabilityFactor: Float

    /// Minimum allowed timestep [s]
    public let minTimestep: Float

    /// Maximum allowed timestep [s]
    public let maxTimestep: Float

    // MARK: - Initialization

    public init(
        stabilityFactor: Float = 0.9,
        minTimestep: Float = 1e-6,
        maxTimestep: Float = 1e-2
    ) {
        precondition(stabilityFactor > 0.0 && stabilityFactor < 1.0, "Stability factor must be in (0, 1)")
        precondition(minTimestep > 0.0, "Minimum timestep must be positive")
        precondition(maxTimestep > minTimestep, "Maximum timestep must be larger than minimum")

        // 🐛 DEBUG: TimeStepCalculator initialization
        print("[DEBUG-TSCALC] TimeStepCalculator init:")
        print("[DEBUG-TSCALC]   minTimestep: \(minTimestep)")
        print("[DEBUG-TSCALC]   maxTimestep: \(maxTimestep)")
        print("[DEBUG-TSCALC]   stabilityFactor: \(stabilityFactor)")

        self.stabilityFactor = stabilityFactor
        self.minTimestep = minTimestep
        self.maxTimestep = maxTimestep
    }

    /// 最小タイムステップ（秒）
    ///
    /// タイムステップを縮小リトライする際の下限値として利用する。
    public var minimumTimestep: Float {
        minTimestep
    }

    // MARK: - Timestep Computation

    /// Compute stable timestep from transport coefficients
    ///
    /// - Parameters:
    ///   - transportCoeffs: Transport coefficients (chi, D, V)
    ///   - dr: Grid spacing [m]
    /// - Returns: Stable timestep [s]
    public func compute(
        transportCoeffs: TransportCoefficients,
        dr: Float
    ) -> Float {
        // Find maximum diffusion coefficient
        let chiIonMax = transportCoeffs.chiIon.value.max().item(Float.self)
        let chiElectronMax = transportCoeffs.chiElectron.value.max().item(Float.self)
        let particleDiffMax = transportCoeffs.particleDiffusivity.value.max().item(Float.self)

        let chiMax = max(chiIonMax, chiElectronMax, particleDiffMax)

        // CFL condition for diffusion: dt < C * dr^2 / χ
        let dtDiffusion = stabilityFactor * dr * dr / max(chiMax, 1e-10)

        // CFL condition for convection: dt < C * dr / |v|
        let vMax = abs(transportCoeffs.convectionVelocity.value).max().item(Float.self)
        let dtConvection = stabilityFactor * dr / max(vMax, 1e-10)

        // Take minimum of both conditions
        let dt = min(dtDiffusion, dtConvection)

        // Clamp to allowed range
        return clamp(dt, min: minTimestep, max: maxTimestep)
    }

    /// Compute adaptive timestep considering profile evolution
    ///
    /// This variant also considers the rate of change of profiles
    /// to prevent too large changes in a single timestep.
    ///
    /// - Parameters:
    ///   - transportCoeffs: Transport coefficients
    ///   - profiles: Current profiles
    ///   - profilesPrev: Profiles from previous timestep
    ///   - dtPrev: Previous timestep
    ///   - dr: Grid spacing
    ///   - maxRelativeChange: Maximum allowed relative change per timestep
    /// - Returns: Adaptive timestep
    public func computeAdaptive(
        transportCoeffs: TransportCoefficients,
        profiles: CoreProfiles,
        profilesPrev: CoreProfiles,
        dtPrev: Float,
        dr: Float,
        maxRelativeChange: Float = 0.1
    ) -> Float {
        // Start with CFL-based timestep
        var dt = compute(transportCoeffs: transportCoeffs, dr: dr)

        // Compute rate of change for each variable
        let changeTi = abs(profiles.ionTemperature.value - profilesPrev.ionTemperature.value)
        let maxChangeTi = changeTi.max().item(Float.self)
        let rateTi = maxChangeTi / dtPrev

        let changeTe = abs(profiles.electronTemperature.value - profilesPrev.electronTemperature.value)
        let maxChangeTe = changeTe.max().item(Float.self)
        let rateTe = maxChangeTe / dtPrev

        let changeNe = abs(profiles.electronDensity.value - profilesPrev.electronDensity.value)
        let maxChangeNe = changeNe.max().item(Float.self)
        let rateNe = maxChangeNe / dtPrev

        // Compute maximum rate
        let maxRate = max(rateTi, rateTe, rateNe)

        // Limit timestep based on maximum allowed change
        if maxRate > 1e-10 {
            let dtMaxChange = maxRelativeChange / maxRate
            dt = min(dt, dtMaxChange)
        }

        // Gradual adaptation: don't change dt too rapidly
        let dtRatio = dt / dtPrev
        if dtRatio > 1.5 {
            dt = 1.5 * dtPrev  // Increase by at most 50%
        } else if dtRatio < 0.5 {
            dt = 0.5 * dtPrev  // Decrease by at most 50%
        }

        // Clamp to allowed range
        return clamp(dt, min: minTimestep, max: maxTimestep)
    }

    // MARK: - Helper Functions

    /// Clamp value to range [min, max]
    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        return Swift.max(min, Swift.min(max, value))
    }
}
