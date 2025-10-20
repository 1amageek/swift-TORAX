// PlotData.swift
// 2D simulation data container for plotting
//
// Converts TORAX simulation data to display units:
// - Temperature: eV → keV
// - Density: m^-3 → 10^20 m^-3

import Foundation
import TORAX

/// Complete simulation output data for 2D plotting
public struct PlotData: Sendable {
    // MARK: - Coordinates

    /// Normalized radius ρ ∈ [0, 1] [nCells]
    public let rho: [Float]

    /// Time [s] [nTime]
    public let time: [Float]

    // MARK: - Temperature & Density Profiles [nTime, nCells]

    /// Ion temperature [keV]
    public let Ti: [[Float]]

    /// Electron temperature [keV]
    public let Te: [[Float]]

    /// Electron density [10^20 m^-3]
    public let ne: [[Float]]

    // MARK: - Magnetic Field Profiles [nTime, nCells]

    /// Safety factor (dimensionless)
    public let q: [[Float]]

    /// Magnetic shear (dimensionless)
    public let magneticShear: [[Float]]

    /// Poloidal flux [Wb]
    public let psi: [[Float]]

    // MARK: - Transport Coefficients [nTime, nCells] [m^2/s]

    /// Total ion heat conductivity
    public let chiTotalIon: [[Float]]

    /// Total electron heat conductivity
    public let chiTotalElectron: [[Float]]

    /// Turbulent ion heat conductivity
    public let chiTurbIon: [[Float]]

    /// Turbulent electron heat conductivity
    public let chiTurbElectron: [[Float]]

    /// Particle diffusivity
    public let dFace: [[Float]]

    // MARK: - Current Density Profiles [nTime, nCells] [MA/m^2]

    /// Total toroidal current density
    public let jTotal: [[Float]]

    /// Ohmic current density
    public let jOhmic: [[Float]]

    /// Bootstrap current density
    public let jBootstrap: [[Float]]

    /// ECRH-driven current density
    public let jECRH: [[Float]]

    // MARK: - Source Terms [nTime, nCells] [MW/m^3]

    /// Ohmic heating source
    public let ohmicHeatSource: [[Float]]

    /// Fusion heating source
    public let fusionHeatSource: [[Float]]

    /// ICRH ion heating density
    public let pICRHIon: [[Float]]

    /// ICRH electron heating density
    public let pICRHElectron: [[Float]]

    /// ECRH electron heating density
    public let pECRHElectron: [[Float]]

    // MARK: - Time Series Scalars [nTime]

    /// Plasma current [MA]
    public let IpProfile: [Float]

    /// Bootstrap current [MA]
    public let IBootstrap: [Float]

    /// ECRH-driven current [MA]
    public let IECRH: [Float]

    /// Fusion gain (dimensionless)
    public let qFusion: [Float]

    /// Auxiliary heating power [MW]
    public let pAuxiliary: [Float]

    /// Ohmic heating power (electron) [MW]
    public let pOhmicE: [Float]

    /// Alpha particle heating power [MW]
    public let pAlphaTotal: [Float]

    /// Bremsstrahlung radiation loss [MW]
    public let pBremsstrahlung: [Float]

    /// Total radiation loss [MW]
    public let pRadiation: [Float]

    // MARK: - Utilities

    /// Number of time points
    public var nTime: Int { time.count }

    /// Number of radial cells
    public var nCells: Int { rho.count }

    /// Time range
    public var timeRange: ClosedRange<Float> { time.first!...time.last! }

    /// Rho range
    public var rhoRange: ClosedRange<Float> { 0.0...1.0 }

    // MARK: - Initialization

    public init(
        rho: [Float],
        time: [Float],
        Ti: [[Float]],
        Te: [[Float]],
        ne: [[Float]],
        q: [[Float]],
        magneticShear: [[Float]],
        psi: [[Float]],
        chiTotalIon: [[Float]],
        chiTotalElectron: [[Float]],
        chiTurbIon: [[Float]],
        chiTurbElectron: [[Float]],
        dFace: [[Float]],
        jTotal: [[Float]],
        jOhmic: [[Float]],
        jBootstrap: [[Float]],
        jECRH: [[Float]],
        ohmicHeatSource: [[Float]],
        fusionHeatSource: [[Float]],
        pICRHIon: [[Float]],
        pICRHElectron: [[Float]],
        pECRHElectron: [[Float]],
        IpProfile: [Float],
        IBootstrap: [Float],
        IECRH: [Float],
        qFusion: [Float],
        pAuxiliary: [Float],
        pOhmicE: [Float],
        pAlphaTotal: [Float],
        pBremsstrahlung: [Float],
        pRadiation: [Float]
    ) {
        self.rho = rho
        self.time = time
        self.Ti = Ti
        self.Te = Te
        self.ne = ne
        self.q = q
        self.magneticShear = magneticShear
        self.psi = psi
        self.chiTotalIon = chiTotalIon
        self.chiTotalElectron = chiTotalElectron
        self.chiTurbIon = chiTurbIon
        self.chiTurbElectron = chiTurbElectron
        self.dFace = dFace
        self.jTotal = jTotal
        self.jOhmic = jOhmic
        self.jBootstrap = jBootstrap
        self.jECRH = jECRH
        self.ohmicHeatSource = ohmicHeatSource
        self.fusionHeatSource = fusionHeatSource
        self.pICRHIon = pICRHIon
        self.pICRHElectron = pICRHElectron
        self.pECRHElectron = pECRHElectron
        self.IpProfile = IpProfile
        self.IBootstrap = IBootstrap
        self.IECRH = IECRH
        self.qFusion = qFusion
        self.pAuxiliary = pAuxiliary
        self.pOhmicE = pOhmicE
        self.pAlphaTotal = pAlphaTotal
        self.pBremsstrahlung = pBremsstrahlung
        self.pRadiation = pRadiation
    }
}

