# TORAX Configuration System Design

## Overview

Swift ConfigurationとArgumentParserを組み合わせた型安全で階層的な設定管理システムの設計。

### Core Principles

1. **階層的オーバーライド**: CLI Args > Environment Variables > JSON File
2. **静的/動的パラメータの分離**: コンパイル最適化のため
3. **型安全性**: Codable + Sendable準拠
4. **ホットリロード**: インタラクティブモードでの設定変更
5. **TORAX互換**: オリジナルTORAXの設定構造を踏襲

## Configuration Hierarchy

```
SimulationConfiguration (root)
├── runtime: RuntimeConfiguration
│   ├── static: StaticRuntimeParams    ← 変更時に再コンパイル必要
│   └── dynamic: DynamicRuntimeParams  ← 再コンパイル不要
├── geometry: GeometryConfiguration
├── transport: TransportConfiguration
├── sources: SourceConfiguration
├── pedestal: PedestalConfiguration
└── numerics: NumericsConfiguration
```

## Provider Priority

```
1. CommandLineArgumentsProvider (highest priority)
   ↓ (if not found)
2. EnvironmentVariablesProvider
   ↓ (if not found)
3. ReloadingJSONProvider (from --config file)
   ↓ (if not found)
4. Default values in struct
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      torax run                              │
│                   (ArgumentParser)                          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
         ┌───────────────────────────────┐
         │      ConfigReader             │
         │  (Swift Configuration)        │
         └───────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
   ┌─────────┐   ┌──────────┐   ┌──────────────┐
   │  CLI    │   │   ENV    │   │  JSON File   │
   │  Args   │   │   Vars   │   │  (reload)    │
   └─────────┘   └──────────┘   └──────────────┘
                         │
                         ▼
         ┌───────────────────────────────┐
         │  SimulationConfiguration      │
         │        (Codable)              │
         └───────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
   ┌─────────┐   ┌──────────┐   ┌──────────────┐
   │ Static  │   │ Dynamic  │   │  Geometry    │
   │ Runtime │   │ Runtime  │   │  Transport   │
   └─────────┘   └──────────┘   └──────────────┘
                         │
                         ▼
         ┌───────────────────────────────┐
         │  SimulationOrchestrator       │
         │         (Actor)               │
         └───────────────────────────────┘
```

## File Structure

```
Sources/
├── TORAX/
│   └── Configuration/
│       ├── SimulationConfiguration.swift      # Root configuration
│       ├── RuntimeConfiguration.swift         # Runtime parameters
│       ├── GeometryConfiguration.swift        # Geometry parameters
│       ├── TransportConfiguration.swift       # Transport model config
│       ├── SourceConfiguration.swift          # Source term config
│       ├── PedestalConfiguration.swift        # Pedestal model config
│       ├── NumericsConfiguration.swift        # Solver config
│       └── ConfigurationValidator.swift       # Validation logic
│
└── torax-cli/
    ├── Configuration/
    │   ├── ConfigReaderFactory.swift          # ConfigReader creation
    │   ├── EnvironmentConfig.swift            # (existing)
    │   └── ConfigurationLoader.swift          # Load & validate
    └── Commands/
        ├── RunCommand.swift                   # (modified)
        └── InteractiveMenu.swift              # (modified for reload)
```

## Configuration Structures

### 1. Root Configuration

```swift
// Sources/TORAX/Configuration/SimulationConfiguration.swift

import Foundation

/// Root simulation configuration
///
/// This structure represents the complete configuration for a TORAX simulation,
/// loaded from JSON files and overridable via environment variables or CLI arguments.
public struct SimulationConfiguration: Codable, Sendable {
    /// Runtime parameters (static + dynamic)
    public let runtime: RuntimeConfiguration

    /// Geometry configuration
    public let geometry: GeometryConfiguration

    /// Transport model configuration
    public let transport: TransportConfiguration

    /// Source term configuration
    public let sources: SourceConfiguration

    /// Pedestal model configuration (optional)
    public let pedestal: PedestalConfiguration?

    /// Numerics configuration (solver settings)
    public let numerics: NumericsConfiguration

    /// Time stepping configuration
    public let time: TimeConfiguration

    public init(
        runtime: RuntimeConfiguration,
        geometry: GeometryConfiguration,
        transport: TransportConfiguration,
        sources: SourceConfiguration,
        pedestal: PedestalConfiguration? = nil,
        numerics: NumericsConfiguration,
        time: TimeConfiguration
    ) {
        self.runtime = runtime
        self.geometry = geometry
        self.transport = transport
        self.sources = sources
        self.pedestal = pedestal
        self.numerics = numerics
        self.time = time
    }
}
```

