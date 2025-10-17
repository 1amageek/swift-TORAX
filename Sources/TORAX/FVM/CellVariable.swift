import MLX
import Foundation

// MARK: - MLX Utilities

/// Compute forward difference along axis
private func diff(_ array: MLXArray, axis: Int = 0) -> MLXArray {
    let shape = array.shape
    guard axis < shape.count else {
        fatalError("Axis \(axis) out of bounds for array with ndim=\(shape.count)")
    }

    // For 1D array, compute array[1:] - array[:-1]
    if axis == 0 {
        let left = array[0..<(shape[0] - 1)]
        let right = array[1..<shape[0]]
        return right - left
    }

    fatalError("diff() currently only supports axis=0")
}

// MARK: - Cell Variable

/// Grid variable with boundary conditions for 1D finite volume method
///
/// `CellVariable` represents values discretized on a 1D uniform grid.
/// It stores values at cell centers and handles boundary conditions
/// at the leftmost and rightmost faces.
///
/// Note: This type now uses EvaluatedArray to ensure type safety.
/// It is pure Sendable since all fields are Sendable.
public struct CellVariable: Sendable {
    // MARK: - Properties

    /// Values at cell centers (shape: [nCells])
    public let value: EvaluatedArray

    /// Distance between cell centers
    public let dr: Float

    /// Optional value constraint for the leftmost face
    public let leftFaceConstraint: Float?

    /// Optional gradient constraint for the leftmost face
    public let leftFaceGradConstraint: Float?

    /// Optional value constraint for the rightmost face
    public let rightFaceConstraint: Float?

    /// Optional gradient constraint for the rightmost face
    public let rightFaceGradConstraint: Float?

    // MARK: - Initialization

    /// Create a cell variable with optional boundary conditions
    ///
    /// - Parameters:
    ///   - value: Values at cell centers (will be evaluated)
    ///   - dr: Distance between cell centers
    ///   - leftFaceConstraint: Optional value constraint for left boundary
    ///   - leftFaceGradConstraint: Optional gradient constraint for left boundary
    ///   - rightFaceConstraint: Optional value constraint for right boundary
    ///   - rightFaceGradConstraint: Optional gradient constraint for right boundary
    ///
    /// - Note: Exactly one of (leftFaceConstraint, leftFaceGradConstraint) must be non-nil,
    ///         and exactly one of (rightFaceConstraint, rightFaceGradConstraint) must be non-nil
    public init(
        value: MLXArray,
        dr: Float,
        leftFaceConstraint: Float? = nil,
        leftFaceGradConstraint: Float? = nil,
        rightFaceConstraint: Float? = nil,
        rightFaceGradConstraint: Float? = nil
    ) {
        precondition(value.ndim == 1, "CellVariable value must be 1D array")
        precondition(dr > 0, "dr must be positive")

        // Validate left boundary condition
        let hasLeftValue = leftFaceConstraint != nil
        let hasLeftGrad = leftFaceGradConstraint != nil
        precondition(
            hasLeftValue != hasLeftGrad,
            "Exactly one of leftFaceConstraint or leftFaceGradConstraint must be set"
        )

        // Validate right boundary condition
        let hasRightValue = rightFaceConstraint != nil
        let hasRightGrad = rightFaceGradConstraint != nil
        precondition(
            hasRightValue != hasRightGrad,
            "Exactly one of rightFaceConstraint or rightFaceGradConstraint must be set"
        )

        self.value = EvaluatedArray(evaluating: value)
        self.dr = dr
        self.leftFaceConstraint = leftFaceConstraint
        self.leftFaceGradConstraint = leftFaceGradConstraint
        self.rightFaceConstraint = rightFaceConstraint
        self.rightFaceGradConstraint = rightFaceGradConstraint
    }

    // MARK: - Computed Properties

    /// Number of cells
    public var nCells: Int {
        value.shape[0]
    }

    /// Number of faces (nCells + 1)
    public var nFaces: Int {
        nCells + 1
    }

    // MARK: - Face Value Calculation

