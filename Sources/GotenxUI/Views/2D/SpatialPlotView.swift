// SpatialPlotView.swift
// Spatial profile charts (ρ-axis plots)

import SwiftUI
import Charts

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
