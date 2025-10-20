// PlotData3D.swift
// 3D volumetric simulation data for Chart3D visualization
//
// Converts 1D radial profiles to 3D cylindrical coordinates assuming:
// 1. Toroidal symmetry (no φ dependence)
// 2. Circular poloidal cross-section
// 3. Up-down symmetry

import Foundation

/// 3D volumetric simulation data for Chart3D visualization
public struct PlotData3D: Sendable {
    // MARK: - Cylindrical Coordinates

    /// Major radius R [m] - flattened from (ρ, θ) grid
    public let r: [Float]

    /// Height Z [m] - flattened from (ρ, θ) grid
    public let z: [Float]

    /// Toroidal angle φ [rad] [nPhi]
    public let phi: [Float]

    /// Time [s] [nTime]
    public let time: [Float]

    // MARK: - 4D Volumetric Data [nTime, nPoints, nPhi]
    // Note: nPoints = nRho * nTheta (poloidal cross-section points)

    /// Temperature [keV]
    public let temperature: [[[Float]]]

    /// Density [10^20 m^-3]
    public let density: [[[Float]]]

    /// Pressure [kPa]
    public let pressure: [[[Float]]]

    // MARK: - Grid Dimensions

    /// Number of radial points (ρ direction)
    public let nRho: Int

    /// Number of poloidal angle points (θ direction)
    public let nTheta: Int

    /// Total poloidal cross-section points
    public var nPoints: Int { r.count }

    /// Number of toroidal angle points (φ direction)
    public var nPhi: Int { phi.count }

    /// Number of time points
    public var nTime: Int { time.count }

    // Legacy compatibility (deprecated)
    @available(*, deprecated, message: "Use nPoints instead (nPoints = nRho * nTheta)")
    public var nR: Int { nRho }

    @available(*, deprecated, message: "Use nPoints instead (nPoints = nRho * nTheta)")
    public var nZ: Int { nTheta }

    // MARK: - Initialization

    public init(
        r: [Float],
        z: [Float],
        phi: [Float],
        time: [Float],
        temperature: [[[Float]]],
        density: [[[Float]]],
        pressure: [[[Float]]],
        nRho: Int,
        nTheta: Int
    ) {
        self.r = r
        self.z = z
        self.phi = phi
        self.time = time
        self.temperature = temperature
        self.density = density
        self.pressure = pressure
        self.nRho = nRho
        self.nTheta = nTheta
    }

    /// Generate 3D volumetric data from 1D radial profile
    ///
    /// **Physical Model**:
    /// - Circular poloidal cross-section: R(ρ,θ) = R₀ + ρ·a·cos(θ), Z(ρ,θ) = ρ·a·sin(θ)
    /// - Toroidal symmetry: All quantities independent of φ
    /// - Pressure: P = n·k_B·T (ideal gas law)
    ///
    /// **Coordinate System**:
    /// - ρ ∈ [0,1]: Normalized minor radius
    /// - θ ∈ [0,2π): Poloidal angle (θ=0 is outboard midplane)
    /// - φ ∈ [0,2π): Toroidal angle
    ///
    /// - Parameters:
    ///   - profile: 1D radial profiles (Ti, Te, ne vs ρ)
    ///   - nTheta: Number of poloidal angle points (default: 16)
    ///   - nPhi: Number of toroidal angle points (default: 16)
    ///   - geometry: Tokamak geometry (R₀, a)
    public init(
        from profile: PlotData,
        nTheta: Int = 16,
        nPhi: Int = 16,
        geometry: GeometryParams
    ) {
        let nCells = profile.nCells

        // Physical constants
        let kB_eV_per_K: Float = 8.617333e-5  // Boltzmann constant [eV/K]
        let eV_to_J: Float = 1.602176634e-19  // eV to Joule conversion

        // Generate poloidal cross-section grid (ρ, θ) → (R, Z)
        var rPoints: [Float] = []
        var zPoints: [Float] = []

        for i in 0..<nCells {
            let rho = profile.rho[i]

            for j in 0..<nTheta {
                let theta = Float(j) * 2.0 * Float.pi / Float(nTheta)

                // Circular cross-section in (R, Z) coordinates
                let r = geometry.majorRadius + rho * geometry.minorRadius * cos(theta)
                let z = rho * geometry.minorRadius * sin(theta)

                rPoints.append(r)
                zPoints.append(z)
            }
        }

        self.r = rPoints
        self.z = zPoints
        self.nRho = nCells
        self.nTheta = nTheta

        // Generate toroidal angle grid
        self.phi = (0..<nPhi).map { i in
            Float(i) * 2.0 * Float.pi / Float(nPhi)
        }

        self.time = profile.time

        // Convert 1D radial profiles to 3D assuming toroidal symmetry
        // Data structure: [nTime][nRho * nTheta][nPhi]
        // Each (ρ, θ) point has the same value for all φ

        self.temperature = profile.Ti.map { tiAtTime in
            (0..<nCells).flatMap { iRho in
                (0..<nTheta).map { _ in
                    (0..<nPhi).map { _ in
                        tiAtTime[iRho]  // Toroidal symmetry: T(ρ,θ,φ) = T(ρ)
                    }
                }
            }
        }

        self.density = profile.ne.map { neAtTime in
            (0..<nCells).flatMap { iRho in
                (0..<nTheta).map { _ in
                    (0..<nPhi).map { _ in
                        neAtTime[iRho]  // Toroidal symmetry: n(ρ,θ,φ) = n(ρ)
                    }
                }
            }
        }

        // Pressure from ideal gas law: P = n * k_B * T
        // Input: ne [10^20 m^-3], Te [keV]
        // Output: P [kPa]
        //
        // P [Pa] = n [m^-3] * k_B [J/K] * T [K]
        //        = n [10^20 m^-3] * 10^20 * k_B [eV/K] * T [keV] * 1000 * eV_to_J [J/eV]
        //        = n * 10^20 * 8.617e-5 * T * 1000 * 1.602e-19
        //        = n * T * 0.1380649  [Pa]
        // P [kPa] = n * T * 1.380649e-4
        let pressureConversion: Float = 1.380649e-4  // (10^20 m^-3 * keV) → kPa

        self.pressure = zip(profile.ne, profile.Te).map { ne, te in
            (0..<nCells).flatMap { iRho in
                (0..<nTheta).map { _ in
                    (0..<nPhi).map { _ in
                        ne[iRho] * te[iRho] * pressureConversion
                    }
                }
            }
        }
    }

