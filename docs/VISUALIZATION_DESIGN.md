# Gotenx Visualization System Design

**Version**: 1.0
**Date**: 2025-01-20
**Status**: Design Document

## Executive Summary

This document defines the comprehensive visualization system for swift-Gotenx, designed from the perspective of tokamak fusion researchers. The system provides multi-scale, multi-physics visualization capabilities ranging from real-time monitoring to detailed post-processing analysis.

### Design Principles

1. **Physics-First**: All visualizations reflect physically meaningful quantities
2. **Multi-Scale**: 0D (scalars) → 1D (profiles) → 2D (poloidal) → 3D (volumetric)
3. **Real-time Capable**: Critical monitoring during simulation execution
4. **Interactive**: Time evolution, parameter comparison, drill-down analysis
5. **Unit Consistency**: Proper unit conversions with clear documentation

---

## 1. Research Workflow and Visualization Requirements

### 1.1 Workflow Phases

| Phase | Objective | Time Constraint | Visualization Type |
|-------|-----------|-----------------|-------------------|
| **Quick Check** | Verify simulation health | Real-time during run | 0D time series + convergence |
| **Physics Validation** | Confirm physical correctness | Post-processing | 1D profiles + conservation |
| **Performance Analysis** | Evaluate confinement metrics | Post-processing | Derived metrics dashboard |
| **Transport Study** | Understand transport physics | Post-processing | Transport coefficients |
| **Optimization** | Heating/current drive tuning | Post-processing | Source distributions |

### 1.2 Priority Classification

**P0 (Critical)**: Must be implemented for minimum viable product
**P1 (High)**: Essential for serious research use
**P2 (Medium)**: Enhances productivity and understanding
**P3 (Future)**: Advanced features, presentation quality

---

## 2. Visualization Categories

### 2.1 0D Time Series (P0 Priority)

**Purpose**: Real-time monitoring of scalar quantities evolution

#### Required Quantities

**Core Parameters** (highest priority):
```swift
struct TimeSeriesData: Sendable {
    // Temperature
    let Ti_core: [Float]        // Ion temperature at ρ=0 [keV]
    let Te_core: [Float]        // Electron temperature at ρ=0 [keV]

    // Density
    let ne_core: [Float]        // Electron density at ρ=0 [10^20 m^-3]
    let ne_avg: [Float]         // Volume-averaged density

    // Energy
    let W_thermal: [Float]      // Total thermal energy [MJ]
    let W_ion: [Float]          // Ion thermal energy [MJ]
    let W_electron: [Float]     // Electron thermal energy [MJ]

    // Fusion Performance
    let P_fusion: [Float]       // Fusion power [MW]
    let Q_fusion: [Float]       // Fusion gain Q = P_fusion / P_aux

    // Current
    let I_plasma: [Float]       // Total plasma current [MA]
    let I_bootstrap: [Float]    // Bootstrap current [MA]

    // Confinement
    let tau_E: [Float]          // Energy confinement time [s]
    let H_factor: [Float]       // H-factor (τE / τE_ITER89-P)
    let beta_N: [Float]         // Normalized beta

    // Time axis
    let time: [Float]           // Time [s]
}
```

#### Display Requirements

**Chart Type**: Multi-line chart with independent y-axes

**Features**:
- Real-time update during simulation (async callback)
- Target value reference lines (e.g., Q=10 for ITER)
- Zoom/pan for detailed inspection
- Export to CSV/JSON

**Implementation**:
```swift
struct TimeSeriesDashboard: View {
    let data: TimeSeriesData
    @State private var selectedMetric: MetricType = .corePlasma

    enum MetricType: String, CaseIterable {
        case corePlasma = "Core Plasma"
        case energy = "Energy"
        case fusion = "Fusion Power"
        case confinement = "Confinement"
    }

    var body: some View {
        VStack {
            Picker("Metric", selection: $selectedMetric) {
                ForEach(MetricType.allCases, id: \.self) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            switch selectedMetric {
            case .corePlasma:
                CorePlasmaChart(data: data)
            case .energy:
                EnergyChart(data: data)
            case .fusion:
                FusionChart(data: data)
            case .confinement:
                ConfinementChart(data: data)
            }
        }
    }
}
```

---

### 2.2 1D Radial Profiles (P0 Priority)

**Purpose**: Spatial distribution of plasma quantities along normalized minor radius ρ

#### Required Profile Groups

##### Group 1: Temperature & Density (P0)
```swift
struct TemperatureDensityProfiles {
    let rho: [Float]           // Normalized radius [0, 1]
    let Ti: [[Float]]          // Ion temperature [keV] [nTime, nCells]
    let Te: [[Float]]          // Electron temperature [keV]
    let ne: [[Float]]          // Electron density [10^20 m^-3]
}
```

**Physical Expectations**:
- Central peaking: Ti(0) > Ti(1), Te(0) > Te(1)
- Smooth profiles (no unphysical oscillations)
- Pedestal structure in H-mode

##### Group 2: Magnetic Configuration (P1)
```swift
struct MagneticProfiles {
    let q: [[Float]]           // Safety factor [dimensionless]
    let s: [[Float]]           // Magnetic shear s = (ρ/q)(dq/dρ)
    let psi: [[Float]]         // Poloidal flux [Wb]
}
```

**Physical Expectations**:
- q > 1 everywhere (kink stability)
- q monotonic (standard scenario) or non-monotonic (advanced scenario)
- Rational surfaces q = 1, 2, 3 (sawtooth, NTM locations)

##### Group 3: Transport Coefficients (P1)
```swift
struct TransportProfiles {
    let chi_i: [[Float]]       // Ion heat diffusivity [m^2/s]
    let chi_e: [[Float]]       // Electron heat diffusivity [m^2/s]
    let D: [[Float]]           // Particle diffusivity [m^2/s]
    let v: [[Float]]           // Convection velocity [m/s]
}
```

**Physical Expectations**:
- Anomalous transport: χ ~ 0.1–10 m²/s
- ITB region: χ < 0.1 m²/s (transport barrier)
- Core: typically higher than edge

##### Group 4: Current Density (P1)
```swift
struct CurrentProfiles {
    let j_total: [[Float]]     // Total current density [MA/m^2]
    let j_ohmic: [[Float]]     // Ohmic current density
    let j_bootstrap: [[Float]] // Bootstrap current density
    let j_ECCD: [[Float]]      // ECCD-driven current
    let j_NBI: [[Float]]       // NBI-driven current
}
```

**Physical Expectations**:
- j_total = Σ j_i (consistency check)
- Bootstrap fraction f_bs = ∫j_bootstrap / ∫j_total (target: >50% for steady-state)

##### Group 5: Heating Sources (P1)
```swift
struct HeatingProfiles {
    let P_ohmic: [[Float]]     // Ohmic heating [MW/m^3]
    let P_fusion: [[Float]]    // Fusion α heating [MW/m^3]
    let P_ECRH: [[Float]]      // ECRH heating [MW/m^3]
    let P_ICRH_i: [[Float]]    // ICRH ion heating [MW/m^3]
    let P_ICRH_e: [[Float]]    // ICRH electron heating [MW/m^3]
    let P_NBI_i: [[Float]]     // NBI ion heating [MW/m^3]
    let P_NBI_e: [[Float]]     // NBI electron heating [MW/m^3]
    let P_radiation: [[Float]] // Radiation loss [MW/m^3]
}
```

**Physical Expectations**:
- Power balance: ∇·Q = P_heat - P_loss
- Localized heating: ECRH (narrow), ICRH (mid-radius), NBI (broad)

#### Display Requirements

