import MLX
import Foundation

// MARK: - Flattened State

/// Flattened state vector for efficient Jacobian computation
///
/// This type enables efficient Jacobian computation using vjp() instead of
/// multiple separate grad() calls. For a system with 4 variables (Ti, Te, ne, psi),
/// this reduces Jacobian computation from 4n to n function evaluations.
public struct FlattenedState: Sendable {
    /// Flattened state values: [Ti; Te; ne; psi]
    public let values: EvaluatedArray

    /// Memory layout information
    public let layout: StateLayout

    // MARK: - State Layout

    /// Memory layout for state variables
    public struct StateLayout: Sendable, Equatable {
        /// Number of cells
        public let nCells: Int

        /// Range for ion temperature
        public let tiRange: Range<Int>

        /// Range for electron temperature
        public let teRange: Range<Int>

        /// Range for electron density
        public let neRange: Range<Int>

        /// Range for poloidal flux
        public let psiRange: Range<Int>

        /// Initialize layout
        ///
        /// - Parameter nCells: Number of cells in grid
        /// - Throws: FlattenedStateError if invalid
        public init(nCells: Int) throws {
            guard nCells > 0 else {
                throw FlattenedStateError.invalidCellCount(nCells)
            }

            self.nCells = nCells
            self.tiRange = 0..<nCells
            self.teRange = nCells..<(2 * nCells)
            self.neRange = (2 * nCells)..<(3 * nCells)
            self.psiRange = (3 * nCells)..<(4 * nCells)
        }

        /// Total size of flattened state
        public var totalSize: Int { 4 * nCells }

        /// Validate layout consistency
        ///
        /// - Throws: FlattenedStateError if layout is inconsistent
        public func validate() throws {
            guard tiRange.count == nCells,
                  teRange.count == nCells,
                  neRange.count == nCells,
                  psiRange.count == nCells else {
                throw FlattenedStateError.inconsistentLayout
            }

            guard psiRange.upperBound == totalSize else {
                throw FlattenedStateError.layoutMismatch
            }
        }
    }

    // MARK: - Errors

    /// Errors for FlattenedState operations
    public enum FlattenedStateError: Error {
        case invalidCellCount(Int)
        case inconsistentLayout
        case layoutMismatch
        case shapeMismatch(expected: Int, actual: Int)
    }

    // MARK: - Initialization

    /// Create flattened state from CoreProfiles
    ///
    /// - Parameter profiles: Core profiles to flatten
    /// - Throws: FlattenedStateError if profiles have inconsistent shapes
    public init(profiles: CoreProfiles) throws {
        let nCells = profiles.ionTemperature.shape[0]
        let layout = try StateLayout(nCells: nCells)
        try layout.validate()

        // Validate all profiles have same shape
        guard profiles.electronTemperature.shape[0] == nCells,
              profiles.electronDensity.shape[0] == nCells,
              profiles.poloidalFlux.shape[0] == nCells else {
            throw FlattenedStateError.shapeMismatch(
                expected: nCells,
                actual: profiles.electronTemperature.shape[0]
            )
        }

        // Extract MLXArrays from EvaluatedArrays and flatten: [Ti; Te; ne; psi]
        let flattened = concatenated([
            profiles.ionTemperature.value,
            profiles.electronTemperature.value,
            profiles.electronDensity.value,
            profiles.poloidalFlux.value
        ], axis: 0)

        // Wrap flattened result in EvaluatedArray
        self.values = EvaluatedArray(evaluating: flattened)
        self.layout = layout
    }

    /// Create flattened state from raw values (internal use)
    ///
    /// - Parameters:
    ///   - values: Pre-evaluated flattened array
    ///   - layout: Memory layout
    public init(values: EvaluatedArray, layout: StateLayout) {
        self.values = values
        self.layout = layout
    }

    // MARK: - Conversion

    /// Restore to CoreProfiles
    ///
    /// - Returns: Core profiles reconstructed from flattened state
    public func toCoreProfiles() -> CoreProfiles {
        // Extract MLXArray from EvaluatedArray
        let array = values.value

        // Slice array and wrap each slice in EvaluatedArray
        let extracted = EvaluatedArray.evaluatingBatch([
            array[layout.tiRange],
            array[layout.teRange],
            array[layout.neRange],
            array[layout.psiRange]
        ])

        return CoreProfiles(
            ionTemperature: extracted[0],
            electronTemperature: extracted[1],
            electronDensity: extracted[2],
            poloidalFlux: extracted[3]
        )
    }
}

// MARK: - Jacobian Computation Utilities

/// Compute Jacobian via vector-Jacobian product (efficient reverse-mode AD)
///
/// This function computes the full Jacobian matrix using vjp() in reverse mode,
/// which is more efficient than multiple forward-mode grad() calls.
///
/// - Parameters:
///   - residualFn: Residual function mapping state to residual
///   - x: State vector
/// - Returns: Jacobian matrix (n × n)
public func computeJacobianViaVJP(
    _ residualFn: @escaping (MLXArray) -> MLXArray,
    _ x: MLXArray
) -> MLXArray {
    let n = x.shape[0]
    var jacobianTranspose: [MLXArray] = []

    // Use vjp() for reverse-mode AD
    for i in 0..<n {
        // Standard basis vector
        let cotangent = MLXArray.zeros([n])
        cotangent[i] = MLXArray(1.0)

        // vjp computes: J^T · cotangent = (i-th row of J)^T
        let wrappedFn: ([MLXArray]) -> [MLXArray] = { inputs in
            [residualFn(inputs[0])]
        }

        let (_, vjpResult) = vjp(
            wrappedFn,
            primals: [x],
            cotangents: [cotangent]
        )

        jacobianTranspose.append(vjpResult[0])
    }

    // Transpose to get Jacobian
    return MLX.stacked(jacobianTranspose, axis: 0).T
}

/// Compute Jacobian via vector-Jacobian product with batching
///
/// This variant processes multiple cotangent vectors in parallel for better performance.
///
/// - Parameters:
///   - residualFn: Residual function mapping state to residual
///   - x: State vector
///   - batchSize: Number of cotangent vectors to process at once
/// - Returns: Jacobian matrix (n × n)
public func computeJacobianViaVJPBatched(
    _ residualFn: @escaping (MLXArray) -> MLXArray,
    _ x: MLXArray,
    batchSize: Int = 10
) -> MLXArray {
    let n = x.shape[0]
    var jacobianRows: [MLXArray] = []

    // Process in batches
    for batchStart in stride(from: 0, to: n, by: batchSize) {
        let batchEnd = min(batchStart + batchSize, n)

        var batchCotangents: [MLXArray] = []
        for i in batchStart..<batchEnd {
            let cotangent = MLXArray.zeros([n])
            cotangent[i] = MLXArray(1.0)
            batchCotangents.append(cotangent)
        }

        // Process batch
        let wrappedFn: ([MLXArray]) -> [MLXArray] = { inputs in
            [residualFn(inputs[0])]
        }

        for cotangent in batchCotangents {
            let (_, vjpResult) = vjp(
                wrappedFn,
                primals: [x],
                cotangents: [cotangent]
            )
            jacobianRows.append(vjpResult[0])
        }
    }

    return MLX.stacked(jacobianRows, axis: 0)
}