### 2. Runtime Configuration (Static vs Dynamic)

```swift
// Sources/TORAX/Configuration/RuntimeConfiguration.swift

import Foundation

/// Runtime configuration (static + dynamic split)
public struct RuntimeConfiguration: Codable, Sendable {
    /// Static parameters: trigger recompilation when changed
    public let `static`: StaticRuntimeParams

    /// Dynamic parameters: no recompilation needed
    public let dynamic: DynamicRuntimeParams

    public init(static: StaticRuntimeParams, dynamic: DynamicRuntimeParams) {
        self.static = `static`
        self.dynamic = dynamic
    }
}

/// Static runtime parameters
///
/// Changing these parameters requires recompilation of the step function.
/// These affect the computation graph structure.
public struct StaticRuntimeParams: Codable, Sendable, Hashable {
    /// Mesh configuration
    public let mesh: MeshConfig

    /// Which equations to evolve
    public let evolve: EvolutionConfig

    /// Solver type
    public let solver: SolverConfig

    /// Time stepper type
    public let stepper: StepperConfig

    public init(
        mesh: MeshConfig,
        evolve: EvolutionConfig = .default,
        solver: SolverConfig = .default,
        stepper: StepperConfig = .default
    ) {
        self.mesh = mesh
        self.evolve = evolve
        self.solver = solver
        self.stepper = stepper
    }
}

/// Dynamic runtime parameters
///
/// These parameters can change between timesteps without recompilation.
/// Used for time-dependent boundary conditions, source parameters, etc.
public struct DynamicRuntimeParams: Codable, Sendable {
    /// Boundary conditions (time-dependent)
    public let boundaryConditions: BoundaryConditionConfig

    /// Transport model parameters
    public let transport: TransportParameters

    /// Source model parameters
    public let sources: SourceParameters

    /// Pedestal model parameters (optional)
    public let pedestal: PedestalParameters?

    public init(
        boundaryConditions: BoundaryConditionConfig,
        transport: TransportParameters,
        sources: SourceParameters,
        pedestal: PedestalParameters? = nil
    ) {
        self.boundaryConditions = boundaryConditions
        self.transport = transport
        self.sources = sources
        self.pedestal = pedestal
    }
}

/// Mesh configuration
public struct MeshConfig: Codable, Sendable, Hashable {
    /// Number of radial cells
    public let nCells: Int

    /// Major radius [m]
    public let majorRadius: Float

    /// Minor radius [m]
    public let minorRadius: Float

    /// Toroidal magnetic field [T]
    public let toroidalField: Float

    public init(nCells: Int, majorRadius: Float, minorRadius: Float, toroidalField: Float) {
        self.nCells = nCells
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.toroidalField = toroidalField
    }
}

/// Evolution configuration (which equations to evolve)
public struct EvolutionConfig: Codable, Sendable, Hashable {
    public let ionTemperature: Bool
    public let electronTemperature: Bool
    public let electronDensity: Bool
    public let poloidalFlux: Bool

    public static let `default` = EvolutionConfig(
        ionTemperature: true,
        electronTemperature: true,
        electronDensity: true,
        poloidalFlux: false  // Current diffusion often disabled for simplicity
    )

    public init(
        ionTemperature: Bool,
        electronTemperature: Bool,
        electronDensity: Bool,
        poloidalFlux: Bool
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
        self.poloidalFlux = poloidalFlux
    }
}

/// Solver configuration
public struct SolverConfig: Codable, Sendable, Hashable {
    /// Solver type: "linear", "newton", "optimizer"
    public let type: String

    /// Maximum iterations
    public let maxIterations: Int

    /// Convergence tolerance
    public let tolerance: Float

    public static let `default` = SolverConfig(
        type: "linear",
        maxIterations: 30,
        tolerance: 1e-6
    )

    public init(type: String, maxIterations: Int, tolerance: Float) {
        self.type = type
        self.maxIterations = maxIterations
        self.tolerance = tolerance
    }
}

/// Time stepper configuration
public struct StepperConfig: Codable, Sendable, Hashable {
    /// Theta parameter for implicit/explicit scheme
    /// θ=0: explicit, θ=0.5: Crank-Nicolson, θ=1: fully implicit
    public let theta: Float

    public static let `default` = StepperConfig(theta: 1.0)  // Fully implicit

    public init(theta: Float) {
        self.theta = theta
    }
}

/// Boundary condition configuration
public struct BoundaryConditionConfig: Codable, Sendable {
    /// Ion temperature at boundary [eV]
    public let ionTemperature: Float

    /// Electron temperature at boundary [eV]
    public let electronTemperature: Float

    /// Electron density at boundary [m^-3]
    public let electronDensity: Float

    public init(
        ionTemperature: Float,
        electronTemperature: Float,
        electronDensity: Float
    ) {
        self.ionTemperature = ionTemperature
        self.electronTemperature = electronTemperature
        self.electronDensity = electronDensity
    }
}
```