**Interactive Features**:
1. **Time Slider**: Select any time point to view snapshot
2. **Multi-Time Overlay**: Compare 2-5 time points simultaneously
3. **Profile Animation**: Auto-play through time evolution
4. **Export**: Save data as CSV/JSON/HDF5

**Implementation**:
```swift
struct ProfileViewer: View {
    let data: PlotData
    @State private var selectedGroup: ProfileGroup = .tempDensity
    @State private var timeIndex: Int = 0
    @State private var comparisonMode: Bool = false
    @State private var comparisonIndices: Set<Int> = []

    enum ProfileGroup: String, CaseIterable {
        case tempDensity = "T & n"
        case magnetic = "q & ψ"
        case transport = "χ & D"
        case current = "j profiles"
        case heating = "Heating"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Profile group selector
            Picker("Profile Group", selection: $selectedGroup) {
                ForEach(ProfileGroup.allCases, id: \.self) { group in
                    Text(group.rawValue).tag(group)
                }
            }
            .pickerStyle(.segmented)

            // Main chart
            ProfileChart(
                data: data,
                group: selectedGroup,
                timeIndices: comparisonMode ? Array(comparisonIndices) : [timeIndex]
            )
            .frame(height: 400)

            // Time slider
            TimeSlider(
                data: data,
                timeIndex: $timeIndex,
                displayMode: .both
            )

            // Comparison mode toggle
            Toggle("Comparison Mode", isOn: $comparisonMode)

            if comparisonMode {
                TimeSelectionGrid(
                    data: data,
                    selection: $comparisonIndices
                )
            }
        }
        .padding()
    }
}
```

---

### 2.3 Convergence & Diagnostics (P1 Priority)

**Purpose**: Verify numerical stability and physical consistency

#### Required Diagnostics

##### Numerical Convergence
```swift
struct ConvergenceDiagnostics {
    let time: [Float]
    let residual_norm: [Float]        // ||Residual|| at each timestep
    let newton_iterations: [Int]      // # of Newton iterations per step
    let dt_history: [Float]           // Adaptive timestep history
    let linear_solver_iterations: [Int] // # of linear solver iterations
}
```

**Display**:
- Residual history (log scale)
- Newton iteration count bar chart
- Timestep adaptation timeline

##### Conservation Laws
```swift
struct ConservationDiagnostics {
    let time: [Float]
    let particle_drift: [Float]       // ΔN/N_0 (target: < 1%)
    let energy_drift: [Float]         // ΔW/W_0 (target: < 1%)
    let current_drift: [Float]        // ΔI/I_0 (target: < 1%)
}
```

**Display**:
- Drift vs time with ±1% bands
- Alert if drift exceeds threshold

**Implementation**:
```swift
struct DiagnosticsDashboard: View {
    let convergence: ConvergenceDiagnostics
    let conservation: ConservationDiagnostics

    var body: some View {
        Grid {
            GridRow {
                // Residual history
                Chart {
                    ForEach(convergence.time.indices, id: \.self) { i in
                        LineMark(
                            x: .value("Time", convergence.time[i]),
                            y: .value("Residual", convergence.residual_norm[i])
                        )
                    }
                }
                .chartYScale(type: .log)
                .chartYAxisLabel("||Residual||")

                // Particle conservation
                Chart {
                    ForEach(conservation.time.indices, id: \.self) { i in
                        LineMark(
                            x: .value("Time", conservation.time[i]),
                            y: .value("Drift", conservation.particle_drift[i] * 100)
                        )
                    }

                    // ±1% reference bands
                    RectangleMark(
                        xStart: .value("Start", conservation.time.first ?? 0),
                        xEnd: .value("End", conservation.time.last ?? 1),
                        yStart: .value("Lower", -1.0),
                        yEnd: .value("Upper", 1.0)
                    )
                    .foregroundStyle(.green.opacity(0.2))
                }
                .chartYAxisLabel("ΔN/N₀ [%]")
            }

            GridRow {
                // Newton iterations
                Chart {
                    ForEach(convergence.time.indices, id: \.self) { i in
                        BarMark(
                            x: .value("Time", convergence.time[i]),
                            y: .value("Iterations", convergence.newton_iterations[i])
                        )
                    }
                }
                .chartYAxisLabel("Newton Iterations")

                // Energy conservation
                Chart {
                    ForEach(conservation.time.indices, id: \.self) { i in
                        LineMark(
                            x: .value("Time", conservation.time[i]),
                            y: .value("Drift", conservation.energy_drift[i] * 100)
                        )
                    }
                }
                .chartYAxisLabel("ΔW/W₀ [%]")
            }
        }
    }
}
```

---

### 2.4 Performance Metrics Dashboard (P1 Priority)

**Purpose**: High-level confinement performance evaluation

#### Required Metrics

```swift
struct PerformanceMetrics: Sendable {
    // Confinement
    let tau_E: Float            // Energy confinement time [s]
    let H_factor: Float         // H98(y,2) or H89-P factor
    let tau_E_scaling: Float    // Scaling law prediction [s]

    // Beta limits
    let beta_toroidal: Float    // Toroidal beta [%]
    let beta_poloidal: Float    // Poloidal beta
    let beta_N: Float           // Normalized beta (target: 2.5-3.0)
    let beta_N_limit: Float     // Troyon limit

    // Fusion performance
    let P_fusion: Float         // Fusion power [MW]
    let P_auxiliary: Float      // Auxiliary heating [MW]
    let P_alpha: Float          // Alpha heating [MW]
    let Q: Float                // Fusion gain (target: 10 for ITER)

    // Current drive
    let I_plasma: Float         // Total plasma current [MA]
    let I_bootstrap: Float      // Bootstrap current [MA]
    let f_bootstrap: Float      // Bootstrap fraction (target: >0.5)

    // Triple product
    let n_T_tau: Float          // Fusion triple product [10^21 keV s m^-3]
    let n_T_tau_target: Float   // Ignition threshold
}
```

#### Display Requirements

**Dashboard Layout**:
```
┌─────────────────────────────────────────────────────┐
│ ITER Performance Dashboard                          │
├──────────────────┬──────────────────┬───────────────┤
│ Confinement      │ Beta Limits      │ Fusion Gain   │
│                  │                  │               │
│ τE = 3.7s        │ βN = 2.8         │ Q = 10.2      │
│ H98 = 1.0 ✓      │ βN,lim = 3.2 ✓   │ Target: 10 ✓  │
│                  │                  │               │
│ [Progress bar]   │ [Gauge chart]    │ [Gauge chart] │
├──────────────────┼──────────────────┼───────────────┤
│ Current Drive    │ Triple Product   │ Power Balance │
│                  │                  │               │
│ f_bs = 52% ✓     │ nTτ = 5.2        │ P_fus = 500MW │
│ I_bs = 7.8 MA    │ Target: 5.0 ✓    │ P_aux = 50MW  │
└──────────────────┴──────────────────┴───────────────┘
```

**Implementation**:
```swift
struct PerformanceDashboard: View {
    let metrics: PerformanceMetrics

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 20) {
            // Header
            GridRow {
                Text("ITER Performance Dashboard")
                    .font(.title)
                    .gridCellColumns(3)
            }

            // Top row: Main metrics
            GridRow {
                ConfinementCard(metrics: metrics)
                BetaLimitsCard(metrics: metrics)
                FusionGainCard(metrics: metrics)
            }

            // Bottom row: Secondary metrics
            GridRow {
                CurrentDriveCard(metrics: metrics)
                TripleProductCard(metrics: metrics)
                PowerBalanceCard(metrics: metrics)
            }
        }
        .padding()
    }
}

struct ConfinementCard: View {
    let metrics: PerformanceMetrics

    var body: some View {
        VStack(alignment: .leading) {
            Text("Confinement")
                .font(.headline)

            Divider()

            MetricRow(label: "τE", value: metrics.tau_E, unit: "s", target: 3.7)
            MetricRow(label: "H98", value: metrics.H_factor, unit: "", target: 1.0)

            ProgressView(value: metrics.tau_E / metrics.tau_E_scaling) {
                Text("vs. Scaling")
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

struct MetricRow: View {
    let label: String
    let value: Float
    let unit: String
    let target: Float?

    var meetsTarget: Bool {
        guard let target = target else { return true }
        return value >= target * 0.95  // Within 5% of target
    }

    var body: some View {
        HStack {
            Text(label)
                .fontWeight(.medium)
            Spacer()
            Text(String(format: "%.2f %@", value, unit))
                .foregroundColor(meetsTarget ? .green : .orange)
            if meetsTarget {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
    }
}
```