    // MARK: - 3D Point Extraction

    /// Extract 3D points for PointMark3D at given time index
    ///
    /// Returns flattened array of all (R, Z, φ) points at the specified time.
    /// Points are ordered as: [(ρ₀,θ₀,φ₀), (ρ₀,θ₀,φ₁), ..., (ρₙ,θₘ,φₖ)]
    ///
    /// - Parameter timeIndex: Time index (0..<nTime)
    /// - Returns: Array of volumetric points with physical quantities
    public func volumetricPoints(timeIndex: Int) -> [VolumetricPoint] {
        guard timeIndex < nTime else { return [] }

        let nPoloidalPoints = nRho * nTheta

        var points: [VolumetricPoint] = []
        points.reserveCapacity(nPoloidalPoints * nPhi)

        for iPoloidal in 0..<nPoloidalPoints {
            for iPhi in 0..<nPhi {
                let point = VolumetricPoint(
                    r: r[iPoloidal],
                    z: z[iPoloidal],
                    phi: phi[iPhi],
                    temperature: temperature[timeIndex][iPoloidal][iPhi],
                    density: density[timeIndex][iPoloidal][iPhi],
                    pressure: pressure[timeIndex][iPoloidal][iPhi]
                )
                points.append(point)
            }
        }

        return points
    }

    /// Temperature range for color mapping
    public var temperatureRange: ClosedRange<Float> {
        let allValues = temperature.flatMap { $0.flatMap { $0 } }
        let min = allValues.min() ?? 0
        let max = allValues.max() ?? 1
        return min...max
    }

    /// Density range for color mapping
    public var densityRange: ClosedRange<Float> {
        let allValues = density.flatMap { $0.flatMap { $0 } }
        let min = allValues.min() ?? 0
        let max = allValues.max() ?? 1
        return min...max
    }

    /// Pressure range for color mapping
    public var pressureRange: ClosedRange<Float> {
        let allValues = pressure.flatMap { $0.flatMap { $0 } }
        let min = allValues.min() ?? 0
        let max = allValues.max() ?? 1
        return min...max
    }
}

// MARK: - Supporting Types

/// Geometry parameters for 3D reconstruction
public struct GeometryParams: Sendable {
    /// Major radius R₀ [m]
    public let majorRadius: Float

    /// Minor radius a [m]
    public let minorRadius: Float

    public init(majorRadius: Float, minorRadius: Float) {
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
    }

    /// Default ITER-like geometry (R₀=6.2m, a=2.0m)
    public static let iterLike = GeometryParams(majorRadius: 6.2, minorRadius: 2.0)

    /// Aspect ratio R₀/a
    public var aspectRatio: Float {
        majorRadius / minorRadius
    }

    /// Plasma volume [m³] for circular cross-section
    /// V = 2π²·R₀·a²
    public var volume: Float {
        2.0 * Float.pi * Float.pi * majorRadius * minorRadius * minorRadius
    }
}

/// Single point in 3D volumetric space
public struct VolumetricPoint: Identifiable, Sendable {
    public let id = UUID()

    /// Major radius R [m]
    public let r: Float

    /// Height Z [m]
    public let z: Float

    /// Toroidal angle φ [rad]
    public let phi: Float

    /// Temperature [keV]
    public let temperature: Float

    /// Density [10^20 m^-3]
    public let density: Float

    /// Pressure [kPa]
    public let pressure: Float

    public init(r: Float, z: Float, phi: Float, temperature: Float, density: Float, pressure: Float) {
        self.r = r
        self.z = z
        self.phi = phi
        self.temperature = temperature
        self.density = density
        self.pressure = pressure
    }

    /// Distance from magnetic axis [m]
    public func minorRadius(geometry: GeometryParams) -> Float {
        let dr = r - geometry.majorRadius
        return sqrt(dr * dr + z * z)
    }

    /// Normalized minor radius ρ = r_minor / a
    public func normalizedRadius(geometry: GeometryParams) -> Float {
        minorRadius(geometry: geometry) / geometry.minorRadius
    }

    /// Poloidal angle θ [rad]
    public func poloidalAngle(geometry: GeometryParams) -> Float {
        let dr = r - geometry.majorRadius
        return atan2(z, dr)
    }
}
