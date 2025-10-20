// DisplayUnitsTests.swift
// Tests for display unit conversions

import Testing
import Foundation
@testable import GotenxCLI

@Suite("Display Unit Conversion Tests")
struct DisplayUnitsTests {

    // MARK: - Temperature Conversion Tests

    @Test("Temperature: eV → keV conversion (Float)")
    func testTemperatureEvToKeVFloat() {
        let eV: Float = 1000.0
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV - 1.0) < 1e-6)
    }

    @Test("Temperature: eV → keV conversion (Double)")
    func testTemperatureEvToKeVDouble() {
        let eV: Double = 2000.0
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV - 2.0) < 1e-9)
    }

    @Test("Temperature: eV → keV array conversion (Float)")
    func testTemperatureEvToKeVArrayFloat() {
        let eV: [Float] = [100.0, 1000.0, 10000.0]
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV[0] - 0.1) < 1e-6)
        #expect(abs(keV[1] - 1.0) < 1e-6)
        #expect(abs(keV[2] - 10.0) < 1e-6)
    }

    @Test("Temperature: eV → keV array conversion (Double)")
    func testTemperatureEvToKeVArrayDouble() {
        let eV: [Double] = [100.0, 1000.0, 10000.0]
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV[0] - 0.1) < 1e-9)
        #expect(abs(keV[1] - 1.0) < 1e-9)
        #expect(abs(keV[2] - 10.0) < 1e-9)
    }

    @Test("Temperature: keV → eV reverse conversion (Float)")
    func testTemperatureKeVToEvFloat() {
        let keV: Float = 1.5
        let eV = DisplayUnits.fromKeV(keV)
        #expect(abs(eV - 1500.0) < 1e-3)
    }

    @Test("Temperature: keV → eV reverse conversion (Double)")
    func testTemperatureKeVToEvDouble() {
        let keV: Double = 1.5
        let eV = DisplayUnits.fromKeV(keV)
        #expect(abs(eV - 1500.0) < 1e-6)
    }

    // MARK: - Density Conversion Tests

    @Test("Density: m^-3 → 10^20 m^-3 conversion (Float)")
    func testDensityM3To1e20Float() {
        let m3: Float = 1e20
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20 - 1.0) < 1e-6)
    }

    @Test("Density: m^-3 → 10^20 m^-3 conversion (Double)")
    func testDensityM3To1e20Double() {
        let m3: Double = 3e19
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20 - 0.3) < 1e-9)
    }

    @Test("Density: m^-3 → 10^20 m^-3 array conversion (Float)")
    func testDensityM3To1e20ArrayFloat() {
        let m3: [Float] = [1e19, 1e20, 5e20]
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20[0] - 0.1) < 1e-6)
        #expect(abs(value1e20[1] - 1.0) < 1e-6)
        #expect(abs(value1e20[2] - 5.0) < 1e-6)
    }

    @Test("Density: m^-3 → 10^20 m^-3 array conversion (Double)")
    func testDensityM3To1e20ArrayDouble() {
        let m3: [Double] = [1e19, 1e20, 5e20]
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20[0] - 0.1) < 1e-9)
        #expect(abs(value1e20[1] - 1.0) < 1e-9)
        #expect(abs(value1e20[2] - 5.0) < 1e-9)
    }

    @Test("Density: 10^20 m^-3 → m^-3 reverse conversion (Float)")
    func testDensity1e20ToM3Float() {
        let value1e20: Float = 2.5
        let m3 = DisplayUnits.from1e20m3(value1e20)
        #expect(abs(m3 - 2.5e20) < 1e14)
    }

    @Test("Density: 10^20 m^-3 → m^-3 reverse conversion (Double)")
    func testDensity1e20ToM3Double() {
        let value1e20: Double = 2.5
        let m3 = DisplayUnits.from1e20m3(value1e20)
        #expect(abs(m3 - 2.5e20) < 1e6)
    }

    // MARK: - Round-Trip Conversion Tests

    @Test("Temperature round-trip conversion (eV → keV → eV)")
    func testTemperatureRoundTrip() {
        let originalEv: Float = 1234.5
        let keV = DisplayUnits.toKeV(originalEv)
        let backToEv = DisplayUnits.fromKeV(keV)
        #expect(abs(backToEv - originalEv) < 1e-3)
    }

    @Test("Density round-trip conversion (m^-3 → 10^20 m^-3 → m^-3)")
    func testDensityRoundTrip() {
        let originalM3: Float = 3.7e19
        let value1e20 = DisplayUnits.to1e20m3(originalM3)
        let backToM3 = DisplayUnits.from1e20m3(value1e20)
        #expect(abs(backToM3 - originalM3) < 1e13)
    }

    // MARK: - ProfileStats Extension Tests

    @Test("ProfileStats temperature display units conversion")
    func testProfileStatsTemperatureDisplayUnits() {
        let stats = ProfileStats(
            min: 100.0,   // eV
            max: 10000.0, // eV
            core: 8000.0, // eV
            edge: 100.0   // eV
        )

        let displayStats = stats.toDisplayUnits()

        #expect(abs(displayStats.min - 0.1) < 1e-9)     // 0.1 keV
        #expect(abs(displayStats.max - 10.0) < 1e-9)    // 10 keV
        #expect(abs(displayStats.core - 8.0) < 1e-9)    // 8 keV
        #expect(abs(displayStats.edge - 0.1) < 1e-9)    // 0.1 keV
    }

    @Test("ProfileStats density display units conversion")
    func testProfileStatsDensityDisplayUnits() {
        let stats = ProfileStats(
            min: 1e19,    // m^-3
            max: 5e20,    // m^-3
            core: 3e20,   // m^-3
            edge: 1e19    // m^-3
        )

        let displayStats = stats.toDisplayUnitsDensity()

        #expect(abs(displayStats.min - 0.1) < 1e-9)     // 0.1 × 10^20 m^-3
        #expect(abs(displayStats.max - 5.0) < 1e-9)     // 5.0 × 10^20 m^-3
        #expect(abs(displayStats.core - 3.0) < 1e-9)    // 3.0 × 10^20 m^-3
        #expect(abs(displayStats.edge - 0.1) < 1e-9)    // 0.1 × 10^20 m^-3
    }

    // MARK: - Edge Case Tests

    @Test("Temperature conversion with zero")
    func testTemperatureConversionZero() {
        let eV: Float = 0.0
        let keV = DisplayUnits.toKeV(eV)
        #expect(keV == 0.0)
    }

    @Test("Density conversion with zero")
    func testDensityConversionZero() {
        let m3: Float = 0.0
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(value1e20 == 0.0)
    }

    @Test("Temperature conversion with very small value")
    func testTemperatureConversionSmallValue() {
        let eV: Float = 1.0  // 1 eV
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV - 0.001) < 1e-6)  // 0.001 keV
    }

    @Test("Density conversion with very small value")
    func testDensityConversionSmallValue() {
        let m3: Float = 1e18  // 10^18 m^-3
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20 - 0.01) < 1e-9)  // 0.01 × 10^20 m^-3
    }

    @Test("Temperature conversion with very large value")
    func testTemperatureConversionLargeValue() {
        let eV: Float = 1e6  // 1 MeV in eV
        let keV = DisplayUnits.toKeV(eV)
        #expect(abs(keV - 1000.0) < 1e-3)  // 1000 keV = 1 MeV
    }

    @Test("Density conversion with very large value")
    func testDensityConversionLargeValue() {
        let m3: Float = 1e21  // 10^21 m^-3
        let value1e20 = DisplayUnits.to1e20m3(m3)
        #expect(abs(value1e20 - 10.0) < 1e-6)  // 10 × 10^20 m^-3
    }
}