---

### 2.5 2D Poloidal Cross-Section (P2 Priority)

**Purpose**: Visualize spatial structure in (R, Z) coordinates

#### Required Visualizations

##### Contour Plots
```swift
struct PoloidalCrossSection {
    // Grid
    let R: [[Float]]           // Major radius [m]
    let Z: [[Float]]           // Height [m]

    // Scalar fields
    let temperature: [[Float]] // T(R,Z) [keV]
    let density: [[Float]]     // n(R,Z) [10^20 m^-3]
    let pressure: [[Float]]    // P(R,Z) [kPa]

    // Vector fields
    let B_poloidal: [[Float]]  // Poloidal magnetic field [T]

    // Flux surfaces
    let psi_surfaces: [Float]  // Contour levels for ψ
}
```

**Display Types**:
1. **Filled contours**: Temperature/density/pressure distribution
2. **Iso-lines**: Flux surfaces (magnetic field lines)
3. **Vector field**: Poloidal magnetic field arrows
4. **Separatrix**: Last closed flux surface (LCFS)

**Implementation Strategy**:
```swift
// Option 1: Swift Charts (limited contour support)
// Option 2: Custom GeometryReader with path drawing
// Option 3: RealityKit/SceneKit for smooth rendering

struct PoloidalContourView: View {
    let data: PoloidalCrossSection
    @State private var field: ScalarField = .temperature

    enum ScalarField: String, CaseIterable {
        case temperature = "Temperature"
        case density = "Density"
        case pressure = "Pressure"
    }

    var body: some View {
        VStack {
            Picker("Field", selection: $field) {
                ForEach(ScalarField.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)

            // Custom contour renderer
            GeometryReader { geometry in
                Canvas { context, size in
                    drawContours(
                        context: context,
                        size: size,
                        data: fieldData(field),
                        R: data.R,
                        Z: data.Z
                    )

                    // Overlay flux surfaces
                    drawFluxSurfaces(
                        context: context,
                        size: size,
                        psi: data.psi_surfaces
                    )
                }
            }
        }
    }

    private func fieldData(_ field: ScalarField) -> [[Float]] {
        switch field {
        case .temperature: return data.temperature
        case .density: return data.density
        case .pressure: return data.pressure
        }
    }
}
```

---

### 2.6 3D Volumetric Visualization (P3 Priority)

**Purpose**: Publication-quality 3D rendering for presentations

#### Visualization Types

1. **Iso-surfaces**: Temperature/density/pressure constant surfaces
2. **Volume rendering**: Semi-transparent 3D scalar fields
3. **Flux surfaces**: Nested toroidal magnetic surfaces
4. **Streamlines**: Magnetic field line tracing

**Implementation Options**:

**Option A: Chart3D (Swift Charts)** - Requires macOS 26+
```swift
#if available(macOS 26, iOS 26, visionOS 26)
import Charts

struct Gotenx3DView: View {
    let data: PlotData3D

    var body: some View {
        Chart3D {
            ForEach(data.volumetricPoints(timeIndex: 0)) { point in
                PointMark3D(
                    x: .value("R", point.r),
                    y: .value("Z", point.z),
                    z: .value("φ", point.phi)
                )
                .foregroundStyle(by: .value("T", point.temperature))
            }
        }
    }
}
#endif
```

**Option B: RealityKit** - Full control, Apple platform native
```swift
import RealityKit

struct RealityKitGotenxView: View {
    let data: PlotData3D

    var body: some View {
        RealityView { content in
            let entity = generateTokamakEntity(from: data)
            content.add(entity)
        }
    }

    private func generateTokamakEntity(from data: PlotData3D) -> Entity {
        // Generate 3D mesh from volumetric data
        // Apply temperature-based color mapping
        // Create iso-surface geometry
    }
}
```

**Option C: SceneKit** - Mature, broad platform support
```swift
import SceneKit

struct SceneKitGotenxView: View {
    let data: PlotData3D

    var body: some View {
        SceneView(
            scene: generateScene(),
            options: [.allowsCameraControl, .autoenablesDefaultLighting]
        )
    }

    private func generateScene() -> SCNScene {
        let scene = SCNScene()

        // Generate flux surface geometry
        let fluxSurfaces = createFluxSurfaces(data)
        scene.rootNode.addChildNode(fluxSurfaces)

        // Add iso-temperature surfaces
        let isoSurfaces = createIsoSurfaces(data, levels: [5, 10, 15])
        scene.rootNode.addChildNode(isoSurfaces)

        return scene
    }
}
```

---

## 3. Data Architecture

### 3.1 Current Implementation Status (As-Is)

**⚠️ CRITICAL**: The design below describes the **target architecture**. The current implementation has significant gaps:

#### Current Limitations

1. **SimulationState** (Sources/Gotenx/Orchestration/SimulationState.swift:12-120)
   ```swift
   // CURRENT: Only profiles + metadata
   public struct SimulationState: Sendable {
       public let profiles: CoreProfiles           // ✅ Exists
       private let timeAccumulator: Double          // ✅ Exists
       public let dt: Float                         // ✅ Exists
       public let step: Int                         // ✅ Exists
       public var statistics: SimulationStatistics  // ✅ Exists

       // ❌ MISSING: transport, sources, geometry, derived, diagnostics
   }
   ```

2. **PlotData Conversion** (Sources/GotenxUI/Models/PlotData.swift:205-278)
   ```swift
   // CURRENT: Zero-filled placeholders
   self.chiTotalIon = zeroProfiles              // ❌ Not real data
   self.chiTotalElectron = zeroProfiles         // ❌ Not real data
   self.ohmicHeatSource = zeroProfiles          // ❌ Not real data
   self.fusionHeatSource = zeroProfiles         // ❌ Not real data
   // ... all non-profile fields are zeros
   ```

3. **Missing Types**
   - ❌ `DerivedQuantities` - Does not exist
   - ❌ `NumericalDiagnostics` - Does not exist
   - ❌ `PerformanceMetrics` - Does not exist
   - ❌ `TimeSeriesData` - Does not exist

#### Implementation Phases

**Phase 0 (Current)**: Minimal visualization with profiles only
- ✅ CoreProfiles (Ti, Te, ne, psi)
- ✅ Basic 1D profile plots
- ❌ Everything else zero-filled

