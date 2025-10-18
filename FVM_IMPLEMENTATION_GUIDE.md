# TORAX Finite Volume Method (FVM) Implementation Guide

This document provides comprehensive details for implementing TORAX's Finite Volume Method in Swift using MLX, based on research from the arXiv paper (arXiv:2406.06718v2) and the original TORAX codebase.

## Table of Contents

1. [Overview](#overview)
2. [Grid Structure](#grid-structure)
3. [CellVariable: Grid Variables with Boundary Conditions](#cellvariable)
4. [Spatial Discretization](#spatial-discretization)
5. [Flux Calculation](#flux-calculation)
6. [Temporal Discretization: Theta Method](#temporal-discretization)
7. [Block1DCoeffs Structure](#block1dcoeffs-structure)
8. [Matrix Assembly](#matrix-assembly)
9. [Boundary Conditions](#boundary-conditions)
10. [Solver Integration](#solver-integration)
11. [MLX Optimization Opportunities](#mlx-optimization)

---

## Overview

TORAX uses a **Finite Volume Method (FVM)** for spatial discretization of 1D transport PDEs on a uniform grid in normalized toroidal flux coordinates (ρ̂). The temporal discretization uses the **theta method**, which provides a unified framework for explicit Euler (θ=0), Crank-Nicolson (θ=0.5), and implicit Euler (θ=1) schemes.

The FVM approach:
1. Integrates the PDE over control volumes
2. Applies the divergence theorem to convert volume integrals to surface integrals
3. Produces a tridiagonal (or block-tridiagonal for coupled equations) linear system

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
Cell faces:       ρ̂ᵢ₊₁/₂ where i = -1, 0, ..., N-1
                  (N+1 faces total, including boundaries at i=-1 and i=N-1)
```

**Important**: Both boundaries (ρ̂=0 and ρ̂=1) are located on the **face grid**, not the cell grid.

### FiPy Convention

Following FiPy conventions, the 1D case is treated as a special case of 3D finite volume:
- Cell volume: `V = dρ̂ · A` (with arbitrary face area A)
- Face area: `A` (cancels out in 1D)
- In 1D, volume and area factors simplify, reducing FVM to finite differences

### Swift Implementation

```swift
/// 1D uniform grid for FVM discretization
public struct Grid1D: Sendable, Equatable {
    /// Number of cells
    public let nCells: Int

    /// Grid spacing (uniform)
    public let dr: Float

    /// Cell centers: ρ̂ᵢ ∈ [dr/2, 1 - dr/2]
    public let cellCenters: EvaluatedArray

    /// Cell faces: ρ̂ᵢ₊₁/₂ ∈ [0, 1]
    /// Length: nCells + 1 (includes both boundaries)
    public let cellFaces: EvaluatedArray

    public init(nCells: Int) throws {
        guard nCells > 0 else {
            throw Grid1DError.invalidCellCount(nCells)
        }

        self.nCells = nCells
        self.dr = 1.0 / Float(nCells)

        // Cell centers at ρ̂ᵢ = (i + 0.5) * dr for i = 0...(nCells-1)
        let centers = MLXArray(0..<nCells).asType(.float32) * dr + dr/2
        self.cellCenters = EvaluatedArray(evaluating: centers)

        // Cell faces at ρ̂ᵢ₊₁/₂ = i * dr for i = 0...nCells
        let faces = MLXArray(0...nCells).asType(.float32) * dr
        self.cellFaces = EvaluatedArray(evaluating: faces)
    }
}
```

---

## CellVariable: Grid Variables with Boundary Conditions

The `CellVariable` structure represents variables on the FVM grid with boundary conditions.

### Structure

```swift
/// Variable on 1D FVM mesh with boundary conditions
public struct CellVariable: Sendable, Equatable {
    /// Values at cell centers (length: nCells)
    public let value: EvaluatedArray

    /// Grid spacing (uniform)
    public let dr: Float

    // Boundary conditions (exactly one constraint per face)

    /// Left face (ρ̂=0) Dirichlet condition
    public let leftFaceConstraint: Float?

    /// Left face (ρ̂=0) Neumann condition (gradient)
    public let leftFaceGradConstraint: Float?

    /// Right face (ρ̂=1) Dirichlet condition
    public let rightFaceConstraint: Float?

    /// Right face (ρ̂=1) Neumann condition (gradient)
    public let rightFaceGradConstraint: Float?

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
}
```

### Face Value Calculation

**IMPORTANT**: Both `faceValue()` and `faceGrad()` return `MLXArray`, NOT `EvaluatedArray`.

```swift
extension CellVariable {
    /// Compute values at cell faces (length: nCells + 1)
    ///
    /// Inner faces are calculated as the average of neighboring cell values.
    /// Boundary faces use the specified constraints.
    ///
    /// - Returns: Array of face values (shape: [nFaces]) as MLXArray
    public func faceValue() -> MLXArray {
        // Extract underlying MLXArray for computation
        let cellValues = value.value

        // Left face value (reshape to [1] for concatenation)
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

    /// Calculate gradients at faces
    ///
    /// Gradients are computed using forward differences between cells,
    /// with boundary gradients determined by the specified constraints.
    ///
    /// - Parameter x: Optional coordinate array for non-uniform grids
    /// - Returns: Array of face gradients (shape: [nFaces]) as MLXArray
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
∂/∂t(Vᵢ·xᵢ) + (Γᵢ₊₁/₂·Aᵢ₊₁/₂ - Γᵢ₋₁/₂·Aᵢ₋₁/₂) = Vᵢ·Sᵢ
```

In 1D with V = dρ̂·A:

```
∂xᵢ/∂t + (1/dρ̂)·(Γᵢ₊₁/₂ - Γᵢ₋₁/₂) = Sᵢ
```

This is the fundamental discretized equation for each cell.

---

## Flux Calculation

### Flux Decomposition

The flux separates into **diffusion** and **convection** terms:

```
Γ = -D·(∂x/∂ρ̂) + V·x
```

Where:
- `D`: diffusion coefficient (≥ 0)
- `V`: convection coefficient (can be positive or negative)

### Face Fluxes

At face i+1/2 (between cells i and i+1):

```
Γᵢ₊₁/₂ = -Dᵢ₊₁/₂·(xᵢ₊₁ - xᵢ)/dρ̂ + Vᵢ₊₁/₂·xᵢ₊₁/₂
```

**Key challenge**: `xᵢ₊₁/₂` must be interpolated from cell values.

### Power-Law Interpolation Scheme

To handle varying Péclet numbers (ratio of convection to diffusion), TORAX uses a **power-law weighting scheme**:

```
xᵢ₊₁/₂ = αᵢ₊₁/₂·xᵢ + (1 - αᵢ₊₁/₂)·xᵢ₊₁
xᵢ₋₁/₂ = αᵢ₋₁/₂·xᵢ + (1 - αᵢ₋₁/₂)·xᵢ₋₁
```

#### Péclet Number

```
Pe = V·dρ̂/D
```

The Péclet number measures the ratio of convection to diffusion:
- Pe << 1: diffusion-dominated (use central differencing)
- Pe >> 1: convection-dominated (use upwinding)

#### Weighting Factor α(Pe)

The power-law scheme provides a smooth transition:

```
α(Pe) = {
    (Pe - 1) / Pe                           if Pe > 10
    [(Pe - 1) + (1 - Pe/10)⁵] / Pe         if 0 < Pe ≤ 10
    [(1 + Pe/10)⁵ - 1] / Pe                if -10 ≤ Pe < 0
    -1 / Pe                                 if Pe < -10
}
```

**Special case**: When |Pe| < ε (very small), use α = 0.5 (central differencing).

### Swift Implementation

```swift
/// Compute power-law weighting factor α from Péclet number
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

/// Calculate fluxes at cell faces
///
/// Computes total flux (diffusion + convection) at all face locations.
/// Uses CellVariable's faceGrad() and faceValue() methods which correctly
/// handle boundary conditions and produce [nFaces] arrays.
public func calculateFluxes(
    cellValues: CellVariable,
    dFace: EvaluatedArray,  // Diffusion coefficients at faces (nFaces = nCells+1)
    vFace: EvaluatedArray   // Convection coefficients at faces (nFaces = nCells+1)
) -> EvaluatedArray {
    let d = dFace.value     // [nFaces]
    let v = vFace.value     // [nFaces]

    // Use CellVariable methods to compute face gradients and values
    // These methods correctly handle boundaries and produce [nFaces] arrays
    let faceGrad = cellValues.faceGrad()   // [nFaces]
    let faceValues = cellValues.faceValue() // [nFaces]

    // Diffusion flux: -D·(∂x/∂ρ̂)
    // Both d and faceGrad are [nFaces], so result is [nFaces]
    let diffusionFlux = -d * faceGrad

    // Convection flux: V·xᵢ₊₁/₂ using power-law interpolation
    let convectionFlux = v * faceValues

    // Total flux at faces
    let totalFlux = diffusionFlux + convectionFlux

    return EvaluatedArray(evaluating: totalFlux)
}
```

---

## Temporal Discretization: Theta Method

The theta method provides a unified framework for time integration.

### Generic ODE Form

For an ODE:
```
dx/dt = F(x, t)
```

The theta method approximates:

```
x_{t+Δt} - x_t = Δt·[θ·F(x_{t+Δt}, t+Δt) + (1-θ)·F(x_t, t)]
```

### Theta Parameter Values

- **θ = 0**: Explicit Euler (forward Euler)
  - Unstable for stiff problems
  - Simple, but requires small timesteps

- **θ = 0.5**: Crank-Nicolson
  - Second-order accurate
  - Unconditionally stable (A-stable)
  - Can produce oscillations for stiff problems

- **θ = 1**: Implicit Euler (backward Euler)
  - First-order accurate
  - L-stable (strong damping)
  - Preferred for stiff transport problems

### TORAX State Evolution Equation

For the coupled PDE system, TORAX uses:

```
T̃(x_{t+Δt}, u_{t+Δt}) ⊙ x_{t+Δt} - T̃(x_t, u_t) ⊙ x_t =
    Δt·[θ(C̄(x_{t+Δt}, u_{t+Δt})·x_{t+Δt} + c(x_{t+Δt}, u_{t+Δt}))
        + (1-θ)(C̄(x_t, u_t)·x_t + c(x_t, u_t))]
```

Where:
- **x**: State vector (Ti, Te, ne, psi)
- **u**: Input parameters (time-dependent)
- **T̃**: Transient coefficient (element-wise multiplier)
- **C̄**: Discretization matrix (block-tridiagonal)
- **c**: Source/boundary condition vector
- **⊙**: Element-wise multiplication (Hadamard product)

### Matrix Equation Form

Rearranging for linear solver:

```
[T̃_{t+Δt} ⊙ I - θ·Δt·C̄_{t+Δt}]·x_{t+Δt} =
    [T̃_t ⊙ I + (1-θ)·Δt·C̄_t]·x_t + Δt·[θ·c_{t+Δt} + (1-θ)·c_t]
```

Or more compactly:

```
LHS·x_{t+Δt} = RHS
```

Where:
- **LHS** = `transient_in - θ·Δt·C̄_{t+Δt}` (implicit side)
- **RHS** = `transient_out + (1-θ)·Δt·C̄_t·x_t + Δt·sources` (explicit side)

### Swift Implementation

```swift
/// Theta method parameters
public struct ThetaMethodParams: Sendable {
    /// Theta parameter: 0 (explicit), 0.5 (Crank-Nicolson), 1 (implicit)
    public let theta: Float

    /// Timestep
    public let dt: Float

    public init(theta: Float, dt: Float) throws {
        guard (0...1).contains(theta) else {
            throw ThetaMethodError.invalidTheta(theta)
        }
        guard dt > 0 else {
            throw ThetaMethodError.invalidTimestep(dt)
        }
        self.theta = theta
        self.dt = dt
    }
}

/// Construct theta method matrices
///
/// **NOTE**: This is a SIMPLIFIED example. The actual implementation requires:
/// 1. Building block-tridiagonal matrices from per-equation EquationCoeffs
/// 2. Assembling contributions from all 4 equations (Ti, Te, ne, psi)
/// 3. Handling cross-coupling via sourceMatCell terms
///
/// For the actual implementation, see Block1DCoeffsBuilder which constructs
/// the full discretization matrix from EquationCoeffs.
public func thetaMethodMatrixEquation(
    coeffsOld: Block1DCoeffs,
    coeffsNew: Block1DCoeffs,
    xOld: CoreProfiles,
    params: ThetaMethodParams
) -> (lhs: MLXArray, rhs: MLXArray) {
    let theta = params.theta
    let dt = params.dt

    // Build discretization matrices from per-equation coefficients
    // (This requires matrix assembly - see calcC() function below)
    let (cMatOld, sourceOld) = buildDiscretizationMatrix(coeffs: coeffsOld)
    let (cMatNew, sourceNew) = buildDiscretizationMatrix(coeffs: coeffsNew)

    // Extract transient coefficients (concatenated from all equations)
    let transientOld = concatenateTransientCoeffs(coeffsOld)
    let transientNew = concatenateTransientCoeffs(coeffsNew)

    // State vector from CoreProfiles (flattened: [Ti; Te; ne; psi])
    let xOldVec = flattenCoreProfiles(xOld)

    // LHS: T̃_new - θ·dt·C̄_new
    // where T̃ is diagonal matrix with transient coefficients
    let tNew = diag(transientNew)
    let lhs = tNew - theta * dt * cMatNew

    // RHS: T̃_old·x_old + (1-θ)·dt·C̄_old·x_old + dt·[θ·s_new + (1-θ)·s_old]
    let tOld = diag(transientOld)
    let rhs = matmul(tOld, xOldVec)
            + (1 - theta) * dt * matmul(cMatOld, xOldVec)
            + dt * (theta * sourceNew + (1 - theta) * sourceOld)

    return (lhs, rhs)
}

/// Helper: Concatenate transient coefficients from all equations
private func concatenateTransientCoeffs(_ coeffs: Block1DCoeffs) -> MLXArray {
    return concatenated([
        coeffs.ionCoeffs.transientCoeff.value,
        coeffs.electronCoeffs.transientCoeff.value,
        coeffs.densityCoeffs.transientCoeff.value,
        coeffs.fluxCoeffs.transientCoeff.value
    ], axis: 0)
}

/// Helper: Flatten CoreProfiles to state vector
private func flattenCoreProfiles(_ profiles: CoreProfiles) -> MLXArray {
    return concatenated([
        profiles.ionTemperature.value,
        profiles.electronTemperature.value,
        profiles.electronDensity.value,
        profiles.poloidalFlux.value
    ], axis: 0)
}

/// Helper: Create diagonal matrix
private func diag(_ array: MLXArray) -> MLXArray {
    let n = array.shape[0]
    var mat = MLXArray.zeros([n, n])
    for i in 0..<n {
        mat[i, i] = array[i]
    }
    return mat
}
```

---

## Block1DCoeffs Structure

The `Block1DCoeffs` structure encapsulates all coefficients for the discretized PDE system at one instant in time.

**CRITICAL**: The actual implementation uses **per-equation coefficients** via `EquationCoeffs`, NOT a flat structure.

### Actual Structure Definition

```swift
/// Block-structured coefficients for coupled 1D transport equations
///
/// Manages coefficients for 4 coupled PDEs:
/// - Ti: Ion temperature
/// - Te: Electron temperature
/// - ne: Electron density
/// - psi: Poloidal flux
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
    /// For equation coupling: s_mat·ψ
    public let sourceMatCell: EvaluatedArray

    /// Transient coefficient for time stepping [nCells]
    /// Multiplies ∂ψ/∂t term (e.g., n_e for temperature equations)
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

### Relationship to Matrix Equation

The `Block1DCoeffs` fields are used to construct the discretization matrix `C̄` and source vector `c`:

1. **Diffusion terms** (`dFace`) → Contribute to tridiagonal structure of `C̄`
2. **Convection terms** (`vFace`, `dFace`) → Contribute to tridiagonal structure of `C̄`
3. **Implicit source matrix** (`sourceMatCell`) → Add coupling terms to `C̄`
4. **Explicit source vector** (`sourceCell`) → Add to source vector `c`

### Coefficient Computation

The `CoeffsCallback` is responsible for computing `Block1DCoeffs`:

```swift
/// Callback to compute coefficients from current state
public typealias CoeffsCallback = @Sendable (
    CoreProfiles,
    Geometry,
    DynamicRuntimeParams
) -> Block1DCoeffs

/// Example: Compute coefficients from transport and source models
func makeCoeffsCallback(
    transport: any TransportModel,
    sources: any SourceModel,
    staticParams: StaticRuntimeParams
) -> CoeffsCallback {
    return { profiles, geometry, dynamicParams in
        // 1. Compute transport coefficients (chi_i, chi_e, D, V)
        let transportCoeffs = transport.computeCoefficients(
            profiles: profiles,
            geometry: geometry,
            params: dynamicParams.transportParams
        )

        // 2. Compute source terms
        let sourceTerms = sources.computeTerms(
            profiles: profiles,
            geometry: geometry,
            params: dynamicParams.sourceParams
        )

        // 3. Build geometric factors
        let geoFactors = GeometricFactors.from(geometry: geometry)

        // 4. Build per-equation coefficients
        let ionCoeffs = EquationCoeffs(
            dFace: transportCoeffs.chiIon,      // Diffusion at faces
            vFace: transportCoeffs.vIon,         // Convection at faces
            sourceCell: sourceTerms.ionHeating,  // Source in cells
            sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),  // No coupling
            transientCoeff: profiles.electronDensity  // n_e multiplies ∂T_i/∂t
        )

        let electronCoeffs = EquationCoeffs(
            dFace: transportCoeffs.chiElectron,
            vFace: transportCoeffs.vElectron,
            sourceCell: sourceTerms.electronHeating,
            sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
            transientCoeff: profiles.electronDensity  // n_e multiplies ∂T_e/∂t
        )

        let densityCoeffs = EquationCoeffs(
            dFace: transportCoeffs.particleDiffusivity,
            vFace: transportCoeffs.convectionVelocity,
            sourceCell: sourceTerms.particleSource,
            sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
            transientCoeff: EvaluatedArray.ones([geometry.nCells])  // ∂n_e/∂t
        )

        let fluxCoeffs = EquationCoeffs(
            dFace: EvaluatedArray.zeros([geometry.nCells + 1]),  // No diffusion for psi
            vFace: EvaluatedArray.zeros([geometry.nCells + 1]),  // No convection for psi
            sourceCell: sourceTerms.currentDensity,
            sourceMatCell: EvaluatedArray.zeros([geometry.nCells]),
            transientCoeff: EvaluatedArray.ones([geometry.nCells])  // ∂ψ/∂t
        )

        // 5. Assemble Block1DCoeffs
        return Block1DCoeffs(
            ionCoeffs: ionCoeffs,
            electronCoeffs: electronCoeffs,
            densityCoeffs: densityCoeffs,
            fluxCoeffs: fluxCoeffs,
            geometry: geoFactors
        )
    }
}
```

---

## Matrix Assembly

The `calc_c` function assembles the discretization matrix `C̄` and source vector `c` from `Block1DCoeffs`.

### Assembly Process

1. **Initialize**: Create block-structured matrices/vectors (one block per channel)
2. **Add diffusion terms**: Call `make_diffusion_terms` for each channel
3. **Add convection terms**: Call `make_convection_terms` for each channel
4. **Add implicit sources**: Add `source_mat_cell` contributions
5. **Add explicit sources**: Add `source_cell` to vector `c`

### Diffusion Matrix Construction

For diffusion term `-D·(∂²x/∂ρ̂²)`, the discretization yields a tridiagonal matrix:

```
Diffusion matrix for cell i:
    diag[i]  = -(D_{i+1/2} + D_{i-1/2}) / dr²
    above[i] = D_{i+1/2} / dr²
    below[i] = D_{i-1/2} / dr²
```

Boundary adjustments:
- **Dirichlet BC**: Adjust diagonal and source vector
- **Neumann BC**: Adjust diagonal using gradient constraint

### Convection Matrix Construction

For convection term `V·(∂x/∂ρ̂)`, using power-law interpolation:

```
Convection matrix for cell i:
    diag[i]  = (α_{i-1/2}·V_{i-1/2} - α_{i+1/2}·V_{i+1/2}) / dr
    above[i] = -(1 - α_{i+1/2})·V_{i+1/2} / dr
    below[i] = (1 - α_{i-1/2})·V_{i-1/2} / dr
```

Where `α` is the power-law weighting factor from Péclet number.

### Swift Implementation

```swift
/// Construct discretization matrix and source vector
public func calcC(
    coeffs: Block1DCoeffs,
    cellVars: [CellVariable],
    nChannels: Int
) -> (cMat: EvaluatedArray, cVec: EvaluatedArray) {
    let nCells = cellVars[0].value.shape[0]

    // Initialize block matrices
    var cMat = MLXArray.zeros([nChannels * nCells, nChannels * nCells])
    var cVec = MLXArray.zeros([nChannels * nCells])

    // Process each channel
    for channel in 0..<nChannels {
        let blockStart = channel * nCells
        let blockEnd = blockStart + nCells

        // 1. Add diffusion terms (if present)
        if let dFace = coeffs.dFace {
            let (diffMat, diffVec) = makeDiffusionTerms(
                var: cellVars[channel],
                dFace: dFace
            )
            cMat[blockStart..<blockEnd, blockStart..<blockEnd] += diffMat.value
            cVec[blockStart..<blockEnd] += diffVec.value
        }

        // 2. Add convection terms (if present)
        if let vFace = coeffs.vFace, let dFace = coeffs.dFace {
            let (convMat, convVec) = makeConvectionTerms(
                var: cellVars[channel],
                vFace: vFace,
                dFace: dFace
            )
            cMat[blockStart..<blockEnd, blockStart..<blockEnd] += convMat.value
            cVec[blockStart..<blockEnd] += convVec.value
        }

        // 3. Add explicit source terms
        if let sourceCell = coeffs.sourceCell {
            cVec[blockStart..<blockEnd] += sourceCell.value
        }
    }

    // 4. Add implicit source coupling (cross-channel terms)
    if let sourceMatCell = coeffs.sourceMatCell {
        for i in 0..<nChannels {
            for j in 0..<nChannels {
                let iStart = i * nCells
                let jStart = j * nCells
                cMat[iStart..<(iStart+nCells), jStart..<(jStart+nCells)]
                    += sourceMatCell[i][j].value
            }
        }
    }

    return (
        cMat: EvaluatedArray(evaluating: cMat),
        cVec: EvaluatedArray(evaluating: cVec)
    )
}

/// Create diffusion matrix and vector
func makeDiffusionTerms(
    var cellVar: CellVariable,
    dFace: EvaluatedArray
) -> (mat: EvaluatedArray, vec: EvaluatedArray) {
    let nCells = cellVar.value.shape[0]
    let dr = cellVar.dr
    let d = dFace.value

    // Diagonal: -(d_{i+1/2} + d_{i-1/2})
    let diag = -(d[1..<(nCells+1)] + d[0..<nCells])

    // Off-diagonals: d_{i+1/2}
    let off = d[1..<nCells]

    var vec = MLXArray.zeros([nCells])

    // Apply boundary conditions
    var diagAdjusted = diag

    // Left boundary (i=0)
    if let leftConstraint = cellVar.leftFaceConstraint {
        // Dirichlet: modify diagonal and vector
        vec[0] = -d[0] * leftConstraint / (dr * dr)
    } else if let leftGradConstraint = cellVar.leftFaceGradConstraint {
        // Neumann: modify diagonal
        diagAdjusted[0] = -d[1]
        vec[0] = -d[0] * leftGradConstraint / dr
    }

    // Right boundary (i=nCells-1)
    if let rightConstraint = cellVar.rightFaceConstraint {
        vec[nCells-1] = -d[nCells] * rightConstraint / (dr * dr)
    } else if let rightGradConstraint = cellVar.rightFaceGradConstraint {
        diagAdjusted[nCells-1] = -d[nCells-1]
        vec[nCells-1] = d[nCells] * rightGradConstraint / dr
    }

    // Build tridiagonal matrix
    let mat = tridiag(diag: diagAdjusted, above: off, below: off) / (dr * dr)

    return (
        mat: EvaluatedArray(evaluating: mat),
        vec: EvaluatedArray(evaluating: vec)
    )
}

/// Create convection matrix and vector
func makeConvectionTerms(
    var cellVar: CellVariable,
    vFace: EvaluatedArray,
    dFace: EvaluatedArray
) -> (mat: EvaluatedArray, vec: EvaluatedArray) {
    let nCells = cellVar.value.shape[0]
    let dr = cellVar.dr
    let v = vFace.value
    let d = dFace.value

    // Compute Péclet number and alpha
    let peclet = v * dr / (d + 1e-10)
    let alpha = pecletToAlpha(peclet)

    // Split into left and right faces
    let leftAlpha = alpha[0..<nCells]    // α_{i-1/2}
    let rightAlpha = alpha[1..<(nCells+1)]  // α_{i+1/2}
    let leftV = v[0..<nCells]
    let rightV = v[1..<(nCells+1)]

    // Diagonal: (α_{i-1/2}·V_{i-1/2} - α_{i+1/2}·V_{i+1/2}) / dr
    let diag = (leftAlpha * leftV - rightAlpha * rightV) / dr

    // Above diagonal: -(1 - α_{i+1/2})·V_{i+1/2} / dr
    let above = -(1.0 - rightAlpha[0..<(nCells-1)]) * rightV[0..<(nCells-1)] / dr

    // Below diagonal: (1 - α_{i-1/2})·V_{i-1/2} / dr
    let below = (1.0 - leftAlpha[1..<nCells]) * leftV[1..<nCells] / dr

    let mat = tridiag(diag: diag, above: above, below: below)

    // Vector for boundary conditions (handled via ghost cell approach)
    let vec = MLXArray.zeros([nCells])

    return (
        mat: EvaluatedArray(evaluating: mat),
        vec: EvaluatedArray(evaluating: vec)
    )
}

/// Build tridiagonal matrix
func tridiag(
    diag: MLXArray,
    above: MLXArray,
    below: MLXArray
) -> MLXArray {
    let n = diag.shape[0]
    var mat = MLXArray.zeros([n, n])

    // Diagonal
    for i in 0..<n {
        mat[i, i] = diag[i]
    }

    // Above diagonal
    for i in 0..<(n-1) {
        mat[i, i+1] = above[i]
    }

    // Below diagonal
    for i in 1..<n {
        mat[i, i-1] = below[i-1]
    }

    return mat
}
```

---

## Boundary Conditions

TORAX supports both Dirichlet and Neumann boundary conditions, implemented using ghost cells.

### Dirichlet Boundary Conditions

**Definition**: Fix the value at the boundary.
```
x(ρ̂=0) = x_left  (left boundary)
x(ρ̂=1) = x_right (right boundary)
```

**Implementation**: Set face constraint in `CellVariable`:
```swift
let cellVar = try CellVariable(
    value: cellValues,
    dr: grid.dr,
    leftFaceConstraint: 0.0,      // x(0) = 0
    rightFaceConstraint: 1.0       // x(1) = 1
)
```

**Ghost cell approach**:
- Face value is directly set to constraint
- Affects diffusion/convection matrix assembly

### Neumann Boundary Conditions

**Definition**: Fix the gradient at the boundary.
```
∂x/∂ρ̂|_{ρ̂=0} = g_left
∂x/∂ρ̂|_{ρ̂=1} = g_right
```

**Implementation**: Set gradient constraint in `CellVariable`:
```swift
let cellVar = try CellVariable(
    value: cellValues,
    dr: grid.dr,
    leftFaceGradConstraint: 0.0,   // Zero gradient at core
    rightFaceConstraint: 1.0        // Fixed value at edge
)
```

**Ghost cell approach**:
- Ghost cell value determined by: `x_ghost = x_boundary ± (dr/2) · gradient`
- Linear extrapolation through edge cells

### Typical TORAX Boundary Conditions

| Variable | Left (ρ̂=0) | Right (ρ̂=1) |
|----------|------------|--------------|
| T_i (ion temp) | Neumann (∂T_i/∂ρ̂ = 0) | Dirichlet (T_i = T_i_edge) |
| T_e (electron temp) | Neumann (∂T_e/∂ρ̂ = 0) | Dirichlet (T_e = T_e_edge) |
| n_e (density) | Neumann (∂n_e/∂ρ̂ = 0) | Dirichlet (n_e = n_e_edge) |
| psi (poloidal flux) | Dirichlet (psi = 0) | Neumann (∂psi/∂ρ̂ ∝ I_p) |

---

## Solver Integration

### Linear Solver (Predictor-Corrector)

For the linear system:
```
LHS·x_{t+Δt} = RHS
```

**Strategy**: Fixed-point iteration
- Coefficients evaluated at iteration k-1
- Makes equation linear at each iteration
- Solve via standard linear algebra

```swift
func linearSolve(
    coeffsOld: Block1DCoeffs,
    coeffsNew: Block1DCoeffs,
    xOld: CoreProfiles,
    params: ThetaMethodParams
) -> CoreProfiles {
    // Build matrix equation
    let (lhs, rhs) = thetaMethodMatrixEquation(
        coeffsOld: coeffsOld,
        coeffsNew: coeffsNew,
        xOld: xOld,
        params: params
    )

    // Solve linear system
    let xNewVec = solve(lhs, rhs)  // MLX linear solver

    // Convert back to CoreProfiles
    return CoreProfiles.fromVector(EvaluatedArray(evaluating: xNewVec))
}
```

### Newton-Raphson Solver

For nonlinear systems, use iterative root-finding:

**Residual function**:
```
R(x_{t+Δt}) = [T̃·I - θ·Δt·C̄(x_{t+Δt})]·x_{t+Δt}
            - [T̃·I + (1-θ)·Δt·C̄]·x_t
            - Δt·sources
```

**Newton iteration**:
```
1. Compute residual: R(x_k)
2. Compute Jacobian: J(x_k) = ∂R/∂x
3. Solve linear system: J·δx = -R
4. Update: x_{k+1} = x_k + δx
5. Repeat until ||R|| < tolerance
```

**JAX autodiff advantage**: Jacobian computed automatically via `jax.jacfwd`.

**MLX implementation**:
```swift
func newtonRaphsonSolve(
    coeffsCallback: CoeffsCallback,
    xOld: CoreProfiles,
    geometry: Geometry,
    params: ThetaMethodParams,
    dynamicParams: DynamicRuntimeParams,
    maxIterations: Int = 30,
    tolerance: Float = 1e-6
) -> CoreProfiles {
    var xNew = xOld  // Initial guess

    for iteration in 0..<maxIterations {
        // 1. Compute coefficients at current guess
        let coeffsNew = coeffsCallback(xNew, geometry, dynamicParams)
        let coeffsOld = coeffsCallback(xOld, geometry, dynamicParams)

        // 2. Flatten state for differentiation
        let flatState = try! FlattenedState(profiles: xNew)

        // 3. Define residual function
        let residualFn = { (stateVec: MLXArray) -> MLXArray in
            let profiles = FlattenedState(
                values: EvaluatedArray(evaluating: stateVec),
                layout: flatState.layout
            ).toCoreProfiles()

            let coeffs = coeffsCallback(profiles, geometry, dynamicParams)
            let (lhs, rhs) = thetaMethodMatrixEquation(
                coeffsOld: coeffsOld,
                coeffsNew: coeffs,
                xOld: xOld,
                params: params
            )

            return matmul(lhs, stateVec) - rhs
        }

        // 4. Compute Jacobian using MLX autodiff
        let jacobian = computeJacobianViaVJP(residualFn, flatState.values.value)
        let residual = residualFn(flatState.values.value)

        // 5. Check convergence
        let residualNorm = sqrt(sum(residual * residual)).item(Float.self)
        if residualNorm < tolerance {
            print("Newton-Raphson converged in \(iteration) iterations")
            break
        }

        // 6. Solve linear system: J·δx = -R
        let delta = solve(jacobian, -residual)

        // 7. Line search (prevent unphysical states)
        var alpha: Float = 1.0
        var xTrial: CoreProfiles
        repeat {
            let trialVec = flatState.values.value + alpha * delta
            xTrial = FlattenedState(
                values: EvaluatedArray(evaluating: trialVec),
                layout: flatState.layout
            ).toCoreProfiles()

            if isPhysical(xTrial) {
                break
            }
            alpha *= 0.5
        } while alpha > 1e-4

        // 8. Update
        xNew = xTrial
    }

    return xNew
}

/// Check if state is physical (all temperatures/densities positive)
func isPhysical(_ profiles: CoreProfiles) -> Bool {
    let ti = profiles.ionTemperature.value
    let te = profiles.electronTemperature.value
    let ne = profiles.electronDensity.value

    return all(ti .> 0).item(Bool.self) &&
           all(te .> 0).item(Bool.self) &&
           all(ne .> 0).item(Bool.self)
}
```

---

## MLX Optimization Opportunities

### 1. Vectorized Operations

**Replace loops with MLX array operations**:
```swift
// ❌ Inefficient: Loop over cells
for i in 0..<nCells {
    result[i] = exp(-1000.0 / temperature[i])
}

// ✅ Efficient: Vectorized operation
let result = exp(-1000.0 / temperature)
```

**Benefits**:
- Single GPU kernel launch instead of nCells launches
- Leverages SIMD and parallelism
- Lazy evaluation enables fusion

### 2. Lazy Evaluation and Fusion

MLX operations are **lazy** until `eval()` is called:

```swift
// All operations are lazy (computation graph)
let flux1 = -dFace * grad
let flux2 = vFace * cellValues
let totalFlux = flux1 + flux2
let divergence = (totalFlux[1:] - totalFlux[:-1]) / dr

// Force evaluation (single fused kernel)
eval(divergence)
```

**Benefits**:
- Intermediate arrays not materialized
- Operations fused into single kernel
- Reduced memory bandwidth

### 3. Batch Operations

Compute coefficients for all cells in one operation:

```swift
// ❌ Per-cell computation
var peclet = MLXArray.zeros([nCells + 1])
for i in 0..<(nCells + 1) {
    peclet[i] = vFace[i] * dr / (dFace[i] + 1e-10)
}

// ✅ Batch computation
let peclet = vFace * dr / (dFace + 1e-10)
```

### 4. Compile() Optimization

Compile the entire time step for maximum performance:

```swift
let compiledStep = compile { (state: SimulationState, dt: Float) -> SimulationState in
    // 1. Compute coefficients
    let coeffs = computeCoefficients(state.profiles, state.geometry)

    // 2. Assemble matrix
    let (lhs, rhs) = buildMatrixEquation(coeffs, dt)

    // 3. Solve
    let newProfiles = solve(lhs, rhs)

    // 4. Update state
    return state.withUpdatedProfiles(newProfiles)
}

// Execute compiled function (optimized)
for step in 0..<nSteps {
    state = compiledStep(state, dt)
    eval(state.profiles)  // Evaluate once per timestep
}
```

**Benefits**:
- Entire computation graph optimized
- Kernel fusion across operations
- Minimal CPU-GPU synchronization

### 5. Efficient Jacobian Computation

Use `vjp()` for efficient Jacobian:

```swift
// ❌ Inefficient: 4 separate grad() calls for 4 variables
let dR_dTi = grad { Ti in residual(Ti, Te, ne, psi) }(Ti)
let dR_dTe = grad { Te in residual(Ti, Te, ne, psi) }(Te)
// ... 4n function evaluations

// ✅ Efficient: Flattened state with vjp()
let flatState = [Ti; Te; ne; psi]  // Concatenate
let jacobian = computeJacobianViaVJP(residualFlat, flatState)
// Only n function evaluations
```

### 6. Memory Management

Monitor and optimize GPU memory:

```swift
// Check memory usage
let snapshot = MLX.GPU.snapshot()
print("Active memory: \(snapshot.activeMemory / 1024 / 1024) MB")

// Set cache limit
MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024)  // 1GB

// Clear cache if needed
MLX.GPU.clearCache()
```

### 7. Evaluation Strategy

**Key principle**: Evaluate at the end of each timestep, not more frequently.

```swift
// ❌ Over-evaluation
for step in 0..<nSteps {
    coeffs = computeCoeffs(state)
    eval(coeffs)  // ❌ Unnecessary

    state = solveStep(coeffs, state)
    eval(state)   // ❌ Unnecessary
}

// ✅ Minimal evaluation
for step in 0..<nSteps {
    state = compiledStep(state)
    // Only evaluate at end of timestep
}
eval(state.profiles)  // Final evaluation for output
```

### 8. Type-Safe EvaluatedArray Wrapper

Use `EvaluatedArray` to enforce evaluation at actor boundaries:

```swift
/// Type-safe wrapper ensuring evaluation
public struct EvaluatedArray: @unchecked Sendable {
    private let array: MLXArray

    public init(evaluating array: MLXArray) {
        eval(array)  // Guaranteed evaluation
        self.array = array
    }

    public var value: MLXArray { array }
}

/// Safe actor boundary crossing
public struct CoreProfiles: Sendable {
    public let ionTemperature: EvaluatedArray
    public let electronTemperature: EvaluatedArray
    // ... can safely cross actor boundaries
}
```

---

## Summary

This guide provides the complete foundation for implementing TORAX's FVM in Swift with MLX:

1. **Grid Structure**: Uniform 1D grid with cell-centered values and face-centered fluxes
2. **CellVariable**: Grid variables with boundary conditions (Dirichlet/Neumann)
3. **Spatial Discretization**: FVM with divergence theorem, power-law interpolation for Péclet weighting
4. **Flux Calculation**: Decompose into diffusion + convection, interpolate face values
5. **Temporal Discretization**: Theta method (θ=0: explicit, θ=0.5: Crank-Nicolson, θ=1: implicit)
6. **Block1DCoeffs**: Encapsulate all PDE coefficients (transient, diffusion, convection, sources)
7. **Matrix Assembly**: Build block-tridiagonal system from coefficients
8. **Boundary Conditions**: Ghost cell approach for both Dirichlet and Neumann
9. **Solvers**: Linear (predictor-corrector) and Newton-Raphson (with autodiff Jacobian)
10. **MLX Optimization**: Vectorization, lazy evaluation, compile(), efficient Jacobian, minimal evaluation

The key design principles:
- **Keep MLXArray throughout computation chain** for autodiff and compile() optimization
- **Use EvaluatedArray wrapper** for type-safe actor boundary crossing
- **Batch operations** for all cells simultaneously
- **Lazy evaluation** until explicit `eval()` calls
- **Compile entire timestep** for maximum performance
