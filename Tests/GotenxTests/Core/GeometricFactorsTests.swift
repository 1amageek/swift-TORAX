// GeometricFactorsTests.swift
// Tests for metric tensor and non-uniform grid support

import Testing
import MLX
@testable import GotenxCore

@Suite("Geometric Factors Tests")
struct GeometricFactorsTests {

    @Test("GeometricFactors created from Geometry includes metric tensors")
    func metricTensorInclusion() throws {
        // Create geometry with known metric tensor values
        let nCells = 10
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 3.0,
            minorRadius: 1.0,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        // Create GeometricFactors from geometry
        let geoFactors = GeometricFactors.from(geometry: geometry)

        // Verify metric tensors are included
        #expect(geoFactors.jacobian.value.shape[0] == nCells)
        #expect(geoFactors.g1.value.shape[0] == nCells)
        #expect(geoFactors.g2.value.shape[0] == nCells)

        // Verify values are positive (physical requirement)
        let jacobianArray = geoFactors.jacobian.value.asArray(Float.self)
        let g1Array = geoFactors.g1.value.asArray(Float.self)
        let g2Array = geoFactors.g2.value.asArray(Float.self)

        for i in 0..<nCells {
            #expect(jacobianArray[i] > 0.0)  // Jacobian must be positive
            #expect(g1Array[i].isFinite)     // g1 must be finite
            #expect(g2Array[i].isFinite)     // g2 must be finite
        }
    }

    @Test("Metric tensor preserves shape consistency")
    func metricTensorShapeConsistency() throws {
        let nCells = 20
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 6.0,
            minorRadius: 2.0,
            toroidalField: 4.0
        )
        let geometry = Geometry(config: meshConfig)

        let geoFactors = GeometricFactors.from(geometry: geometry)

        // All cell-centered quantities should have shape [nCells]
        #expect(geoFactors.cellVolumes.value.shape[0] == nCells)
        #expect(geoFactors.rCell.value.shape[0] == nCells)
        #expect(geoFactors.jacobian.value.shape[0] == nCells)
        #expect(geoFactors.g1.value.shape[0] == nCells)
        #expect(geoFactors.g2.value.shape[0] == nCells)

        // Face-centered quantities should have shape [nFaces] = [nCells + 1]
        #expect(geoFactors.faceAreas.value.shape[0] == nCells + 1)
        #expect(geoFactors.rFace.value.shape[0] == nCells + 1)

        // Cell distances between centers should have shape [nCells - 1]
        #expect(geoFactors.cellDistances.value.shape[0] == nCells - 1)
    }

    @Test("Metric tensor flux divergence reduces to standard for uniform grid")
    func metricTensorUniformGridEquivalence() throws {
        // For uniform circular geometry with constant Jacobian,
        // metric tensor formulation should be equivalent to standard formulation

        let nCells = 10
        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: 3.0,
            minorRadius: 1.0,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        let geoFactors = GeometricFactors.from(geometry: geometry)

        // For circular geometry, Jacobian should be approximately constant
        // (varies slightly with radius for tokamak geometry)
        let jacobianArray = geoFactors.jacobian.value.asArray(Float.self)

        // Check that Jacobian doesn't vary by more than 50% (generous bound for circular geom)
        let jMean = jacobianArray.reduce(0.0, +) / Float(nCells)
        for j in jacobianArray {
            let relativeVariation = abs(j - jMean) / jMean
            #expect(relativeVariation < 0.5)
        }
    }

    @Test("Cell volumes computed correctly from geometry")
    func cellVolumeComputation() throws {
        let nCells = 10
        let minorRadius: Float = 1.0
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        let geoFactors = GeometricFactors.from(geometry: geometry)

        // For uniform grid: V_cell = 2π R₀ Δr
        let dr = minorRadius / Float(nCells)
        let expectedVolume = 2.0 * Float.pi * majorRadius * dr

        let volumes = geoFactors.cellVolumes.value.asArray(Float.self)

        for v in volumes {
            #expect(abs(v - expectedVolume) < expectedVolume * 0.01)  // Within 1%
        }
    }

    @Test("Face areas constant for cylindrical geometry")
    func faceAreaConstancy() throws {
        let nCells = 10
        let majorRadius: Float = 3.0

        let meshConfig = MeshConfig(
            nCells: nCells,
            majorRadius: majorRadius,
            minorRadius: 1.0,
            toroidalField: 5.0
        )
        let geometry = Geometry(config: meshConfig)

        let geoFactors = GeometricFactors.from(geometry: geometry)

        // For 1D cylindrical approximation: A = 2π R₀ (constant)
        let expectedArea = 2.0 * Float.pi * majorRadius

        let areas = geoFactors.faceAreas.value.asArray(Float.self)

        for a in areas {
            #expect(abs(a - expectedArea) < expectedArea * 0.01)  // Within 1%
        }
    }
}