### 3. Transport, Source, Geometry Configurations

```swift
// Sources/TORAX/Configuration/TransportConfiguration.swift

public struct TransportConfiguration: Codable, Sendable {
    /// Transport model type: "constant", "bohm-gyrobohm", "qlknn"
    public let modelType: String

    /// Model-specific parameters
    public let parameters: [String: Float]

    public init(modelType: String, parameters: [String: Float] = [:]) {
        self.modelType = modelType
        self.parameters = parameters
    }
}

// Sources/TORAX/Configuration/SourceConfiguration.swift

public struct SourceConfiguration: Codable, Sendable {
    /// Heating sources
    public let heating: HeatingConfig

    /// Particle sources
    public let particles: ParticleSourceConfig?

    /// Current drive sources
    public let currentDrive: CurrentDriveConfig?

    public init(
        heating: HeatingConfig,
        particles: ParticleSourceConfig? = nil,
        currentDrive: CurrentDriveConfig? = nil
    ) {
        self.heating = heating
        self.particles = particles
        self.currentDrive = currentDrive
    }
}

public struct HeatingConfig: Codable, Sendable {
    /// Enable Ohmic heating
    public let ohmicHeating: Bool

    /// Enable fusion power
    public let fusionPower: Bool

    /// Enable ion-electron exchange
    public let ionElectronExchange: Bool

    /// Enable Bremsstrahlung radiation
    public let bremsstrahlung: Bool

    public init(
        ohmicHeating: Bool = true,
        fusionPower: Bool = true,
        ionElectronExchange: Bool = true,
        bremsstrahlung: Bool = true
    ) {
        self.ohmicHeating = ohmicHeating
        self.fusionPower = fusionPower
        self.ionElectronExchange = ionElectronExchange
        self.bremsstrahlung = bremsstrahlung
    }
}

// Sources/TORAX/Configuration/GeometryConfiguration.swift

public struct GeometryConfiguration: Codable, Sendable {
    /// Geometry type: "circular", "shaped"
    public let type: String

    /// Time-dependent geometry
    public let timeDependent: Bool

    public init(type: String = "circular", timeDependent: Bool = false) {
        self.type = type
        self.timeDependent = timeDependent
    }
}

// Sources/TORAX/Configuration/TimeConfiguration.swift

public struct TimeConfiguration: Codable, Sendable {
    /// Initial time [s]
    public let tInitial: Float

    /// Final time [s]
    public let tFinal: Float

    /// Initial timestep [s]
    public let dtInitial: Float

    /// Minimum timestep [s]
    public let dtMin: Float

    /// Maximum timestep [s]
    public let dtMax: Float

    public init(
        tInitial: Float = 0.0,
        tFinal: Float = 1.0,
        dtInitial: Float = 1e-3,
        dtMin: Float = 1e-6,
        dtMax: Float = 1e-1
    ) {
        self.tInitial = tInitial
        self.tFinal = tFinal
        self.dtInitial = dtInitial
        self.dtMin = dtMin
        self.dtMax = dtMax
    }
}
```

## CLI Integration

### ConfigReader Factory

```swift
// Sources/torax-cli/Configuration/ConfigReaderFactory.swift

import Configuration
import Foundation

/// Factory for creating ConfigReader with TORAX provider hierarchy
struct ConfigReaderFactory {
    /// Create ConfigReader with standard TORAX provider hierarchy
    ///
    /// Priority order:
    /// 1. Command line arguments (highest)
    /// 2. Environment variables
    /// 3. JSON configuration file (reloadable)
    ///
    /// - Parameter configPath: Path to JSON configuration file
    /// - Returns: Configured ConfigReader
    static func createReader(configPath: String) async throws -> ConfigReader {
        var providers: [any ConfigProvider] = []

        // Priority 1: Command line arguments
        providers.append(CommandLineArgumentsProvider())

        // Priority 2: Environment variables with TORAX_ prefix
        providers.append(EnvironmentVariablesProvider(prefix: "TORAX_"))

        // Priority 3: JSON file (reloadable for interactive mode)
        let jsonProvider = try await ReloadingJSONProvider(path: configPath)
        providers.append(jsonProvider)

        return ConfigReader(providers: providers)
    }
}
```

