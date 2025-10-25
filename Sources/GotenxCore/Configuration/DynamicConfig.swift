// DynamicConfig.swift
// Dynamic configuration (runtime changeable)

import Foundation

/// Dynamic configuration (runtime changeable)
///
/// These parameters can change between timesteps without recompilation:
/// - Boundary conditions
/// - Source parameters
/// - Transport coefficients
/// - MHD model parameters
/// - Initial profile shape
public struct DynamicConfig: Codable, Sendable, Equatable {
    /// Boundary conditions (can be time-dependent)
    public let boundaries: BoundaryConfig

    /// Transport model configuration
    public let transport: TransportConfig

    /// Source configurations
    public let sources: SourcesConfig

    /// Pedestal configuration (optional)
    public let pedestal: PedestalConfig?

    /// MHD models configuration
    public let mhd: MHDConfig

    /// Restart configuration
    public let restart: RestartConfig

    /// Initial profile configuration
    public let initialProfile: InitialProfileConfig

    public init(
        boundaries: BoundaryConfig,
        transport: TransportConfig,
        sources: SourcesConfig = .default,
        pedestal: PedestalConfig? = nil,
        mhd: MHDConfig = .default,
        restart: RestartConfig = .default,
        initialProfile: InitialProfileConfig = .default
    ) {
        self.boundaries = boundaries
        self.transport = transport
        self.sources = sources
        self.pedestal = pedestal
        self.mhd = mhd
        self.restart = restart
        self.initialProfile = initialProfile
    }

    /// Convenience initializer with default transport
    public init(
        boundaries: BoundaryConfig,
        sources: SourcesConfig = .default,
        pedestal: PedestalConfig? = nil,
        mhd: MHDConfig = .default,
        restart: RestartConfig = .default,
        initialProfile: InitialProfileConfig = .default
    ) {
        self.boundaries = boundaries
        self.transport = TransportConfig(modelType: .constant)
        self.sources = sources
        self.pedestal = pedestal
        self.mhd = mhd
        self.restart = restart
        self.initialProfile = initialProfile
    }
}

/// Pedestal configuration (placeholder for future implementation)
public struct PedestalConfig: Codable, Sendable, Equatable {
    /// Pedestal model type
    public let model: String

    public init(model: String = "none") {
        self.model = model
    }
}

// MARK: - Conversion to Runtime Parameters

extension DynamicConfig {
    /// Convert to DynamicRuntimeParams for simulation execution
    ///
    /// This adapter bridges the configuration system with the runtime execution.
    /// - Parameter dt: Timestep value (from TimeConfig)
    /// - Returns: DynamicRuntimeParams ready for simulation
    public func toDynamicRuntimeParams(dt: Float) -> DynamicRuntimeParams {
        DynamicRuntimeParams(
            dt: dt,
            boundaryConditions: boundaries.toBoundaryConditions(),
            profileConditions: toProfileConditions(),
            sourceParams: sources.toSourceParams(),
            transportParams: transport.toTransportParameters()
        )
    }

    /// Generate profile conditions from boundary values and initial profile configuration
    ///
    /// Creates parabolic profiles using configurable ratios and exponents.
    /// This replaces hardcoded values with user-configurable settings.
    ///
    /// **Units**: eV for temperature, m^-3 for density (no conversion)
    /// This maintains consistency with CoreProfiles and BoundaryConditions.
    func toProfileConditions() -> ProfileConditions {
        ProfileConditions(
            ionTemperature: .parabolic(
                peak: boundaries.ionTemperature * initialProfile.temperaturePeakRatio,
                edge: boundaries.ionTemperature,
                exponent: initialProfile.temperatureExponent
            ),
            electronTemperature: .parabolic(
                peak: boundaries.electronTemperature * initialProfile.temperaturePeakRatio,
                edge: boundaries.electronTemperature,
                exponent: initialProfile.temperatureExponent
            ),
            electronDensity: .parabolic(
                peak: boundaries.density * initialProfile.densityPeakRatio,
                edge: boundaries.density,
                exponent: initialProfile.densityExponent
            ),
            currentDensity: .constant(1.0)  // Placeholder: 1 MA/m^2
        )
    }
}
