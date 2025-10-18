// DisplayUnits.swift
// Unit conversion utilities for CLI display

import Foundation

/// Display unit conversion utilities
///
/// TORAX internally uses eV for temperature and m^-3 for density,
/// but displays values in conventional tokamak units (keV, 10^20 m^-3)
/// for better alignment with literature and user expectations.
enum DisplayUnits {
    // MARK: - Temperature Conversion

    /// Convert temperature from internal units (eV) to display units (keV)
    ///
    /// - Parameter eV: Temperature in electron volts
    /// - Returns: Temperature in kilo-electron volts
    static func toKeV(_ eV: Float) -> Float {
        eV / 1000.0
    }

    /// Convert temperature from internal units (eV) to display units (keV)
    ///
    /// - Parameter eV: Temperature in electron volts
    /// - Returns: Temperature in kilo-electron volts
    static func toKeV(_ eV: Double) -> Double {
        eV / 1000.0
    }

    /// Convert temperature array from internal units (eV) to display units (keV)
    ///
    /// - Parameter eV: Temperature array in electron volts
    /// - Returns: Temperature array in kilo-electron volts
    static func toKeV(_ eV: [Float]) -> [Float] {
        eV.map { $0 / 1000.0 }
    }

    /// Convert temperature array from internal units (eV) to display units (keV)
    ///
    /// - Parameter eV: Temperature array in electron volts
    /// - Returns: Temperature array in kilo-electron volts
    static func toKeV(_ eV: [Double]) -> [Double] {
        eV.map { $0 / 1000.0 }
    }

    // MARK: - Density Conversion

    /// Convert density from internal units (m^-3) to display units (10^20 m^-3)
    ///
    /// - Parameter m3: Density in particles per cubic meter
    /// - Returns: Density in units of 10^20 m^-3
    static func to1e20m3(_ m3: Float) -> Float {
        m3 / 1e20
    }

    /// Convert density from internal units (m^-3) to display units (10^20 m^-3)
    ///
    /// - Parameter m3: Density in particles per cubic meter
    /// - Returns: Density in units of 10^20 m^-3
    static func to1e20m3(_ m3: Double) -> Double {
        m3 / 1e20
    }

    /// Convert density array from internal units (m^-3) to display units (10^20 m^-3)
    ///
    /// - Parameter m3: Density array in particles per cubic meter
    /// - Returns: Density array in units of 10^20 m^-3
    static func to1e20m3(_ m3: [Float]) -> [Float] {
        m3.map { $0 / 1e20 }
    }

    /// Convert density array from internal units (m^-3) to display units (10^20 m^-3)
    ///
    /// - Parameter m3: Density array in particles per cubic meter
    /// - Returns: Density array in units of 10^20 m^-3
    static func to1e20m3(_ m3: [Double]) -> [Double] {
        m3.map { $0 / 1e20 }
    }

    // MARK: - Reverse Conversion (for completeness)

    /// Convert temperature from display units (keV) to internal units (eV)
    ///
    /// - Parameter keV: Temperature in kilo-electron volts
    /// - Returns: Temperature in electron volts
    static func fromKeV(_ keV: Float) -> Float {
        keV * 1000.0
    }

    /// Convert temperature from display units (keV) to internal units (eV)
    ///
    /// - Parameter keV: Temperature in kilo-electron volts
    /// - Returns: Temperature in electron volts
    static func fromKeV(_ keV: Double) -> Double {
        keV * 1000.0
    }

    /// Convert density from display units (10^20 m^-3) to internal units (m^-3)
    ///
    /// - Parameter value1e20: Density in units of 10^20 m^-3
    /// - Returns: Density in particles per cubic meter
    static func from1e20m3(_ value1e20: Float) -> Float {
        value1e20 * 1e20
    }

    /// Convert density from display units (10^20 m^-3) to internal units (m^-3)
    ///
    /// - Parameter value1e20: Density in units of 10^20 m^-3
    /// - Returns: Density in particles per cubic meter
    static func from1e20m3(_ value1e20: Double) -> Double {
        value1e20 * 1e20
    }
}

// MARK: - ProfileStats Display Extension

extension ProfileStats {
    /// Convert to display units (keV for temperature)
    func toDisplayUnits() -> ProfileStats {
        ProfileStats(
            min: DisplayUnits.toKeV(min),
            max: DisplayUnits.toKeV(max),
            core: DisplayUnits.toKeV(core),
            edge: DisplayUnits.toKeV(edge)
        )
    }

    /// Convert to display units (10^20 m^-3 for density)
    func toDisplayUnitsDensity() -> ProfileStats {
        ProfileStats(
            min: DisplayUnits.to1e20m3(min),
            max: DisplayUnits.to1e20m3(max),
            core: DisplayUnits.to1e20m3(core),
            edge: DisplayUnits.to1e20m3(edge)
        )
    }
}
