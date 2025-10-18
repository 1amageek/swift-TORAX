# TORAX Finite Volume Method (FVM) Implementation Guide

**Version**: 2.0 (Corrected)
**Date**: 2025-10-18
**Status**: Verified against actual implementation

This document provides accurate implementation details for TORAX's Finite Volume Method in Swift using MLX, verified against the actual codebase.

---

## Table of Contents

1. [Overview](#overview)
2. [Grid Structure](#grid-structure)
3. [CellVariable: Grid Variables with Boundary Conditions](#cellvariable)
4. [Spatial Discretization](#spatial-discretization)
5. [Power-Law Interpolation Scheme](#power-law-scheme)
6. [Flux Calculation](#flux-calculation)
7. [Block1DCoeffs Structure](#block1dcoeffs-structure)
8. [Temporal Discretization: Theta Method](#temporal-discretization)
9. [Boundary Conditions](#boundary-conditions)
10. [Implementation Notes](#implementation-notes)

---

## Overview

TORAX uses a **Finite Volume Method (FVM)** for spatial discretization of 1D transport PDEs on a uniform grid in normalized toroidal flux coordinates (ρ̂). The temporal discretization uses the **theta method**, which provides a unified framework for explicit Euler (θ=0), Crank-Nicolson (θ=0.5), and implicit Euler (θ=1) schemes.

### Generic Conservation Law

```
∂x/∂t + ∇·Γ = S
```

Where:
- `x`: conserved quantity (Ti, Te, ne, psi)
- `Γ`: flux (diffusion + convection)
- `S`: source term

---

## Grid Structure

### Uniform 1D Grid

TORAX divides the domain [0,1] in normalized toroidal flux coordinates (ρ̂) into **N cells**:

```
Grid spacing:     dρ̂ = 1/N
Cell centers:     ρ̂ᵢ where i = 0, 1, ..., N-1
Cell faces:       ρ̂ᵢ₊₁/₂ where i = 0, 1, ..., N
                  (N+1 faces total, including boundaries)
```

**Important**: Both boundaries (ρ̂=0 and ρ̂=1) are located on the **face grid**, not the cell grid.

### Grid Dimensions

- **Cells**: `[nCells]` - values at cell centers
- **Faces**: `[nFaces]` where `nFaces = nCells + 1` - values at cell boundaries

---

## CellVariable: Grid Variables with Boundary Conditions

### Structure Definition

**Source**: `Sources/TORAX/FVM/CellVariable.swift`

```swift
/// Grid variable with boundary conditions for 1D finite volume method
public struct CellVariable: Sendable, Equatable {
    /// Values at cell centers (shape: [nCells])
    /// Internal storage as EvaluatedArray for type safety
    public let value: EvaluatedArray

    /// Distance between cell centers (uniform grid)
    public let dr: Float

    // Boundary conditions (exactly one constraint per face)

    /// Left face (ρ̂=0) Dirichlet condition (value)
    public let leftFaceConstraint: Float?

    /// Left face (ρ̂=0) Neumann condition (gradient)
    public let leftFaceGradConstraint: Float?

    /// Right face (ρ̂=1) Dirichlet condition (value)
    public let rightFaceConstraint: Float?

    /// Right face (ρ̂=1) Neumann condition (gradient)
    public let rightFaceGradConstraint: Float?

    /// Number of cells
    public var nCells: Int {
        value.shape[0]
    }

    /// Number of faces (nCells + 1)
    public var nFaces: Int {
        nCells + 1
    }
}
```

### Initialization

**CRITICAL**:
- Accepts `MLXArray` (NOT `EvaluatedArray`)
- Does NOT throw (uses `precondition`)
- Wraps input in `EvaluatedArray` internally

```swift
public init(
    value: MLXArray,           // ← MLXArray input
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

    self.value = EvaluatedArray(evaluating: value)  // ← Wrap in EvaluatedArray
    self.dr = dr
    self.leftFaceConstraint = leftFaceConstraint
    self.leftFaceGradConstraint = leftFaceGradConstraint
    self.rightFaceConstraint = rightFaceConstraint
    self.rightFaceGradConstraint = rightFaceGradConstraint
}
```

### Usage Example

```swift
// Create cell values (e.g., temperature profile)
let nCells = 25
let cellValues = MLXArray.ones([nCells]) * 1000.0  // 1000 eV

// Create CellVariable with boundary conditions
// NO try keyword - init does not throw!
let cellVar = CellVariable(
    value: cellValues,
    dr: 1.0 / Float(nCells),
    leftFaceGradConstraint: 0.0,    // Zero gradient at core (ρ̂=0)
    rightFaceConstraint: 100.0       // Fixed value at edge (ρ̂=1)
)
```

### Face Value Calculation

**CRITICAL**: Returns `MLXArray` (NOT `EvaluatedArray`)

```swift
/// Calculate values at faces
///
/// - Returns: Array of face values (shape: [nFaces]) as MLXArray
public func faceValue() -> MLXArray {
    // Extract underlying MLXArray for computation
    let cellValues = value.value

    // Left face value
    let leftValue: MLXArray
    if let constraint = leftFaceConstraint {
        leftValue = MLXArray([constraint])
    } else if let gradConstraint = leftFaceGradConstraint {
        // Linear extrapolation: x_face = x_cell0 - (dr/2) * gradient
        let firstCell = cellValues[0..<1]
        leftValue = firstCell - MLXArray(gradConstraint * dr / 2.0)
    } else {
        fatalError("Left boundary condition not properly set")
    }

    // Inner face values (average of neighbors)
    let leftCells = cellValues[0..<(nCells - 1)]
    let rightCells = cellValues[1..<nCells]
    let innerValues = (leftCells + rightCells) / 2.0

    // Right face value
    let rightValue: MLXArray
    if let constraint = rightFaceConstraint {
        rightValue = MLXArray([constraint])
    } else if let gradConstraint = rightFaceGradConstraint {
        let lastCell = cellValues[(nCells - 1)..<nCells]
        rightValue = lastCell + MLXArray(gradConstraint * dr / 2.0)
    } else {
        fatalError("Right boundary condition not properly set")
    }

    // Concatenate: [left, inner..., right]
    return concatenated([leftValue, innerValues, rightValue], axis: 0)
}
```

### Face Gradient Calculation

**CRITICAL**: Returns `MLXArray` (NOT `EvaluatedArray`)

**Note**: Uses private `diff()` helper function defined in CellVariable.swift

```swift
/// Calculate gradients at faces
///
/// - Parameter x: Optional coordinate array for non-uniform grids
/// - Returns: Array of face gradients (shape: [nFaces]) as MLXArray
public func faceGrad(x: MLXArray? = nil) -> MLXArray {
    let cellValues = value.value

    // Forward difference for inner faces
    // Uses private diff() function: array[1:] - array[:-1]
    let difference = diff(cellValues, axis: 0)
    let dx = x != nil ? diff(x!, axis: 0) : MLXArray(dr)
    let forwardDiff = difference / dx

    // Left gradient
    let leftGrad: MLXArray
    if let gradConstraint = leftFaceGradConstraint {
        leftGrad = MLXArray([gradConstraint])
    } else if let valueConstraint = leftFaceConstraint {
        let firstCell = cellValues[0..<1]
        leftGrad = (firstCell - MLXArray(valueConstraint)) / MLXArray(dr / 2.0)
    } else {
        fatalError("Left boundary condition not properly set")
    }

    // Right gradient
    let rightGrad: MLXArray
    if let gradConstraint = rightFaceGradConstraint {
        rightGrad = MLXArray([gradConstraint])
    } else if let valueConstraint = rightFaceConstraint {
        let lastCell = cellValues[(nCells - 1)..<nCells]
        rightGrad = (MLXArray(valueConstraint) - lastCell) / MLXArray(dr / 2.0)
    } else {
        fatalError("Right boundary condition not properly set")
    }

    // Concatenate: [left, forward_diff..., right]
    return concatenated([leftGrad, forwardDiff, rightGrad], axis: 0)
}
```

---

## Spatial Discretization

### Discretized Conservation Equation

Applying FVM to the conservation law:

```
∂x/∂t + ∇·Γ = S
```

Integrating over cell i and applying divergence theorem:

```
∂xᵢ/∂t + (1/dρ̂)·(Γᵢ₊₁/₂ - Γᵢ₋₁/₂) = Sᵢ
```

---

## Power-Law Interpolation Scheme

### Péclet Number

```
Pe = V·dρ̂/D
```

The Péclet number measures the ratio of convection to diffusion:
- Pe << 1: diffusion-dominated (use central differencing)
- Pe >> 1: convection-dominated (use upwinding)

### Weighting Factor α(Pe)

The power-law scheme provides a smooth transition (Patankar formulation):

```
α(Pe) = {
    (Pe - 1) / Pe                           if Pe > 10
    [(Pe - 1) + (1 - Pe/10)⁵] / Pe         if 0 < Pe ≤ 10
    [(1 + Pe/10)⁵ - 1] / Pe                if -10 ≤ Pe < 0
    -1 / Pe                                 if Pe < -10
}
```

**Special case**: When |Pe| < ε (very small), use α = 0.5 (central differencing).

### Reference Implementation

**NOTE**: This function is provided as reference implementation and is not currently present in the codebase.

```swift
/// Compute power-law weighting factor α from Péclet number (Reference)
///
/// This is a reference implementation for documentation purposes.
/// Production code should implement this based on specific physics requirements.
public func pecletToAlpha(_ peclet: MLXArray) -> MLXArray {
    let eps: Float = 1e-3

    // Avoid division by zero
    let p = MLX.where(abs(peclet) .< eps, eps, peclet)

    // Four regions
    let alphaLarge = (p - 1) / p                              // Pe > 10
    let alphaPositive = ((p - 1) + pow(1 - p/10, 5)) / p     // 0 < Pe ≤ 10
    let alphaNegative = (pow(1 + p/10, 5) - 1) / p           // -10 ≤ Pe < 0
    let alphaSmall = -1 / p                                   // Pe < -10

    // Default to central differencing
    var alpha = MLXArray(0.5, shape: p.shape, type: p.dtype)

    // Apply conditions
    alpha = MLX.where(p .> 10.0, alphaLarge, alpha)
    alpha = MLX.where((p .> eps) .&& (p .<= 10.0), alphaPositive, alpha)
    alpha = MLX.where((p .>= -10.0) .&& (p .< -eps), alphaNegative, alpha)
    alpha = MLX.where(p .< -10.0, alphaSmall, alpha)

    return alpha
}
```

---

## Flux Calculation

### Flux Decomposition

```
Γ = -D·(∂x/∂ρ̂) + V·x
```

At face i+1/2:

```
Γᵢ₊₁/₂ = -Dᵢ₊₁/₂·(∂x/∂ρ̂)ᵢ₊₁/₂ + Vᵢ₊₁/₂·xᵢ₊₁/₂
```

### Reference Implementation

**CRITICAL**: Uses CellVariable methods which return `MLXArray`

**NOTE**: This function is provided as reference implementation and is not currently present in the codebase.

```swift
/// Calculate fluxes at cell faces (Reference)
///
/// This is a reference implementation for documentation purposes.
/// Uses CellVariable's faceGrad() and faceValue() methods which
/// correctly handle boundary conditions and produce [nFaces] arrays.
///
/// - Parameters:
///   - cellValues: CellVariable containing cell-centered values
///   - dFace: Diffusion coefficients at faces [nFaces]
///   - vFace: Convection coefficients at faces [nFaces]
/// - Returns: Total flux at faces [nFaces]
public func calculateFluxes(
    cellValues: CellVariable,
    dFace: EvaluatedArray,
    vFace: EvaluatedArray
) -> EvaluatedArray {
    let d = dFace.value     // Extract MLXArray [nFaces]
    let v = vFace.value     // Extract MLXArray [nFaces]

    // CellVariable methods return MLXArray (not EvaluatedArray)
    let faceGrad = cellValues.faceGrad()   // MLXArray [nFaces]
    let faceValues = cellValues.faceValue() // MLXArray [nFaces]

    // Diffusion flux: -D·(∂x/∂ρ̂)
    let diffusionFlux = -d * faceGrad

    // Convection flux: V·xᵢ₊₁/₂
    let convectionFlux = v * faceValues

    // Total flux at faces
    let totalFlux = diffusionFlux + convectionFlux

    return EvaluatedArray(evaluating: totalFlux)
}
```

---

## Block1DCoeffs Structure

**Source**: `Sources/TORAX/Solver/Block1DCoeffs.swift`

### Actual Structure

**CRITICAL**: Uses **per-equation** structure, NOT flat arrays

```swift
/// Block-structured coefficients for coupled 1D transport equations
public struct Block1DCoeffs: Sendable {
    /// Coefficients for ion temperature equation
    public let ionCoeffs: EquationCoeffs

    /// Coefficients for electron temperature equation
    public let electronCoeffs: EquationCoeffs

    /// Coefficients for electron density equation
    public let densityCoeffs: EquationCoeffs

    /// Coefficients for poloidal flux equation
    public let fluxCoeffs: EquationCoeffs

    /// Geometric factors (shared across all equations)
    public let geometry: GeometricFactors
}

/// Coefficients for a single PDE equation
public struct EquationCoeffs: Sendable {
    /// Diffusion coefficient at cell faces [nFaces]
    public let dFace: EvaluatedArray

    /// Convection velocity at cell faces [nFaces]
    public let vFace: EvaluatedArray

    /// Source term in cells [nCells]
    public let sourceCell: EvaluatedArray

    /// Source matrix coefficient in cells [nCells]
    public let sourceMatCell: EvaluatedArray

    /// Transient coefficient for time stepping [nCells]
    public let transientCoeff: EvaluatedArray
}

/// Geometric factors for finite volume discretization
public struct GeometricFactors: Sendable {
    /// Cell volumes [nCells]
    public let cellVolumes: EvaluatedArray

    /// Face areas [nFaces]
    public let faceAreas: EvaluatedArray

    /// Distance between adjacent cell centers [nCells-1]
    public let cellDistances: EvaluatedArray

    /// Radial coordinate at cell centers [nCells]
    public let rCell: EvaluatedArray

    /// Radial coordinate at cell faces [nFaces]
    public let rFace: EvaluatedArray
}
```

### Usage Example

```swift
/// Construct coefficients for all equations
func buildBlock1DCoeffs(
    profiles: CoreProfiles,
    geometry: Geometry,
    transportCoeffs: TransportCoefficients,
    sourceTerms: SourceTerms
) -> Block1DCoeffs {
    let geoFactors = GeometricFactors.from(geometry: geometry)

    // Build per-equation coefficients
    //
    // Note: TransportCoefficients has fields:
    //   - chiIon, chiElectron (diffusivities)
    //   - particleDiffusivity
    //   - convectionVelocity (shared for all equations)
    //
    // There are NO separate vIon/vElectron fields. Use convectionVelocity for all.

    let ionCoeffs = EquationCoeffs(
        dFace: transportCoeffs.chiIon,
        vFace: transportCoeffs.convectionVelocity,  // ← Use convectionVelocity
        sourceCell: sourceTerms.ionHeating,
        sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
        transientCoeff: profiles.electronDensity  // n_e multiplies ∂T_i/∂t
    )

    let electronCoeffs = EquationCoeffs(
        dFace: transportCoeffs.chiElectron,
        vFace: transportCoeffs.convectionVelocity,  // ← Use convectionVelocity
        sourceCell: sourceTerms.electronHeating,
        sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
        transientCoeff: profiles.electronDensity
    )

    let densityCoeffs = EquationCoeffs(
        dFace: transportCoeffs.particleDiffusivity,
        vFace: transportCoeffs.convectionVelocity,
        sourceCell: sourceTerms.particleSource,
        sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
        transientCoeff: EvaluatedArray.ones([geometry.nCells])
    )

    let fluxCoeffs = EquationCoeffs(
        dFace: EvaluatedArray.zeros([geometry.nCells + 1]),
        vFace: EvaluatedArray.zeros([geometry.nCells + 1]),
        sourceCell: sourceTerms.currentSource,  // ← Correct field name
        sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
        transientCoeff: EvaluatedArray.ones([geometry.nCells])
    )

    return Block1DCoeffs(
        ionCoeffs: ionCoeffs,
        electronCoeffs: electronCoeffs,
        densityCoeffs: densityCoeffs,
        fluxCoeffs: fluxCoeffs,
        geometry: geoFactors
    )
}
```

---

## Temporal Discretization: Theta Method

### Theta Parameter Values

- **θ = 0**: Explicit Euler (unstable for stiff problems)
- **θ = 0.5**: Crank-Nicolson (second-order accurate, A-stable)
- **θ = 1**: Implicit Euler (L-stable, preferred for stiff transport)

### Matrix Equation Form

```
[T̃_{t+Δt} - θ·Δt·C̄_{t+Δt}]·x_{t+Δt} =
    [T̃_t + (1-θ)·Δt·C̄_t]·x_t + Δt·sources
```

### Helper Functions

**CRITICAL**: CoreProfiles uses EvaluatedArray, need `.value` to extract MLXArray

```swift
/// Flatten CoreProfiles to state vector
///
/// CoreProfiles stores EvaluatedArray, so we need .value to get MLXArray
func flattenCoreProfiles(_ profiles: CoreProfiles) -> MLXArray {
    return concatenated([
        profiles.ionTemperature.value,      // .value extracts MLXArray
        profiles.electronTemperature.value,
        profiles.electronDensity.value,
        profiles.poloidalFlux.value
    ], axis: 0)
}

/// Unflatten state vector to CoreProfiles
///
/// NOTE: This is a helper for documentation - actual implementation
/// would use FlattenedState.toCoreProfiles()
func unflattenToProfiles(_ vector: MLXArray, nCells: Int) -> CoreProfiles {
    let tiRange = 0..<nCells
    let teRange = nCells..<(2*nCells)
    let neRange = (2*nCells)..<(3*nCells)
    let psiRange = (3*nCells)..<(4*nCells)

    return CoreProfiles(
        ionTemperature: EvaluatedArray(evaluating: vector[tiRange]),
        electronTemperature: EvaluatedArray(evaluating: vector[teRange]),
        electronDensity: EvaluatedArray(evaluating: vector[neRange]),
        poloidalFlux: EvaluatedArray(evaluating: vector[psiRange])
    )
}

/// Concatenate transient coefficients from all equations
func concatenateTransientCoeffs(_ coeffs: Block1DCoeffs) -> MLXArray {
    return concatenated([
        coeffs.ionCoeffs.transientCoeff.value,
        coeffs.electronCoeffs.transientCoeff.value,
        coeffs.densityCoeffs.transientCoeff.value,
        coeffs.fluxCoeffs.transientCoeff.value
    ], axis: 0)
}
```

---

## Boundary Conditions

### Dirichlet Boundary Conditions

**Definition**: Fix the value at the boundary.

```swift
// NO try keyword!
let cellVar = CellVariable(
    value: cellValues,
    dr: grid.dr,
    leftFaceConstraint: 0.0,      // x(0) = 0
    rightFaceConstraint: 1.0       // x(1) = 1
)
```

### Neumann Boundary Conditions

**Definition**: Fix the gradient at the boundary.

```swift
// NO try keyword!
let cellVar = CellVariable(
    value: cellValues,
    dr: grid.dr,
    leftFaceGradConstraint: 0.0,   // Zero gradient at core
    rightFaceConstraint: 1.0        // Fixed value at edge
)
```

### Typical TORAX Boundary Conditions

| Variable | Left (ρ̂=0) | Right (ρ̂=1) |
|----------|------------|--------------|
| T_i | Neumann (∂T_i/∂ρ̂ = 0) | Dirichlet (T_i = T_i_edge) |
| T_e | Neumann (∂T_e/∂ρ̂ = 0) | Dirichlet (T_e = T_e_edge) |
| n_e | Neumann (∂n_e/∂ρ̂ = 0) | Dirichlet (n_e = n_e_edge) |
| psi | Dirichlet (psi = 0) | Neumann (∂psi/∂ρ̂ ∝ I_p) |

---

## Implementation Notes

### Type Safety Rules

1. **CellVariable**:
   - Input: `MLXArray`
   - Storage: `EvaluatedArray` (internal)
   - Methods return: `MLXArray` (not EvaluatedArray)

2. **CoreProfiles**:
   - Storage: `EvaluatedArray` fields
   - Extract MLXArray: use `.value` property

3. **Block1DCoeffs**:
   - Uses per-equation structure
   - Each EquationCoeffs has separate dFace, vFace, etc.

### Common Mistakes

❌ **WRONG**:
```swift
// 1. Using try with CellVariable init
let cellVar = try CellVariable(...)  // ← NO! init doesn't throw

// 2. Expecting EvaluatedArray from faceValue()
let faces: EvaluatedArray = cellVar.faceValue()  // ← NO! Returns MLXArray

// 3. Accessing Block1DCoeffs.dFace directly
let d = coeffs.dFace  // ← NO! Must use coeffs.ionCoeffs.dFace

// 4. Forgetting .value when extracting MLXArray
let ti = profiles.ionTemperature  // ← Type is EvaluatedArray
// Need: profiles.ionTemperature.value to get MLXArray
```

✅ **CORRECT**:
```swift
// 1. CellVariable init without try
let cellVar = CellVariable(...)

// 2. Correct type for faceValue()
let faces: MLXArray = cellVar.faceValue()

// 3. Access via equation-specific coeffs
let d = coeffs.ionCoeffs.dFace.value  // MLXArray [nFaces]

// 4. Extract MLXArray from EvaluatedArray
let ti: MLXArray = profiles.ionTemperature.value
```

### Array Dimensions Reference

| Type | Dimension | Example |
|------|-----------|---------|
| Cell values | `[nCells]` | Temperature at cell centers |
| Face values | `[nFaces]` | Flux at cell boundaries |
| Diffusion coeff | `[nFaces]` | D at faces |
| Convection coeff | `[nFaces]` | V at faces |
| Source terms | `[nCells]` | Heating power at cells |
| Transient coeff | `[nCells]` | Time derivative multiplier |

---

## Summary

Key points for correct implementation:

1. **CellVariable.init()**: Takes `MLXArray`, no `try`, uses `precondition`
2. **faceValue()/faceGrad()**: Return `MLXArray` (not EvaluatedArray)
3. **Block1DCoeffs**: Per-equation structure (ionCoeffs, electronCoeffs, etc.)
4. **CoreProfiles**: EvaluatedArray storage, use `.value` to extract MLXArray
5. **Boundary conditions**: Set via optional Float parameters, validated by precondition

This guide is verified against actual implementation in:
- `Sources/TORAX/FVM/CellVariable.swift`
- `Sources/TORAX/Solver/Block1DCoeffs.swift`
- `Sources/TORAX/Solver/EquationCoeffs.swift`
