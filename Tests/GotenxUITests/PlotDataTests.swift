// PlotDataTests.swift
// Unit tests for PlotData model

import Testing
import Foundation
@testable import GotenxUI

@Suite("PlotData Tests")
struct PlotDataTests {

    // MARK: - Data Structure Tests

    @Test("PlotData initialization with valid data")
    func testPlotDataInitialization() {
        let plotData = createMockPlotData(nCells: 10, nTime: 5)

        #expect(plotData.nCells == 10)
        #expect(plotData.nTime == 5)
        #expect(plotData.rho.count == 10)
        #expect(plotData.time.count == 5)
    }

    @Test("Rho coordinate generation")
    func testRhoCoordinate() {
        let plotData = createMockPlotData(nCells: 10, nTime: 1)

        // Verify rho coordinate (normalized radius from 0 to 1)
        #expect(plotData.rho.first! == 0.0)
        #expect(plotData.rho.last! == 1.0)
        #expect(plotData.rho.count == 10)

        // Check spacing
        let expectedSpacing = 1.0 / Float(10 - 1)
        for i in 0..<9 {
            let spacing = plotData.rho[i + 1] - plotData.rho[i]
            #expect(abs(spacing - expectedSpacing) < 1e-6)
        }
    }

    @Test("Time range calculation")
    func testTimeRange() {
        let plotData = createMockPlotData(nCells: 5, nTime: 10)

        let range = plotData.timeRange
        #expect(range.lowerBound == plotData.time.first!)
        #expect(range.upperBound == plotData.time.last!)
    }

    @Test("Rho range calculation")
    func testRhoRange() {
        let plotData = createMockPlotData(nCells: 5, nTime: 1)

        let range = plotData.rhoRange
        #expect(range.lowerBound == 0.0)
        #expect(range.upperBound == 1.0)
    }

    // MARK: - Mock Data Helpers

    private func createMockPlotData(nCells: Int, nTime: Int) -> PlotData {
        let rho = (0..<nCells).map { Float($0) / Float(max(nCells - 1, 1)) }
        let time = (0..<nTime).map { Float($0) * 0.01 }

        let zeroProfile: [Float] = Array(repeating: 0.0 as Float, count: nCells)
        let zeroProfiles: [[Float]] = Array(repeating: zeroProfile, count: nTime)
        let zeroScalar: [Float] = Array(repeating: 0.0 as Float, count: nTime)

        return PlotData(
            rho: rho,
            time: time,
            Ti: zeroProfiles,
            Te: zeroProfiles,
            ne: zeroProfiles,
            q: zeroProfiles,
            magneticShear: zeroProfiles,
            psi: zeroProfiles,
            chiTotalIon: zeroProfiles,
            chiTotalElectron: zeroProfiles,
            chiTurbIon: zeroProfiles,
            chiTurbElectron: zeroProfiles,
            dFace: zeroProfiles,
            jTotal: zeroProfiles,
            jOhmic: zeroProfiles,
            jBootstrap: zeroProfiles,
            jECRH: zeroProfiles,
            ohmicHeatSource: zeroProfiles,
            fusionHeatSource: zeroProfiles,
            pICRHIon: zeroProfiles,
            pICRHElectron: zeroProfiles,
            pECRHElectron: zeroProfiles,
            IpProfile: zeroScalar,
            IBootstrap: zeroScalar,
            IECRH: zeroScalar,
            qFusion: zeroScalar,
            pAuxiliary: zeroScalar,
            pOhmicE: zeroScalar,
            pAlphaTotal: zeroScalar,
            pBremsstrahlung: zeroScalar,
            pRadiation: zeroScalar
        )
    }
}
