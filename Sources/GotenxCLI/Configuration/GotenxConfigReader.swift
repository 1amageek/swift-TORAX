// GotenxConfigReader.swift
// ConfigReader-based configuration loading for Gotenx

import Configuration
import Foundation
import SystemPackage
import Gotenx

/// TORAX-specific ConfigReader wrapper
///
/// Provides hierarchical configuration loading with the following priority:
/// 1. CLI arguments (highest)
/// 2. Environment variables
/// 3. JSON file (reloadable)
/// 4. Default values (lowest)
public actor GotenxConfigReader {
    private let configReader: ConfigReader

    private init(configReader: ConfigReader) {
        self.configReader = configReader
    }

    /// Create GotenxConfigReader with hierarchical providers
    ///
    /// - Parameters:
    ///   - jsonPath: Path to JSON configuration file
    ///   - cliOverrides: CLI argument overrides as key-value pairs
    /// - Returns: Configured GotenxConfigReader
    public static func create(
        jsonPath: String,
        cliOverrides: [String: String] = [:]
    ) async throws -> GotenxConfigReader {
        var providers: [any ConfigProvider] = []

        // IMPORTANT: ConfigReader uses FIRST-MATCH priority order
        // First provider in array has HIGHEST priority
        // (This is the OPPOSITE of what the initial assumption was)

        // Priority 1 (highest): CLI arguments
        if !cliOverrides.isEmpty {
            // Convert [String: String] to [String: ConfigValue]
            // Note: Values are provided as strings, ConfigReader will handle type conversion
            let configValues = cliOverrides.mapValues { value in
                // Attempt to parse as different types
                if let intValue = Int(value) {
                    return ConfigValue(.int(intValue), isSecret: false)
                } else if let doubleValue = Double(value) {
                    return ConfigValue(.double(doubleValue), isSecret: false)
                } else if let boolValue = Bool(value) {
                    return ConfigValue(.bool(boolValue), isSecret: false)
                } else {
                    return ConfigValue(.string(value), isSecret: false)
                }
            }
            providers.append(
                InMemoryProvider(values: configValues)
            )
        }

        // Priority 2: Environment variables
        providers.append(
            EnvironmentVariablesProvider()
        )

        // Priority 3 (lowest): JSON file
        let jsonProvider = try await JSONProvider(filePath: FilePath(jsonPath))
        providers.append(jsonProvider)

        let reader = ConfigReader(providers: providers)
        return GotenxConfigReader(configReader: reader)
    }

    // MARK: - Configuration Fetching

    /// Fetch complete SimulationConfiguration
    public func fetchConfiguration() async throws -> SimulationConfiguration {
        let runtime = try await fetchRuntimeConfig()
        let time = try await fetchTimeConfig()
        let output = try await fetchOutputConfig()

        return SimulationConfiguration(
            runtime: runtime,
            time: time,
            output: output
        )
    }

    /// Reload configuration by creating a new GotenxConfigReader
    ///
    /// Note: ConfigReader doesn't have a reload() method. To reload configuration,
    /// you need to create a new GotenxConfigReader instance. For automatic reloading,
    /// use ReloadingJSONProvider instead of JSONProvider when creating the reader.
    ///
    /// This method is deprecated and will be removed. Use create() to get fresh config.
    @available(*, deprecated, message: "Use GotenxConfigReader.create() to reload configuration")
    public func reload() async throws -> SimulationConfiguration {
        // ConfigReader doesn't support reload - this is a placeholder
        return try await fetchConfiguration()
    }

    // MARK: - Runtime Configuration

    private func fetchRuntimeConfig() async throws -> RuntimeConfiguration {
        let staticConfig = try await fetchStaticConfig()
        let dynamicConfig = try await fetchDynamicConfig()

        return RuntimeConfiguration(
            static: staticConfig,
            dynamic: dynamicConfig
        )
    }

    private func fetchStaticConfig() async throws -> StaticConfig {
        // Mesh configuration
        let meshNCells = try await configReader.fetchInt(
            forKey: "runtime.static.mesh.nCells",
            default: 100
        )
        let majorRadius = try await configReader.fetchDouble(
            forKey: "runtime.static.mesh.majorRadius",
            default: 3.0
        )
        let minorRadius = try await configReader.fetchDouble(
            forKey: "runtime.static.mesh.minorRadius",
            default: 1.0
        )
        let toroidalField = try await configReader.fetchDouble(
            forKey: "runtime.static.mesh.toroidalField",
            default: 2.5
        )
        let geometryType = try await configReader.fetchString(
            forKey: "runtime.static.mesh.geometryType",
            default: "circular"
        )

        let mesh = MeshConfig(
            nCells: meshNCells,
            majorRadius: Float(majorRadius),
            minorRadius: Float(minorRadius),
            toroidalField: Float(toroidalField),
            geometryType: GeometryType(rawValue: geometryType) ?? .circular
        )

        // Evolution configuration
        let evolveIonHeat = try await configReader.fetchBool(
            forKey: "runtime.static.evolution.ionTemperature",
            default: true
        )
        let evolveElectronHeat = try await configReader.fetchBool(
            forKey: "runtime.static.evolution.electronTemperature",
            default: true
        )
        let evolveDensity = try await configReader.fetchBool(
            forKey: "runtime.static.evolution.electronDensity",
            default: true
        )
        let evolveCurrent = try await configReader.fetchBool(
            forKey: "runtime.static.evolution.poloidalFlux",
            default: false
        )

        let evolution = EvolutionConfig(
            ionHeat: evolveIonHeat,
            electronHeat: evolveElectronHeat,
            density: evolveDensity,
            current: evolveCurrent
        )

        // Solver configuration
        let solverType = try await configReader.fetchString(
            forKey: "runtime.static.solver.type",
            default: "linear"
        )
        let solverMaxIter = try await configReader.fetchInt(
            forKey: "runtime.static.solver.maxIterations",
            default: 30
        )
        let solverTolerance = try await configReader.fetchDouble(
            forKey: "runtime.static.solver.tolerance",
            default: 1e-6
        )

        let solver = SolverConfig(
            type: solverType,
            tolerance: Float(solverTolerance),
            maxIterations: solverMaxIter
        )

        // Scheme configuration
        let theta = try await configReader.fetchDouble(
            forKey: "runtime.static.scheme.theta",
            default: 1.0
        )

        let scheme = SchemeConfig(theta: Float(theta))

        return StaticConfig(
            mesh: mesh,
            evolution: evolution,
            solver: solver,
            scheme: scheme
        )
    }

    private func fetchDynamicConfig() async throws -> DynamicConfig {
        // Boundary conditions
        let ionTemp = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.boundaries.ionTemperature",
            default: 100.0
        )
        let electronTemp = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.boundaries.electronTemperature",
            default: 100.0
        )
        let electronDensity = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.boundaries.electronDensity",
            default: 1e19
        )

        let boundaries = BoundaryConfig(
            ionTemperature: Float(ionTemp),
            electronTemperature: Float(electronTemp),
            density: Float(electronDensity)
        )

        // Transport configuration
        let transport = try await fetchTransportConfig()

        // Sources configuration
        let sources = try await fetchSourcesConfig()

        // Pedestal configuration (optional)
        let pedestalModel = try await configReader.fetchString(
            forKey: "runtime.dynamic.pedestal.model",
            default: "none"
        )
        let pedestal = pedestalModel != "none" ? PedestalConfig(model: pedestalModel) : nil

        // MHD configuration
        let mhd = try await fetchMHDConfig()

        // Restart configuration
        let restart = try await fetchRestartConfig()

        return DynamicConfig(
            boundaries: boundaries,
            transport: transport,
            sources: sources,
            pedestal: pedestal,
            mhd: mhd,
            restart: restart
        )
    }

    private func fetchTransportConfig() async throws -> TransportConfig {
        let modelType = try await configReader.fetchString(
            forKey: "runtime.dynamic.transport.modelType",
            default: "constant"
        )

        // Transport-specific parameters (optional)
        var parameters: [String: Float] = [:]

        if let chiIon = try? await configReader.fetchDouble(forKey: "runtime.dynamic.transport.chiIon") {
            parameters["chiIon"] = Float(chiIon)
        }
        if let chiElectron = try? await configReader.fetchDouble(forKey: "runtime.dynamic.transport.chiElectron") {
            parameters["chiElectron"] = Float(chiElectron)
        }

        return TransportConfig(
            modelType: modelType,
            parameters: parameters
        )
    }

    private func fetchSourcesConfig() async throws -> SourcesConfig {
        let ohmicEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.sources.ohmicHeating",
            default: true
        )
        let fusionEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.sources.fusionPower",
            default: true
        )
        let ionElectronEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.sources.ionElectronExchange",
            default: true
        )
        let bremsstrahlungEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.sources.bremsstrahlung",
            default: true
        )

        return SourcesConfig(
            ohmicHeating: ohmicEnabled,
            fusionPower: fusionEnabled,
            ionElectronExchange: ionElectronEnabled,
            bremsstrahlung: bremsstrahlungEnabled
        )
    }

    private func fetchMHDConfig() async throws -> MHDConfig {
        let sawtoothEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.mhd.sawtoothEnabled",
            default: false
        )

        // Sawtooth parameters
        let qCritical = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.mhd.sawtooth.qCritical",
            default: 1.0
        )
        let inversionRadius = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.mhd.sawtooth.inversionRadius",
            default: 0.3
        )
        let mixingTime = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.mhd.sawtooth.mixingTime",
            default: 1e-4
        )
        let minCrashInterval = try await configReader.fetchDouble(
            forKey: "runtime.dynamic.mhd.sawtooth.minCrashInterval",
            default: 0.01
        )

        let sawtoothParams = SawtoothParameters(
            qCritical: Float(qCritical),
            inversionRadius: Float(inversionRadius),
            mixingTime: Float(mixingTime),
            minCrashInterval: Float(minCrashInterval)
        )

        let ntmEnabled = try await configReader.fetchBool(
            forKey: "runtime.dynamic.mhd.ntmEnabled",
            default: false
        )

        return MHDConfig(
            sawtoothEnabled: sawtoothEnabled,
            sawtoothParams: sawtoothParams,
            ntmEnabled: ntmEnabled
        )
    }

    private func fetchRestartConfig() async throws -> RestartConfig {
        let doRestart = try await configReader.fetchBool(
            forKey: "runtime.dynamic.restart.doRestart",
            default: false
        )

        let filename = try? await configReader.fetchString(
            forKey: "runtime.dynamic.restart.filename"
        )

        let time = try? await configReader.fetchDouble(
            forKey: "runtime.dynamic.restart.time"
        )

        let stitch = try await configReader.fetchBool(
            forKey: "runtime.dynamic.restart.stitch",
            default: true
        )

        return RestartConfig(
            filename: filename,
            time: time.map { Float($0) },
            doRestart: doRestart,
            stitch: stitch
        )
    }

    // MARK: - Time Configuration

    private func fetchTimeConfig() async throws -> TimeConfiguration {
        let start = try await configReader.fetchDouble(
            forKey: "time.start",
            default: 0.0
        )
        let end = try await configReader.fetchDouble(
            forKey: "time.end",
            default: 1.0
        )
        let initialDt = try await configReader.fetchDouble(
            forKey: "time.initialDt",
            default: 1e-3
        )

        // Adaptive timestep configuration (optional)
        let adaptiveEnabled = try await configReader.fetchBool(
            forKey: "time.adaptive.enabled",
            default: true
        )

        let adaptive: AdaptiveTimestepConfig?
        if adaptiveEnabled {
            let safetyFactor = try await configReader.fetchDouble(
                forKey: "time.adaptive.safetyFactor",
                default: 0.9
            )
            let minDt = try await configReader.fetchDouble(
                forKey: "time.adaptive.minDt",
                default: 1e-6
            )
            let maxDt = try await configReader.fetchDouble(
                forKey: "time.adaptive.maxDt",
                default: 1e-1
            )

            adaptive = AdaptiveTimestepConfig(
                minDt: Float(minDt),
                maxDt: Float(maxDt),
                safetyFactor: Float(safetyFactor)
            )
        } else {
            adaptive = nil
        }

        return TimeConfiguration(
            start: Float(start),
            end: Float(end),
            initialDt: Float(initialDt),
            adaptive: adaptive
        )
    }

    // MARK: - Output Configuration

    private func fetchOutputConfig() async throws -> OutputConfiguration {
        let saveInterval = try? await configReader.fetchDouble(
            forKey: "output.saveInterval"
        )

        let directory = try await configReader.fetchString(
            forKey: "output.directory",
            default: "/tmp/gotenx_results"
        )

        let formatStr = try await configReader.fetchString(
            forKey: "output.format",
            default: "json"
        )

        let format: Gotenx.OutputFormat
        switch formatStr.lowercased() {
        case "json":
            format = .json
        case "hdf5":
            format = .hdf5
        case "netcdf":
            format = .netcdf
        default:
            format = .json
        }

        return OutputConfiguration(
            saveInterval: saveInterval.map { Float($0) },
            directory: directory,
            format: format
        )
    }
}
