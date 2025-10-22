# Gotenx GUI Application Design

**Version**: 1.0
**Date**: 2025-01-20
**Status**: Design Phase
**Target**: macOS 13+, iOS 16+ (2D Charts only)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Component Specifications](#component-specifications)
4. [Data Flow & State Management](#data-flow--state-management)
5. [View Hierarchy](#view-hierarchy)
6. [Implementation Guide](#implementation-guide)
7. [Testing Strategy](#testing-strategy)
8. [Performance Optimization](#performance-optimization)
9. [Accessibility & Localization](#accessibility--localization)

---

## 1. Executive Summary

### 1.1 Purpose

GotenxApp is a native macOS/iOS application that provides:
- **Simulation Execution**: Configure and run tokamak transport simulations
- **Real-time Monitoring**: Watch 0D scalar metrics evolve during simulation
- **Interactive Visualization**: Explore 1D spatial profiles with time slider
- **Post-processing Analysis**: Compare runs, export data, generate reports

### 1.2 Design Goals

| Goal | Rationale | Success Metric |
|------|-----------|----------------|
| **Swift-native** | Leverage Swift 6 concurrency, type safety | Zero Obj-C bridging |
| **Responsive UI** | Never block main thread during simulation | 60 FPS UI updates |
| **Memory efficient** | Run on MacBook Air with 8GB RAM | <100 MB for 20k-step simulation |
| **Type-safe** | Catch errors at compile time | @Observable + Sendable |
| **Testable** | Unit and UI tests without mocks | 80%+ code coverage |

### 1.3 Technology Stack

```swift
// SwiftUI
import SwiftUI                   // UI framework (macOS 13+, iOS 16+)
import Charts                    // 2D plotting (native Swift Charts)

// Gotenx Core
import GotenxCore                // Simulation engine
import GotenxPhysics             // Physics models
import GotenxUI                  // Chart components

// Swift Concurrency
// - @Observable macro for state management
// - async/await for simulation execution
// - Task for background progress monitoring
```

---

## 2. Architecture Overview

### 2.1 MVVM Pattern

```
┌────────────────────────────────────────────────────────────┐
│                      GotenxApp (@main)                      │
└────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌────────────────────────────────────────────────────────────┐
│                      ContentView (View)                     │
│  ┌────────────────────────────────────────────────────┐   │
│  │  TabView                                             │   │
│  │  ├─ DashboardView (12 charts, spatial profiles)     │   │
│  │  ├─ TimeSeriesDashboard (0D scalar metrics)         │   │
│  │  ├─ ConfigurationView (parameter editor)            │   │
│  │  └─ SimulationControlView (run/pause/stop)          │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
                              │
                              ↓ (observes)
┌────────────────────────────────────────────────────────────┐
│            SimulationViewModel (@Observable)                │
│  ┌────────────────────────────────────────────────────┐   │
│  │  @Published var plotData: PlotData?                 │   │
│  │  @Published var timeSeriesData: [DerivedQuantities] │   │
│  │  @Published var progress: Double                    │   │
│  │  @Published var isRunning: Bool                     │   │
│  │  @Published var errorMessage: String?               │   │
│  │                                                       │   │
│  │  func runSimulation() async                          │   │
│  │  func cancelSimulation()                             │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
                              │
                              ↓ (uses)
┌────────────────────────────────────────────────────────────┐
│             SimulationRunner (Model / Actor)                │
│  ┌────────────────────────────────────────────────────┐   │
│  │  actor SimulationRunner {                           │   │
│  │    func initialize(transport:sources:)              │   │
│  │    func run(progressCallback:) -> SimulationResult  │   │
│  │  }                                                   │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
                              │
                              ↓ (orchestrates)
┌────────────────────────────────────────────────────────────┐
│          SimulationOrchestrator (Simulation Core)           │
│  ┌────────────────────────────────────────────────────┐   │
│  │  actor SimulationOrchestrator {                     │   │
│  │    func run(until:dynamicParams:) -> SimulationResult│  │
│  │    func getProgress() -> ProgressInfo                │  │
│  │  }                                                   │   │
│  └────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
```

### 2.2 Layer Responsibilities

| Layer | Responsibility | Example |
|-------|---------------|---------|
| **View** | UI rendering, user input handling | `DashboardView`, `TimeSeriesDashboard` |
| **ViewModel** | Business logic, state management, async orchestration | `SimulationViewModel` |
| **Model** | Domain logic, data structures | `SimulationRunner`, `CoreProfiles` |
| **Service** | External operations (I/O, simulation) | `SimulationOrchestrator`, `OutputWriter` |

### 2.3 Concurrency Architecture

```swift
// Main Thread (UI updates only)
@MainActor
class SimulationViewModel {
    func runSimulation() async {
        // 1. Create background task
        let task = Task {
            // 2. Run simulation on background thread
            let result = try await runner.run { fraction, info in
                // 3. Post updates to main thread
                await MainActor.run {
                    self.progress = Double(fraction)
                    self.updateTimeSeriesData(from: info)
                }
            }
            return result
        }

        // 4. Wait for completion
        let result = try await task.value

        // 5. Update UI on main thread
        self.plotData = try PlotData(from: result)
    }
}
```

**Key Points**:
- ✅ Simulation runs on background thread (actor-isolated)
- ✅ UI updates on main thread only (@MainActor)
- ✅ Progress updates every 100ms (non-blocking)
- ✅ Cancellation support via Task

---

## 3. Component Specifications

### 3.1 GotenxApp (Entry Point)

**File**: `Sources/GotenxApp/GotenxApp.swift`

```swift
import SwiftUI

@main
struct GotenxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1200, minHeight: 900)
        }
        #if os(macOS)
        .defaultSize(width: 1400, height: 1000)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Simulation") {
                    // Create new window
                }
                .keyboardShortcut("n")
            }

            CommandGroup(after: .saveItem) {
                Button("Export Results...") {
                    // Export dialog
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(iOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
```

**Responsibilities**:
- App lifecycle management
- Window/scene configuration
- Menu bar commands (macOS)
- Settings UI (iOS)

---

### 3.2 ContentView (Tab Navigation)

**File**: `Sources/GotenxApp/ContentView.swift`

```swift
import SwiftUI
import GotenxUI

struct ContentView: View {
    @State private var viewModel = SimulationViewModel()

    var body: some View {
        NavigationSplitView {
            // Sidebar (macOS only)
            #if os(macOS)
            Sidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
            #endif
        } detail: {
            // Main content (Tabs)
            TabView {
                // Tab 1: Dashboard (spatial profiles)
                if let plotData = viewModel.plotData {
                    DashboardView(plotData: plotData)
                        .tabItem {
                            Label("Dashboard", systemImage: "chart.xyaxis.line")
                        }
                        .tag(0)
                } else {
                    EmptyStateView(message: "Run a simulation to see results")
                        .tabItem {
                            Label("Dashboard", systemImage: "chart.xyaxis.line")
                        }
                        .tag(0)
                }

                // Tab 2: Time Series (0D scalars)
                if !viewModel.timeSeriesData.isEmpty {
                    TimeSeriesDashboard(
                        scalarData: viewModel.timeSeriesData,
                        time: viewModel.time
                    )
                    .tabItem {
                        Label("Time Series", systemImage: "waveform.path.ecg")
                    }
                    .tag(1)
                } else {
                    EmptyStateView(message: "No time series data available")
                        .tabItem {
                            Label("Time Series", systemImage: "waveform.path.ecg")
                        }
                        .tag(1)
                }

                // Tab 3: Configuration
                ConfigurationView(viewModel: viewModel)
                    .tabItem {
                        Label("Configuration", systemImage: "gearshape")
                    }
                    .tag(2)

                // Tab 4: Control
                SimulationControlView(viewModel: viewModel)
                    .tabItem {
                        Label("Control", systemImage: "play.circle")
                    }
                    .tag(3)
            }
        }
        .navigationTitle("Gotenx")
        .alert("Simulation Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }
}
```

**Responsibilities**:
- Tab navigation
- Empty state handling
- Error alerts
- Sidebar (macOS)

---

### 3.3 DashboardView (Spatial Profiles)

**File**: `Sources/GotenxApp/Views/DashboardView.swift`

```swift
import SwiftUI
import Charts
import GotenxUI

struct DashboardView: View {
    let plotData: PlotData

    @State private var timeIndex: Int = 0
    @State private var selectedCharts: Set<ChartType> = Set(ChartType.defaultSelection)

    enum ChartType: String, CaseIterable, Identifiable {
        case tempDensity = "Temperature & Density"
        case current = "Current Density"
        case safetyFactor = "Safety Factor q"
        case transport = "Transport Coefficients"
        case heatSources = "Heat Sources"
        case particleDiffusion = "Particle Diffusion"
        case currentProfile = "Total Current"
        case bootstrap = "Bootstrap Current"
        case ohmic = "Ohmic Current"
        case magneticShear = "Magnetic Shear"
        case pressureGradient = "Pressure Gradient"
        case fluxSurface = "Flux Surface"

        var id: String { rawValue }

        static var defaultSelection: [ChartType] {
            [.tempDensity, .current, .safetyFactor, .transport,
             .heatSources, .particleDiffusion, .currentProfile, .bootstrap]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Spatial Profiles Dashboard")
                    .font(.headline)

                Spacer()

                // Chart selector
                Menu {
                    ForEach(ChartType.allCases) { chartType in
                        Toggle(chartType.rawValue, isOn: Binding(
                            get: { selectedCharts.contains(chartType) },
                            set: { if $0 { selectedCharts.insert(chartType) } else { selectedCharts.remove(chartType) } }
                        ))
                    }
                } label: {
                    Label("Select Charts", systemImage: "square.grid.3x3")
                }
            }
            .padding()

            Divider()

            // Chart grid
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: 3),
                    spacing: 16
                ) {
                    ForEach(Array(selectedCharts), id: \.self) { chartType in
                        chartView(for: chartType)
                            .frame(height: 300)
                    }
                }
                .padding()
            }

            Divider()

            // Time controls
            VStack(spacing: 8) {
                TimeSlider(
                    timeIndex: $timeIndex,
                    maxIndex: plotData.nTime - 1,
                    timeValues: plotData.time
                )

                PlaybackControls(
                    timeIndex: $timeIndex,
                    maxIndex: plotData.nTime - 1
                )
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func chartView(for type: ChartType) -> some View {
        switch type {
        case .tempDensity:
            TemperatureDensityChart(data: plotData, timeIndex: timeIndex)
        case .current:
            CurrentDensityChart(data: plotData, timeIndex: timeIndex)
        case .safetyFactor:
            SafetyFactorChart(data: plotData, timeIndex: timeIndex)
        case .transport:
            TransportCoeffsChart(data: plotData, timeIndex: timeIndex)
        case .heatSources:
            HeatSourcesChart(data: plotData, timeIndex: timeIndex)
        case .particleDiffusion:
            ParticleDiffusionChart(data: plotData, timeIndex: timeIndex)
        case .currentProfile:
            CurrentProfileChart(data: plotData, timeIndex: timeIndex)
        case .bootstrap:
            BootstrapChart(data: plotData, timeIndex: timeIndex)
        case .ohmic:
            OhmicChart(data: plotData, timeIndex: timeIndex)
        case .magneticShear:
            MagneticShearChart(data: plotData, timeIndex: timeIndex)
        case .pressureGradient:
            PressureGradientChart(data: plotData, timeIndex: timeIndex)
        case .fluxSurface:
            FluxSurfaceChart(data: plotData, timeIndex: timeIndex)
        }
    }
}
```

**Responsibilities**:
- Display 12 spatial profile charts in 4×3 grid
- Shared time slider synchronization
- Chart selection (show/hide)
- Playback controls

---

### 3.4 TimeSeriesDashboard (0D Scalars)

**File**: `Sources/GotenxApp/Views/TimeSeriesDashboard.swift`

```swift
import SwiftUI
import Charts

struct TimeSeriesDashboard: View {
    let scalarData: [DerivedQuantities]
    let time: [Float]

    @State private var selectedCategory: Category = .corePlasma

    enum Category: String, CaseIterable {
        case corePlasma = "Core Plasma"
        case energy = "Energy & Power"
        case confinement = "Confinement"
        case current = "Current Drive"
        case fusion = "Fusion Performance"
        case beta = "Beta Limits"
    }

    var body: some View {
        VStack {
            // Category selector
            Picker("Category", selection: $selectedCategory) {
                ForEach(Category.allCases, id: \.self) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Charts for selected category
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: 2),
                    spacing: 16
                ) {
                    switch selectedCategory {
                    case .corePlasma:
                        CoreTemperatureChart(data: scalarData, time: time)
                        CoreDensityChart(data: scalarData, time: time)
                        VolumeAveragedChart(data: scalarData, time: time)

                    case .energy:
                        ThermalEnergyChart(data: scalarData, time: time)
                        IonElectronEnergyChart(data: scalarData, time: time)
                        PowerBalanceChart(data: scalarData, time: time)

                    case .confinement:
                        TauEChart(data: scalarData, time: time)
                        HFactorChart(data: scalarData, time: time)
                        TripleProductChart(data: scalarData, time: time)

                    case .current:
                        PlasmaCurrentChart(data: scalarData, time: time)
                        BootstrapFractionChart(data: scalarData, time: time)

                    case .fusion:
                        FusionPowerChart(data: scalarData, time: time)
                        QChart(data: scalarData, time: time)
                        AlphaPowerChart(data: scalarData, time: time)

                    case .beta:
                        BetaNChart(data: scalarData, time: time)
                        BetaToroidalChart(data: scalarData, time: time)
                        BetaLimitChart(data: scalarData, time: time)
                    }
                }
                .padding()
            }
        }
    }
}
```

**Responsibilities**:
- Display 0D scalar time series charts
- Category-based organization
- 2-column grid layout
- Real-time updates during simulation

---

### 3.5 SimulationViewModel (Business Logic)

**File**: `Sources/GotenxApp/ViewModels/SimulationViewModel.swift`

```swift
import SwiftUI
import GotenxCore
import GotenxPhysics
import GotenxUI

@Observable
@MainActor
class SimulationViewModel {
    // MARK: - Published State

    /// Spatial profile data for Dashboard
    var plotData: PlotData?

    /// Time series scalar data
    var timeSeriesData: [DerivedQuantities] = []

    /// Time values corresponding to timeSeriesData
    var time: [Float] = []

    /// Simulation progress (0.0 to 1.0)
    var progress: Double = 0.0

    /// Is simulation currently running?
    var isRunning: Bool = false

    /// Error message (if any)
    var errorMessage: String?

    // MARK: - Configuration

    /// Simulation configuration (editable)
    var config: SimulationConfiguration

    // MARK: - Private State

    /// Simulation runner (created during execution)
    private var runner: SimulationRunner?

    /// Background task handle
    private var simulationTask: Task<Void, Never>?

    // MARK: - Initialization

    init(config: SimulationConfiguration = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Run simulation with current configuration
    func runSimulation() async {
        guard !isRunning else { return }

        isRunning = true
        progress = 0.0
        errorMessage = nil
        timeSeriesData = []
        time = []

        simulationTask = Task {
            do {
                // Create transport model
                let transport = try TransportModelFactory.create(
                    type: config.runtime.dynamic.transport.modelType,
                    params: config.runtime.dynamic.transport.params
                )

                // Create source models
                let sources = try SourceModelFactory.createModels(
                    config: config.runtime.dynamic.sources
                )

                // Initialize runner
                runner = SimulationRunner(config: config)
                try await runner?.initialize(
                    transportModel: transport,
                    sourceModels: sources
                )

                // Run simulation with progress callback
                let result = try await runner?.run { fraction, progressInfo in
                    await MainActor.run {
                        self.progress = Double(fraction)

                        // Append time series data in real-time
                        if let state = progressInfo.currentState {
                            self.updateTimeSeriesData(from: state)
                        }
                    }
                }

                // Update final results
                if let result = result {
                    await MainActor.run {
                        self.plotData = try? PlotData(from: result)
                        self.timeSeriesData = result.timeSeries?.compactMap { $0.derived } ?? []
                        self.time = result.timeSeries?.map { $0.time } ?? []
                        self.isRunning = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    /// Cancel running simulation
    func cancelSimulation() {
        simulationTask?.cancel()
        isRunning = false
    }

    // MARK: - Private Helpers

    private func updateTimeSeriesData(from state: SimulationState) {
        if let derived = state.derived {
            timeSeriesData.append(derived)
            time.append(state.time)
        }
    }
}
```

**Responsibilities**:
- Manage simulation lifecycle
- Coordinate async simulation execution
- Update UI state from background progress
- Handle errors gracefully
- Provide cancellation support

---

## 4. Data Flow & State Management

### 4.1 State Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                       User Action                            │
│  (Button tap: "Run Simulation")                             │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│             SimulationViewModel.runSimulation()              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  1. Set isRunning = true                               │  │
│  │  2. Reset progress, errorMessage                       │  │
│  │  3. Create SimulationRunner                            │  │
│  │  4. Initialize transport & source models               │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│         SimulationRunner.run(progressCallback:)              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  actor SimulationRunner {                              │  │
│  │    func run(progressCallback:) async throws {          │  │
│  │      while state.time < endTime {                       │  │
│  │        performStep()                                    │  │
│  │        callback(progress, state)  // Every 100 steps    │  │
│  │      }                                                   │  │
│  │      return result                                       │  │
│  │    }                                                     │  │
│  │  }                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓ (every 100 steps)
┌─────────────────────────────────────────────────────────────┐
│                    Progress Callback                         │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  await MainActor.run {                                 │  │
│  │    self.progress = fraction                             │  │
│  │    if let derived = state.derived {                     │  │
│  │      self.timeSeriesData.append(derived)                │  │
│  │      self.time.append(state.time)                       │  │
│  │    }                                                     │  │
│  │  }                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                   SwiftUI Re-render                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  - ProgressView updates (progress bar)                 │  │
│  │  - TimeSeriesDashboard re-renders (new data points)    │  │
│  │  - Charts animate smoothly (60 FPS)                    │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓ (simulation complete)
┌─────────────────────────────────────────────────────────────┐
│                    Final State Update                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  await MainActor.run {                                 │  │
│  │    self.plotData = PlotData(from: result)              │  │
│  │    self.timeSeriesData = result.timeSeries             │  │
│  │    self.isRunning = false                               │  │
│  │  }                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│               DashboardView becomes available                │
│  - User switches to Dashboard tab                           │
│  - 12 spatial profile charts render                         │
│  - Time slider enables interactive scrubbing                │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Thread Safety

| Component | Threading Model | Rationale |
|-----------|-----------------|-----------|
| **SimulationViewModel** | @MainActor | UI state must be on main thread |
| **SimulationRunner** | actor | Isolated simulation execution |
| **SimulationOrchestrator** | actor | Mutable simulation state |
| **Progress Callback** | async closure | Bridges actor → @MainActor |
| **Chart Views** | @MainActor | SwiftUI views are main-thread only |

**Key Pattern**: Actor isolation for computation + @MainActor for UI updates

```swift
// Background actor (simulation)
actor SimulationOrchestrator {
    func step() async -> SimulationState {
        // Heavy computation on background thread
        return newState
    }
}

// Main thread (UI)
@MainActor
class ViewModel {
    func update(from state: SimulationState) {
        // UI updates on main thread
        self.timeSeriesData.append(state.derived!)
    }
}

// Bridge
let result = await orchestrator.step()  // Background
await MainActor.run {
    viewModel.update(from: result)  // Main thread
}
```

---

## 5. View Hierarchy

### 5.1 Component Tree

```
GotenxApp
└── ContentView
    ├── NavigationSplitView
    │   ├── Sidebar (macOS only)
    │   │   ├── RecentSimulationsListView
    │   │   ├── PresetsListView
    │   │   └── ExamplesListView
    │   │
    │   └── TabView
    │       ├── Tab 1: DashboardView
    │       │   ├── Toolbar (chart selector)
    │       │   ├── LazyVGrid (4×3 charts)
    │       │   │   ├── TemperatureDensityChart
    │       │   │   ├── CurrentDensityChart
    │       │   │   ├── SafetyFactorChart
    │       │   │   ├── TransportCoeffsChart
    │       │   │   ├── HeatSourcesChart
    │       │   │   ├── ParticleDiffusionChart
    │       │   │   ├── CurrentProfileChart
    │       │   │   ├── BootstrapChart
    │       │   │   ├── OhmicChart
    │       │   │   ├── MagneticShearChart
    │       │   │   ├── PressureGradientChart
    │       │   │   └── FluxSurfaceChart
    │       │   ├── TimeSlider
    │       │   └── PlaybackControls
    │       │
    │       ├── Tab 2: TimeSeriesDashboard
    │       │   ├── CategoryPicker (segmented)
    │       │   └── LazyVGrid (2 columns)
    │       │       ├── CoreTemperatureChart
    │       │       ├── CoreDensityChart
    │       │       ├── ThermalEnergyChart
    │       │       ├── TauEChart
    │       │       ├── QChart
    │       │       └── ... (18 total charts)
    │       │
    │       ├── Tab 3: ConfigurationView
    │       │   ├── Form
    │       │   │   ├── Section "Mesh"
    │       │   │   ├── Section "Time"
    │       │   │   ├── Section "Transport"
    │       │   │   ├── Section "Sources"
    │       │   │   └── Section "Output"
    │       │   └── Toolbar (save/load/reset)
    │       │
    │       └── Tab 4: SimulationControlView
    │           ├── StatusCard (progress, eta, stats)
    │           ├── ProgressView (determinate)
    │           ├── Button "Run Simulation"
    │           ├── Button "Cancel" (if running)
    │           └── LogView (console output)
    │
    └── Alert (error handling)
```

### 5.2 Reusable Components

**TimeSlider** (`Sources/GotenxUI/Components/TimeSlider.swift`):
```swift
public struct TimeSlider: View {
    @Binding var timeIndex: Int
    let maxIndex: Int
    let timeValues: [Float]

    public var body: some View {
        VStack {
            Slider(value: .init(
                get: { Double(timeIndex) },
                set: { timeIndex = Int($0) }
            ), in: 0...Double(maxIndex), step: 1)

            HStack {
                Text("t = \(timeValues[timeIndex], specifier: "%.4f") s")
                    .font(.caption)
                    .monospacedDigit()

                Spacer()

                Text("\(timeIndex + 1) / \(maxIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

**PlaybackControls** (`Sources/GotenxUI/Components/PlaybackControls.swift`):
```swift
public struct PlaybackControls: View {
    @Binding var timeIndex: Int
    let maxIndex: Int

    @State private var isPlaying: Bool = false
    @State private var playbackSpeed: Double = 1.0

    public var body: some View {
        HStack {
            // Previous frame
            Button(action: { timeIndex = max(0, timeIndex - 1) }) {
                Image(systemName: "backward.frame")
            }
            .disabled(timeIndex == 0)

            // Play/Pause
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle" : "play.circle")
            }

            // Next frame
            Button(action: { timeIndex = min(maxIndex, timeIndex + 1) }) {
                Image(systemName: "forward.frame")
            }
            .disabled(timeIndex == maxIndex)

            Divider()

            // Reset to start
            Button(action: { timeIndex = 0 }) {
                Image(systemName: "arrow.counterclockwise")
            }

            Spacer()

            // Speed selector
            Picker("Speed", selection: $playbackSpeed) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }

            while isPlaying && timeIndex < maxIndex {
                try? await Task.sleep(for: .seconds(0.03 / playbackSpeed))
                timeIndex += 1
            }

            if timeIndex >= maxIndex {
                isPlaying = false
            }
        }
    }

    private func togglePlayback() {
        if timeIndex == maxIndex {
            timeIndex = 0
        }
        isPlaying.toggle()
    }
}
```

---

## 6. Implementation Guide

### 6.1 Phase 1: Project Setup (Day 1)

#### Step 1: Update Package.swift

```swift
// Package.swift additions
.executableTarget(
    name: "GotenxApp",
    dependencies: [
        "Gotenx",
        "GotenxPhysics",
        "GotenxUI"
    ],
    resources: [
        .process("Resources")
    ],
    swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency")
    ]
),
```

#### Step 2: Create Directory Structure

```bash
mkdir -p Sources/GotenxApp/{Views,ViewModels,Resources}
mkdir -p Sources/GotenxApp/Views/{Charts,Configuration}
```

#### Step 3: Create Minimal App

**Sources/GotenxApp/GotenxApp.swift**:
```swift
import SwiftUI

@main
struct GotenxApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Hello, Gotenx!")
        }
    }
}
```

#### Step 4: Build & Run

```bash
swift build --target GotenxApp
swift run GotenxApp
```

Expected output: Window with "Hello, Gotenx!" text

---

### 6.2 Phase 2: ViewModel (Day 2)

**Create** `Sources/GotenxApp/ViewModels/SimulationViewModel.swift`

**Implement**:
- [ ] Basic @Observable class structure
- [ ] State properties (plotData, progress, isRunning)
- [ ] runSimulation() stub (no actual simulation yet)
- [ ] cancelSimulation() stub

**Test**:
```swift
let viewModel = SimulationViewModel()
XCTAssertFalse(viewModel.isRunning)
XCTAssertNil(viewModel.plotData)

Task {
    await viewModel.runSimulation()
    XCTAssertTrue(viewModel.isRunning)  // Should change state
}
```

---

### 6.3 Phase 3: Dashboard (Days 3-4)

**Day 3: Empty Dashboard Layout**

**Create** `Sources/GotenxApp/Views/DashboardView.swift`

**Implement**:
- [ ] VStack with placeholder for chart grid
- [ ] TimeSlider component
- [ ] PlaybackControls component
- [ ] Accept mock PlotData

**Day 4: Populate with Charts**

**Implement**:
- [ ] LazyVGrid with 12 chart placeholders
- [ ] Wire up actual GotenxPlotView components from GotenxUI
- [ ] Connect time slider to all charts
- [ ] Test time scrubbing performance

---

### 6.4 Phase 4: Time Series Dashboard (Day 5)

**Create** `Sources/GotenxApp/Views/TimeSeriesDashboard.swift`

**Implement**:
- [ ] Category picker (6 categories)
- [ ] LazyVGrid with chart views
- [ ] Create 18 individual chart views:
  - CoreTemperatureChart
  - ThermalEnergyChart
  - TauEChart
  - QChart
  - ... (14 more)

---

### 6.5 Phase 5: Integration & Polish (Day 6-7)

**Day 6: Full Integration**

- [ ] Wire up SimulationViewModel → DashboardView
- [ ] Test real simulation execution
- [ ] Add error handling
- [ ] Implement cancellation

**Day 7: Polish & Testing**

- [ ] Add empty state views
- [ ] Improve loading states
- [ ] Add keyboard shortcuts
- [ ] Test on iOS (iPad)
- [ ] Write unit tests

---

## 7. Testing Strategy

### 7.1 Unit Tests

**Test Coverage Goals**:
- ViewModel business logic: 90%
- Data transformations: 90%
- Chart computations: 80%

**Example**:
```swift
@Test
func testSimulationViewModelInitialState() {
    let viewModel = SimulationViewModel()

    #expect(!viewModel.isRunning)
    #expect(viewModel.progress == 0.0)
    #expect(viewModel.plotData == nil)
    #expect(viewModel.timeSeriesData.isEmpty)
}

@Test
func testSimulationRunCreatesPlotData() async throws {
    let viewModel = SimulationViewModel(config: .minimal)

    await viewModel.runSimulation()

    #expect(viewModel.plotData != nil)
    #expect(!viewModel.timeSeriesData.isEmpty)
    #expect(!viewModel.isRunning)
}
```

### 7.2 UI Tests

**Critical Paths**:
1. Launch app → See empty dashboard
2. Switch to Configuration tab → Edit parameters
3. Switch to Control tab → Click "Run Simulation"
4. See progress bar update
5. Switch to Dashboard tab → See 12 charts
6. Drag time slider → Charts update smoothly
7. Click playback button → Charts animate

**Example**:
```swift
@Test(XCUIApplication.self)
func testSimulationWorkflow() async throws {
    let app = XCUIApplication()
    app.launch()

    // Navigate to Control tab
    app.tabs["Control"].tap()

    // Start simulation
    let runButton = app.buttons["Run Simulation"]
    #expect(runButton.exists)
    runButton.tap()

    // Wait for completion (or timeout)
    let progressView = app.progressIndicators.firstMatch
    await waitForNonExistence(of: progressView, timeout: 60)

    // Navigate to Dashboard
    app.tabs["Dashboard"].tap()

    // Verify charts exist
    let charts = app.charts
    #expect(charts.count > 0)
}
```

---

## 8. Performance Optimization

### 8.1 Chart Rendering

**Problem**: 12 charts × 100 cells × 60 FPS = 72,000 data points/second

**Solutions**:

1. **Lazy Loading**: Use `LazyVGrid` to render only visible charts
2. **Drawing Group**: Cache complex charts with `.drawingGroup()`
3. **Data Decimation**: Downsample for charts with >1000 points

```swift
Chart {
    ForEach(decimatedData, id: \.index) { point in
        LineMark(x: .value("ρ", point.rho), y: .value("Ti", point.value))
    }
}
.drawingGroup()  // Cache rendered output
```

### 8.2 Memory Management

**Challenge**: 20,000 timesteps × 100 cells × 4 profiles × 4 bytes = 32 MB

**Solution**: Use `SamplingConfig.balanced` (only save every 100 steps)

```swift
// In SimulationRunner
let orchestrator = await SimulationOrchestrator(
    ...,
    samplingConfig: .balanced  // 201 snapshots instead of 20,000
)
```

**Result**: 32 MB → 320 KB (100× reduction)

### 8.3 Progress Callback Throttling

**Problem**: Callback every timestep = 20,000 UI updates/second

**Solution**: Throttle to 10 Hz (every 100ms)

```swift
var lastCallbackTime: Date = Date()

while state.time < endTime {
    state = step(state)

    let now = Date()
    if now.timeIntervalSince(lastCallbackTime) > 0.1 {
        callback(progress, state)
        lastCallbackTime = now
    }
}
```

---

## 9. Accessibility & Localization

### 9.1 Accessibility

**VoiceOver Support**:
```swift
Chart { ... }
    .accessibilityLabel("Temperature profile at time \(timeValues[timeIndex]) seconds")
    .accessibilityValue("Ion temperature: \(Ti_core) keV, Electron temperature: \(Te_core) keV")
```

**Keyboard Navigation**:
- Tab: Focus next chart
- Space: Play/pause playback
- Arrow keys: Scrub time slider

### 9.2 Localization

**Strings**:
```swift
// Use LocalizedStringKey
Text("Temperature & Density", bundle: .module)
```

**Units** (always international):
- Temperature: keV (not eV)
- Density: 10²⁰ m⁻³ (not m⁻³)
- Current: MA (not A)

No localization needed for units (scientific standard).

---

## Appendix A: File Checklist

### Required Files

- [ ] Sources/GotenxApp/GotenxApp.swift
- [ ] Sources/GotenxApp/ContentView.swift
- [ ] Sources/GotenxApp/Views/DashboardView.swift
- [ ] Sources/GotenxApp/Views/TimeSeriesDashboard.swift
- [ ] Sources/GotenxApp/Views/ConfigurationView.swift
- [ ] Sources/GotenxApp/Views/SimulationControlView.swift
- [ ] Sources/GotenxApp/ViewModels/SimulationViewModel.swift
- [ ] Sources/GotenxApp/Resources/DefaultConfig.json
- [ ] Tests/GotenxAppTests/ViewModelTests.swift

### Chart Views (18 total)

**Time Series Charts**:
- [ ] CoreTemperatureChart.swift
- [ ] CoreDensityChart.swift
- [ ] VolumeAveragedChart.swift
- [ ] ThermalEnergyChart.swift
- [ ] IonElectronEnergyChart.swift
- [ ] PowerBalanceChart.swift
- [ ] TauEChart.swift
- [ ] HFactorChart.swift
- [ ] TripleProductChart.swift
- [ ] PlasmaCurrentChart.swift
- [ ] BootstrapFractionChart.swift
- [ ] FusionPowerChart.swift
- [ ] QChart.swift
- [ ] AlphaPowerChart.swift
- [ ] BetaNChart.swift
- [ ] BetaToroidalChart.swift
- [ ] BetaLimitChart.swift

**Spatial Profile Charts** (reuse GotenxUI components):
- [ ] TemperatureDensityChart (from GotenxUI)
- [ ] CurrentDensityChart (from GotenxUI)
- [ ] SafetyFactorChart (from GotenxUI)
- [ ] ... (9 more from GotenxUI)

---

## Appendix B: Dependencies

```swift
// Package.swift dependencies
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.18.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
]
```

**Platform Requirements**:
- macOS 13.0+ (for Swift Charts)
- iOS 16.0+ (for Swift Charts)
- Swift 6.0+ (for @Observable macro)
- Xcode 16.0+ (for Swift 6 support)

---

**Document Version**: 1.0
**Last Updated**: 2025-01-20
**Authors**: Gotenx Development Team
**Status**: Ready for Implementation
