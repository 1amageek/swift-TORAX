# swift-TORAX Command-Line Interface

This document describes the command-line interface (CLI) design for swift-TORAX, inspired by the original [TORAX CLI](https://deepwiki.com/google-deepmind/torax).

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Commands](#commands)
4. [Configuration](#configuration)
5. [Output Formats](#output-formats)
6. [Environment Variables](#environment-variables)
7. [Examples](#examples)
8. [Development Guide](#development-guide)

---

## Overview

swift-TORAX provides a command-line interface for running tokamak core transport simulations and visualizing results. The CLI is built using [swift-argument-parser](https://github.com/apple/swift-argument-parser) and follows Swift idioms while maintaining compatibility with the original TORAX workflow.

### Design Goals

- **Type-safe**: Leverage Swift's type system for argument validation
- **User-friendly**: Clear error messages and interactive menus
- **Scriptable**: Support for batch processing and automation
- **Extensible**: Easy to add new commands and options
- **Cross-platform**: Works on macOS (primary target) with potential Linux support

### Key Features

- **Two primary commands**: `run` for simulations, `plot` for visualization
- **Interactive menu**: Post-simulation actions without recompilation
- **Progress logging**: Real-time monitoring of simulation progress
- **Multiple output formats**: JSON, HDF5, NetCDF (planned)
- **Debugging support**: Disable compilation, enable error checking
- **Reference comparison**: Plot against reference runs

---

## Architecture

### Package Structure

```
swift-TORAX/
├── Sources/
│   ├── TORAX/                    # Core library
│   │   ├── Simulation/
│   │   ├── Physics/
│   │   ├── Numerics/
│   │   └── ...
│   └── torax-cli/                # CLI executable (NEW)
│       ├── main.swift            # Entry point
│       ├── Commands/
│       │   ├── RunCommand.swift
│       │   ├── PlotCommand.swift
│       │   └── InteractiveMenu.swift
│       ├── Configuration/
│       │   ├── CLIConfiguration.swift
│       │   └── EnvironmentConfig.swift
│       └── Output/
│           ├── OutputWriter.swift
│           ├── ProgressLogger.swift
│           └── SimulationPlotter.swift
└── Package.swift
```

### Dependency Graph

```
torax-cli
    ├── TORAX (core library)
    │   ├── MLX
    │   ├── Numerics
    │   └── AnyCodable
    └── ArgumentParser
```

### Target Configuration

The CLI is implemented as a separate executable target in `Package.swift`:

```swift
.executableTarget(
    name: "torax-cli",
    dependencies: [
        "TORAX",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    ],
    path: "Sources/torax-cli"
)
```

This allows the core TORAX library to remain independent of CLI concerns, enabling:
- Use as a Swift package in other projects
- Separate testing of core vs CLI functionality
- Future support for alternative interfaces (GUI, web API, etc.)

---

## Commands

### Main Command: `torax`

```bash
torax [command] [options]
```

**Subcommands:**
- `run` - Execute a TORAX simulation
- `plot` - Visualize simulation results

**Global Options:**
- `--version` - Display version information
- `--help` - Display help message

---

### `torax run` - Execute Simulation

Run a TORAX simulation with specified configuration.

#### Synopsis

```bash
torax run --config <file> [options]
```

#### Required Arguments

- `--config <path>`
  - Path to configuration file (JSON or TOML)
  - Must contain complete simulation parameters
  - Example: `--config examples/basic_config.json`

#### Output Options

- `--output-dir <path>` (default: `./torax_results`)
  - Directory for output files
  - Created automatically if doesn't exist
  - Absolute or relative path supported

- `--output-format <format>` (default: `json`)
  - Output file format
  - Options: `json`, `hdf5`, `netcdf`
  - Current implementation: JSON only (HDF5/NetCDF planned)

#### Logging Options

- `--log-progress`
  - Enable real-time progress logging
  - Outputs: current time, timestep (dt), iteration count
  - Format: `t=1.2345s, dt=0.001s, iter=12`

- `--log-output`
  - Enable detailed debug logging
  - Logs initial and final state summaries
  - Includes temperature, density, safety factor profiles

#### Plotting Options

- `--plot-config <path>`
  - Path to plot configuration file
  - Defines which quantities to plot and how
  - Used by post-simulation menu

- `--reference-run <path>`
  - Path to reference run output for comparison
  - Enables comparison plotting
  - Must be compatible output format

#### Performance Options

- `--no-compile`
  - Disable MLX JIT compilation
  - Useful for debugging
  - Significantly slower execution
  - Equivalent to `TORAX_COMPILATION_ENABLED=false`

- `--enable-errors`
  - Enable additional error checking
  - Validates intermediate results
  - Performance impact
  - Equivalent to `TORAX_ERRORS_ENABLED=true`

- `--cache-limit <MB>`
  - Set MLX GPU cache limit in megabytes
  - Controls memory usage
  - Example: `--cache-limit 2048` (2GB)

#### Interactive Mode Options

- `--quit`
  - Exit immediately after simulation completes
  - Bypasses interactive menu
  - Useful for batch processing and scripts

#### Examples

**Basic simulation:**
```bash
torax run --config examples/basic_config.json
```

**Production run with logging:**
```bash
torax run \
  --config iter_hybrid_scenario.json \
  --output-dir ~/simulations/iter_001 \
  --log-progress \
  --cache-limit 4096
```

**Debugging mode:**
```bash
torax run \
  --config test_transport.json \
  --no-compile \
  --enable-errors \
  --log-output
```

**Batch processing (non-interactive):**
```bash
torax run \
  --config batch_run.json \
  --output-dir ./batch_results \
  --quit
```

---

### Interactive Menu

After simulation completes (unless `--quit` specified), an interactive menu is presented:

```
╔════════════════════════════════════════════════╗
║           TORAX Interactive Menu               ║
╠════════════════════════════════════════════════╣
║  r   - RUN SIMULATION                          ║
║  mc  - Modify current configuration            ║
║  cc  - Change configuration file               ║
║  tlp - Toggle log progress                     ║
║  tlo - Toggle log output                       ║
║  pr  - Plot results                            ║
║  q   - Quit                                    ║
╚════════════════════════════════════════════════╝

Select option:
```

#### Menu Options

**`r` - RUN SIMULATION**
- Rerun simulation with current configuration
- No recompilation overhead (uses cached compiled function)
- Fast iteration for parameter tuning

**`mc` - Modify current configuration**
- Interactive parameter modification
- Enter parameter path (e.g., `solver.maxIterations`)
- Enter new value
- Reloads configuration

**`cc` - Change configuration file**
- Load entirely new configuration
- Enter path to new config file
- Triggers recompilation if static parameters changed

**`tlp` - Toggle log progress**
- Enable/disable progress logging
- Takes effect on next simulation run

**`tlo` - Toggle log output**
- Enable/disable detailed output logging
- Shows final state summary

**`pr` - Plot results**
- Generate plots of last simulation
- Uses plot configuration if specified
- Compares with reference run if provided

**`q` - Quit**
- Exit the program

#### Benefits of Interactive Menu

1. **No recompilation overhead**: Compiled functions are cached
2. **Rapid iteration**: Quick parameter tuning
3. **Immediate feedback**: Plot results without external tools
4. **Workflow continuity**: Keep working in same session

---

### `torax plot` - Visualize Results

Generate plots from simulation output files.

#### Synopsis

```bash
torax plot <outfile>... [options]
```

#### Arguments

- `<outfile>...`
  - One or two output file paths
  - Single file: Plot time evolution
  - Two files: Comparison plotting
  - Formats: `.json`, `.h5`, `.nc`

#### Options

- `--plot-config <path>`
  - Path to plot configuration file
  - Defines quantities to plot, styles, etc.
  - Default: built-in default configuration

- `--format <format>` (default: `png`)
  - Output image format
  - Options: `png`, `pdf`, `svg`

- `--output-dir <path>` (default: `./plots`)
  - Directory for generated plots
  - Created automatically if doesn't exist

- `--interactive`
  - Launch interactive plot viewer
  - Platform-dependent availability
  - Future enhancement

#### Examples

**Plot single run:**
```bash
torax plot results/state_history_20250117_143022.json
```

**Compare two runs:**
```bash
torax plot baseline.json optimized.json
```

**Custom plot configuration:**
```bash
torax plot results.json \
  --plot-config configs/publication_plots.json \
  --format pdf \
  --output-dir ./figures
```

**Generate SVG for web:**
```bash
torax plot simulation.json \
  --format svg \
  --output-dir ./web/assets
```

---

## Configuration

### Configuration File Format

swift-TORAX supports JSON configuration files with a structured, type-safe format.

#### Example Configuration

```json
{
  "runtime": {
    "static": {
      "mesh": {
        "nCells": 100,
        "rMinor": 0.44,
        "rMajor": 1.65
      },
      "solver": {
        "type": "newton-raphson",
        "maxIterations": 30,
        "tolerance": 1e-6
      },
      "equations": {
        "ionTemperature": true,
        "electronTemperature": true,
        "electronDensity": true,
        "poloidalFlux": true
      }
    },
    "dynamic": {
      "boundaryConditions": {
        "ionTemperature": {
          "type": "dirichlet",
          "value": 1.0
        },
        "electronTemperature": {
          "type": "dirichlet",
          "value": 1.0
        }
      },
      "transportParams": {
        "model": "constant",
        "chiIon": 1.0,
        "chiElectron": 1.0
      }
    }
  },
  "timestepping": {
    "tMax": 5.0,
    "dt": 0.01,
    "adaptiveTimestep": false
  }
}
```

#### Configuration Structure

**Top-level sections:**

1. **`runtime`** - Runtime parameters
   - `static` - Parameters that trigger recompilation when changed
   - `dynamic` - Time-dependent parameters (no recompilation)

2. **`timestepping`** - Time integration settings
   - `tMax` - Maximum simulation time
   - `dt` - Initial timestep
   - `adaptiveTimestep` - Enable adaptive timestepping

3. **`output`** (optional) - Output settings
   - `saveInterval` - Time between saves
   - `quantities` - Which quantities to save

#### Static vs Dynamic Parameters

**Static Parameters** (trigger recompilation):
- Mesh configuration (grid size, geometry type)
- Solver type and settings
- Which equations to evolve
- Numerical methods

**Dynamic Parameters** (no recompilation):
- Boundary conditions
- Source parameters (heating power, particle sources)
- Transport model coefficients
- Time-dependent profiles

This distinction is **critical for MLX `compile()` optimization**:
- Static parameters define the computation graph structure
- Dynamic parameters are inputs to the compiled function
- Changing static parameters requires recompilation
- Changing dynamic parameters uses existing compiled function

### Plot Configuration

Plot configuration defines visualization parameters.

#### Example Plot Configuration

```json
{
  "figures": [
    {
      "name": "temperatures",
      "quantities": ["ionTemperature", "electronTemperature"],
      "ylabel": "Temperature (keV)",
      "xlabel": "Normalized radius",
      "legend": true
    },
    {
      "name": "density",
      "quantities": ["electronDensity"],
      "ylabel": "Density (10^20 m^-3)",
      "xlabel": "Normalized radius"
    }
  ],
  "style": {
    "linewidth": 2,
    "colormap": "viridis",
    "figsize": [12, 8],
    "dpi": 150
  }
}
```

---

## Output Formats

### JSON Format (Current)

**File naming convention:**
```
state_history_YYYYMMDD_HHMMSS.json
```

**Structure:**
```json
{
  "metadata": {
    "version": "0.1.0",
    "timestamp": "2025-01-17T14:30:22Z",
    "configuration": { ... }
  },
  "timepoints": [
    {
      "time": 0.0,
      "state": {
        "ionTemperature": [1.0, 0.95, ...],
        "electronTemperature": [1.0, 0.95, ...],
        "electronDensity": [1.0, 0.98, ...],
        "poloidalFlux": [0.0, 0.01, ...]
      }
    },
    ...
  ],
  "geometry": { ... }
}
```

**Advantages:**
- Human-readable
- Easy to parse with any tool
- Good for debugging
- Universal support

**Disadvantages:**
- Large file size for long simulations
- Slower I/O compared to binary formats

### HDF5 Format (Planned)

**File naming convention:**
```
state_history_YYYYMMDD_HHMMSS.h5
```

**Structure:**
```
/metadata
  ├── version
  ├── timestamp
  └── configuration
/state
  ├── time [n_timepoints]
  ├── ionTemperature [n_timepoints, n_cells]
  ├── electronTemperature [n_timepoints, n_cells]
  ├── electronDensity [n_timepoints, n_cells]
  └── poloidalFlux [n_timepoints, n_cells]
/geometry
  └── ...
```

**Advantages:**
- Compact binary format
- Fast I/O
- Compression support
- Industry standard for scientific data

**Requirements:**
- HDF5 Swift bindings
- External HDF5 library dependency

### NetCDF Format (Planned)

**File naming convention:**
```
state_history_YYYYMMDD_HHMMSS.nc
```

**Advantages:**
- Self-describing format
- CF conventions support
- Wide adoption in plasma physics community
- Excellent tool support (ncview, Panoply)

**Requirements:**
- NetCDF Swift bindings
- External NetCDF library dependency

---

## Environment Variables

swift-TORAX respects environment variables for global configuration.

### MLX Configuration

**`TORAX_COMPILATION_ENABLED`**
- Enable/disable MLX JIT compilation
- Values: `true`, `false`
- Default: `true`
- Override: `--no-compile` flag

```bash
export TORAX_COMPILATION_ENABLED=false
torax run --config test.json  # Runs without compilation
```

**`TORAX_ERRORS_ENABLED`**
- Enable additional error checking
- Values: `true`, `false`
- Default: `false`
- Override: `--enable-errors` flag

```bash
export TORAX_ERRORS_ENABLED=true
torax run --config test.json  # Runs with error checking
```

**`TORAX_GPU_CACHE_LIMIT`**
- MLX GPU cache limit in bytes
- Example: `1073741824` (1GB)
- Override: `--cache-limit` flag (in MB)

```bash
export TORAX_GPU_CACHE_LIMIT=2147483648  # 2GB
```

### Logging Configuration

**`TORAX_LOG_LEVEL`**
- Logging verbosity
- Values: `debug`, `info`, `warning`, `error`
- Default: `info`

```bash
export TORAX_LOG_LEVEL=debug
```

**`TORAX_LOG_FILE`**
- Path to log file
- If unset, logs to stdout only

```bash
export TORAX_LOG_FILE=~/logs/torax.log
```

### Output Configuration

**`TORAX_OUTPUT_DIR`**
- Default output directory
- Override: `--output-dir` flag

```bash
export TORAX_OUTPUT_DIR=~/simulations/results
```

---

## Examples

### Basic Workflow

```bash
# 1. Run simulation
torax run --config examples/basic_config.json --log-progress

# 2. Plot results
torax plot torax_results/state_history_20250117_143022.json

# 3. Compare with reference
torax plot \
  torax_results/state_history_20250117_143022.json \
  reference_data/iter_baseline.json
```

### Parameter Scan

```bash
# Bash script for parameter scan
for chi in 0.5 1.0 1.5 2.0; do
  # Modify config (using jq or similar)
  jq ".runtime.dynamic.transportParams.chiIon = $chi" \
    base_config.json > config_chi_${chi}.json

  # Run simulation
  torax run \
    --config config_chi_${chi}.json \
    --output-dir results/chi_${chi} \
    --quit
done

# Plot all results
torax plot results/chi_*/state_history_*.json
```

### Debugging Workflow

```bash
# 1. Run with full debugging
torax run \
  --config test_model.json \
  --no-compile \
  --enable-errors \
  --log-output \
  --cache-limit 512

# 2. Check logs for issues

# 3. Fix and rerun (with compilation)
torax run \
  --config test_model.json \
  --log-progress
```

### Production Simulation

```bash
# Long ITER simulation with monitoring
torax run \
  --config iter_hybrid_15MA.json \
  --output-dir ~/simulations/iter_hybrid_$(date +%Y%m%d) \
  --log-progress \
  --cache-limit 8192 \
  --quit \
  > simulation.log 2>&1 &

# Monitor progress
tail -f simulation.log

# When complete, plot results
torax plot \
  ~/simulations/iter_hybrid_*/state_history_*.json \
  --plot-config configs/iter_standard_plots.json \
  --format pdf \
  --output-dir ~/simulations/figures
```

---

## Development Guide

### Adding New Commands

1. **Create command file:**

```swift
// Sources/torax-cli/Commands/MyCommand.swift
import ArgumentParser
import TORAX

struct MyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mycommand",
        abstract: "Description of my command"
    )

    @Option(name: .long, help: "An option")
    var myOption: String

    mutating func run() async throws {
        // Implementation
    }
}
```

2. **Register in main.swift:**

```swift
@main
struct ToraxCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "torax",
        subcommands: [
            RunCommand.self,
            PlotCommand.self,
            MyCommand.self  // Add here
        ]
    )
}
```

### Adding New Options

```swift
// Flag (boolean)
@Flag(name: .long, help: "Enable feature")
var enableFeature: Bool = false

// Option with default
@Option(name: .long, help: "Set value")
var value: Int = 42

// Option with custom parsing
@Option(name: .long, help: "Output format")
var format: OutputFormat = .json

enum OutputFormat: String, ExpressibleByArgument {
    case json, hdf5, netcdf
}
```

### Adding New Output Formats

1. **Extend OutputFormat enum:**

```swift
enum OutputFormat: String, ExpressibleByArgument {
    case json
    case hdf5
    case netcdf
    case myformat  // Add here

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .hdf5: return "h5"
        case .netcdf: return "nc"
        case .myformat: return "myext"
        }
    }
}
```

2. **Implement writer:**

```swift
extension OutputWriter {
    private func writeMyFormat(
        _ results: SimulationResults,
        to url: URL
    ) throws {
        // Implementation
    }
}
```

### Testing CLI Commands

```swift
// Tests/torax-cliTests/RunCommandTests.swift
import XCTest
import ArgumentParser
@testable import torax_cli

final class RunCommandTests: XCTestCase {
    func testBasicRun() async throws {
        var command = try RunCommand.parse([
            "--config", "test_config.json",
            "--quit"
        ])

        try await command.run()

        // Verify output exists
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "torax_results/state_history.json"
        ))
    }
}
```

### Building and Installation

**Development:**
```bash
# Build
swift build

# Run
.build/debug/torax-cli run --config test.json
```

**Release:**
```bash
# Build optimized binary
swift build -c release

# Binary location
.build/release/torax-cli
```

**Installation:**
```bash
# Install to /usr/local/bin
swift build -c release
sudo cp .build/release/torax-cli /usr/local/bin/torax

# Or use Swift Package Manager
swift package experimental-install -c release
```

---

## Future Enhancements

### Short-term (v0.2)
- [ ] HDF5 output format
- [ ] TOML configuration support
- [ ] Enhanced plot customization
- [ ] Parameter validation at CLI level
- [ ] Shell completion scripts (bash, zsh, fish)

### Medium-term (v0.3)
- [ ] NetCDF output format
- [ ] Interactive plot viewer
- [ ] Configuration templates
- [ ] Checkpoint/restart functionality
- [ ] Distributed execution support

### Long-term (v1.0)
- [ ] Web-based UI
- [ ] Real-time monitoring dashboard
- [ ] Parameter optimization tools
- [ ] Integrated sensitivity analysis
- [ ] Cloud deployment support

---

## References

- [Original TORAX CLI](https://deepwiki.com/google-deepmind/torax#5.1)
- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
- [MLX-Swift](https://github.com/ml-explore/mlx-swift)
- [Swift Package Manager](https://swift.org/package-manager/)
