// GotenxPlotView.swift
// Main 2D plot view dispatcher

import SwiftUI
import Charts

// MARK: - Main Plot View

/// 2D plot view for Gotenx simulation data
///
/// Dispatches to appropriate chart views based on plot type:
/// - Spatial profiles (ρ-axis): SpatialPlotView.swift
/// - Time series (t-axis): TimeSeriesPlotView.swift
public struct GotenxPlotView: View {
    let data: PlotData
    let config: PlotConfiguration

    public init(data: PlotData, config: PlotConfiguration) {
        self.data = data
        self.config = config
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text(config.plot.title)
                .font(.title2)
                .fontWeight(.bold)

            // Chart dispatcher
            switch config.plot.type {
            // Spatial profiles (ρ-axis)
            case .tempDensity:
                TempDensityChart(data: data, config: config)
            case .currentDensity:
                CurrentDensityChart(data: data, config: config)
            case .qProfile:
                QProfileChart(data: data, config: config)
            case .psi:
                PsiChart(data: data, config: config)
            case .chiEffective, .chiComparison:
                ChiChart(data: data, config: config)
            case .particleDiffusivity:
                DiffusivityChart(data: data, config: config)
            case .heatSources:
                HeatSourcesChart(data: data, config: config)
            case .particleSources:
                ParticleSourcesChart(data: data, config: config)

            // Time series (t-axis)
            case .plasmaCurrent:
                PlasmaCurrentChart(data: data, config: config)
            case .fusionPower:
                FusionPowerChart(data: data, config: config)
            case .energyBalance:
                EnergyBalanceChart(data: data, config: config)

            // 3D plots (requires iOS 26.0+)
            case .temperature3D, .density3D, .pressure3D:
                Text("3D plots require GotenxPlot3DView")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, config.figure.margins.top)
        .padding(.leading, config.figure.margins.left)
        .padding(.bottom, config.figure.margins.bottom)
        .padding(.trailing, config.figure.margins.right)
        .frame(width: config.figure.width, height: config.figure.height)
        .background(Color(hex: config.figure.backgroundColor))
    }
}

// MARK: - Helper Extensions

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

func lineDash(for style: LineStyle?) -> [CGFloat] {
    switch style {
    case .solid, .none:
        return []
    case .dashed:
        return [10, 5]
    case .dotted:
        return [2, 2]
    case .dashDot:
        return [10, 5, 2, 5]
    }
}

// MARK: - Previews

#Preview("Temperature & Density Profile") {
    @Previewable @State var timeIndex: Int = 0

    let sampleData = PlotData.sampleITERLike()
    let config = PlotConfiguration(
        plot: PlotProperties(
            type: .tempDensity,
            title: "Temperature and Density Profiles",
            xLabel: "Normalized radius ρ",
            yLabel: "Temperature [keV] / Density [10²⁰ m⁻³]",
            showLegend: true,
            colors: ["#FF6B6B", "#4ECDC4", "#45B7D1"],
            lineStyles: [.solid, .solid, .dashed],
            timeIndex: timeIndex
        ),
        figure: FigureProperties(
            width: 800,
            height: 600,
            margins: FigureMargins(top: 20, right: 20, bottom: 40, left: 60)
        )
    )

    VStack {
        GotenxPlotView(data: sampleData, config: config)

        // Time slider
        HStack {
            Text("Time: \(sampleData.time[timeIndex], specifier: "%.2f") s")
                .font(.caption)
            Slider(value: Binding(
                get: { Double(timeIndex) },
                set: { timeIndex = Int($0) }
            ), in: 0...Double(sampleData.nTime - 1), step: 1)
        }
        .padding()
    }
}

#Preview("Current Density Profile") {
    let sampleData = PlotData.sampleITERLike()
    let config = PlotConfiguration(
        plot: PlotProperties(
            type: .currentDensity,
            title: "Current Density Profile",
            xLabel: "Normalized radius ρ",
            yLabel: "Current Density [MA/m²]",
            showLegend: true,
            timeIndex: -1  // Last timestep
        ),
        figure: FigureProperties()
    )

    GotenxPlotView(data: sampleData, config: config)
        .padding()
}