// MARK: - Conversion from SimulationResult

extension PlotData {
    /// Create PlotData from SimulationResult with unit conversion
    ///
    /// **Unit Conversions**:
    /// - Temperature: eV → keV (÷ 1000)
    /// - Density: m^-3 → 10^20 m^-3 (÷ 1e20)
    /// - Other quantities: No conversion
    ///
    /// - Parameter result: Simulation result with time series
    /// - Throws: If time series is missing
    public init(from result: SimulationResult) throws {
        guard let timeSeries = result.timeSeries, !timeSeries.isEmpty else {
            throw PlotDataError.missingTimeSeries
        }

        let nTime = timeSeries.count
        let nCells = timeSeries[0].profiles.ionTemperature.count

        // Generate rho coordinate
        self.rho = (0..<nCells).map { Float($0) / Float(max(nCells - 1, 1)) }

        // Extract time
        self.time = timeSeries.map { $0.time }

        // Convert temperature profiles: eV → keV
        self.Ti = timeSeries.map { timePoint in
            timePoint.profiles.ionTemperature.map { $0 / 1000.0 }
        }
        self.Te = timeSeries.map { timePoint in
            timePoint.profiles.electronTemperature.map { $0 / 1000.0 }
        }

        // Convert density profiles: m^-3 → 10^20 m^-3
        self.ne = timeSeries.map { timePoint in
            timePoint.profiles.electronDensity.map { $0 / 1e20 }
        }

        // Poloidal flux (no conversion)
        self.psi = timeSeries.map { timePoint in
            timePoint.profiles.poloidalFlux
        }

        // Placeholder for unimplemented fields (filled with zeros)
        let zeroProfile = Array(repeating: Float(0.0), count: nCells)
        let zeroProfiles = Array(repeating: zeroProfile, count: nTime)

        self.q = zeroProfiles
        self.magneticShear = zeroProfiles
        self.chiTotalIon = zeroProfiles
        self.chiTotalElectron = zeroProfiles
        self.chiTurbIon = zeroProfiles
        self.chiTurbElectron = zeroProfiles
        self.dFace = zeroProfiles
        self.jTotal = zeroProfiles
        self.jOhmic = zeroProfiles
        self.jBootstrap = zeroProfiles
        self.jECRH = zeroProfiles
        self.ohmicHeatSource = zeroProfiles
        self.fusionHeatSource = zeroProfiles
        self.pICRHIon = zeroProfiles
        self.pICRHElectron = zeroProfiles
        self.pECRHElectron = zeroProfiles

        // Time series scalars
        // Phase 1: Attempt to extract from derived quantities if available
        // Phase 2+: Derived quantities should always be populated

        // Check if any time point has derived quantities
        let hasDerived = timeSeries.contains { $0.derived != nil }

        if hasDerived {
            // Extract from derived quantities with fallback to zero
            self.IpProfile = timeSeries.map { $0.derived?.I_plasma ?? 0.0 }
            self.IBootstrap = timeSeries.map { $0.derived?.I_bootstrap ?? 0.0 }
            self.IECRH = Array(repeating: Float(0.0), count: nTime)  // Not in DerivedQuantities yet

            // Fusion performance metrics
            self.qFusion = timeSeries.map { timePoint in
                // Q = P_fusion / (P_auxiliary + P_ohmic)
                guard let derived = timePoint.derived else { return 0.0 }
                let P_input = derived.P_auxiliary + derived.P_ohmic + 1e-10  // Avoid division by zero
                return derived.P_fusion / P_input
            }

            self.pAuxiliary = timeSeries.map { $0.derived?.P_auxiliary ?? 0.0 }
            self.pOhmicE = timeSeries.map { $0.derived?.P_ohmic ?? 0.0 }
            self.pAlphaTotal = timeSeries.map { $0.derived?.P_alpha ?? 0.0 }
            self.pBremsstrahlung = Array(repeating: Float(0.0), count: nTime)  // Not in DerivedQuantities
            self.pRadiation = Array(repeating: Float(0.0), count: nTime)  // Not in DerivedQuantities
        } else {
            // Phase 1: No derived quantities available, use zeros
            let zeroScalar = Array(repeating: Float(0.0), count: nTime)
            self.IpProfile = zeroScalar
            self.IBootstrap = zeroScalar
            self.IECRH = zeroScalar
            self.qFusion = zeroScalar
            self.pAuxiliary = zeroScalar
            self.pOhmicE = zeroScalar
            self.pAlphaTotal = zeroScalar
            self.pBremsstrahlung = zeroScalar
            self.pRadiation = zeroScalar
        }
    }
}

// MARK: - Errors

public enum PlotDataError: LocalizedError {
    case missingTimeSeries
    case inconsistentDataShape

    public var errorDescription: String? {
        switch self {
        case .missingTimeSeries:
            return "SimulationResult must contain time series data for plotting"
        case .inconsistentDataShape:
            return "Data arrays have inconsistent shapes"
        }
    }
}
