// PlotData3DTests.swift
// Unit tests for PlotData3D model

import Testing
import Foundation
@testable import GotenxUI

@Suite("PlotData3D Tests")
struct PlotData3DTests {

    // MARK: - Coordinate System Tests

    @Test("Circular cross-section coordinate generation")
    func testCircularCrossSection() {
        let nTheta = 8
        let geometry = GeometryParams(majorRadius: 6.0, minorRadius: 2.0)

        let mockPlotData = createMockPlotData(nCells: 3, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: nTheta, nPhi: 4, geometry: geometry)

        // Check that we have nCells * nTheta poloidal points
        #expect(plotData3D.nPoints == 3 * 8)
        #expect(plotData3D.r.count == 24)
        #expect(plotData3D.z.count == 24)

        // Check first point (ρ=0, θ=0) should be at (R₀, 0)
        #expect(abs(plotData3D.r[0] - geometry.majorRadius) < 1e-6)
        #expect(abs(plotData3D.z[0]) < 1e-6)

        // Check outboard midplane point (ρ=1, θ=0) should be at (R₀+a, 0)
        let lastRhoFirstTheta = (3 - 1) * nTheta  // (nCells-1) * nTheta
        #expect(abs(plotData3D.r[lastRhoFirstTheta] - (geometry.majorRadius + geometry.minorRadius)) < 1e-5)
        #expect(abs(plotData3D.z[lastRhoFirstTheta]) < 1e-5)
    }

    @Test("Toroidal angle grid generation")
    func testToroidalGrid() {
        let nPhi = 8
        let geometry = GeometryParams.iterLike

        let mockPlotData = createMockPlotData(nCells: 5, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: nPhi, geometry: geometry)

        // Check phi coordinate (should span 0 to 2π)
        #expect(plotData3D.phi.count == nPhi)
        #expect(plotData3D.phi.first! == 0.0)

        let expectedLastPhi = 2.0 * Float.pi * Float(nPhi - 1) / Float(nPhi)
        #expect(abs(plotData3D.phi.last! - expectedLastPhi) < 1e-5)
    }

    @Test("Toroidal symmetry assumption")
    func testToroidalSymmetry() {
        let nPhi = 4
        let geometry = GeometryParams.iterLike

        let mockPlotData = createMockPlotData(nCells: 5, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: nPhi, geometry: geometry)

        // Extract temperature at fixed poloidal point for all phi
        let iPoloidal = 10  // Arbitrary poloidal point

        let tempAtDifferentPhi = (0..<nPhi).map { iPhi in
            plotData3D.temperature[0][iPoloidal][iPhi]
        }

        // All phi values should be the same (toroidal symmetry)
        let referenceTemp = tempAtDifferentPhi[0]
        for temp in tempAtDifferentPhi {
            #expect(abs(temp - referenceTemp) < 1e-6)
        }
    }

    // MARK: - Physical Calculations Tests

    @Test("Pressure calculation from ideal gas law")
    func testPressureCalculation() {
        let geometry = GeometryParams.iterLike

        // Create data with known values
        let mockPlotData = createMockPlotData(
            nCells: 5,
            nTime: 1,
            tempValues: [10.0, 8.0, 6.0, 4.0, 2.0],  // keV
            densityValues: [5.0, 4.0, 3.0, 2.0, 1.0]  // 10^20 m^-3
        )

        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: 2, geometry: geometry)

        // Check pressure at first radial point (ρ=0)
        // P = n * T * 1.380649e-4  [kPa]
        // P(ρ=0) = 5.0 * 10.0 * 1.380649e-4 = 0.00690 kPa
        let expectedPressure: Float = 5.0 * 10.0 * 1.380649e-4
        let actualPressure = plotData3D.pressure[0][0][0]  // First time, first point, first phi

