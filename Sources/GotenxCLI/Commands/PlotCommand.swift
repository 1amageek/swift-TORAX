// PlotCommand.swift
// Command for plotting Gotenx simulation results

import ArgumentParser
import Foundation

struct PlotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plot",
        abstract: "Plot Gotenx simulation results",
        discussion: """
            Visualize simulation results from one or two output files.

            Single file plotting shows time evolution of plasma parameters.
            Two file plotting generates comparison plots between runs.

            Example:
              torax plot output/state_history_20250117_143022.json
              torax plot baseline.json optimized.json --format pdf
            """
    )

    // MARK: - Arguments

    @Argument(
        help: "Path(s) to output file(s) (.json, .h5, .nc). Max 2 files for comparison."
    )
    var outfiles: [String]

    // MARK: - Options

    @Option(
        name: .long,
        help: "Path to plot configuration file (JSON)"
    )
    var plotConfig: String?

    @Option(
        name: .long,
        help: "Output format for plots (png, pdf, svg)"
    )
    var format: PlotFormat = .png

    @Option(
        name: .long,
        help: "Output directory for plots"
    )
    var outputDir: String = "./plots"

    @Option(
        name: .long,
        help: "Figure width in inches"
    )
    var width: Double = 12

    @Option(
        name: .long,
        help: "Figure height in inches"
    )
    var height: Double = 8

    @Option(
        name: .long,
        help: "DPI for raster outputs (png)"
    )
    var dpi: Int = 150

    @Flag(
        name: .long,
        help: "Show interactive plots (if available)"
    )
    var interactive: Bool = false

    @Flag(
        name: .long,
        help: "Verbose output"
    )
    var verbose: Bool = false

    // MARK: - Execution

    mutating func run() async throws {
        // Validate inputs
        guard !outfiles.isEmpty else {
            throw PlotError.noInputFiles
        }

        guard outfiles.count <= 2 else {
            throw PlotError.tooManyFiles
        }

        printBanner()

        // Verify input files exist
        for file in outfiles {
            guard FileManager.default.fileExists(atPath: file) else {
                throw PlotError.fileNotFound(file)
            }
        }

        // Create output directory
        try createOutputDirectory()

        // Load plot configuration
        let config = try loadPlotConfiguration()

        // Generate plots
        if outfiles.count == 1 {
            try await plotSingleRun(outfiles[0], config: config)
        } else {
            try await plotComparison(outfiles[0], outfiles[1], config: config)
        }

        print("\n✅ Plots saved to: \(outputDir)")

        if interactive {
            print("⚠️  Interactive plotting not yet implemented")
        }
    }

    // MARK: - Helper Methods

    private func printBanner() {
        print("""
        ═══════════════════════════════════════════════════
        Gotenx Plot Generator
        ═══════════════════════════════════════════════════
        """)
    }

    private func createOutputDirectory() throws {
        let url = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        if verbose {
            print("Output directory: \(outputDir)")
        }
    }

    private func loadPlotConfiguration() throws -> PlotConfiguration {
        if let configPath = plotConfig {
            if verbose {
                print("Loading plot configuration: \(configPath)")
            }

            guard FileManager.default.fileExists(atPath: configPath) else {
                throw PlotError.configNotFound(configPath)
            }

            // TODO: Load and parse plot configuration
            print("⚠️  Custom plot configuration not yet implemented")
            return PlotConfiguration.default
        } else {
            if verbose {
                print("Using default plot configuration")
            }
            return PlotConfiguration.default
        }
    }

    private func plotSingleRun(_ filepath: String, config: PlotConfiguration) async throws {
        print("\n📊 Generating plots for: \(filepath)")

        // TODO: Implement plotting with unit conversion
        // IMPORTANT: Apply DisplayUnits conversion before plotting:
        //   - Temperature: DisplayUnits.toKeV(dataInEv)
        //   - Density: DisplayUnits.to1e20m3(dataInM3)
        print("""

        ⚠️  Plotting not yet implemented

        Would generate the following plots:
          • Temperature profiles (Ti, Te) vs time [keV - converted from eV]
          • Density profile (ne) vs time [10^20 m^-3 - converted from m^-3]
          • Safety factor (q) and magnetic shear (s)
          • Radial profiles at selected timepoints
          • Time evolution at selected radial positions

        Output format: \(format.rawValue)
        Figure size: \(width) x \(height) inches
        DPI: \(dpi)

        Note: Internal data is in eV/m^-3, will be converted to keV/10^20 m^-3 for display
        """)
    }

    private func plotComparison(
        _ file1: String,
        _ file2: String,
        config: PlotConfiguration
    ) async throws {
        print("\n📊 Generating comparison plots")
        print("  Baseline: \(file1)")
        print("  Comparison: \(file2)")

        // TODO: Implement comparison plotting
        print("""

        ⚠️  Comparison plotting not yet implemented

        Would generate the following comparison plots:
          • Side-by-side temperature profiles
          • Difference plots (run2 - run1)
          • Relative difference plots ((run2 - run1) / run1)
          • Time evolution comparison
          • Performance metrics comparison

        Output format: \(format.rawValue)
        Figure size: \(width) x \(height) inches
        DPI: \(dpi)
        """)
    }
}

// MARK: - Supporting Types

/// Plot output format
enum PlotFormat: String, ExpressibleByArgument {
    case png
    case pdf
    case svg

    var fileExtension: String { rawValue }

    var description: String {
        switch self {
        case .png:
            return "PNG (Portable Network Graphics) - raster"
        case .pdf:
            return "PDF (Portable Document Format) - vector"
        case .svg:
            return "SVG (Scalable Vector Graphics) - vector"
        }
    }
}

/// Plot configuration
struct PlotConfiguration {
    let figures: [FigureSpec]
    let style: PlotStyle

    static let `default` = PlotConfiguration(
        figures: [
            FigureSpec(
                name: "temperatures",
                quantities: ["ionTemperature", "electronTemperature"],
                ylabel: "Temperature (keV)",  // Display units (converted from internal eV)
                xlabel: "Normalized radius"
            ),
            FigureSpec(
                name: "density",
                quantities: ["electronDensity"],
                ylabel: "Density (10^20 m^-3)",  // Display units (converted from internal m^-3)
                xlabel: "Normalized radius"
            ),
            FigureSpec(
                name: "safety_factor",
                quantities: ["safetyFactor", "magneticShear"],
                ylabel: "q / s",
                xlabel: "Normalized radius"
            )
        ],
        style: PlotStyle.default
    )
}

/// Figure specification
struct FigureSpec {
    let name: String
    let quantities: [String]
    let ylabel: String
    let xlabel: String
}

/// Plot style configuration
struct PlotStyle {
    let linewidth: Double
    let colormap: String
    let figsize: (width: Double, height: Double)
    let dpi: Int

    static let `default` = PlotStyle(
        linewidth: 2.0,
        colormap: "viridis",
        figsize: (width: 12, height: 8),
        dpi: 150
    )
}

/// Plot errors
enum PlotError: LocalizedError {
    case noInputFiles
    case tooManyFiles
    case fileNotFound(String)
    case configNotFound(String)
    case unsupportedFormat(String)
    case plottingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input files specified. Provide at least one output file to plot."
        case .tooManyFiles:
            return "Too many input files. Maximum 2 files can be compared."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .configNotFound(let path):
            return "Plot configuration file not found: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format)"
        case .plottingFailed(let message):
            return "Plotting failed: \(message)"
        }
    }
}
