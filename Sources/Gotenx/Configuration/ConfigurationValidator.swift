// ConfigurationValidator.swift
// Configuration validator with physics-aware checks

import Foundation

/// Configuration validator with physics-aware checks
public struct ConfigurationValidator {

    /// Validate complete configuration
    public static func validate(_ config: SimulationConfiguration) throws {
        // Validate individual components
        // Catch physics warnings (advisory only) but propagate hard errors
        do {
            try config.runtime.static.mesh.validate()
        } catch ConfigurationError.physicsWarning(let key, let value, let reason) {
            print("⚠️  Warning for '\(key)': \(value). \(reason)")
        } catch {
            throw error  // Re-throw hard errors
        }

        do {
            try config.runtime.static.scheme.validate()
        } catch ConfigurationError.physicsWarning(let key, let value, let reason) {
            print("⚠️  Warning for '\(key)': \(value). \(reason)")
        } catch {
            throw error  // Re-throw hard errors
        }

        // These validations have hard errors only (no warnings)
        try validateTimeRange(config.time)
        try validateBoundaries(config.runtime.dynamic.boundaries)
        try validateSources(config.runtime.dynamic.sources)

        // Cross-component validation
        try validateConsistency(config)
    }

    /// Validate time range
    private static func validateTimeRange(_ time: TimeConfiguration) throws {
        guard time.end > time.start else {
            throw ConfigurationError.invalidValue(
                key: "time.end",
                value: "\(time.end)",
                reason: "End time must be greater than start time"
            )
        }

        guard time.initialDt > 0 else {
            throw ConfigurationError.invalidValue(
                key: "time.initialDt",
                value: "\(time.initialDt)",
                reason: "Initial timestep must be positive"
            )
        }

        if let adaptive = time.adaptive {
            // minDt must be positive
            guard adaptive.minDt > 0 else {
                throw ConfigurationError.invalidValue(
                    key: "time.adaptive.minDt",
                    value: "\(adaptive.minDt)",
                    reason: "Min timestep must be positive"
                )
            }

            // maxDt must be greater than minDt
            guard adaptive.minDt < adaptive.maxDt else {
                throw ConfigurationError.invalidValue(
                    key: "time.adaptive",
                    value: "min=\(adaptive.minDt), max=\(adaptive.maxDt)",
                    reason: "Min timestep must be less than max timestep"
                )
            }

            // safetyFactor must be in (0, 1]
            guard adaptive.safetyFactor > 0 && adaptive.safetyFactor <= 1.0 else {
                throw ConfigurationError.invalidValue(
                    key: "time.adaptive.safetyFactor",
                    value: "\(adaptive.safetyFactor)",
                    reason: "Safety factor must be in (0, 1]"
                )
            }

            // Warning: initialDt should be within adaptive range
            if time.initialDt < adaptive.minDt || time.initialDt > adaptive.maxDt {
                print("⚠️  Warning: initialDt (\(time.initialDt)s) is outside adaptive range")
                print("   Adaptive range: [\(adaptive.minDt), \(adaptive.maxDt)]s")
                print("   Timestep will be clamped to this range")
            }
        }
    }

    /// Validate boundary conditions
    private static func validateBoundaries(_ boundaries: BoundaryConfig) throws {
        guard boundaries.ionTemperature > 0 else {
            throw ConfigurationError.invalidValue(
                key: "boundaries.ionTemperature",
                value: "\(boundaries.ionTemperature)",
                reason: "Temperature must be positive"
            )
        }

        guard boundaries.electronTemperature > 0 else {
            throw ConfigurationError.invalidValue(
                key: "boundaries.electronTemperature",
                value: "\(boundaries.electronTemperature)",
                reason: "Temperature must be positive"
            )
        }

        guard boundaries.density > 0 else {
            throw ConfigurationError.invalidValue(
                key: "boundaries.density",
                value: "\(boundaries.density)",
                reason: "Density must be positive"
            )
        }
    }

    /// Validate source configuration
    private static func validateSources(_ sources: SourcesConfig) throws {
        if let fusion = sources.fusionConfig {
            let totalFraction = fusion.deuteriumFraction + fusion.tritiumFraction
            guard abs(totalFraction - 1.0) < 1e-6 else {
                throw ConfigurationError.invalidValue(
                    key: "sources.fusionConfig.fractions",
                    value: "D=\(fusion.deuteriumFraction), T=\(fusion.tritiumFraction)",
                    reason: "Fuel fractions must sum to 1.0"
                )
            }

            guard fusion.dilution > 0 && fusion.dilution <= 1.0 else {
                throw ConfigurationError.invalidValue(
                    key: "sources.fusionConfig.dilution",
                    value: "\(fusion.dilution)",
                    reason: "Dilution must be in (0, 1]"
                )
            }
        }
    }

    /// Cross-component consistency checks
    private static func validateConsistency(_ config: SimulationConfiguration) throws {
        // Check: If current evolution is enabled, appropriate sources must be configured
        if config.runtime.static.evolution.current {
            guard config.runtime.dynamic.sources.ohmicHeating else {
                throw ConfigurationError.inconsistency(
                    reason: "Current evolution requires Ohmic heating to be enabled"
                )
            }
        }

        // Warning: Timestep stability check (not enforced)
        // Note: True CFL condition depends on transport coefficients
        // Diffusive CFL: dt < C * dx^2 / D_max
        // Convective CFL: dt < dx / v_max
        let mesh = config.runtime.static.mesh

        // Conservative diffusive CFL estimate
        // Use C = 0.5 for stability, assume worst-case D ~ 10 m²/s (high transport)
        let conservativeDiffusiveCFL = 0.5 * mesh.dr * mesh.dr / 10.0

        if config.time.initialDt > conservativeDiffusiveCFL {
            // Warning only - actual stability depends on transport model
            print("⚠️  Warning: Initial timestep may violate diffusive CFL condition")
            print("   Current dt: \(config.time.initialDt)s")
            print("   Conservative CFL limit: \(conservativeDiffusiveCFL)s (assuming D~10 m²/s)")
            print("   Actual stability depends on transport coefficients")
        }

        // Conservative convective CFL estimate
        // Assume typical convection velocity ~ 10 m/s
        let conservativeConvectiveCFL = mesh.dr / 10.0

        if config.time.initialDt > conservativeConvectiveCFL {
            print("⚠️  Warning: Initial timestep may violate convective CFL condition")
            print("   Current dt: \(config.time.initialDt)s")
            print("   Convective limit: \(conservativeConvectiveCFL)s (assuming v~10 m/s)")
            print("   Consider reducing timestep if convection is significant")
        }
    }
}
