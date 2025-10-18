// InteractiveMenu.swift
// Interactive post-simulation menu for TORAX

import Foundation

/// Interactive menu for post-simulation actions
struct InteractiveMenu {
    let logger: ProgressLogger
    let plotConfig: String?
    let referenceRun: String?

    private var logProgress: Bool
    private var logOutput: Bool

    init(logger: ProgressLogger, plotConfig: String?, referenceRun: String?) {
        self.logger = logger
        self.plotConfig = plotConfig
        self.referenceRun = referenceRun
        self.logProgress = logger.logProgress
        self.logOutput = logger.logOutput
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
        ║           TORAX Interactive Menu               ║
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
            print("\n👋 Exiting TORAX. Goodbye!")
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

    private func rerunSimulation() async throws {
        print("\n🔄 Rerunning simulation...")
        print("⚠️  Simulation execution not yet implemented")
        print("This would rerun with current configuration (no recompilation needed)")
    }

    private func modifyConfiguration() async throws {
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

        print("\n⚠️  Configuration modification not yet implemented")
        print("Would set: \(path) = \(valueStr)")
        print("\nNote: Modifying static parameters will trigger recompilation")
        print("      Modifying dynamic parameters uses existing compiled code")
    }

    private func changeConfiguration() async throws {
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

        print("\n⚠️  Configuration loading not yet implemented")
        print("Would load configuration from: \(path)")
        print("This will trigger recompilation if static parameters changed")
    }

    private func plotResults() async throws {
        print("\n📊 Plot Results")
        print("═══════════════════════════════════════════════════")

        if let referencePath = referenceRun {
            print("Comparing with reference: \(referencePath)")
        }

        if let configPath = plotConfig {
            print("Using plot configuration: \(configPath)")
        } else {
            print("Using default plot configuration")
        }

        print("\n⚠️  Plotting not yet implemented")
        print("This would generate plots of:")
        print("  • Temperature profiles (Ti, Te)")
        print("  • Density profiles (ne)")
        print("  • Safety factor (q) and magnetic shear (s)")
        print("  • Time evolution")

        if referenceRun != nil {
            print("  • Comparison with reference run")
        }
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
