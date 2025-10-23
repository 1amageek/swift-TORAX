// InteractiveMenu.swift
// Interactive post-simulation menu for Gotenx

import Foundation
import GotenxCore
import GotenxPhysics

/// Interactive menu for post-simulation actions
struct InteractiveMenu {
    let logger: ProgressLogger
    let plotConfig: String?
    let referenceRun: String?

    private var currentConfig: SimulationConfiguration
    private var currentConfigPath: String?
    private var logProgress: Bool
    private var logOutput: Bool
    private var lastResult: SimulationResult?

    init(
        logger: ProgressLogger,
        plotConfig: String?,
        referenceRun: String?,
        config: SimulationConfiguration,
        configPath: String?,
        lastResult: SimulationResult?
    ) {
        self.logger = logger
        self.plotConfig = plotConfig
        self.referenceRun = referenceRun
        self.currentConfig = config
        self.currentConfigPath = configPath
        self.logProgress = logger.logProgress
        self.logOutput = logger.logOutput
        self.lastResult = lastResult
    }

    /// Run the interactive menu loop
    mutating func run() async throws {
        print("""

        ═══════════════════════════════════════════════════
        Interactive Menu
        ═══════════════════════════════════════════════════
        """)

        while true {
            printMenu()

            guard let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
                continue
            }

            do {
                let shouldQuit = try await handleCommand(input)
                if shouldQuit {
                    return
                }
            } catch {
                print("❌ Error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu Display

    private func printMenu() {
        print("""

        ╔════════════════════════════════════════════════╗
        ║           Gotenx Interactive Menu               ║
        ╠════════════════════════════════════════════════╣
        ║  r   - RUN SIMULATION                          ║
        ║  mc  - Modify current configuration            ║
        ║  cc  - Change configuration file               ║
        ║  tlp - Toggle log progress [\(logProgress ? "ON " : "OFF")]             ║
        ║  tlo - Toggle log output [\(logOutput ? "ON " : "OFF")]               ║
        ║  pr  - Plot results                            ║
        ║  q   - Quit                                    ║
        ╚════════════════════════════════════════════════╝

        Select option:
        """, terminator: " ")
    }

    // MARK: - Command Handling

    private mutating func handleCommand(_ input: String) async throws -> Bool {
        switch input {
        case "r":
            try await rerunSimulation()
            return false

        case "mc":
            try await modifyConfiguration()
            return false

        case "cc":
            try await changeConfiguration()
            return false

        case "tlp":
            logProgress.toggle()
            print("Log progress: \(logProgress ? "enabled" : "disabled")")
            return false

        case "tlo":
            logOutput.toggle()
            print("Log output: \(logOutput ? "enabled" : "disabled")")
            return false

        case "pr":
            try await plotResults()
            return false

        case "q", "quit", "exit":
            print("\n👋 Exiting Gotenx. Goodbye!")
            return true

        case "h", "help", "?":
            // Help is implicit from menu
            return false

        default:
            print("❌ Unknown command: '\(input)'. Type 'h' for help or 'q' to quit.")
            return false
        }
    }

    // MARK: - Command Implementations

    private mutating func rerunSimulation() async throws {
        print("\n🔄 Rerunning simulation...")
        print("═══════════════════════════════════════════════════")

        // Initialize physics models
        print("🔧 Initializing physics models...")
        let transportModel = try TransportModelFactory.create(config: currentConfig.runtime.dynamic.transport)
        let sourceModel = try SourceModelFactory.create(config: currentConfig.runtime.dynamic.sources)

        // Initialize simulation runner
        let runner = SimulationRunner(config: currentConfig)
        try await runner.initialize(
            transportModel: transportModel,
            sourceModels: [sourceModel]
        )

        // Run simulation
        print("⏱️  Running simulation...")
        let result = try await runner.run(
            progressCallback: logProgress ? makeProgressCallback() : nil
        )

        // Store result
        lastResult = result

        // Display results
        print("\n📊 Simulation Results:")
        print("  Total steps: \(result.statistics.totalSteps)")
        print("  Total iterations: \(result.statistics.totalIterations)")
        print("  Wall time: \(String(format: "%.2f", result.statistics.wallTime))s")
        print("  Converged: \(result.statistics.converged ? "Yes" : "No")")

        // Save results
        print("\n💾 Saving results...")
        try await saveResults(result, config: currentConfig)
        print("  ✓ Results saved to: \(currentConfig.output.directory)")
    }

    private mutating func modifyConfiguration() async throws {
        print("\n⚙️  Modify Configuration")
        print("═══════════════════════════════════════════════════")
        print("Available parameters:")
        print("  1. mesh.nCells - Number of radial grid cells")
        print("  2. mesh.majorRadius - Major radius (m)")
        print("  3. mesh.minorRadius - Minor radius (m)")
        print("  4. time.end - Simulation end time (s)")
        print("  5. time.initialDt - Initial timestep (s)")
        print("  6. boundaries.ionTemperature - Ion temperature boundary (eV)")
        print("  7. boundaries.electronTemperature - Electron temperature boundary (eV)")
        print("  8. boundaries.electronDensity - Electron density boundary (m^-3)")
        print()

        print("Enter parameter number (1-8) or 'c' to cancel: ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
            print("❌ Invalid input")
            return
        }

        if input.lowercased() == "c" {
            print("Cancelled")
            return
        }

        guard let paramNum = Int(input), (1...8).contains(paramNum) else {
            print("❌ Invalid parameter number")
            return
        }

        print("Enter new value: ", terminator: "")
        guard let valueStr = readLine()?.trimmingCharacters(in: .whitespaces), !valueStr.isEmpty else {
            print("❌ Invalid value")
            return
        }

        // Apply modification
        var builder = SimulationConfiguration.Builder()
        builder.runtime.static.mesh = currentConfig.runtime.static.mesh.toBuilder()
        builder.runtime.static.evolution = currentConfig.runtime.static.evolution
        builder.runtime.static.solver = currentConfig.runtime.static.solver
        builder.runtime.static.scheme = currentConfig.runtime.static.scheme
        builder.runtime.dynamic.boundaries = currentConfig.runtime.dynamic.boundaries
        builder.runtime.dynamic.transport = currentConfig.runtime.dynamic.transport
        builder.runtime.dynamic.sources = currentConfig.runtime.dynamic.sources
        builder.runtime.dynamic.pedestal = currentConfig.runtime.dynamic.pedestal
        builder.runtime.dynamic.mhd = currentConfig.runtime.dynamic.mhd
        builder.runtime.dynamic.restart = currentConfig.runtime.dynamic.restart

        // Convert time and output configs to builders
        builder.time.start = currentConfig.time.start
        builder.time.end = currentConfig.time.end
        builder.time.initialDt = currentConfig.time.initialDt
        builder.time.adaptive = currentConfig.time.adaptive

        builder.output.saveInterval = currentConfig.output.saveInterval
        builder.output.directory = currentConfig.output.directory
        builder.output.format = currentConfig.output.format

        var needsRecompilation = false

        switch paramNum {
        case 1:
            guard let value = Int(valueStr) else {
                print("❌ Invalid integer value")
                return
            }
            builder.runtime.static.mesh.nCells = value
            needsRecompilation = true
        case 2:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            builder.runtime.static.mesh.majorRadius = value
        case 3:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            builder.runtime.static.mesh.minorRadius = value
        case 4:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            builder.time.end = value
        case 5:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            builder.time.initialDt = value
        case 6:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            // BoundaryConfig is immutable, create new instance
            builder.runtime.dynamic.boundaries = BoundaryConfig(
                ionTemperature: value,
                electronTemperature: currentConfig.runtime.dynamic.boundaries.electronTemperature,
                density: currentConfig.runtime.dynamic.boundaries.density
            )
        case 7:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            // BoundaryConfig is immutable, create new instance
            builder.runtime.dynamic.boundaries = BoundaryConfig(
                ionTemperature: currentConfig.runtime.dynamic.boundaries.ionTemperature,
                electronTemperature: value,
                density: currentConfig.runtime.dynamic.boundaries.density
            )
        case 8:
            guard let value = Float(valueStr) else {
                print("❌ Invalid float value")
                return
            }
            // BoundaryConfig is immutable, create new instance
            builder.runtime.dynamic.boundaries = BoundaryConfig(
                ionTemperature: currentConfig.runtime.dynamic.boundaries.ionTemperature,
                electronTemperature: currentConfig.runtime.dynamic.boundaries.electronTemperature,
                density: value
            )
        default:
            print("❌ Invalid parameter number")
            return
        }

        currentConfig = builder.build()
        try ConfigurationValidator.validate(currentConfig)

        print("✓ Configuration updated")
        if needsRecompilation {
            print("⚠️  Static parameter changed - next run will trigger recompilation")
        }
    }

    private mutating func changeConfiguration() async throws {
        print("\n📁 Change Configuration File")
        print("═══════════════════════════════════════════════════")

        print("Enter path to new configuration file: ", terminator: "")
        guard let path = readLine()?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            print("❌ Invalid path")
            return
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌ File not found: \(path)")
            return
        }

        // Load new configuration
        print("📋 Loading configuration...")
        do {
            let newConfig = try await ConfigurationLoader.loadFromJSON(path)
            currentConfig = newConfig
            currentConfigPath = path

            print("✓ Configuration loaded successfully")
            print("  Mesh cells: \(newConfig.runtime.static.mesh.nCells)")
            print("  Major radius: \(newConfig.runtime.static.mesh.majorRadius) m")
            print("  Time range: [\(newConfig.time.start), \(newConfig.time.end)] s")
            print("\n⚠️  Static parameters changed - next run will trigger recompilation")
        } catch {
            print("❌ Failed to load configuration: \(error.localizedDescription)")
        }
    }

    private func plotResults() async throws {
        print("\n📊 Plot Results")
        print("═══════════════════════════════════════════════════")

        guard lastResult != nil else {
            print("❌ No simulation results available. Run a simulation first (command 'r').")
            return
        }

        if let referencePath = referenceRun {
            print("Comparing with reference: \(referencePath)")
        }

        if let configPath = plotConfig {
            print("Using plot configuration: \(configPath)")
        } else {
            print("Using default plot configuration")
        }

        print("\n⚠️  Plotting not yet implemented (GotenxUI in development)")
        print("This would generate plots of:")
        print("  • Temperature profiles (Ti, Te)")
        print("  • Density profiles (ne)")
        print("  • Safety factor (q) and magnetic shear (s)")
        print("  • Time evolution")

        if referenceRun != nil {
            print("  • Comparison with reference run")
        }
    }

    // MARK: - Helper Methods

    private func makeProgressCallback() -> @Sendable (Float, ProgressInfo) -> Void {
        return { fraction, progress in
            let percentage = Int(fraction * 100)
            print("  Progress: \(percentage)% | Time: \(String(format: "%.6f", progress.currentTime))s | dt: \(String(format: "%.8f", progress.lastDt))s")
        }
    }

    private func saveResults(_ result: SimulationResult, config: SimulationConfiguration) async throws {
        let directory = config.output.directory

        // Convert Gotenx.OutputFormat to CLI OutputFormat
        let cliFormat: OutputFormat
        switch config.output.format {
        case .json:
            cliFormat = .json
        case .hdf5:
            cliFormat = .hdf5
        case .netcdf:
            cliFormat = .netcdf
        }

        // Generate filename with timestamp
        let filename = OutputFileNaming.generateFilename(
            prefix: "state_history",
            format: cliFormat
        )
        let filepath = (directory as NSString).appendingPathComponent(filename)

        // Write results
        let writer = OutputWriter(format: cliFormat)
        try writer.write(result, to: URL(fileURLWithPath: filepath))
    }
}

// MARK: - Menu Utilities

/// Utility functions for menu interaction
extension InteractiveMenu {
    /// Read a yes/no confirmation
    private func readConfirmation(_ prompt: String) -> Bool {
        print("\(prompt) [y/N]: ", terminator: "")
        guard let input = readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return false
        }
        return input == "y" || input == "yes"
    }

    /// Read a numeric value
    private func readNumeric<T: LosslessStringConvertible>(_ prompt: String) -> T? {
        print("\(prompt): ", terminator: "")
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return T(input)
    }

    /// Read a string value
    private func readString(_ prompt: String) -> String? {
        print("\(prompt): ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }
}