### Configuration Loader

```swift
// Sources/torax-cli/Configuration/ConfigurationLoader.swift

import Configuration
import Foundation
import TORAX

/// Configuration loader with validation
struct ConfigurationLoader {
    let configReader: ConfigReader

    /// Load and validate complete simulation configuration
    func load() async throws -> SimulationConfiguration {
        // Load configuration from all providers
        let config = try await configReader.fetch(SimulationConfiguration.self)

        // Validate configuration
        try ConfigurationValidator.validate(config)

        return config
    }

    /// Reload configuration (useful in interactive mode)
    func reload() async throws -> SimulationConfiguration {
        try await configReader.reload()
        return try await load()
    }

    /// Check if static parameters changed (requires recompilation)
    func staticParametersChanged(
        old: SimulationConfiguration,
        new: SimulationConfiguration
    ) -> Bool {
        return old.runtime.static != new.runtime.static
    }
}
```

### Modified RunCommand

```swift
// Sources/torax-cli/Commands/RunCommand.swift (key changes)

struct RunCommand: AsyncParsableCommand {
    // ... existing options ...

    mutating func run() async throws {
        printBanner()

        // 1. Resolve config path
        let resolvedPath = try resolveConfigPath(config)
        print("Configuration: \(resolvedPath)")

        // 2. Create ConfigReader
        let configReader = try await ConfigReaderFactory.createReader(
            configPath: resolvedPath
        )

        // 3. Load and validate configuration
        let loader = ConfigurationLoader(configReader: configReader)
        let simulationConfig = try await loader.load()

        // 4. Setup environment
        let envConfig = EnvironmentConfig(
            compilationEnabled: !noCompile,
            errorsEnabled: enableErrors,
            cacheLimitMB: cacheLimit
        )
        try envConfig.apply()

        // 5. Create output directory
        try createOutputDirectory()

        // 6. Setup logger
        let logger = ProgressLogger(
            logProgress: logProgress,
            logOutput: logOutput
        )

        // 7. Start profiling
        let profiling = profile ? ProfilingContext(outputPath: profileOutput) : nil
        profiling?.start()

        // 8. Run simulation (future implementation)
        print("\n⚠️  Core simulation not yet implemented")
        logConfiguration(simulationConfig)

        // 9. Stop profiling
        if let context = profiling {
            let stats = context.stop()
            logger.logProfilingStats(stats)
        }

        // 10. Interactive menu (with reload capability)
        if !quit {
            try await interactiveMenu(
                logger: logger,
                configReader: configReader,
                currentConfig: simulationConfig
            )
        }
    }

    private func logConfiguration(_ config: SimulationConfiguration) {
        print("\n═══════════════════════════════════════════════════")
        print("Configuration Summary")
        print("═══════════════════════════════════════════════════")
        print("Mesh:")
        print("  • Cells: \(config.runtime.static.mesh.nCells)")
        print("  • Major radius: \(config.runtime.static.mesh.majorRadius) m")
        print("  • Minor radius: \(config.runtime.static.mesh.minorRadius) m")
        print("  • Toroidal field: \(config.runtime.static.mesh.toroidalField) T")
        print("\nEvolution:")
        print("  • Ion temperature: \(config.runtime.static.evolve.ionTemperature)")
        print("  • Electron temperature: \(config.runtime.static.evolve.electronTemperature)")
        print("  • Electron density: \(config.runtime.static.evolve.electronDensity)")
        print("  • Poloidal flux: \(config.runtime.static.evolve.poloidalFlux)")
        print("\nSolver: \(config.runtime.static.solver.type)")
        print("Transport: \(config.transport.modelType)")
        print("═══════════════════════════════════════════════════\n")
    }
}
```

### Modified InteractiveMenu with Reload

```swift
// Sources/torax-cli/Commands/InteractiveMenu.swift (key changes)

struct InteractiveMenu {
    let logger: ProgressLogger
    let plotConfig: String?
    let referenceRun: String?
    let configReader: ConfigReader
    var currentConfig: SimulationConfiguration

    // ... existing code ...

    private mutating func modifyConfiguration() async throws {
        print("\n⚙️  Modify Configuration")
        print("═══════════════════════════════════════════════════")

        print("Enter parameter path (e.g., 'runtime.static.mesh.nCells'): ", terminator: "")
        guard let path = readLine()?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            print("❌ Invalid parameter path")
            return
        }

        print("Enter new value: ", terminator: "")
        guard let valueStr = readLine()?.trimmingCharacters(in: .whitespaces), !valueStr.isEmpty else {
            print("❌ Invalid value")
            return
        }

        // Reload configuration with new value
        // (In real implementation, would modify provider or JSON file)
        print("\n✓ Configuration parameter updated")
        print("  Path: \(path)")
        print("  New value: \(valueStr)")

        // Reload and check for static parameter changes
        let loader = ConfigurationLoader(configReader: configReader)
        let newConfig = try await loader.reload()

        let needsRecompilation = loader.staticParametersChanged(
            old: currentConfig,
            new: newConfig
        )

        if needsRecompilation {
            print("\n⚠️  Static parameter changed - recompilation required")
            print("   This will take a few seconds...")
        } else {
            print("\n✓ Dynamic parameter changed - no recompilation needed")
        }

        currentConfig = newConfig
    }
}
```

