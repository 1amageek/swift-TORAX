// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-TORAX",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "TORAX",
            targets: ["TORAX"]
        ),
        .library(
            name: "TORAXPhysics",
            targets: ["TORAXPhysics"]
        ),
        .executable(
            name: "TORAXCLI",
            targets: ["TORAXCLI"]
        ),
    ],
    dependencies: [
        // MLX-Swift: Array framework for machine learning on Apple Silicon
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),

        // Swift Configuration: Configuration management
        .package(url: "https://github.com/apple/swift-configuration", from: "0.1.1"),

        // Swift Numerics: Numerical computing (special functions, complex numbers, high-precision arithmetic)
        .package(url: "https://github.com/apple/swift-numerics", from: "1.1.1"),

        // Swift Argument Parser: Type-safe command-line argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),

        // SwiftNetCDF: NetCDF file format support for scientific data output
        .package(url: "https://github.com/patrick-zippenfenig/SwiftNetCDF.git", from: "1.2.0"),

        // FusionSurrogates: QLKNN neural network transport model (macOS only)
        .package(url: "https://github.com/1amageek/swift-fusion-surrogates.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "TORAX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXLinalg", package: "mlx-swift"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Numerics", package: "swift-numerics"),
                // FusionSurrogates: Conditional dependency (macOS only)
                .product(
                    name: "FusionSurrogates",
                    package: "swift-fusion-surrogates",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),

        // Physics models target (depends on TORAX core)
        .target(
            name: "TORAXPhysics",
            dependencies: [
                "TORAX",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),

        // CLI executable target
        .executableTarget(
            name: "TORAXCLI",
            dependencies: [
                "TORAX",
                "TORAXPhysics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftNetCDF", package: "SwiftNetCDF"),
            ]
        ),

        .testTarget(
            name: "TORAXTests",
            dependencies: [
                "TORAX",
                "TORAXPhysics",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "ConfigurationTesting", package: "swift-configuration"),
            ]
        ),
        .testTarget(
            name: "TORAXPhysicsTests",
            dependencies: [
                "TORAX",
                "TORAXPhysics",
            ]
        ),
        .testTarget(
            name: "TORAXCLITests",
            dependencies: [
                "TORAXCLI",
            ]
        ),
    ]
)