        #expect(abs(actualPressure - expectedPressure) < 1e-5)
    }

    @Test("Geometry parameters calculations")
    func testGeometryCalculations() {
        let geometry = GeometryParams(majorRadius: 6.0, minorRadius: 2.0)

        // Aspect ratio
        #expect(geometry.aspectRatio == 3.0)

        // Volume for circular cross-section: V = 2π²·R₀·a²
        let expectedVolume = 2.0 * Float.pi * Float.pi * 6.0 * 2.0 * 2.0
        #expect(abs(geometry.volume - expectedVolume) < 1e-4)
    }

    // MARK: - Volumetric Point Extraction Tests

    @Test("Volumetric point extraction")
    func testVolumetricPoints() {
        let nRho = 3
        let nTheta = 4
        let nPhi = 2
        let geometry = GeometryParams(majorRadius: 6.0, minorRadius: 2.0)

        let mockPlotData = createMockPlotData(nCells: nRho, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: nTheta, nPhi: nPhi, geometry: geometry)

        let points = plotData3D.volumetricPoints(timeIndex: 0)

        // Total number of points = nRho × nTheta × nPhi
        let expectedCount = nRho * nTheta * nPhi
        #expect(points.count == expectedCount)

        // Check that all points have valid coordinates
        for point in points {
            #expect(point.r > 0)
            #expect(point.phi >= 0 && point.phi < 2 * Float.pi)
            #expect(point.temperature >= 0)
            #expect(point.density >= 0)
            #expect(point.pressure >= 0)
        }
    }

    @Test("VolumetricPoint helper methods")
    func testVolumetricPointHelpers() {
        let geometry = GeometryParams(majorRadius: 6.0, minorRadius: 2.0)

        // Point at outboard midplane (θ=0) at ρ=0.5
        let r: Float = 6.0 + 0.5 * 2.0 * cos(0)  // = 7.0
        let z: Float = 0.5 * 2.0 * sin(0)        // = 0.0

        let point = VolumetricPoint(
            r: r,
            z: z,
            phi: 0,
            temperature: 10.0,
            density: 5.0,
            pressure: 0.0069
        )

        // Minor radius from axis
        let minorRad = point.minorRadius(geometry: geometry)
        #expect(abs(minorRad - 1.0) < 1e-5)  // Should be 1.0 m (0.5 * 2.0)

        // Normalized radius
        let rho = point.normalizedRadius(geometry: geometry)
        #expect(abs(rho - 0.5) < 1e-5)

        // Poloidal angle
        let theta = point.poloidalAngle(geometry: geometry)
        #expect(abs(theta) < 1e-5)  // Should be 0 (outboard midplane)
    }

    @Test("Range calculations for color mapping")
    func testColorMappingRanges() {
        let mockPlotData = createMockPlotData(
            nCells: 5,
            nTime: 2,
            tempValues: [1.0, 5.0, 10.0, 15.0, 20.0]
        )
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: 4, geometry: .iterLike)

        // Temperature range
        let tempRange = plotData3D.temperatureRange
        #expect(tempRange.lowerBound <= 1.0)
        #expect(tempRange.upperBound >= 20.0)

        // Density range
        let densityRange = plotData3D.densityRange
        #expect(densityRange.lowerBound >= 0)
        #expect(densityRange.upperBound > 0)

        // Pressure range
        let pressureRange = plotData3D.pressureRange
        #expect(pressureRange.lowerBound >= 0)
        #expect(pressureRange.upperBound > 0)
    }

    // MARK: - Edge Case Tests

    @Test("Single radial point")
    func testSingleRadialPoint() {
        let mockPlotData = createMockPlotData(nCells: 1, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: 4, geometry: .iterLike)

        #expect(plotData3D.nRho == 1)
        #expect(plotData3D.nTheta == 4)
        #expect(plotData3D.nPoints == 4)
    }

    @Test("Single poloidal point")
    func testSinglePoloidalPoint() {
        let mockPlotData = createMockPlotData(nCells: 5, nTime: 1)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 1, nPhi: 4, geometry: .iterLike)

        #expect(plotData3D.nTheta == 1)
        #expect(plotData3D.nPoints == 5)
    }

    @Test("Out of bounds time index returns empty points")
    func testOutOfBoundsTimeIndex() {
        let mockPlotData = createMockPlotData(nCells: 5, nTime: 2)
        let plotData3D = PlotData3D(from: mockPlotData, nTheta: 4, nPhi: 4, geometry: .iterLike)

        let points = plotData3D.volumetricPoints(timeIndex: 999)

        #expect(points.isEmpty)
    }

    // MARK: - Mock Data Helpers

    private func createMockPlotData(
        nCells: Int,
        nTime: Int,
        tempValues: [Float]? = nil,
        densityValues: [Float]? = nil
    ) -> PlotData {
        let rho = (0..<nCells).map { Float($0) / Float(max(nCells - 1, 1)) }
        let time = (0..<nTime).map { Float($0) * 0.01 }

        let defaultTemp = tempValues ?? Array(repeating: 10.0 as Float, count: nCells)
        let defaultDensity = densityValues ?? Array(repeating: 5.0 as Float, count: nCells)

        let Ti: [[Float]] = Array(repeating: defaultTemp, count: nTime)
        let Te: [[Float]] = Array(repeating: defaultTemp, count: nTime)
        let ne: [[Float]] = Array(repeating: defaultDensity, count: nTime)

        let zeroProfile: [Float] = Array(repeating: 0.0 as Float, count: nCells)
        let zeroProfiles: [[Float]] = Array(repeating: zeroProfile, count: nTime)
        let zeroScalar: [Float] = Array(repeating: 0.0 as Float, count: nTime)

        return PlotData(
            rho: rho,
            time: time,
            Ti: Ti,
            Te: Te,
            ne: ne,
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
