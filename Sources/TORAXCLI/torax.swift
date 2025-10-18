// swift-TORAX Command-Line Interface
// Entry point for the TORAX CLI

import ArgumentParser
import Foundation

@main
struct ToraxCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "torax",
        abstract: "TORAX - Tokamak core transport simulator for Swift",
        discussion: """
            swift-TORAX is a Swift implementation of Google DeepMind's TORAX,
            a differentiable tokamak core transport simulator optimized for Apple Silicon.

            For detailed documentation, see:
            https://github.com/yourusername/swift-TORAX
            """,
        version: "0.1.0",
        subcommands: [
            RunCommand.self,
            PlotCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}