    /// Calculate values at faces
    ///
    /// Inner faces are calculated as the average of neighboring cell values.
    /// Boundary faces use the specified constraints.
    ///
    /// - Returns: Array of face values (shape: [nFaces])
    public func faceValue() -> MLXArray {
        // Extract underlying MLXArray for computation
        let cellValues = value.value

        // Left face value (reshape to [1] for concatenation)
        let leftValue: MLXArray
        if let constraint = leftFaceConstraint {
            leftValue = MLXArray([constraint])
        } else {
            // Use leftmost cell value as default
            leftValue = cellValues[0..<1]
        }

        // Inner face values (average of neighbors)
        let leftCells = cellValues[0..<(nCells - 1)]
        let rightCells = cellValues[1..<nCells]
        let innerValues = (leftCells + rightCells) / 2.0

        // Right face value (reshape to [1] for concatenation)
        let rightValue: MLXArray
        if let constraint = rightFaceConstraint {
            rightValue = MLXArray([constraint])
        } else if let gradConstraint = rightFaceGradConstraint {
            // Calculate from gradient constraint: value[end] + grad * dr/2
            let lastCell = cellValues[(nCells - 1)..<nCells]
            rightValue = lastCell + MLXArray(gradConstraint * dr / 2.0)
        } else {
            fatalError("Right boundary condition not properly set")
        }

        // Concatenate: [left, inner..., right]
        return concatenated([leftValue, innerValues, rightValue], axis: 0)
    }

    // MARK: - Face Gradient Calculation

    /// Calculate gradients at faces
    ///
    /// Gradients are computed using forward differences between cells,
    /// with boundary gradients determined by the specified constraints.
    ///
    /// - Parameter x: Optional coordinate array for non-uniform grids
    /// - Returns: Array of face gradients (shape: [nFaces])
    public func faceGrad(x: MLXArray? = nil) -> MLXArray {
        // Extract underlying MLXArray for computation
        let cellValues = value.value

        // Forward difference for inner faces
        let difference = diff(cellValues, axis: 0)
        let dx = x != nil ? diff(x!, axis: 0) : MLXArray(dr)
        let forwardDiff = difference / dx

        // Left gradient (reshape to [1] for concatenation)
        let leftGrad: MLXArray
        if let gradConstraint = leftFaceGradConstraint {
            leftGrad = MLXArray([gradConstraint])
        } else if let valueConstraint = leftFaceConstraint {
            // Calculate from value constraint: (value[0] - constraint) / (dr/2)
            let firstCell = cellValues[0..<1]
            leftGrad = (firstCell - MLXArray(valueConstraint)) / MLXArray(dr / 2.0)
        } else {
            fatalError("Left boundary condition not properly set")
        }

        // Right gradient (reshape to [1] for concatenation)
        let rightGrad: MLXArray
        if let gradConstraint = rightFaceGradConstraint {
            rightGrad = MLXArray([gradConstraint])
        } else if let valueConstraint = rightFaceConstraint {
            // Calculate from value constraint: (constraint - value[end]) / (dr/2)
            let lastCell = cellValues[(nCells - 1)..<nCells]
            rightGrad = (MLXArray(valueConstraint) - lastCell) / MLXArray(dr / 2.0)
        } else {
            fatalError("Right boundary condition not properly set")
        }

        // Concatenate: [left, forward_diff..., right]
        return concatenated([leftGrad, forwardDiff, rightGrad], axis: 0)
    }

    // MARK: - Cell Gradient

    /// Calculate gradients at cell centers
    ///
    /// This is computed as the difference of face values divided by dr.
    ///
    /// - Returns: Array of cell gradients (shape: [nCells])
    public func grad() -> MLXArray {
        let faceVals = faceValue()
        let difference = diff(faceVals, axis: 0)
        return difference / MLXArray(dr)
    }
}

// MARK: - Equatable Conformance

extension CellVariable: Equatable {
    public static func == (lhs: CellVariable, rhs: CellVariable) -> Bool {
        // Compare all properties
        guard lhs.dr == rhs.dr,
              lhs.leftFaceConstraint == rhs.leftFaceConstraint,
              lhs.leftFaceGradConstraint == rhs.leftFaceGradConstraint,
              lhs.rightFaceConstraint == rhs.rightFaceConstraint,
              lhs.rightFaceGradConstraint == rhs.rightFaceGradConstraint else {
            return false
        }

        // Compare evaluated arrays
        return lhs.value == rhs.value
    }
}