**Phase 1 (Foundation)**: Add data capture infrastructure
- Add fields to SimulationState (but don't populate yet)
- Create placeholder types (return zeros/defaults)
- Update serialization to handle optional fields

**Phase 2 (Selective Capture)**: Capture derived metrics only
- Implement DerivedQuantities computation
- Save only 0D time series (small memory footprint)
- Skip full profile time series initially

**Phase 3 (Full Capture)**: Complete physics state
- Populate transport/sources in SimulationState
- Implement adaptive sampling (see Section 3.6)
- Enable all visualizations

### 3.2 Target Data Flow (Future)

```
SimulationState (Enhanced)
  ├─ profiles: CoreProfiles
  ├─ transport: TransportCoefficients  ← NEW
  ├─ sources: SourceTerms              ← NEW
  ├─ geometry: Geometry                ← NEW
  ├─ performance: PerformanceMetrics   ← NEW
  └─ diagnostics: NumericalDiagnostics ← NEW
     └─ EnhancedSerializable
        └─ CompletePlotData
           └─ All Views (fully populated)
```

### 3.3 Enhanced SimulationState

```swift
// Gotenx/Orchestration/SimulationState.swift

public struct SimulationState: Sendable {
    // Current (minimal)
    public let profiles: CoreProfiles
    private let timeAccumulator: Double
    public let dt: Float
    public let step: Int
    public var statistics: SimulationStatistics

    // NEW: Complete physics state
    public let transport: TransportCoefficients?
    public let sources: SourceTerms?
    public let geometry: Geometry?
    public let derived: DerivedQuantities?
    public let diagnostics: NumericalDiagnostics?

    public init(
        profiles: CoreProfiles,
        timeAccumulator: Double = 0.0,
        dt: Float = 1e-4,
        step: Int = 0,
        statistics: SimulationStatistics = SimulationStatistics(),
        transport: TransportCoefficients? = nil,
        sources: SourceTerms? = nil,
        geometry: Geometry? = nil,
        derived: DerivedQuantities? = nil,
        diagnostics: NumericalDiagnostics? = nil
    ) {
        self.profiles = profiles
        self.timeAccumulator = timeAccumulator
        self.dt = dt
        self.step = step
        self.statistics = statistics
        self.transport = transport
        self.sources = sources
        self.geometry = geometry
        self.derived = derived
        self.diagnostics = diagnostics
    }
}
```

### 3.4 New Supporting Types

```swift
// Gotenx/Core/DerivedQuantities.swift

/// Derived scalar quantities for performance monitoring
public struct DerivedQuantities: Sendable, Codable {
    // Central values
    public let Ti_core: Float        // Ti(ρ=0) [keV]
    public let Te_core: Float        // Te(ρ=0) [keV]
    public let ne_core: Float        // ne(ρ=0) [10^20 m^-3]

    // Volume-averaged
    public let ne_avg: Float         // <ne> [10^20 m^-3]
    public let Ti_avg: Float         // <Ti> [keV]
    public let Te_avg: Float         // <Te> [keV]

    // Total energies
    public let W_thermal: Float      // Total thermal energy [MJ]
    public let W_ion: Float          // Ion thermal energy [MJ]
    public let W_electron: Float     // Electron thermal energy [MJ]

    // Fusion
    public let P_fusion: Float       // Fusion power [MW]
    public let P_alpha: Float        // Alpha heating [MW]

    // Confinement
    public let tau_E: Float          // Energy confinement time [s]
    public let tau_E_scaling: Float  // Scaling law prediction [s]
    public let H_factor: Float       // H-factor

    // Beta
    public let beta_toroidal: Float  // Toroidal beta [%]
    public let beta_N: Float         // Normalized beta

    // Current
    public let I_plasma: Float       // Total current [MA]
    public let I_bootstrap: Float    // Bootstrap current [MA]
    public let f_bootstrap: Float    // Bootstrap fraction

    // Triple product
    public let n_T_tau: Float        // [10^21 keV s m^-3]

    public init(
        from profiles: CoreProfiles,
        transport: TransportCoefficients?,
        sources: SourceTerms?,
        geometry: Geometry
    ) {
        // Compute all derived quantities
        // Implementation in DerivedQuantities+Computation.swift
    }
}

// Gotenx/Solver/NumericalDiagnostics.swift

/// Numerical solver diagnostics
public struct NumericalDiagnostics: Sendable, Codable {
    // Convergence
    public let residual_norm: Float         // ||R|| at this timestep
    public let newton_iterations: Int       // # of Newton iterations
    public let linear_iterations: Int       // # of linear solver iterations
    public let converged: Bool              // Convergence flag

    // Conservation
    public let particle_drift: Float        // (N - N_0) / N_0
    public let energy_drift: Float          // (W - W_0) / W_0
    public let current_drift: Float         // (I - I_0) / I_0

    // Performance
    public let wall_time: Float             // Wall clock time [s]
    public let eval_count: Int              // # of residual evaluations

    public init(
        residual_norm: Float,
        newton_iterations: Int,
        linear_iterations: Int,
        converged: Bool,
        particle_drift: Float,
        energy_drift: Float,
        current_drift: Float,
        wall_time: Float,
        eval_count: Int
    ) {
        self.residual_norm = residual_norm
        self.newton_iterations = newton_iterations
        self.linear_iterations = linear_iterations
        self.converged = converged
        self.particle_drift = particle_drift
        self.energy_drift = energy_drift
        self.current_drift = current_drift
        self.wall_time = wall_time
        self.eval_count = eval_count
    }
}
```

### 3.5 Data Sampling and Memory Strategy

**Challenge**: Capturing full physics state at every timestep is prohibitively expensive.

#### Memory Footprint Analysis

**Typical ITER simulation**:
- Timesteps: 20,000
- Grid cells: 100
- Variables per cell: ~30 (Ti, Te, ne, psi, χi, χe, D, j_total, P_ohmic, etc.)

**Full capture** (naive):
```
20,000 steps × 100 cells × 30 vars × 4 bytes = 240 MB per simulation
```

This is **manageable** for single runs, but becomes problematic for:
- Parameter scans (100 cases → 24 GB)
- Long-duration simulations (100s → 2.4 GB)
- Real-time visualization (memory pressure)

#### Tiered Sampling Strategy

**Solution**: Different sampling rates for different data types

##### Tier 1: 0D Scalar Time Series (Always Full)
**Frequency**: Every timestep
**Data**: DerivedQuantities, NumericalDiagnostics
**Size**: ~100 floats/step × 20,000 steps = 8 MB
**Rationale**: Small footprint, critical for monitoring

```swift
struct SimulationResult {
    // Always captured - cheap and essential
    let scalarTimeSeries: [DerivedQuantities]
    let diagnostics: [NumericalDiagnostics]

    // Selectively sampled - see below
    let profileTimeSeries: [TimePoint]?
}
```

##### Tier 2: 1D Profile Time Series (Adaptive Sampling)
**Frequency**: Configurable (default: every 100 steps)
**Data**: CoreProfiles, TransportCoefficients, SourceTerms
**Size**: ~3,000 floats/sample × 200 samples = 2.4 MB
**Rationale**: Needed for detailed analysis, but not every step

```swift
struct SamplingConfig {
    /// Save profiles every N steps
    let profileSamplingInterval: Int

    /// Minimum number of samples (override interval if needed)
    let minSamples: Int

    /// Maximum number of samples (cap memory usage)
    let maxSamples: Int

    /// Always include critical time points
    let criticalTimes: [Float]  // e.g., [0.1, 0.5, 1.0, 2.0]

    static let realTime = SamplingConfig(
        profileSamplingInterval: 100,
        minSamples: 50,
        maxSamples: 500,
        criticalTimes: []
    )

    static let postProcessing = SamplingConfig(
        profileSamplingInterval: 10,
        minSamples: 200,
        maxSamples: 2000,
        criticalTimes: [0.1, 0.5, 1.0, 1.5, 2.0]
    )
}
```

##### Tier 3: 2D/3D Spatial Data (On Demand)
**Frequency**: Computed on request, not stored
**Data**: PoloidalCrossSection, PlotData3D
**Rationale**: Reconstructed from saved 1D profiles when needed

```swift
extension PlotData {
    /// Generate 3D data on demand from saved profiles
    func to3D(
        timeIndex: Int,
        nTheta: Int = 16,
        nPhi: Int = 16,
        geometry: GeometryParams
    ) -> PlotData3D {
        // Reconstruct from 1D profiles - no storage overhead
        PlotData3D(
            from: self.slice(timeIndex: timeIndex),
            nTheta: nTheta,
            nPhi: nPhi,
            geometry: geometry
        )
    }
}
```

#### Adaptive Sampling Implementation

**Strategy**: Sample more densely during transient phases

```swift
actor AdaptiveSampler {
    private var lastSampledState: SimulationState?
    private let threshold: Float = 0.05  // 5% change triggers sample

    func shouldSample(_ state: SimulationState, forced: Bool = false) -> Bool {
        if forced { return true }

        guard let last = lastSampledState else {
            return true  // Always sample first step
        }

        // Compute relative change in key quantities
        let dTi = relativeChange(
            state.profiles.ionTemperature.value,
            last.profiles.ionTemperature.value
        )
        let dW = relativeChange(
            state.derived?.W_thermal ?? 0,
            last.derived?.W_thermal ?? 0
        )

        // Sample if significant change
        if dTi > threshold || dW > threshold {
            lastSampledState = state
            return true
        }

        return false
    }

    private func relativeChange(_ new: MLXArray, _ old: MLXArray) -> Float {
        let diff = abs(new - old)
        let scale = abs(old) + 1e-10  // Prevent division by zero
        return (diff / scale).max().item(Float.self)
    }
}
```

#### Memory-Mapped I/O (Future)

For very large simulations, use memory-mapped HDF5:

```swift
import HDF5

class MemoryMappedResults {
    private let file: HDF5File

    func appendTimestep(_ state: SimulationState) throws {
        // Append to HDF5 without loading entire dataset
        try file.append(
            dataset: "profiles/Ti",
            data: state.profiles.ionTemperature.value.asArray(Float.self)
        )
    }

    func readTimeRange(_ range: Range<Int>) throws -> [TimePoint] {
        // Load only requested time range
        try file.readSlice(
            dataset: "profiles/Ti",
            slice: range
        )
    }
}
```

#### Implementation Priority

**Phase 1**: Fixed-interval sampling
```swift
// Simple: Every 100 steps
if step % 100 == 0 {
    timeSeries.append(TimePoint(from: state))
}
```

**Phase 2**: Adaptive sampling
```swift
// Smart: Sample when physics changes
if await sampler.shouldSample(state) {
    timeSeries.append(TimePoint(from: state))
}
```

**Phase 3**: Memory-mapped I/O
```swift
// Scalable: Direct to disk
try results.appendTimestep(state)
```

#### Configuration Recommendations

| Use Case | Sampling Interval | Max Samples | Memory |
|----------|------------------|-------------|---------|
| **Real-time monitoring** | 200 | 100 | 30 MB |
| **Quick analysis** | 100 | 200 | 60 MB |
| **Detailed study** | 20 | 1000 | 300 MB |
| **Publication quality** | 10 | 2000 | 600 MB |

### 3.6 Enhanced PlotData

```swift
// GotenxUI/Models/PlotData.swift

extension PlotData {
    /// Create PlotData from enhanced SimulationResult
    public init(from result: SimulationResult) throws {
        guard let timeSeries = result.timeSeries, !timeSeries.isEmpty else {
            throw PlotDataError.missingTimeSeries
        }

        // Basic profiles (existing)
        // ...

        // Transport coefficients (NEW - real data)
        if let transport = timeSeries.first?.transport {
            self.chiTotalIon = timeSeries.map { timePoint in
                timePoint.transport?.chiIon ?? Array(repeating: 0, count: nCells)
            }
            self.chiTotalElectron = timeSeries.map { timePoint in
                timePoint.transport?.chiElectron ?? Array(repeating: 0, count: nCells)
            }
            // ... other transport coefficients
        } else {
            // Fallback to zeros (legacy compatibility)
            self.chiTotalIon = zeroProfiles
            // ...
        }

        // Source terms (NEW - real data)
        if let sources = timeSeries.first?.sources {
            self.ohmicHeatSource = timeSeries.map { timePoint in
                timePoint.sources?.electronHeating ?? Array(repeating: 0, count: nCells)
            }
            // ... other sources
        } else {
            self.ohmicHeatSource = zeroProfiles
            // ...
        }

        // Derived quantities (NEW - real data)
        self.IpProfile = timeSeries.map { $0.derived?.I_plasma ?? 0 }
        self.qFusion = timeSeries.map { $0.derived?.P_fusion ?? 0 }
        // ... other derived quantities
    }
}
```

---

## 4. Implementation Roadmap

**⚠️ IMPORTANT**: The phases below are cumulative. Each phase builds on the previous one.

### Phase 0: Current State (As of 2025-01-20)

**Status**: ✅ **COMPLETE** - Basic visualization works

#### What Exists:
- ✅ CoreProfiles (Ti, Te, ne, psi)
- ✅ SerializableProfiles
- ✅ PlotData structure (with zero-filled placeholders)
- ✅ GotenxPlotView (1D temperature/density profiles)
- ✅ TimeSlider component
- ✅ PlotData3D physics model

#### What's Missing:
- ❌ Transport coefficients capture
- ❌ Source terms capture
- ❌ Derived quantities (τE, Q, βN)
- ❌ Numerical diagnostics (convergence, conservation)
- ❌ Time series dashboard
- ❌ Performance metrics dashboard

#### What Works:
```swift
// User can run simulation and view basic profiles
let result = try await runner.run(config: config)
let plotData = try PlotData(from: result)

// This works:
GotenxPlotView(data: plotData, config: .temperature)  // ✅ Shows Ti, Te, ne

// This shows zeros:
GotenxPlotView(data: plotData, config: .transport)    // ⚠️ All zeros
```

---

### Phase 1: Infrastructure (Week 1-2) - Foundation

**Goal**: Add data capture infrastructure WITHOUT breaking existing code

**Strategy**: Add optional fields, backward compatible serialization

#### Tasks (in order):

1. **Create new type definitions** (No dependencies)
   ```swift
   // Sources/Gotenx/Core/DerivedQuantities.swift
   public struct DerivedQuantities: Sendable, Codable {
       // Minimal implementation - return zeros for now
   }

   // Sources/Gotenx/Solver/NumericalDiagnostics.swift
   public struct NumericalDiagnostics: Sendable, Codable {
       // Minimal implementation - return defaults
   }
   ```
   **Deliverable**: Types compile, tests pass
   **Time**: 1 day

2. **Extend SimulationState** (Depends on step 1)
   ```swift
   public struct SimulationState: Sendable {
       // Existing fields...

       // NEW: All optional for backward compatibility
       public let transport: TransportCoefficients?
       public let sources: SourceTerms?
       public let geometry: Geometry?
       public let derived: DerivedQuantities?
       public let diagnostics: NumericalDiagnostics?
   }
   ```
   **Deliverable**: SimulationState compiles, existing tests pass
   **Time**: 1 day

3. **Update serialization** (Depends on step 2)
   ```swift
   extension SimulationState {
       public func toSerializable() -> EnhancedSerializable {
           // Handle optional fields gracefully
       }
   }
   ```
   **Deliverable**: Can save/load results with new fields
   **Time**: 1 day

4. **Update PlotData conversion** (Depends on step 3)
   ```swift
   extension PlotData {
       public init(from result: SimulationResult) throws {
           // Use real data if available, fallback to zeros
           if let transport = timeSeries.first?.transport {
               self.chiTotalIon = ... // real data
           } else {
               self.chiTotalIon = zeroProfiles  // fallback
           }
       }
   }
   ```
   **Deliverable**: PlotData conversion doesn't break
   **Time**: 1 day

5. **Add sampling configuration** (Depends on step 4)
   ```swift
   public struct SamplingConfig: Codable {
       public let profileSamplingInterval: Int
       // ... (see Section 3.5)
   }
   ```
   **Deliverable**: Can configure sampling rates
   **Time**: 1 day

**Phase 1 Complete When**:
- [ ] All new types exist and compile
- [ ] SimulationState has new optional fields
- [ ] Serialization handles new fields
- [ ] PlotData conversion works with or without new data
- [ ] All existing tests pass
- [ ] No regressions in existing visualization

**Total Time**: 5 days (1 week)

---

### Phase 2: Scalar Metrics (Week 3) - Quick Wins

**Goal**: Compute and display 0D derived quantities

**Strategy**: Focus on lightweight computations first

#### Tasks:

1. **Implement DerivedQuantities computation** (2 days)
   ```swift
   extension DerivedQuantities {
       public init(
           from profiles: CoreProfiles,
           transport: TransportCoefficients?,
           sources: SourceTerms?,
           geometry: Geometry
       ) {
           // Compute central values
           self.Ti_core = profiles.ionTemperature.value[0].item(Float.self)

           // Compute volume averages
           self.ne_avg = computeVolumeAverage(profiles.electronDensity, geometry)

           // Compute total energies
           self.W_thermal = computeThermalEnergy(profiles, geometry)

           // Leave transport-dependent metrics as zeros for now
           self.tau_E = 0
           self.Q = 0
       }
   }
   ```

2. **Capture DerivedQuantities in orchestrator** (1 day)
   ```swift
   actor SimulationOrchestrator {
       func step(_ state: SimulationState) async -> SimulationState {
           // ... existing code ...

           // NEW: Compute derived quantities
           let derived = DerivedQuantities(
               from: newProfiles,
               transport: nil,  // TODO: Phase 3
               sources: nil,     // TODO: Phase 3
               geometry: geometry
           )

           return state.advanced(
               profiles: newProfiles,
               derived: derived
           )
       }
   }
   ```

3. **Create TimeSeriesDashboard** (2 days)
   ```swift
   struct TimeSeriesDashboard: View {
       let scalarData: [DerivedQuantities]

       var body: some View {
           Grid {
               GridRow {
                   CoreTemperatureChart(data: scalarData)
                   ThermalEnergyChart(data: scalarData)
               }
           }
       }
   }
   ```

**Phase 2 Complete When**:
- [ ] DerivedQuantities computed for Ti_core, Te_core, W_thermal
- [ ] TimeSeriesDashboard displays real-time metrics
- [ ] Scalar time series saved to results
- [ ] User can monitor simulation progress

**Total Time**: 5 days (1 week)

---

### Phase 3: Full Physics State (Week 4-5) - Complete Capture

**Goal**: Capture transport coefficients and source terms

**Strategy**: Modify solver to save physics state

#### Tasks:

1. **Capture TransportCoefficients** (2 days)
   ```swift
   actor SimulationOrchestrator {
       func step(_ state: SimulationState) async -> SimulationState {
           // Compute transport coefficients
           let transport = transportModel.compute(...)

           // NEW: Keep reference for saving
           return state.advanced(
               profiles: newProfiles,
               transport: transport,  // ✅ Now captured
               derived: derived
           )
       }
   }
   ```

2. **Capture SourceTerms** (2 days)
   ```swift
   // Same pattern for sources
   let sources = sourceModel.compute(...)
   return state.advanced(..., sources: sources)
   ```

3. **Implement adaptive sampling** (2 days)
   ```swift
   actor SimulationOrchestrator {
       private let sampler = AdaptiveSampler()

       func run(...) async throws -> SimulationResult {
           for step in 0..<nSteps {
               state = await self.step(state)

               // Smart sampling
               if await sampler.shouldSample(state) {
                   timeSeries.append(TimePoint(from: state))
               }
           }
       }
   }
   ```

4. **Update PlotData to use real data** (1 day)
   ```swift
   // Remove zero-filling, use actual transport/sources
   self.chiTotalIon = timeSeries.map { $0.transport!.chiIon }
   ```

5. **Compute advanced derived metrics** (3 days)
   ```swift
   extension DerivedQuantities {
       // Now we can compute τE, Q, βN using transport/sources
       let P_loss = computeTransportLoss(transport, profiles, geometry)
       self.tau_E = W_thermal / P_loss
       self.Q = P_fusion / P_auxiliary
   }
   ```

**Phase 3 Complete When**:
- [ ] Transport coefficients saved
- [ ] Source terms saved
- [ ] Adaptive sampling works
- [ ] PlotData has real (non-zero) transport/source data
- [ ] τE, Q, βN computed correctly

**Total Time**: 10 days (2 weeks)

---

### Phase 4: Advanced Visualizations (Week 6-7)

(Continue with existing Phase 2-5 content...)

**Deliverable**: Performance dashboard, diagnostics dashboard, full profile viewer

---

## Implementation Dependencies

```
Phase 0 (Current)
  └─ Basic profiles work

Phase 1 (Infrastructure)
  ├─ Step 1: Type definitions
  ├─ Step 2: SimulationState extension (depends on Step 1)
  ├─ Step 3: Serialization (depends on Step 2)
  ├─ Step 4: PlotData conversion (depends on Step 3)
  └─ Step 5: Sampling config (depends on Step 4)

Phase 2 (Scalar Metrics)
  ├─ DerivedQuantities computation (depends on Phase 1)
  ├─ Orchestrator capture (depends on DerivedQuantities)
  └─ TimeSeriesDashboard (depends on captured data)

Phase 3 (Full Physics)
  ├─ Transport capture (depends on Phase 2)
  ├─ Sources capture (depends on Phase 2)
  ├─ Adaptive sampling (depends on Phase 2)
  └─ Advanced metrics (depends on transport/sources)

Phase 4+ (Advanced)
  └─ All depend on Phase 3 completion
```

### Phase 2: Profile Analysis (Week 3-4) - P1

**Goal**: Complete 1D profile visualization

#### Tasks:
1. ⚠️ **Profile group views** - Temperature, magnetic, transport, current, heating
2. ⚠️ **Multi-time comparison** - Overlay mode
3. ⚠️ **Profile animation** - Time evolution playback
4. ⚠️ **DiagnosticsDashboard** - Convergence and conservation monitoring

**Deliverable**: Interactive profile viewer with all physics quantities

### Phase 3: Performance Metrics (Week 5) - P1

**Goal**: High-level performance evaluation

#### Tasks:
1. ⚠️ **PerformanceDashboard** - Confinement, beta, fusion metrics
2. ⚠️ **Scaling law comparison** - ITER89-P, H98(y,2)
3. ⚠️ **Target tracking** - Visual indicators for ITER goals

**Deliverable**: Performance dashboard with Q, τE, βN, f_bs

### Phase 4: 2D Visualization (Week 6-7) - P2

**Goal**: Poloidal cross-section visualization

#### Tasks:
1. ⚠️ **PlotData3D → 2D slice** - Extract (R,Z) from 3D data
2. ⚠️ **Contour renderer** - Custom Canvas implementation
3. ⚠️ **Flux surface overlay** - Magnetic field structure
4. ⚠️ **Vector field rendering** - Poloidal field arrows

**Deliverable**: (R,Z) temperature/density contour plots

### Phase 5: 3D Visualization (Future) - P3

**Goal**: Publication-quality 3D rendering

#### Tasks:
1. ⚠️ **Evaluate Chart3D** - When macOS 26 is released
2. ⚠️ **RealityKit prototype** - Alternative implementation
3. ⚠️ **Iso-surface generation** - Marching cubes algorithm
4. ⚠️ **VR/AR support** - visionOS compatibility

**Deliverable**: Interactive 3D tokamak visualization

---

## 5. Testing Strategy

### 5.1 Unit Tests

```swift
// Tests/GotenxUITests/VisualizationTests.swift

@Test("DerivedQuantities computation accuracy")
func testDerivedQuantitiesAccuracy() async throws {
    let profiles = createTestProfiles()
    let geometry = Geometry(config: .iterLike)

    let derived = DerivedQuantities(
        from: profiles,
        transport: nil,
        sources: nil,
        geometry: geometry
    )

    // Verify central temperature extraction
    let expectedTi = profiles.ionTemperature.value[0].item(Float.self)
    #expect(abs(derived.Ti_core - expectedTi) < 1e-6)

    // Verify volume averaging
    let expectedNe_avg = computeVolumeAverage(
        profiles.electronDensity.value,
        geometry: geometry
    )
    #expect(abs(derived.ne_avg - expectedNe_avg) < 1e-5)
}

@Test("Conservation diagnostics tracking")
func testConservationTracking() async throws {
    let initialState = createTestState()
    let finalState = evolveState(initialState, steps: 100)

    let diagnostics = NumericalDiagnostics(
        from: finalState,
        initial: initialState
    )

    // Particle conservation within 1%
    #expect(abs(diagnostics.particle_drift) < 0.01)

    // Energy conservation within 1%
    #expect(abs(diagnostics.energy_drift) < 0.01)
}
```

### 5.2 Integration Tests

```swift
@Test("End-to-end visualization pipeline")
func testVisualizationPipeline() async throws {
    // Run mini simulation
    let config = SimulationConfig.testConfig
    let result = try await SimulationRunner.run(config)

    // Convert to PlotData
    let plotData = try PlotData(from: result)

    // Verify all fields populated
    #expect(plotData.Ti.count > 0)
    #expect(plotData.chiTotalIon.count > 0)  // Not zeros!
    #expect(plotData.ohmicHeatSource.count > 0)  // Not zeros!

    // Verify derived quantities
    #expect(plotData.IpProfile.allSatisfy { $0 > 0 })
}
```

### 5.3 Visual Regression Tests

```swift
@Test("ProfileViewer snapshot")
func testProfileViewerSnapshot() async throws {
    let data = createMockPlotData()
    let view = ProfileViewer(data: data)

    // Render to image
    let snapshot = view.snapshot(size: CGSize(width: 800, height: 600))

    // Compare with reference
    let reference = loadReferenceImage("profile_viewer_baseline.png")
    let similarity = computeImageSimilarity(snapshot, reference)

    #expect(similarity > 0.99)  // 99% match
}
```

---

## 6. Performance Considerations

### 6.1 Real-time Updates

**Challenge**: Update visualizations during simulation without blocking

**Solution**: Async callbacks with rate limiting
```swift
actor SimulationOrchestrator {
    func run(
        config: SimulationConfig,
        progressCallback: @Sendable (ProgressInfo) async -> Void
    ) async throws -> SimulationResult {
        var lastUpdateTime = Date()

        for step in 0..<nSteps {
            state = solver.step(state)

            // Rate-limited progress updates (max 10 Hz)
            if Date().timeIntervalSince(lastUpdateTime) > 0.1 {
                let info = ProgressInfo(from: state)
                await progressCallback(info)
                lastUpdateTime = Date()
            }
        }
    }
}
```

### 6.2 Large Dataset Handling

**Challenge**: 100,000 timesteps × 100 cells = 10M data points

**Solution**: Adaptive downsampling
```swift
struct AdaptiveSampler {
    func downsample(
        _ data: [Float],
        targetPoints: Int
    ) -> [Float] {
        guard data.count > targetPoints else { return data }

        // Largest-Triangle-Three-Buckets (LTTB) algorithm
        // Preserves visual features while reducing points
        return lttb(data, targetCount: targetPoints)
    }
}
```

### 6.3 Chart Rendering Performance

**Optimization**: Use Chart `.chartPlotStyle` modifiers
```swift
Chart {
    // ... data
}
.chartPlotStyle { plotContent in
    plotContent
        .background(.white)
        .border(Color.gray, width: 1)
}
.drawingGroup()  // GPU-accelerated rendering
```

---

## 7. Accessibility & Usability

### 7.1 Color Schemes

**Colorblind-Safe Palettes**:
- Temperature: Blue (cold) → Red (hot)
- Density: White (low) → Dark Blue (high)
- Current: Purple → Yellow (diverging)

**Implementation**:
```swift
extension Color {
    static func temperatureScale(value: Float, range: ClosedRange<Float>) -> Color {
        let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

        // Viridis-like colormap (colorblind-safe)
        return Color(
            red: viridisR(normalized),
            green: viridisG(normalized),
            blue: viridisB(normalized)
        )
    }
}
```

### 7.2 Keyboard Navigation

- ← → : Navigate time slider
- Space: Play/pause animation
- Cmd+S: Export current view
- Cmd+C: Copy data to clipboard

### 7.3 Export Formats

- **PNG/PDF**: High-resolution figures
- **CSV**: Raw data for external analysis
- **JSON**: Complete state snapshot
- **HDF5**: Large-scale data archival

---

## 8. Documentation Requirements

### 8.1 User Guide

**Topics**:
1. Quick Start: Running first simulation + viewing results
2. Dashboard Tour: Understanding each metric
3. Profile Analysis: Interpreting 1D plots
4. Performance Evaluation: Using metrics dashboard
5. Comparison Mode: Multi-case analysis
6. Export & Publication: Generating figures

### 8.2 API Documentation

**Required DocC Articles**:
- "Visualization Architecture Overview"
- "Creating Custom Plot Configurations"
- "Understanding Performance Metrics"
- "Data Export and Integration"

### 8.3 Physics Reference

**Required Sections**:
- Confinement scaling laws (ITER89-P, H98)
- Beta limits (Troyon, ideal MHD)
- Bootstrap current theory
- Transport coefficient interpretation

---

## 9. Summary & Next Steps

### Current Status
- ✅ Basic PlotData structure
- ✅ 1D profile display for Ti, Te, ne
- ✅ PlotData3D physics model
- ⚠️ Missing: transport, sources, derived quantities
- ⚠️ Missing: time series dashboard
- ⚠️ Missing: diagnostics monitoring

### Immediate Next Steps (Phase 1)

1. **Enhance SimulationState** (Priority: P0)
   - Add `transport`, `sources`, `geometry`, `derived`, `diagnostics` fields
   - Update `SimulationOrchestrator` to populate these fields
   - Modify serialization to include all data

2. **Implement DerivedQuantities** (Priority: P0)
   - Central/averaged values computation
   - Performance metrics calculation
   - Conservation monitoring

3. **Create TimeSeriesDashboard** (Priority: P0)
   - Real-time 0D monitoring
   - Core temperature, energy, Q tracking
   - Progress indicators

4. **Update PlotData conversion** (Priority: P0)
   - Use real transport/source data
   - Remove zero-filled placeholders
   - Add derived quantities time series

### Success Criteria

**Phase 1 Complete** when:
- [ ] Researcher can monitor Ti_core, W_total, Q in real-time
- [ ] SimulationResult contains full physics state
- [ ] PlotData has real (non-zero) transport and source data
- [ ] All P0 visualizations functional

**Phase 2 Complete** when:
- [ ] All 1D profile groups viewable
- [ ] Multi-time comparison works
- [ ] Convergence diagnostics displayed
- [ ] All P1 visualizations functional

**Production Ready** when:
- [ ] All P0 + P1 features implemented
- [ ] Unit tests pass (>90% coverage)
- [ ] Integration tests pass
- [ ] User documentation complete
- [ ] Performance validated (< 100ms render time)

---

## 10. Known Limitations and Open Questions

### 10.1 Implementation-Design Gap

**Current Status** (as of 2025-01-20): The design document describes the **target architecture**. The actual implementation has significant gaps:

#### High Priority Gaps

1. **SimulationState Missing Fields**
   - **Issue**: `SimulationState` only tracks `profiles`, `timeAccumulator`, `dt`, `step`, `statistics`
   - **Impact**: Cannot capture transport coefficients, source terms, or derived metrics
   - **Location**: `Sources/Gotenx/Orchestration/SimulationState.swift:12-120`
   - **Solution**: See Phase 1 roadmap (Section 4)

2. **PlotData Zero-Filled Fields**
   - **Issue**: All non-profile fields are filled with zeros
   - **Impact**: Transport, current, heating visualizations show blank charts
   - **Location**: `Sources/GotenxUI/Models/PlotData.swift:205-278`
   - **Solution**: See Phase 1.5 (backward-compatible fallback)

3. **Missing Core Types**
   - **Issue**: `DerivedQuantities`, `NumericalDiagnostics`, `PerformanceMetrics`, `TimeSeriesData` do not exist
   - **Impact**: Cannot compute or display confinement metrics (τE, Q, βN)
   - **Solution**: See Phase 1.1-1.2 (minimal type creation)

#### Medium Priority Gaps

4. **SerializableProfiles Limited Scope**
   - **Issue**: `TimePoint` only wraps `SerializableProfiles` (4 fields)
   - **Impact**: Cannot serialize full physics state
   - **Location**: `Sources/Gotenx/Orchestration/SimulationState.swift:282-289`
   - **Solution**: See Phase 1.4 (enhanced serialization)

5. **No Sampling Configuration**
   - **Issue**: Captures all timesteps or none (binary choice)
   - **Impact**: Memory explosion for long simulations
   - **Solution**: See Section 3.5 + Phase 1.6

### 10.2 Open Questions

#### Q1: Memory and I/O Strategy

**Question**: Capturing all transport, source, and derived data every timestep could explode memory and I/O. Do we plan to sample/decimate the time series on the solver side, or should the visualization layer own adaptive downsampling before persisting results?

**Answer**: **Tiered sampling strategy** (Section 3.5):
- **Tier 1 (Always)**: 0D scalar metrics (DerivedQuantities, NumericalDiagnostics) - cheap, essential
- **Tier 2 (Sampled)**: 1D profiles (TransportCoefficients, SourceTerms) - configurable interval
- **Tier 3 (On-demand)**: 2D/3D spatial data - computed from saved 1D when needed

**Implementation**:
- Solver side: Implements `SamplingConfig` and `AdaptiveSampler`
- Visualization layer: Receives pre-sampled data, no additional downsampling
- Rationale: Solver knows physics better (when to sample), visualization knows display better (how to render)

**Memory Budget**:
| Use Case | Sampling Interval | Memory |
|----------|------------------|---------|
| Real-time monitoring | Every 200 steps | 30 MB |
| Detailed analysis | Every 20 steps | 300 MB |
| Publication | Every 10 steps | 600 MB |

#### Q2: Backward Compatibility

**Question**: How do we add new fields without breaking existing simulations?

**Answer**: **Optional fields + graceful fallbacks**:
```swift
public struct SimulationState: Sendable {
    public let profiles: CoreProfiles  // Required (always exists)

    // NEW: Optional (nil for old simulations)
    public let transport: TransportCoefficients?
    public let derived: DerivedQuantities?
}

// PlotData conversion
if let transport = timeSeries.first?.transport {
    self.chiTotalIon = timeSeries.map { $0.transport!.chiIon }
} else {
    self.chiTotalIon = zeroProfiles  // Fallback for old data
}
```

#### Q3: Performance Impact

**Question**: Does computing DerivedQuantities at every timestep slow down simulation?

**Answer**: **Negligible impact** (<1%):
- Computation: ~100 scalar operations (Ti_core, ne_avg, W_thermal)
- Cost: ~1 μs per timestep
- Context: Solver takes ~10 ms per timestep (Newton-Raphson)
- Overhead: 1 μs / 10,000 μs = 0.01%

**Optimization**: Can defer expensive metrics (τE, Q) to post-processing if needed.

#### Q4: Disk Space for Long Simulations

**Question**: 100-second simulation with full capture → 2.4 GB. Acceptable?

**Answer**: **Depends on use case**:
- **Acceptable**: Single production runs, parameter scans (10-100 cases)
- **Problematic**: Ensemble studies (1000+ cases), real-time monitoring

**Solutions**:
1. **Compression**: HDF5 with gzip (5-10× reduction → 240-480 MB)
2. **Selective storage**: Save full data only for "interesting" cases
3. **Streaming**: Memory-mapped I/O, delete intermediate steps

**Recommendation**: Start with fixed sampling (Phase 1), add compression (Phase 3), consider memory-mapping (Phase 5).

### 10.3 Future Work Beyond This Document

1. **Multi-run comparison**: Compare 2-10 simulations side-by-side
2. **Animation export**: Save profile evolution as MP4/GIF
3. **Interactive 3D**: visionOS support with hand tracking
4. **Cloud storage**: Export directly to S3/CloudKit
5. **Jupyter integration**: Python bindings for notebook visualization

### 10.4 Design vs. Implementation Reconciliation Plan

**Critical**: Do NOT attempt to implement the full design immediately.

**Correct approach**:
1. ✅ **Phase 1** (Week 1-2): Infrastructure only, all fields optional
2. ✅ **Phase 2** (Week 3): Scalar metrics only (DerivedQuantities)
3. ✅ **Phase 3** (Week 4-5): Full physics state (transport, sources)
4. ⏳ **Phase 4+**: Advanced visualizations

**Anti-pattern** (will fail):
```swift
// ❌ DON'T: Try to populate everything at once
struct SimulationState {
    let transport: TransportCoefficients  // Required but not implemented!
}
// Result: Compilation errors, test failures, blocked progress
```

**Correct pattern**:
```swift
// ✅ DO: Optional fields, gradual enablement
struct SimulationState {
    let transport: TransportCoefficients?  // Optional during transition
}

// Phase 1: Always nil
return SimulationState(..., transport: nil)

// Phase 3: Populated
return SimulationState(..., transport: computedTransport)
```

---

## Appendix A: References

1. **ITER Physics Basis** - Nucl. Fusion 39 (1999) 2137
2. **Gotenx Paper** - arXiv:2406.06718v2
3. **H98(y,2) Scaling** - Nucl. Fusion 39 (1999) 2175
4. **Troyon Beta Limit** - Plasma Phys. Control. Fusion 26 (1984) 209
5. **Swift Charts Documentation** - https://developer.apple.com/documentation/charts

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **ρ** | Normalized minor radius (0 at center, 1 at edge) |
| **τE** | Energy confinement time [s] |
| **Q** | Fusion gain = P_fusion / P_auxiliary |
| **βN** | Normalized beta = β(%) × a(m) × B(T) / Ip(MA) |
| **f_bs** | Bootstrap fraction = I_bootstrap / I_plasma |
| **χ** | Heat diffusivity [m²/s] |
| **ITB** | Internal Transport Barrier |
| **LCFS** | Last Closed Flux Surface |
| **NTM** | Neoclassical Tearing Mode |

---

**Document Version**: 1.0
**Last Updated**: 2025-01-20
**Authors**: Gotenx Development Team
**Status**: Design Phase - Ready for Implementation