## Example JSON Configuration

```json
{
  "runtime": {
    "static": {
      "mesh": {
        "nCells": 100,
        "majorRadius": 3.0,
        "minorRadius": 1.0,
        "toroidalField": 2.5
      },
      "evolve": {
        "ionTemperature": true,
        "electronTemperature": true,
        "electronDensity": true,
        "poloidalFlux": false
      },
      "solver": {
        "type": "linear",
        "maxIterations": 30,
        "tolerance": 1e-6
      },
      "stepper": {
        "theta": 1.0
      }
    },
    "dynamic": {
      "boundaryConditions": {
        "ionTemperature": 100.0,
        "electronTemperature": 100.0,
        "electronDensity": 1e19
      },
      "transport": {
        "modelType": "constant",
        "params": {
          "chi_ion": 1.0,
          "chi_electron": 1.5
        }
      },
      "sources": {
        "heating": {
          "ohmicHeating": true,
          "fusionPower": true,
          "ionElectronExchange": true,
          "bremsstrahlung": true
        }
      }
    }
  },
  "geometry": {
    "type": "circular",
    "timeDependent": false
  },
  "transport": {
    "modelType": "constant",
    "parameters": {
      "chi_ion": 1.0,
      "chi_electron": 1.5
    }
  },
  "sources": {
    "heating": {
      "ohmicHeating": true,
      "fusionPower": true,
      "ionElectronExchange": true,
      "bremsstrahlung": true
    }
  },
  "numerics": {
    "solver": {
      "type": "linear",
      "maxIterations": 30,
      "tolerance": 1e-6
    }
  },
  "time": {
    "tInitial": 0.0,
    "tFinal": 1.0,
    "dtInitial": 0.001,
    "dtMin": 1e-6,
    "dtMax": 0.1
  }
}
```

## Usage Examples

### Basic Usage

```bash
# Run with JSON config
torax run --config examples/basic.json

# Override via environment variable
export TORAX_RUNTIME_STATIC_MESH_NCELLS=200
torax run --config examples/basic.json

# Override via CLI argument
torax run --config examples/basic.json --runtime-static-mesh-ncells 300
```

### Interactive Mode

```bash
torax run --config examples/basic.json --log-progress

# In interactive menu:
# > mc  (modify configuration)
# Enter parameter path: runtime.dynamic.boundaryConditions.electronTemperature
# Enter new value: 150.0
# ✓ Dynamic parameter changed - no recompilation needed
#
# > mc  (modify configuration)
# Enter parameter path: runtime.static.mesh.nCells
# Enter new value: 200
# ⚠️  Static parameter changed - recompilation required
#
# > r   (rerun simulation with new config)
```

## Implementation Priority

### Phase 1: Core Configuration Structures
1. ✅ Create `SimulationConfiguration.swift`
2. ✅ Create `RuntimeConfiguration.swift`
3. ✅ Create helper config structs (Transport, Source, etc.)

### Phase 2: ConfigReader Integration
4. ✅ Create `ConfigReaderFactory.swift`
5. ✅ Create `ConfigurationLoader.swift`
6. ✅ Create `ConfigurationValidator.swift`

### Phase 3: CLI Integration
7. Modify `RunCommand.swift` to use ConfigReader
8. Modify `InteractiveMenu.swift` for reload support
9. Add configuration logging

### Phase 4: Testing & Examples
10. Create example JSON configurations
11. Write unit tests for configuration loading
12. Test environment variable overrides
13. Test CLI argument overrides

## Benefits

1. **Type Safety**: Compile-time checking of configuration structure
2. **Flexibility**: Override any parameter via ENV or CLI
3. **Hot Reload**: Change dynamic params without recompilation
4. **Validation**: Centralized validation logic
5. **Testability**: Easy to mock configurations in tests
6. **TORAX Compatibility**: Mirrors original TORAX structure
