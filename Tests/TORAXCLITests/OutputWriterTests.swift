// OutputWriterTests.swift
// Tests for OutputWriter NetCDF functionality

import Testing
import Foundation
@testable import TORAXCLI
import TORAX

@Suite("OutputWriter Tests")
struct OutputWriterTests {

    @Test("NetCDF writer creates valid file with final profiles only")
    func testNetCDFWriterFinalProfiles() throws {
        // Create test data
        let nCells = 10
        let finalProfiles = SerializableProfiles(
            ionTemperature: (0..<nCells).map { Float($0) * 100.0 },
            electronTemperature: (0..<nCells).map { Float($0) * 90.0 },
            electronDensity: (0..<nCells).map { Float($0) * 1e19 },
            poloidalFlux: (0..<nCells).map { Float($0) * 0.1 }
        )

        let statistics = SimulationStatistics(
            totalIterations: 100,
            totalSteps: 50,
            converged: true,
            maxResidualNorm: 1e-6,
            wallTime: 12.5
        )

        let result = SimulationResult(
            finalProfiles: finalProfiles,
            statistics: statistics,
            timeSeries: nil  // No time series
        )

        // Create output writer
        let writer = OutputWriter(format: .netcdf)

        // Write to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("test_output.nc")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Write NetCDF
        try writer.write(result, to: outputURL)

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Clean up
        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test("NetCDF writer creates valid file with time series")
    func testNetCDFWriterTimeSeries() throws {
        // Create test data with time series
        let nCells = 10
        let nTime = 5

        var timeSeries: [TimePoint] = []
        for t in 0..<nTime {
            let profiles = SerializableProfiles(
                ionTemperature: (0..<nCells).map { Float($0 + t) * 100.0 },
                electronTemperature: (0..<nCells).map { Float($0 + t) * 90.0 },
                electronDensity: (0..<nCells).map { Float($0 + t) * 1e19 },
                poloidalFlux: (0..<nCells).map { Float($0 + t) * 0.1 }
            )
            timeSeries.append(TimePoint(time: Float(t) * 0.1, profiles: profiles))
        }

        let finalProfiles = timeSeries.last!.profiles
        let statistics = SimulationStatistics(
            totalIterations: 100,
            totalSteps: 50,
            converged: true,
            maxResidualNorm: 1e-6,
            wallTime: 12.5
        )

        let result = SimulationResult(
            finalProfiles: finalProfiles,
            statistics: statistics,
            timeSeries: timeSeries
        )

        // Create output writer
        let writer = OutputWriter(format: .netcdf)

        // Write to known location for manual inspection
        let outputURL = URL(fileURLWithPath: "/tmp/torax_test_timeseries.nc")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Write NetCDF
        try writer.write(result, to: outputURL)

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        print("NetCDF file created at: \(outputURL.path)")
        print("Inspect with: ncdump -h \(outputURL.path)")

        // Don't clean up - leave for inspection
        // try? FileManager.default.removeItem(at: outputURL)
    }

    @Test("JSON writer still works")
    func testJSONWriter() throws {
        // Create test data
        let nCells = 10
        let finalProfiles = SerializableProfiles(
            ionTemperature: (0..<nCells).map { Float($0) * 100.0 },
            electronTemperature: (0..<nCells).map { Float($0) * 90.0 },
            electronDensity: (0..<nCells).map { Float($0) * 1e19 },
            poloidalFlux: (0..<nCells).map { Float($0) * 0.1 }
        )

        let statistics = SimulationStatistics(
            totalIterations: 100,
            totalSteps: 50,
            converged: true,
            maxResidualNorm: 1e-6,
            wallTime: 12.5
        )

        let result = SimulationResult(
            finalProfiles: finalProfiles,
            statistics: statistics,
            timeSeries: nil
        )

        // Create output writer
        let writer = OutputWriter(format: .json)

        // Write to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("test_output.json")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Write JSON
        try writer.write(result, to: outputURL)

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Clean up
        try? FileManager.default.removeItem(at: outputURL)
    }

    @Test("NetCDF handles single cell edge case")
    func testNetCDFSingleCell() throws {
        // Create test data with nCells = 1
        let nCells = 1
        let finalProfiles = SerializableProfiles(
            ionTemperature: [1000.0],
            electronTemperature: [900.0],
            electronDensity: [5e19],
            poloidalFlux: [0.5]
        )

        let statistics = SimulationStatistics(
            totalIterations: 10,
            totalSteps: 5,
            converged: true,
            maxResidualNorm: 1e-7,
            wallTime: 1.0
        )

        let result = SimulationResult(
            finalProfiles: finalProfiles,
            statistics: statistics,
            timeSeries: nil
        )

        // Create output writer
        let writer = OutputWriter(format: .netcdf)

        // Write to temporary file
        let outputURL = URL(fileURLWithPath: "/tmp/torax_single_cell.nc")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Write NetCDF - should not crash with division by zero
        try writer.write(result, to: outputURL)

        // Verify file exists
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        print("Single cell NetCDF created at: \(outputURL.path)")

        // Don't clean up - leave for inspection
    }

    @Test("NetCDF detects inconsistent array lengths")
    func testNetCDFInconsistentLengths() throws {
        // Create invalid data with mismatched array lengths
        let finalProfiles = SerializableProfiles(
            ionTemperature: [1000.0, 2000.0],  // 2 elements
            electronTemperature: [900.0],       // 1 element - MISMATCH
            electronDensity: [5e19, 6e19],
            poloidalFlux: [0.5, 0.6]
        )

        let statistics = SimulationStatistics()

        let result = SimulationResult(
            finalProfiles: finalProfiles,
            statistics: statistics,
            timeSeries: nil
        )

        let writer = OutputWriter(format: .netcdf)
        let outputURL = URL(fileURLWithPath: "/tmp/torax_invalid.nc")

        // Should throw error due to mismatched lengths
        #expect(throws: Error.self) {
            try writer.write(result, to: outputURL)
        }
    }
}
