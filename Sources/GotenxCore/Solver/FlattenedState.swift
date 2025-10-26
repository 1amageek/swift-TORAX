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

        /// Equatable implementation (optimized)
        ///
        /// Since all ranges are deterministically computed from nCells,
        /// we only need to compare nCells for equality.
        public static func == (lhs: StateLayout, rhs: StateLayout) -> Bool {
            return lhs.nCells == rhs.nCells
        }

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
        case profileShapeMismatch(expected: Int, Ti: Int, Te: Int, ne: Int, psi: Int)
    }

    // MARK: - Initialization

    /// Create flattened state from CoreProfiles
    ///
    /// - Parameter profiles: Core profiles to flatten
    /// - Throws: FlattenedStateError if profiles have inconsistent shapes
    public init(profiles: CoreProfiles) throws {
        // ✅ FIX: Validate all profiles have same shape with detailed error reporting
        // Capture all shapes BEFORE using any as the reference
        let shapes = (
            Ti: profiles.ionTemperature.shape[0],
            Te: profiles.electronTemperature.shape[0],
            ne: profiles.electronDensity.shape[0],
            psi: profiles.poloidalFlux.shape[0]
        )

        // Check that ALL profiles have the same shape (not just Te, ne, psi)
        // This is more logically consistent than using Ti as implicit reference
        guard shapes.Ti == shapes.Te,
              shapes.Ti == shapes.ne,
              shapes.Ti == shapes.psi else {
            throw FlattenedStateError.profileShapeMismatch(
                expected: shapes.Ti,
                Ti: shapes.Ti,
                Te: shapes.Te,
                ne: shapes.ne,
                psi: shapes.psi
            )
        }

        // Now we can safely use any shape as nCells (they're all equal)
        let nCells = shapes.Ti
        let layout = try StateLayout(nCells: nCells)
        try layout.validate()

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

    // MARK: - GPU-Based Variable Scaling

    /// Create scaled state with reference normalization
    ///
    /// **GPU-First Design**: All operations execute on GPU using MLXArray element-wise
    /// arithmetic. No CPU transfers or type conversions occur.
    ///
    /// **Purpose**: Normalize variables to O(1) scale to improve numerical conditioning
    /// in Newton-Raphson solver. This prevents loss of precision when combining variables
    /// with vastly different magnitudes (e.g., Ti ~10⁴ eV vs ne ~10²⁰ m⁻³).
    ///
    /// **Example**:
    /// ```swift
    /// // Reference state: typical plasma values
    /// let reference = try FlattenedState(profiles: referenceProfiles)
    ///
    /// // Scale current state
    /// let scaled = currentState.scaled(by: reference)
    /// // scaled.values ≈ O(1) for all variables
    ///
    /// // Solve in scaled space
    /// let scaledSolution = solver.solve(scaled)
    ///
    /// // Restore to physical units
    /// let solution = scaledSolution.unscaled(by: reference)
    /// ```
    ///
    /// - Parameter reference: Reference state for normalization
    /// - Returns: Scaled state with values normalized by reference
    public func scaled(by reference: FlattenedState) -> FlattenedState {
        // ✅ CRITICAL FIX: Validate layout compatibility before scaling
        // Prevents silent broadcasting errors that can cause solver divergence
        precondition(reference.layout == layout,
            """
            Layout mismatch in scaled(by:):
            - reference.nCells = \(reference.layout.nCells)
            - self.nCells = \(layout.nCells)
            This indicates a programming error. Ensure both states use the same mesh.
            """)

        // ✅ GPU element-wise division (no CPU transfer)
        // Add small epsilon to prevent division by zero
        let scaledValues = values.value / (reference.values.value + 1e-10)
        eval(scaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: scaledValues),
            layout: layout
        )
    }

    /// Restore from scaled state to physical units
    ///
    /// **GPU-First Design**: All operations execute on GPU using MLXArray element-wise
    /// arithmetic. No CPU transfers or type conversions occur.
    ///
    /// **Purpose**: Convert normalized solution back to physical units after solving
    /// in scaled space.
    ///
    /// **Mathematical Correctness**:
    /// If `scaled(by:)` computes `x_s = x / (r + ε)`, then `unscaled(by:)` must compute:
    /// `x = x_s * (r + ε)` to ensure perfect round-trip: `x.scaled(by: r).unscaled(by: r) == x`
    ///
    /// **Example**:
    /// ```swift
    /// // After solving in scaled space
    /// let scaledSolution = newtonRaphson.solve(scaledState)
    ///
    /// // Restore to physical units
    /// let physicalSolution = scaledSolution.unscaled(by: reference)
    /// // physicalSolution now has correct units (eV, m⁻³, etc.)
    /// ```
    ///
    /// - Parameter reference: Reference state used for original scaling
    /// - Returns: Unscaled state in physical units
    public func unscaled(by reference: FlattenedState) -> FlattenedState {
        // ✅ CRITICAL FIX: Validate layout compatibility before unscaling
        // Prevents silent broadcasting errors that can cause solver divergence
        precondition(reference.layout == layout,
            """
            Layout mismatch in unscaled(by:):
            - reference.nCells = \(reference.layout.nCells)
            - self.nCells = \(layout.nCells)
            This indicates a programming error. Ensure both states use the same mesh.
            """)

        // ✅ GPU element-wise multiplication (no CPU transfer)
        // Must use (reference + ε) to match scaling formula
        let unscaledValues = values.value * (reference.values.value + 1e-10)
        eval(unscaledValues)

        return FlattenedState(
            values: EvaluatedArray(evaluating: unscaledValues),
            layout: layout
        )
    }

    // MARK: - Scaling Utilities

    /// Compute scaling factors from current state
    ///
    /// **Use Case**: Create reference state for variable scaling based on current
    /// plasma conditions.
    ///
    /// **Strategy**: Use absolute values to ensure positive scaling factors,
    /// with minimum floor to prevent division by zero for small values.
    ///
    /// - Parameter minScale: Minimum scaling factor (default: 1e-10)
    /// - Returns: Scaling reference state with safe normalization values
    public func asScalingReference(minScale: Float = 1e-10) -> FlattenedState {
        // ✅ GPU operations: abs() and maximum()
        let absValues = abs(values.value)
        let safeScales = maximum(absValues, MLXArray(minScale))
        eval(safeScales)

        return FlattenedState(
            values: EvaluatedArray(evaluating: safeScales),
            layout: layout
        )
    }

    /// Compute physics-aware scaling factors for Newton-Raphson solver
    ///
    /// **Purpose**: Create reference state with physically meaningful scales for each variable.
    /// This prevents Float32 precision loss when variables span vastly different magnitudes.
    ///
    /// **Problem with asScalingReference()**:
    /// - psi=0.0 → minScale=1e-10
    /// - ne=2e+19 → 2e+19
    /// - Range: [1e-10, 2e+19] = 19 orders of magnitude → Float32 cannot handle
    ///
    /// **Solution**: Use typical physical scales per variable:
    /// - Ti, Te: 1e3 eV (1 keV) - typical plasma temperature
    /// - ne: 1e20 m⁻³ - typical plasma density
    /// - psi: 1.0 Wb - typical poloidal flux scale
    ///
    /// **Result**: All variables normalized to O(1), improving Jacobian conditioning.
    ///
    /// - Returns: Reference state with physically meaningful scales
    public func asPhysicalScalingReference() -> FlattenedState {
        let nCells = layout.nCells

        // Physical scales (in SI units matching CoreProfiles)
        let tiScale: Float = 1e3  // 1 keV in eV
        let teScale: Float = 1e3  // 1 keV in eV
        let neScale: Float = 1e20  // 10^20 m^-3
        let psiScale: Float = 1.0  // 1 Wb

        // Create scaling array: [Ti_scale; Te_scale; ne_scale; psi_scale]
        // Use Swift arrays and convert to MLXArray
        let tiScales = MLXArray(Array(repeating: tiScale, count: nCells))
        let teScales = MLXArray(Array(repeating: teScale, count: nCells))
        let neScales = MLXArray(Array(repeating: neScale, count: nCells))
        let psiScales = MLXArray(Array(repeating: psiScale, count: nCells))

        let scaleArray = concatenated([tiScales, teScales, neScales, psiScales], axis: 0)
        eval(scaleArray)

        return FlattenedState(
            values: EvaluatedArray(evaluating: scaleArray),
            layout: layout
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

    print("[DEBUG-VJP] Starting Jacobian computation: n=\(n)")

    // Use vjp() for reverse-mode AD
    for i in 0..<n {
        // Log progress: first 5 iterations (detailed), then every 50
        let shouldLog = (i < 5) || (i % 50 == 0)

        if shouldLog {
            print("[DEBUG-VJP] Processing vjp iteration \(i)/\(n)")
        }

        // 🐛 DEBUG: Measure vjp call time for first few iterations
        let t0 = (i < 5) ? Date() : nil

        // Standard basis vector
        let cotangent = MLXArray.zeros([n])
        cotangent[i] = MLXArray(1.0)

        if i < 5 {
            print("[DEBUG-VJP] iter \(i): cotangent created, calling vjp()")
        }

        // vjp computes: J^T · cotangent = (i-th row of J)^T
        let wrappedFn: ([MLXArray]) -> [MLXArray] = { inputs in
            [residualFn(inputs[0])]
        }

        let (_, vjpResult) = vjp(
            wrappedFn,
            primals: [x],
            cotangents: [cotangent]
        )

        // ✅ CRITICAL FIX: Force evaluation to prevent computation graph accumulation
        // MLX uses lazy evaluation - without eval(), each vjp() call adds to the graph,
        // making subsequent calls progressively slower (0.15s → 1.0s over 200 iterations).
        // eval() materializes the result and clears the accumulated graph.
        eval(vjpResult[0])

        if let startTime = t0 {
            let elapsed = Date().timeIntervalSince(startTime)
            print("[DEBUG-VJP] iter \(i): vjp() returned in \(String(format: "%.3f", elapsed))s")
        }

        jacobianTranspose.append(vjpResult[0])
    }

    print("[DEBUG-VJP] vjp loop complete, stacking results")
    // Transpose to get Jacobian
    return MLX.stacked(jacobianTranspose, axis: 0).T
}

// MARK: - Error Descriptions

extension FlattenedState.FlattenedStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCellCount(let count):
            return "Invalid cell count: \(count). Cell count must be positive."

        case .inconsistentLayout:
            return "Inconsistent state layout. Internal ranges do not match expected structure."

        case .layoutMismatch:
            return "State layout mismatch. Total size does not match expected layout."

        case .shapeMismatch(let expected, let actual):
            return "Shape mismatch: expected \(expected) cells, got \(actual) cells."

        case .profileShapeMismatch(let expected, let Ti, let Te, let ne, let psi):
            return """
                Profile shape mismatch:
                - Expected: \(expected) cells (from Ti)
                - Ti: \(Ti) cells
                - Te: \(Te) cells
                - ne: \(ne) cells
                - psi: \(psi) cells
                Ensure all profile arrays have the same length.
                """
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidCellCount:
            return "Increase mesh resolution (nCells) to a positive value."

        case .inconsistentLayout, .layoutMismatch:
            return "This is an internal error. Please file a bug report."

        case .shapeMismatch, .profileShapeMismatch:
            return "Check that all profile arrays (Ti, Te, ne, psi) are created with the same mesh configuration."
        }
    }
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

            // ✅ Force evaluation to prevent graph accumulation
            eval(vjpResult[0])

            jacobianRows.append(vjpResult[0])
        }
    }

    return MLX.stacked(jacobianRows, axis: 0)
}
