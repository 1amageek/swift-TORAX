import MLX
import Foundation

// MARK: - Geometry Computation Helpers

/// Compute plasma volume from mesh configuration
///
/// For circular cross-section: V = 2π²R·a²
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Lazy MLXArray (caller wraps in EvaluatedArray)
public func computeVolume(_ mesh: MeshConfig) -> MLXArray {
    let rMajor = MLXArray(mesh.majorRadius)
    let rMinor = MLXArray(mesh.minorRadius)

    // V = 2π²R·a² for circular cross-section
    return 2.0 * Float.pi * Float.pi * rMajor * rMinor * rMinor
}

/// Compute geometric coefficient g0 for FVM
///
/// g0 = (R0 + r·cos(θ))² for circular geometry
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Lazy MLXArray of shape [nFaces] (caller wraps in EvaluatedArray)
public func computeG0(_ mesh: MeshConfig) -> MLXArray {
    // Grid points (face-centered)
    let r = MLXArray.linspace(0.0, mesh.minorRadius, count: mesh.nCells + 1)

    // g0 = (R0 + r)² for circular geometry (assuming θ=0)
    let rMajor = MLXArray(mesh.majorRadius)
    return (rMajor + r) * (rMajor + r)
}

/// Compute geometric coefficient g1 for FVM
///
/// g1 = R0 + r·cos(θ) for circular geometry
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Lazy MLXArray of shape [nFaces] (caller wraps in EvaluatedArray)
public func computeG1(_ mesh: MeshConfig) -> MLXArray {
    // Grid points (face-centered)
    let r = MLXArray.linspace(0.0, mesh.minorRadius, count: mesh.nCells + 1)

    // g1 = R0 + r for circular geometry (assuming θ=0)
    let rMajor = MLXArray(mesh.majorRadius)
    return rMajor + r
}

/// Compute geometric coefficient g2 for FVM
///
/// g2 = 1 for circular geometry
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Lazy MLXArray of shape [nFaces] (caller wraps in EvaluatedArray)
public func computeG2(_ mesh: MeshConfig) -> MLXArray {
    // g2 = 1 for circular geometry
    return MLXArray.ones([mesh.nCells + 1])
}

/// Compute geometric coefficient g3 for FVM
///
/// g3 = r for circular geometry
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Lazy MLXArray of shape [nFaces] (caller wraps in EvaluatedArray)
public func computeG3(_ mesh: MeshConfig) -> MLXArray {
    // Grid points (face-centered)
    let r = MLXArray.linspace(0.0, mesh.minorRadius, count: mesh.nCells + 1)

    // g3 = r for circular geometry
    return r
}

// MARK: - Geometry Construction

/// Construct Geometry from mesh configuration
///
/// - Parameter mesh: Mesh configuration
/// - Returns: Geometry with evaluated arrays
public func createGeometry(from mesh: MeshConfig) -> Geometry {
    Geometry(
        majorRadius: mesh.majorRadius,
        minorRadius: mesh.minorRadius,
        toroidalField: mesh.toroidalField,
        volume: EvaluatedArray(evaluating: computeVolume(mesh)),
        g0: EvaluatedArray(evaluating: computeG0(mesh)),
        g1: EvaluatedArray(evaluating: computeG1(mesh)),
        g2: EvaluatedArray(evaluating: computeG2(mesh)),
        g3: EvaluatedArray(evaluating: computeG3(mesh)),
        type: mesh.geometryType
    )
}

// MARK: - Geometry Provider Implementations

/// Static geometry provider (time-independent)
public struct StaticGeometryProvider: GeometryProvider {
    private let mesh: MeshConfig
    private let geometry: Geometry

    public init(mesh: MeshConfig) {
        self.mesh = mesh
        self.geometry = createGeometry(from: mesh)
    }

    public func geometry(at time: Float) -> Geometry {
        // Same geometry regardless of time
        geometry
    }
}

/// Time-evolving geometry provider
public struct TimeEvolvingGeometryProvider: GeometryProvider {
    private let baseMesh: MeshConfig
    private let scaleProfile: (Float) -> Float

    /// Initialize time-evolving geometry provider
    ///
    /// - Parameters:
    ///   - baseMesh: Base mesh configuration
    ///   - scaleProfile: Time-dependent scaling function
    public init(baseMesh: MeshConfig, scaleProfile: @escaping (Float) -> Float) {
        self.baseMesh = baseMesh
        self.scaleProfile = scaleProfile
    }

    public func geometry(at time: Float) -> Geometry {
        let scale = scaleProfile(time)

        // Scale minor radius and field with time
        let evolvedMesh = MeshConfig(
            nCells: baseMesh.nCells,
            majorRadius: baseMesh.majorRadius,
            minorRadius: baseMesh.minorRadius * scale,
            toroidalField: baseMesh.toroidalField / scale,  // Flux conservation
            geometryType: baseMesh.geometryType
        )

        return createGeometry(from: evolvedMesh)
    }
}
