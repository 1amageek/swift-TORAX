// ToraxPlotView.swift
// 2D plotting with Swift Charts

import SwiftUI
import Charts

// MARK: - Main Plot View

/// 2D plot view for Gotenx simulation data
public struct ToraxPlotView: View {
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

            // Chart
            switch config.plot.type {
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
            case .plasmaCurrent:
                PlasmaCurrentChart(data: data, config: config)
            case .fusionPower:
                FusionPowerChart(data: data, config: config)
            case .energyBalance:
                EnergyBalanceChart(data: data, config: config)
            case .temperature3D, .density3D, .pressure3D:
                Text("3D plots require ToraxPlot3DView")
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

// MARK: - Temperature and Density Chart

struct TempDensityChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            // Ion temperature
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("Ti", data.Ti[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#FF6B6B"))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: lineDash(for: config.plot.lineStyles[safe: 0])))
            }
            .accessibilityLabel("Ion Temperature")

            // Electron temperature
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("Te", data.Te[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#4ECDC4"))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: lineDash(for: config.plot.lineStyles[safe: 1])))
            }
            .accessibilityLabel("Electron Temperature")

            // Electron density (scaled)
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("ne", data.ne[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 2] ?? "#45B7D1"))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: lineDash(for: config.plot.lineStyles[safe: 2])))
            }
            .accessibilityLabel("Electron Density")
        }
        .chartXAxis {
            AxisMarks(position: .bottom)
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Current Density Chart

struct CurrentDensityChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            // Total current
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("j_total", data.jTotal[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#000000"))
            }
            .accessibilityLabel("Total Current")

            // Ohmic current
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("j_ohmic", data.jOhmic[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#FF6B6B"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("Ohmic Current")

            // Bootstrap current
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("j_bootstrap", data.jBootstrap[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 2] ?? "#4ECDC4"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("Bootstrap Current")

            // ECRH current
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("j_ecrh", data.jECRH[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 3] ?? "#FFA07A"))
                .lineStyle(StrokeStyle(dash: [2, 2]))
            }
            .accessibilityLabel("ECRH Current")
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Q Profile Chart

struct QProfileChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("q", data.q[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#9B59B6"))
            }
        }
        .chartLegend(.hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Psi Chart

struct PsiChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("ψ", data.psi[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#E74C3C"))
            }
        }
        .chartLegend(.hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Chi Chart

struct ChiChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            // Ion χ
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("χ_i", data.chiTotalIon[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#E74C3C"))
            }
            .accessibilityLabel("Ion Heat Diffusivity")

            // Electron χ
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("χ_e", data.chiTotalElectron[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#3498DB"))
            }
            .accessibilityLabel("Electron Heat Diffusivity")
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Diffusivity Chart

struct DiffusivityChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("D", data.dFace[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#1ABC9C"))
            }
        }
        .chartLegend(.hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Heat Sources Chart

struct HeatSourcesChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            // Ohmic heating
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("Ohmic", data.ohmicHeatSource[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#E67E22"))
            }
            .accessibilityLabel("Ohmic Heating")

            // Fusion heating
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("Fusion", data.fusionHeatSource[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#9B59B6"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("Fusion Heating")

            // ICRH ion heating
            ForEach(Array(data.rho.enumerated()), id: \.offset) { index, rho in
                LineMark(
                    x: .value("ρ", rho),
                    y: .value("ICRH", data.pICRHIon[timeIndex][index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 2] ?? "#1ABC9C"))
                .lineStyle(StrokeStyle(dash: [2, 2]))
            }
            .accessibilityLabel("ICRH Heating")
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Particle Sources Chart

struct ParticleSourcesChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var timeIndex: Int {
        config.plot.timeIndex < 0 ? data.nTime - 1 : min(config.plot.timeIndex, data.nTime - 1)
    }

    var body: some View {
        Chart {
            // Placeholder: Currently no particle sources in PlotData
            // Will be implemented when particle source data is available
        }
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Plasma Current Chart

struct PlasmaCurrentChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var body: some View {
        Chart {
            // Total plasma current
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("Ip", data.IpProfile[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#000000"))
            }
            .accessibilityLabel("Total Plasma Current")

            // Bootstrap current
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("Ibs", data.IBootstrap[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#E74C3C"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("Bootstrap Current")

            // ECRH current
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("IECRH", data.IECRH[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 2] ?? "#3498DB"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("ECRH Current")
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Fusion Power Chart

struct FusionPowerChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var body: some View {
        Chart {
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("Q", data.qFusion[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#27AE60"))
            }
        }
        .chartLegend(.hidden)
        .frame(height: config.figure.height * 0.7)
    }
}

// MARK: - Energy Balance Chart

struct EnergyBalanceChart: View {
    let data: PlotData
    let config: PlotConfiguration

    var body: some View {
        Chart {
            // Auxiliary power
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("P_aux", data.pAuxiliary[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 0] ?? "#E67E22"))
            }
            .accessibilityLabel("Auxiliary Power")

            // Alpha power
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("P_alpha", data.pAlphaTotal[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 1] ?? "#9B59B6"))
            }
            .accessibilityLabel("Alpha Power")

            // Ohmic power
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("P_ohmic", data.pOhmicE[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 2] ?? "#E74C3C"))
                .lineStyle(StrokeStyle(dash: [5, 5]))
            }
            .accessibilityLabel("Ohmic Power")

            // Radiation
            ForEach(Array(data.time.enumerated()), id: \.offset) { index, time in
                LineMark(
                    x: .value("Time", time),
                    y: .value("P_rad", data.pRadiation[index])
                )
                .foregroundStyle(Color(hex: config.plot.colors[safe: 3] ?? "#95A5A6"))
                .lineStyle(StrokeStyle(dash: [2, 2]))
            }
            .accessibilityLabel("Radiation Loss")
        }
        .chartLegend(config.plot.showLegend ? .visible : .hidden)
        .frame(height: config.figure.height * 0.7)
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
        ToraxPlotView(data: sampleData, config: config)

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

    ToraxPlotView(data: sampleData, config: config)
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

    ToraxPlotView(data: sampleData, config: config)
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

    ToraxPlotView(data: sampleData, config: config)
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
