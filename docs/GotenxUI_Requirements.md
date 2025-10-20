# GotenxUI Requirements & Design Specification

**Version**: 0.1.0
**Date**: 2025-01-20
**Status**: Design Phase
**Target Platforms**: macOS 13+, iOS 16+, visionOS 2+

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [2D Plotting Capabilities](#2d-plotting-capabilities)
4. [3D Plotting Capabilities](#3d-plotting-capabilities)
5. [Data Model](#data-model)
6. [Configuration System](#configuration-system)
7. [User Interface Components](#user-interface-components)
8. [Implementation Plan](#implementation-plan)
9. [API Reference](#api-reference)
10. [Performance & Optimization](#performance--optimization)

---

## Overview

### Purpose

GotenxUI is a Swift Charts-based visualization library for TORAX tokamak plasma simulation data, providing native macOS/iOS/visionOS plotting capabilities with both 2D and 3D visualization modes.

### Goals

- **Native Performance**: Leverage Swift Charts for GPU-accelerated rendering
- **Type Safety**: Full Swift 6 concurrency support
- **Multi-dimensional**: Support both 2D profiles and 3D volumetric visualization
- **Platform Adaptive**: Automatically use best visualization for each platform
- **Modularity**: Reusable components for custom visualizations
- **TORAX Compatibility**: Match original matplotlib functionality

### Platform Support Matrix

**CRITICAL UPDATE**: Swift Charts 3D requires iOS 26.0+, macOS 26.0+, visionOS 26.0+ (future releases)

| Platform | 2D Charts | 3D Charts | Minimum Version |
|----------|-----------|-----------|-----------------|
| macOS | ✅ | ⏳ (iOS 26.0+) | 13.0 / 26.0 |
| iOS | ✅ | ⏳ (iOS 26.0+) | 16.0 / 26.0 |
| visionOS | ✅ | ⏳ (visionOS 26.0+) | 2.0 / 26.0 |
| iPadOS | ✅ | ⏳ (iPadOS 26.0+) | 16.0 / 26.0 |

**Note**: Chart3D is available in future OS releases (iOS 26.0+). Current implementation focuses on 2D charts.

---

## Architecture

### Module Structure

```
GotenxUI/
├── Models/
│   ├── PlotData.swift                    # Simulation data container
│   ├── PlotData3D.swift                  # 3D volumetric data
│   ├── PlotConfiguration.swift           # Plot settings
│   ├── PlotType.swift                    # Spatial/TimeSeries/Volumetric
│   └── DisplayMode.swift                 # 2D/3D mode selection
│
├── Views/
│   ├── 2D/
│   │   ├── ToraxPlotView.swift           # Main 2D plot view
│   │   ├── SpatialPlotView.swift         # Spatial profile charts
│   │   ├── TimeSeriesPlotView.swift      # Time series charts
│   │   └── TimeSliderView.swift          # Interactive slider
│   │
│   ├── 3D/
│   │   ├── ToraxPlot3DView.swift         # Main 3D plot view
│   │   ├── VolumetricPlotView.swift      # 3D surface/volume rendering
│   │   ├── IsosurfaceView.swift          # Temperature isosurfaces
│   │   └── Camera3DController.swift      # Camera manipulation
│   │
│   └── Hybrid/
│       ├── AdaptivePlotView.swift        # Platform-adaptive view
│       └── SplitView2D3D.swift           # Side-by-side comparison
│
├── Configurations/
│   ├── DefaultPlotConfig.swift           # 4×4 grid (2D)
│   ├── SimplePlotConfig.swift            # 2×2 grid (2D)
│   ├── SourcesPlotConfig.swift           # 3×2 grid (2D)
│   └── Volumetric3DConfig.swift          # 3D visualization setups
│
└── Utilities/
    ├── DataTransform.swift               # Unit conversions
    ├── ColorScheme.swift                 # Color palettes
    ├── InterpolationEngine.swift         # 3D data interpolation
    └── SurfaceGenerator.swift            # Mesh generation for 3D
```

### Dependencies

```swift
// Package.swift
dependencies: [
    .target(name: "TORAX"),               // Core simulation data
]

// Conditional imports
#if canImport(Charts)
import Charts                              // 2D plotting (macOS 13+)
#endif

#if canImport(RealityKit)
import RealityKit                          // 3D rendering fallback
#endif

import SwiftUI                             // UI framework
```

---

## 2D Plotting Capabilities

### Plot Types

#### 1. Spatial Profile Plots

**Definition**: 1D profiles of physical quantities vs. normalized radius ρ

**Implementation**:
```swift
Chart {
    ForEach(data.rhoIndices, id: \.self) { i in
        LineMark(
            x: .value("ρ", data.rho[i]),
            y: .value("Temperature", data.Ti[timeIndex][i])
        )
        .foregroundStyle(by: .value("Species", "Ti"))
        .interpolationMethod(.catmullRom)
        .symbol(.circle)
    }
}
.chartXAxisLabel("Normalized radius ρ")
.chartYAxisLabel("Temperature [keV]")
```

**Features**:
- Catmull-Rom interpolation for smooth curves
- Multiple lines on same plot (Ti, Te, etc.)
- Dynamic update via time slider
- Percentile-based y-axis limits
- Zero value suppression

#### 2. Time Series Plots

**Definition**: 0D scalar evolution over simulation time

**Implementation**:
```swift
Chart {
    ForEach(data.timeIndices, id: \.self) { t in
        LineMark(
            x: .value("Time", data.time[t]),
            y: .value("Q_fusion", data.qFusion[t])
        )
        .foregroundStyle(.red)
    }
}
.chartXAxisLabel("Time [s]")
.chartYAxisLabel("Fusion gain")
```

**Features**:
- Linear interpolation
- Static display (no slider update)
- Multiple time series on same axes
- Logarithmic y-axis option

### Supported Variables (30+)

| Category | Variables | Units | Plot Type |
|----------|-----------|-------|-----------|
| **Temperature** | Ti, Te | keV | Spatial |
| **Density** | ne, ni | 10²⁰ m⁻³ | Spatial |
| **Current Density** | j_total, j_ohmic, j_bootstrap, j_ECRH | MA/m² | Spatial |
| **Magnetic** | q, s (shear), ψ | -, -, Wb | Spatial |
| **Transport** | χ_i, χ_e, χ_turb_i, χ_turb_e, D | m²/s | Spatial |
| **Sources** | Q_ohmic, Q_fusion, P_ICRH, P_ECRH | MW/m³ | Spatial |
| **Currents** | Ip, I_bootstrap, I_ECRH | MA | Time Series |
| **Powers** | P_aux, P_ohmic, P_alpha, P_rad | MW | Time Series |
| **Metrics** | Q_fusion (gain), W_thermal | -, MJ | Time Series |

---

## 3D Plotting Capabilities

### Overview

GotenxUI leverages Swift Charts 3D (visionOS 2.0+) and RealityKit for immersive 3D visualization of plasma profiles.

### 3D Chart Types

#### 1. Volumetric Temperature Distribution

**Purpose**: Visualize 3D temperature field T(ρ, θ, z) in cylindrical tokamak geometry

**Implementation**:
```swift
#if canImport(Charts) && os(visionOS)
import Charts

Chart3D(data.volumetricPoints) { point in
    PointMark3D(
        x: .value("R", point.majorRadius),
        y: .value("Z", point.height),
        z: .value("φ", point.toroidalAngle)
    )
    .foregroundStyle(by: .value("Temperature", point.temperature))
    .symbolSize(50)
    .opacity(0.7)
}
.chart3DPose(
    rotation: .init(angle: .degrees(45), axis: (x: 0, y: 1, z: 0)),
    elevation: .degrees(30),
    distance: 5.0
)
.chart3DCameraProjection(.perspective(fieldOfView: .degrees(60)))
#endif
```

**Features**:
- **Point Cloud**: Scatter plot with color-coded temperature
- **Surface Mesh**: Triangulated surface at flux surface
- **Volume Rendering**: Opacity-based volume visualization
- **Camera Control**: Orbit, pan, zoom gestures

#### 2. Isosurface Rendering

**Purpose**: Display constant-value surfaces (isotherms, isodensity)

**Swift Charts 3D**:
```swift
Chart3D {
    SurfaceMark3D(
        x: .value("R", surfacePoints.map { $0.r }),
        y: .value("Z", surfacePoints.map { $0.z }),
        z: .value("φ", surfacePoints.map { $0.phi }),
        style: .init(
            material: .diffuse,
            color: .blue,
            opacity: 0.6
        )
    )
}
.chart3DSurfaceStyle(.smooth)
```

**Isosurface Levels**:
- Temperature: 1, 5, 10, 15 keV contours
- Density: 1, 3, 5, 7 × 10²⁰ m⁻³ contours
- Safety factor: q = 1, 2, 3 surfaces

#### 3. Magnetic Field Lines

**Purpose**: Trace field lines through 3D space

**Implementation**:
```swift
Chart3D {
    ForEach(fieldLines) { line in
        LineMark3D(
            x: .value("R", line.points.map { $0.r }),
            y: .value("Z", line.points.map { $0.z }),
            z: .value("φ", line.points.map { $0.phi })
        )
        .lineStyle(.init(lineWidth: 2))
        .foregroundStyle(.yellow)
    }
}
```

#### 4. Current Density Streamlines

**Purpose**: Visualize current flow patterns in 3D

**Features**:
- Arrow glyphs along streamlines
- Color-coded by magnitude
- Animated flow (optional)

### 3D Camera System

#### Chart3DCameraProjection

**Available in iOS 26.0+, macOS 26.0+, visionOS 26.0+**

```swift
struct Chart3DCameraProjection: Equatable, Hashable {
    static var automatic: Chart3DCameraProjection
    static var orthographic: Chart3DCameraProjection
    static var perspective: Chart3DCameraProjection
}
```

**Projection Modes**:
- **automatic**: Platform-default projection
- **orthographic**: Parallel projection (no perspective distortion), ideal for technical diagrams
- **perspective**: Realistic depth perception

**Usage**:
```swift
Chart3D { ... }
    .chart3DCameraProjection(.perspective)
```

#### Chart3DPose

**Available in iOS 26.0+, macOS 26.0+, visionOS 26.0+**

```swift
struct Chart3DPose: Equatable, Hashable {
    var azimuth: Angle2D        // Azimuthal angle of the chart pose
    var inclination: Angle2D    // Inclination angle of the chart pose

    init(azimuth: Angle2D, inclination: Angle2D)

    // Predefined poses
    static var `default`: Chart3DPose    // Default viewing position
    static var front: Chart3DPose        // View from front
    static var back: Chart3DPose         // View from back
    static var left: Chart3DPose         // View from left
    static var right: Chart3DPose        // View from right
    static var top: Chart3DPose          // View from top
    static var bottom: Chart3DPose       // View from bottom
}
```

**Usage**:
```swift
@State private var pose: Chart3DPose = .default

Chart3D { ... }
    .chart3DPose($pose)  // Binding for interactive control
```

**Interactive Controls** (when using binding):
- **Drag**: Rotate around center (modifies azimuth/inclination)
- **Pinch**: Zoom in/out
- **Two-finger drag**: Pan
- **Double-tap**: Reset to default pose

### 3D Symbol Shapes

**Available in iOS 26.0+, macOS 26.0+, visionOS 26.0+**

```swift
// Chart3DSymbolShape protocol
protocol Chart3DSymbolShape { }

// BasicChart3DSymbolShape provides built-in shapes
extension Chart3DSymbolShape {
    static var sphere: BasicChart3DSymbolShape    // Sphere symbol
    static var cube: BasicChart3DSymbolShape      // Cube symbol
    static var cylinder: BasicChart3DSymbolShape  // Cylinder symbol
    static var cone: BasicChart3DSymbolShape      // Cone symbol
}
```

**Usage**:
```swift
PointMark3D(...)
    .symbolShape(.sphere)
    .symbolSize(radius: 0.05)
```

### 3D Surface Styles

```swift
public struct Chart3DSurfaceStyle {
    var material: Material              // .diffuse, .specular, .metallic
    var color: Color
    var opacity: Double                 // 0.0 - 1.0
    var doubleSided: Bool              // Render both faces
}

// Example
SurfaceMark3D(...)
    .surfaceStyle(.init(
        material: .diffuse,
        color: Color(red: 1.0, green: 0.5, blue: 0.0),
        opacity: 0.8,
        doubleSided: true
    ))
```

### 3D Data Model

```swift
/// 3D volumetric simulation data
public struct PlotData3D: Sendable {
    // Cylindrical coordinates
    public let r: [Float]          // Major radius [m]
    public let z: [Float]          // Height [m]
    public let phi: [Float]        // Toroidal angle [rad]

    // 4D data [nTime, nR, nZ, nPhi]
    public let temperature: [[[[Float]]]]    // [keV]
    public let density: [[[[Float]]]]        // [10^20 m^-3]
    public let pressure: [[[[Float]]]]       // [kPa]

    // Metadata
    public let time: [Float]
    public var nTime: Int { time.count }
    public var nR: Int { r.count }
    public var nZ: Int { z.count }
    public var nPhi: Int { phi.count }

    /// Generate from 1D profile assuming toroidal symmetry
    public init(from profile: PlotData, nPhi: Int = 16) {
        // Interpolate to 3D grid
        // Assume axisymmetry (no φ dependence initially)
    }

    /// Extract isosurface at given value
    public func isosurface(of variable: KeyPath<Self, [[[[Float]]]]>,
                          value: Float,
                          timeIndex: Int) -> SurfaceMesh {
        // Marching cubes algorithm
    }
}
```

### 3D Visualization Modes

```swift
public enum DisplayMode3D: Sendable {
    case pointCloud        // Scatter plot with color mapping
    case surface           // Flux surface mesh
    case isosurface        // Constant-value surfaces
    case volume            // Volumetric rendering with opacity
    case fieldLines        // Magnetic field line tracing
    case streamlines       // Current density flow
    case hybrid            // Combine multiple modes
}
```

---

## Data Model

### 2D PlotData

```swift
/// Complete simulation output for 2D plotting
public struct PlotData: Sendable {
    // Coordinates
    public let rho: [Float]              // Normalized radius [nCells]
    public let time: [Float]             // Time [s] [nTime]

    // Temperature & Density [nTime, nCells]
    public let Ti: [[Float]]             // Ion temperature [keV]
    public let Te: [[Float]]             // Electron temperature [keV]
    public let ne: [[Float]]             // Electron density [10^20 m^-3]

    // Magnetic [nTime, nCells]
    public let q: [[Float]]              // Safety factor
    public let magneticShear: [[Float]]  // s
    public let psi: [[Float]]            // Poloidal flux [Wb]

    // Transport [nTime, nCells] [m^2/s]
    public let chiTotalIon: [[Float]]
    public let chiTotalElectron: [[Float]]
    public let chiTurbIon: [[Float]]
    public let chiTurbElectron: [[Float]]
    public let dFace: [[Float]]

    // Current Density [nTime, nCells] [MA/m^2]
    public let jTotal: [[Float]]
    public let jOhmic: [[Float]]
    public let jBootstrap: [[Float]]
    public let jECRH: [[Float]]

    // Sources [nTime, nCells] [MW/m^3]
    public let ohmicHeatSource: [[Float]]
    public let fusionHeatSource: [[Float]]
    public let pICRHIon: [[Float]]
    public let pICRHElectron: [[Float]]
    public let pECRHElectron: [[Float]]

    // Time Series [nTime]
    public let IpProfile: [Float]        // [MA]
    public let IBootstrap: [Float]
    public let IECRH: [Float]
    public let qFusion: [Float]          // Fusion gain
    public let pAuxiliary: [Float]       // [MW]
    public let pOhmicE: [Float]
    public let pAlphaTotal: [Float]
    public let pBremsstrahlung: [Float]
    public let pRadiation: [Float]

    // Utilities
    public var nTime: Int { time.count }
    public var nCells: Int { rho.count }
}

extension PlotData {
    /// Create from SimulationResult with unit conversion
    public init(from result: SimulationResult) {
        // Convert eV → keV, m^-3 → 10^20 m^-3
    }
}
```

### Unit Conversion Strategy

| Quantity | TORAX Internal | Display (2D) | Display (3D) |
|----------|---------------|--------------|--------------|
| Temperature | eV | keV | keV |
| Density | m⁻³ | 10²⁰ m⁻³ | 10²⁰ m⁻³ |
| Length | m | m | m |
| Angle | rad | deg | rad |
| Current | MA | MA | MA |
| Power | MW | MW | MW |

---

## Configuration System

### Plot Type Enumeration

```swift
public enum PlotType: Sendable {
    case spatial        // 1D profile (updated by slider)
    case timeSeries     // 0D time evolution (static)
    case volumetric3D   // 3D volumetric (visionOS)
}
```

### PlotProperties

```swift
public struct PlotProperties: Sendable {
    // Data sources
    public let attrs: [KeyPath<PlotData, [[Float]]>]
    public let timeSeriesAttrs: [KeyPath<PlotData, [Float]>]?
    public let labels: [String]
    public let ylabel: String
    public let plotType: PlotType

    // Styling
    public var legendFontSize: CGFloat? = nil
    public var lineWidth: CGFloat = 2.0
    public var symbolSize: CGFloat = 8.0

    // Data filtering
    public var upperPercentile: Float = 100.0
    public var lowerPercentile: Float = 0.0
    public var includeFirstTimepoint: Bool = true
    public var ylimMinZero: Bool = false
    public var suppressZeroValues: Bool = false

    // 3D specific (optional)
    public var mode3D: DisplayMode3D? = nil
    public var isosurfaceLevels: [Float]? = nil
}
```

### FigureProperties

```swift
public struct FigureProperties: Sendable {
    public let rows: Int
    public let cols: Int
    public let axes: [PlotProperties]

    // Styling
    public var figureSizeFactor: CGFloat = 300
    public var tickFontSize: CGFloat = 10
    public var axesFontSize: CGFloat = 12
    public var titleFontSize: CGFloat = 16
    public var defaultLegendFontSize: CGFloat = 10
    public var colors: [Color] = [.blue, .red, .green, .orange, .purple, .pink]

    // 3D view settings
    public var defaultCameraProjection: Chart3DCameraProjection = .perspective(fieldOfView: .degrees(60))
    public var defaultPose: Chart3DPose = .init(
        rotation: .init(angle: .degrees(45), axis: (0, 1, 0)),
        elevation: .degrees(30),
        distance: 5.0
    )

    public var hasSpatialPlots: Bool {
        axes.contains { $0.plotType == .spatial }
    }

    public var has3DPlots: Bool {
        axes.contains { $0.plotType == .volumetric3D }
    }
}
```

### Pre-defined Configurations

#### 2D Configurations

**Default** (4×4 grid, 16 subplots):
```swift
PlotConfigurations.default
```

**Simple** (2×2 grid, 4 subplots):
```swift
PlotConfigurations.simple
```

**Sources** (3×2 grid, 6 subplots):
```swift
PlotConfigurations.sources
```

#### 3D Configurations

**Volumetric Temperature**:
```swift
PlotConfigurations.volumetric3D = FigureProperties(
    rows: 1,
    cols: 1,
    axes: [
        PlotProperties(
            attrs: [\.Ti],
            labels: ["Temperature"],
            ylabel: "",
            plotType: .volumetric3D,
            mode3D: .volume,
            isosurfaceLevels: [1, 5, 10, 15]  // keV
        )
    ]
)
```

**Magnetic Surfaces**:
```swift
PlotConfigurations.magneticSurfaces3D = FigureProperties(
    rows: 1,
    cols: 1,
    axes: [
        PlotProperties(
            attrs: [\.q],
            labels: ["q surfaces"],
            ylabel: "",
            plotType: .volumetric3D,
            mode3D: .isosurface,
            isosurfaceLevels: [1, 2, 3]  // q values
        )
    ]
)
```

---

## User Interface Components

### ToraxPlotView (2D)

```swift
@available(macOS 13.0, iOS 16.0, *)
public struct ToraxPlotView: View {
    let data: PlotData
    let config: FigureProperties
    let comparisonData: PlotData?

    @State private var timeIndex: Int = 0

    public var body: some View {
        VStack(spacing: 0) {
            // Plot grid
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: config.cols),
                    spacing: 16
                ) {
                    ForEach(config.axes.indices, id: \.self) { idx in
                        subplot(for: config.axes[idx])
                            .frame(height: config.figureSizeFactor)
                    }
                }
                .padding()
            }

            // Time slider
            if config.hasSpatialPlots {
                timeSlider
                    .padding()
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}
```

### ToraxPlot3DView (3D)

```swift
@available(visionOS 2.0, macOS 14.0, iOS 17.0, *)
public struct ToraxPlot3DView: View {
    let data: PlotData3D
    let config: FigureProperties

    @State private var timeIndex: Int = 0
    @State private var cameraPose: Chart3DPose
    @State private var selectedIsosurface: Int = 0

    public init(data: PlotData3D, config: FigureProperties) {
        self.data = data
        self.config = config
        _cameraPose = State(initialValue: config.defaultPose)
    }

    public var body: some View {
        VStack {
            // 3D Chart
            volumetricPlot
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls
            HStack {
                // Time slider
                timeSlider

                Divider()

                // Isosurface selector
                if let levels = config.axes.first?.isosurfaceLevels {
                    isosurfacePicker(levels: levels)
                }

                Divider()

                // Camera reset
                Button("Reset Camera") {
                    cameraPose = config.defaultPose
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var volumetricPlot: some View {
        Chart3D(data.volumetricPoints(timeIndex: timeIndex)) { point in
            PointMark3D(
                x: .value("R", point.r),
                y: .value("Z", point.z),
                z: .value("φ", point.phi)
            )
            .foregroundStyle(by: .value("Temperature", point.temperature))
            .symbolShape(.sphere)
            .symbolSize(50)
            .opacity(0.7)
        }
        .chart3DPose(cameraPose)
        .chart3DCameraProjection(config.defaultCameraProjection)
        .chartForegroundStyleScale([
            "Low": Color.blue,
            "High": Color.red
        ], range: data.temperatureRange)
    }
}
```

### Adaptive Plot View

```swift
@available(macOS 13.0, iOS 16.0, *)
public struct AdaptivePlotView: View {
    let data: PlotData
    let config: FigureProperties

    @State private var displayMode: DisplayModeSelection = .auto

    public enum DisplayModeSelection {
        case auto
        case force2D
        case force3D
    }

    public var body: some View {
        Group {
            #if os(visionOS)
            if displayMode == .auto || displayMode == .force3D {
                ToraxPlot3DView(
                    data: PlotData3D(from: data),
                    config: config
                )
            } else {
                ToraxPlotView(data: data, config: config)
            }
            #else
            ToraxPlotView(data: data, config: config)
            #endif
        }
        .toolbar {
            #if os(visionOS)
            Picker("Display Mode", selection: $displayMode) {
                Label("Auto", systemImage: "eye").tag(DisplayModeSelection.auto)
                Label("2D", systemImage: "chart.xyaxis.line").tag(DisplayModeSelection.force2D)
                Label("3D", systemImage: "cube").tag(DisplayModeSelection.force3D)
            }
            #endif
        }
    }
}
```

---

## Implementation Plan

### Phase 1: Core 2D Infrastructure (P0) - 4-6 hours

**Deliverables**:
1. ✅ Package.swift integration (COMPLETE - macOS 26+, iOS 26+, visionOS 26+)
2. `PlotData` model with unit conversion
3. `PlotProperties` and `FigureProperties`
4. Basic `ToraxPlotView` (2D)
5. Time slider component
6. `SimplePlotConfig` (2×2 grid)

**Testing**:
- Unit tests for data conversion
- UI preview tests for 2D layouts

**Platform**: macOS 13+, iOS 16+ (2D Charts only)

### Phase 2: 2D Plot Rendering (P0) - 4-6 hours

**Deliverables**:
1. Spatial plot view with `LineMark`
2. Time series plot view
3. Color scheme management
4. Legend and axis labels
5. Comparison plots (2 runs)

**Testing**:
- Visual regression tests
- Performance benchmarks

**Platform**: macOS 13+, iOS 16+

### Phase 3: 2D Configurations (P1) - 2-4 hours

**Deliverables**:
1. `DefaultPlotConfig` (4×4, 16 subplots)
2. `SourcesPlotConfig` (3×2, 6 subplots)
3. Percentile filtering
4. Zero value suppression

**Platform**: macOS 13+, iOS 16+

### Phase 4: 3D Foundation (P2 - Future) - 6-8 hours

**BLOCKED**: Requires iOS 26.0+, macOS 26.0+, visionOS 26.0+ (not yet released)

**Deliverables** (when available):
1. `PlotData3D` model
2. Cylindrical grid generation from 1D profiles
3. Basic `ToraxPlot3DView` using `Chart3D`
4. Camera controller with `Chart3DPose` binding
5. Point cloud rendering with `PointMark3D`

**Platform**: iOS 26.0+, macOS 26.0+, visionOS 26.0+ (future)

**Note**: Current Package.swift is configured for iOS 26+, but this limits deployment until OS release.

### Phase 5: 3D Advanced Features (P3 - Future) - 8-12 hours

**BLOCKED**: Requires iOS 26.0+ availability

**Deliverables** (when available):
1. `SurfacePlot` for mathematical functions
2. Surface mesh rendering for flux surfaces
3. Multiple `PointMark3D` layers with opacity
4. Predefined camera poses (`.front`, `.top`, `.default`)
5. Interactive camera controls via `@State` binding

**Platform**: iOS 26.0+, macOS 26.0+, visionOS 26.0+

### Phase 6: CLI Integration (P1) - 2-3 hours

**Deliverables**:
1. Update `PlotCommand.swift` to use GotenxUI 2D views
2. Window management for macOS
3. Export to PNG/PDF via `ImageRenderer`
4. 3D snapshot export (future, when iOS 26+ available)

**Platform**: macOS 13+ (2D), macOS 26+ (3D)

---

## API Reference

### Public API

```swift
// Models
public struct PlotData: Sendable
public struct PlotData3D: Sendable
public struct PlotProperties: Sendable
public struct FigureProperties: Sendable
public enum PlotType: Sendable
public enum DisplayMode3D: Sendable

// 2D Views
@available(macOS 13.0, iOS 16.0, *)
public struct ToraxPlotView: View

// 3D Views
@available(visionOS 2.0, macOS 14.0, *)
public struct ToraxPlot3DView: View

// Adaptive Views
@available(macOS 13.0, iOS 16.0, *)
public struct AdaptivePlotView: View

// Configurations
public enum PlotConfigurations {
    public static var `default`: FigureProperties      // 2D 4×4
    public static var simple: FigureProperties          // 2D 2×2
    public static var sources: FigureProperties         // 2D 3×2
    public static var volumetric3D: FigureProperties    // 3D volume
    public static var magneticSurfaces3D: FigureProperties  // 3D surfaces
}
```

### Usage Examples

#### 2D Plotting

```swift
import GotenxUI
import SwiftUI

@main
struct ToraxApp: App {
    var body: some Scene {
        WindowGroup {
            ToraxPlotView(
                data: PlotData(from: simulationResult),
                config: PlotConfigurations.default
            )
            .frame(minWidth: 1200, minHeight: 900)
        }
    }
}
```

#### 3D Plotting (visionOS)

```swift
#if os(visionOS)
import GotenxUI
import SwiftUI

@main
struct ToraxApp3D: App {
    var body: some Scene {
        WindowGroup {
            ToraxPlot3DView(
                data: PlotData3D(from: simulationResult),
                config: PlotConfigurations.volumetric3D
            )
        }
        .windowStyle(.volumetric)
    }
}
#endif
```

#### Adaptive Plotting

```swift
@main
struct ToraxAppAdaptive: App {
    var body: some Scene {
        WindowGroup {
            AdaptivePlotView(
                data: PlotData(from: simulationResult),
                config: PlotConfigurations.default
            )
        }
    }
}
```

---

## Performance & Optimization

### 2D Performance Targets

| Scenario | nTime | nCells | Points/Plot | Target FPS |
|----------|-------|--------|-------------|------------|
| Small | 100 | 50 | 5,000 | 60 |
| Medium | 1,000 | 100 | 100,000 | 60 |
| Large | 10,000 | 200 | 2,000,000 | 30 |

### 3D Performance Targets

| Scenario | nR × nZ × nPhi | Total Points | Target FPS |
|----------|----------------|--------------|------------|
| Low | 32 × 32 × 16 | 16,384 | 60 |
| Medium | 64 × 64 × 32 | 131,072 | 30 |
| High | 128 × 128 × 64 | 1,048,576 | 15 |

### Optimization Strategies

#### 2D Optimizations
- **Lazy VGrid**: Only render visible subplots
- **Data decimation**: Downsample for <1000 points per plot
- **DrawingGroup**: Cache complex charts
- **KeyPath access**: O(1) field lookup

#### 3D Optimizations
- **Level-of-detail**: Reduce mesh resolution for distant objects
- **Frustum culling**: Skip rendering of off-screen geometry
- **GPU instancing**: Batch similar geometry
- **Async mesh generation**: Background thread for heavy computation

---

## Platform-Specific Considerations

### macOS

- **Window management**: Resizable, multiple windows
- **Export**: PDF, PNG via `ImageRenderer`
- **Keyboard shortcuts**: Cmd+S (save), Cmd+P (export)

### iOS/iPadOS

- **Touch gestures**: Pinch-zoom, pan
- **Rotation**: Lock landscape for 3D views
- **Sharing**: Share sheet for export

### visionOS

- **Spatial computing**: Full 3D immersion
- **Hand tracking**: Gesture-based camera control
- **Eye tracking**: Focus-based UI hints
- **Windows**: Volumetric window for 3D plots

---

## Future Enhancements

### Phase 7: Advanced 3D (Future)

- Particle tracing animation
- Time-dependent 3D evolution (4D)
- VR controller support
- Collaborative viewing (SharePlay)

### Phase 8: ML Integration (Future)

- Anomaly detection highlighting
- Predictive visualization
- Auto-generated insights

---

## References

1. **TORAX matplotlib**: `torax/_src/plotting/plotruns_lib.py`
2. **Swift Charts**: https://developer.apple.com/documentation/charts
3. **Chart3D**: https://developer.apple.com/documentation/charts/chart3d
4. **RealityKit**: https://developer.apple.com/documentation/realitykit
5. **TORAX paper**: arXiv:2406.06718v2

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1.0 | 2025-01-20 | Claude | Initial requirements with 2D and 3D capabilities |

---

**Status**: Ready for implementation. Begin with Phase 1 (2D core).