#Preview("Safety Factor q(ρ)") {
    let sampleData = PlotData.sampleITERLike()
    let config = PlotConfiguration(
        plot: PlotProperties(
            type: .qProfile,
            title: "Safety Factor Profile",
            xLabel: "Normalized radius ρ",
            yLabel: "Safety Factor q",
            showLegend: false,
            timeIndex: -1
        ),
        figure: FigureProperties()
    )

    GotenxPlotView(data: sampleData, config: config)
        .padding()
}

#Preview("Fusion Power Time Series") {
    let sampleData = PlotData.sampleITERLike()
    let config = PlotConfiguration(
        plot: PlotProperties(
            type: .fusionPower,
            title: "Fusion Gain Q",
            xLabel: "Time [s]",
            yLabel: "Fusion Gain Q",
            showLegend: false
        ),
        figure: FigureProperties()
    )

    GotenxPlotView(data: sampleData, config: config)
        .padding()
}

// MARK: - Sample Data for Previews

extension PlotData {
    /// Create ITER-like sample data for previews
    static func sampleITERLike() -> PlotData {
        let nCells = 50
        let nTime = 20

        // Normalized radius
        let rho = (0..<nCells).map { Float($0) / Float(nCells - 1) }

        // Time array
        let time = (0..<nTime).map { Float($0) * 0.1 }  // 0 to 2 seconds

        // Create realistic profiles
        func makeProfile(
            core: Float,
            edge: Float,
            peaking: Float = 2.0
        ) -> [Float] {
            rho.map { r in
                edge + (core - edge) * pow(1.0 - pow(r, peaking), 1.5)
            }
        }

        // Temperature profiles: peaked at core
        let Ti = (0..<nTime).map { t in
            let evolution = 1.0 + Float(t) / Float(nTime) * 0.5  // 50% increase
            return makeProfile(core: 15.0 * evolution, edge: 0.1, peaking: 2.0)
        }
        let Te = (0..<nTime).map { t in
            let evolution = 1.0 + Float(t) / Float(nTime) * 0.5
            return makeProfile(core: 12.0 * evolution, edge: 0.1, peaking: 2.0)
        }

        // Density profile: less peaked
        let ne = (0..<nTime).map { _ in
            makeProfile(core: 10.0, edge: 2.0, peaking: 1.0)
        }

        // Safety factor: q(0) ~ 1, q(edge) ~ 3.5
        let q = (0..<nTime).map { _ in
            rho.map { 1.0 + 2.5 * pow($0, 2.0) }
        }

        // Zero profiles for unimplemented features
        let zeros = (0..<nTime).map { _ in Array(repeating: Float(0), count: nCells) }

        // Time series: plasma current, fusion gain
        let IpProfile = (0..<nTime).map { Float(15.0 - Float($0) * 0.1) }  // 15 MA
        let qFusion = (0..<nTime).map { Float($0) < 10 ? Float($0) * 0.5 : 5.0 }  // Ramp to Q=5

        return PlotData(
            rho: rho,
            time: time,
            Ti: Ti,
            Te: Te,
            ne: ne,
            q: q,
            magneticShear: zeros,
            psi: zeros,
            chiTotalIon: zeros,
            chiTotalElectron: zeros,
            chiTurbIon: zeros,
            chiTurbElectron: zeros,
            dFace: zeros,
            jTotal: zeros,
            jOhmic: zeros,
            jBootstrap: zeros,
            jECRH: zeros,
            ohmicHeatSource: zeros,
            fusionHeatSource: zeros,
            pICRHIon: zeros,
            pICRHElectron: zeros,
            pECRHElectron: zeros,
            IpProfile: IpProfile,
            IBootstrap: Array(repeating: 5.0, count: nTime),
            IECRH: Array(repeating: 2.0, count: nTime),
            qFusion: qFusion,
            pAuxiliary: Array(repeating: 50.0, count: nTime),
            pOhmicE: Array(repeating: 10.0, count: nTime),
            pAlphaTotal: Array(repeating: 25.0, count: nTime),
            pBremsstrahlung: Array(repeating: 5.0, count: nTime),
            pRadiation: Array(repeating: 15.0, count: nTime)
        )
    }
}
