// swift-Gotenx Command-Line Interface
// Entry point for the Gotenx CLI

import ArgumentParser
import Foundation

@main
struct GotenxCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gotenx",
        abstract: "Gotenx - Tokamak core transport simulator for Swift",
        discussion: """
            swift-Gotenx is a Swift implementation of Google DeepMind's TORAX,
            a differentiable tokamak core transport simulator optimized for Apple Silicon.

            For detailed documentation, see:
            https://github.com/yourusername/swift-Gotenx
            """,
        version: "0.1.0",
        subcommands: [
            RunCommand.self,
            PlotCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}
