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

    public init(
        boundaries: BoundaryConfig,
        transport: TransportConfig,
        sources: SourcesConfig = .default,
        pedestal: PedestalConfig? = nil,
        mhd: MHDConfig = .default,
        restart: RestartConfig = .default
    ) {
        self.boundaries = boundaries
        self.transport = transport
        self.sources = sources
        self.pedestal = pedestal
        self.mhd = mhd
        self.restart = restart
    }

    /// Convenience initializer with default transport
    public init(
        boundaries: BoundaryConfig,
        sources: SourcesConfig = .default,
        pedestal: PedestalConfig? = nil,
        mhd: MHDConfig = .default,
        restart: RestartConfig = .default
    ) {
        self.boundaries = boundaries
        self.transport = TransportConfig(modelType: .constant)
        self.sources = sources
        self.pedestal = pedestal
        self.mhd = mhd
        self.restart = restart
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

    /// Generate default profile conditions from boundary values
    ///
    /// Creates parabolic profiles assuming:
    /// - Core temperature is 10× edge temperature (typical tokamak profile)
    /// - Core density is 3× edge density (flatter density profile)
    /// - Current density is uniform (placeholder)
    ///
    /// **Units**: eV for temperature, m^-3 for density (no conversion)
    /// This maintains consistency with CoreProfiles and BoundaryConditions.
    func toProfileConditions() -> ProfileConditions {
        ProfileConditions(
            ionTemperature: .parabolic(
                peak: boundaries.ionTemperature * 10.0,  // eV, core ~10× edge
                edge: boundaries.ionTemperature,
                exponent: 2.0
            ),
            electronTemperature: .parabolic(
                peak: boundaries.electronTemperature * 10.0,
                edge: boundaries.electronTemperature,
                exponent: 2.0
            ),
            electronDensity: .parabolic(
                peak: boundaries.density * 3.0,  // m^-3, core ~3× edge
                edge: boundaries.density,
                exponent: 1.5  // Flatter density profile
            ),
            currentDensity: .constant(1.0)  // Placeholder: 1 MA/m^2
        )
    }
}
