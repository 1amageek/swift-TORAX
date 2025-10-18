# QLKNN Integration Design Review & Corrections

**Date**: 2025-10-18
**Status**: Critical Design Issues Identified

---

## Executive Summary

Four critical design issues have been identified in the original `QLKNN_INTEGRATION.md` plan. This document provides detailed explanations of each issue and proposes corrected solutions.

**Issues**:
1. ❌ **Python dependency not feasible** without platform/deployment strategy
2. ❌ **MLXArray indexing misuse** - for-loops are not compilable in MLX
3. ❌ **Geometry structure insufficient** - missing q, Bp data
4. ❌ **TransportConfig extension incompatible** with existing code

---

## Issue 1: Python Dependency Feasibility

### 🔴 Problem Statement

The original plan assumes adding `swift-fusion-surrogates` and `PythonKit` as dependencies, but:

1. **Current codebase has NO Python interop infrastructure**
   - No PythonKit usage anywhere
   - No Python path configuration
   - No Python environment validation

2. **Platform limitations**
   - PythonKit only works reliably on macOS
   - Linux support is fragile (libpython linking issues)
   - iOS/visionOS support is non-existent (sandbox restrictions)

3. **SwiftPM sandbox constraints**
   - Swift packages run in sandboxed environments in some contexts
   - Python subprocess spawning may be blocked
   - Dynamic library loading may fail

4. **Deployment complexity**
   - Users must install Python 3.12+
   - Users must `pip install fusion-surrogates`
   - Python environment must be in PATH or configured
   - No graceful fallback if Python unavailable

### 📚 Tutorial: Python Interop in Swift

#### How PythonKit Works

PythonKit uses the Python C API to bridge Swift and Python:

```swift
import PythonKit

// 1. Import Python module
let numpy = Python.import("numpy")

// 2. Call Python functions
let array = numpy.array([1, 2, 3])

// 3. Convert between Swift and Python types
let swiftArray: [Int] = Array(array)!
```

**Under the hood**:
```
Swift Code
    ↓
PythonKit (C bridge)
    ↓
libpython3.12.dylib (Python interpreter)
    ↓
Python Code (fusion_surrogates)
```

#### Platform-Specific Challenges

**macOS**: ✅ Works (with caveats)
- Python.org installer: ✅
- Homebrew Python: ✅
- System Python: ⚠️ (limited packages)

**Linux**: ⚠️ Fragile
- Must link against correct libpython version
- Requires `PYTHON_LIBRARY` environment variable
- ABI compatibility issues between distros

**iOS/visionOS**: ❌ Not supported
- No Python runtime available
- Sandbox prevents subprocess execution
- No dynamic library loading

**CI/CD**: ⚠️ Requires special setup
- GitHub Actions: Need to install Python + packages
- Xcode Cloud: No Python support

### ✅ Proposed Solutions

We have **three architectural options**:

---

#### Option A: Pure Swift QLKNN Implementation (Recommended)

**Concept**: Reimplement QLKNN neural network inference in pure Swift using MLX.

**Pros**:
- ✅ No Python dependency
- ✅ Full cross-platform support (macOS, Linux, iOS, visionOS)
- ✅ Better performance (no Python interop overhead)
- ✅ Type-safe, Swift-native API
- ✅ MLX compile() can optimize entire pipeline

**Cons**:
- ⚠️ Requires porting neural network weights
- ⚠️ Need to replicate QLKNN preprocessing
- ⚠️ Initial implementation effort (2-3 weeks)

**Implementation Path**:

1. **Export QLKNN weights from Python**
   ```python
   # In Python (one-time export)
   import fusion_surrogates
   import numpy as np

   model = fusion_surrogates.qlknn.QLKNNModel()
   weights = model.export_weights()
   np.savez("qlknn_weights.npz", **weights)
   ```

2. **Load weights in Swift**
   ```swift
   import MLX
   import MLXNN

   struct QLKNNNetwork: Module {
       let layer1: Linear
       let layer2: Linear
       let outputLayer: Linear

       init() throws {
           // Load weights from .npz file
           let weights = try loadWeights("qlknn_weights.npz")
           self.layer1 = Linear(10, 64)
           self.layer2 = Linear(64, 32)
           self.outputLayer = Linear(32, 8)
           // Set weights...
       }

       func callAsFunction(_ input: MLXArray) -> MLXArray {
           var x = input
           x = relu(layer1(x))
           x = relu(layer2(x))
           return outputLayer(x)
       }
   }
   ```

3. **Inference**
   ```swift
   let qlknn = try QLKNNNetwork()
   let inputs: MLXArray = ... // [batch_size, 10]
   let outputs = qlknn(inputs)  // [batch_size, 8]
   ```

**Status**: This is the **recommended approach** for production.

---

#### Option B: Optional Python Fallback

**Concept**: Pure Swift by default, optional Python-based QLKNN for validation.

**Architecture**:
```swift
public protocol QLKNNBackend: Sendable {
    func predict(_ inputs: [String: MLXArray]) throws -> [String: MLXArray]
}

// Default: Pure Swift implementation
public struct SwiftQLKNN: QLKNNBackend {
    private let network: QLKNNNetwork

    public func predict(_ inputs: [String: MLXArray]) throws -> [String: MLXArray] {
        // Pure Swift inference
    }
}

#if canImport(PythonKit)
// Optional: Python-based implementation (macOS only)
public struct PythonQLKNN: QLKNNBackend {
    private let pythonModel: PythonObject

    public func predict(_ inputs: [String: MLXArray]) throws -> [String: MLXArray] {
        // Python interop
    }
}
#endif

// Factory chooses backend
public struct QLKNNTransportModel: TransportModel {
    private let backend: any QLKNNBackend

    public init(preferPython: Bool = false) throws {
        #if canImport(PythonKit)
        if preferPython {
            self.backend = try PythonQLKNN()
        } else {
            self.backend = try SwiftQLKNN()
        }
        #else
        self.backend = try SwiftQLKNN()
        #endif
    }
}
```

**Pros**:
- ✅ Python available for validation/debugging
- ✅ Swift implementation for production
- ✅ Graceful degradation

**Cons**:
- ⚠️ Increased complexity (two implementations)
- ⚠️ Must maintain parity between backends

---

#### Option C: Python-Only with Strict Platform Constraints

**Concept**: Accept Python dependency, but document limitations clearly.

**Changes Required**:

1. **Update Package.swift platforms**
   ```swift
   platforms: [
       .macOS(.v13)  // Only macOS supported
   ]
   ```

2. **Add Python validation**
   ```swift
   public struct PythonEnvironment {
       public static func validate() throws {
           #if os(macOS)
           // Check Python availability
           guard PythonLibrary.useVersion(3, 12) else {
               throw QLKNNError.pythonNotFound(
                   "Python 3.12+ required. Install: brew install python@3.12"
               )
           }
           // Check fusion_surrogates
           let importResult = Python.attemptImport("fusion_surrogates")
           guard !importResult.isNone else {
               throw QLKNNError.packageNotFound(
                   "fusion_surrogates not found. Install: pip install fusion-surrogates"
               )
           }
           #else
           throw QLKNNError.platformNotSupported(
               "QLKNN requires macOS. Use BohmGyroBohm on other platforms."
           )
           #endif
       }
   }
   ```

3. **CI/CD setup**
   ```yaml
   # .github/workflows/test.yml
   - name: Install Python dependencies
     run: |
       python3 -m pip install fusion-surrogates

   - name: Run tests (macOS only)
     if: runner.os == 'macOS'
     run: swift test
   ```

**Pros**:
- ✅ Quickest implementation (use swift-fusion-surrogates as-is)
- ✅ Validated against Python TORAX

**Cons**:
- ❌ macOS only
- ❌ Complex deployment
- ❌ Fragile (Python environment issues)

---

### 🎯 Recommendation

**Primary**: Implement **Option A (Pure Swift QLKNN)**
- Target timeframe: 2-3 weeks
- Full platform support
- Better long-term maintainability

**Short-term**: Use **Option B (Optional Python Fallback)**
- Immediate implementation with swift-fusion-surrogates
- Pure Swift as roadmap item
- Allows validation against Python reference

---

## Issue 2: MLXArray Indexing Misuse

### 🔴 Problem Statement

The original plan contains code like:

```swift
// ❌ WRONG: This does not compile in MLX
var gradient = MLXArray.zeros(like: field)
for i in 1..<(n-1) {
    gradient[i] = (field[i+1] - field[i-1]) / (radii[i+1] - radii[i-1])
}
```

**Why this is wrong**:

1. **MLXArray is not subscript-assignable**
   - `gradient[i] = value` does not exist in MLX API
   - MLX arrays are immutable by design

2. **Loop-based computation defeats MLX optimization**
   - MLX is designed for vectorized tensor operations
   - Loops prevent graph optimization and GPU fusion

3. **Performance catastrophe**
   - CPU-based loop: ~1ms per cell (100 cells = 100ms)
   - Vectorized MLX: ~0.01ms total (10,000× faster)

### 📚 Tutorial: MLX Vectorization

#### MLX Philosophy

MLX (like JAX, NumPy, PyTorch) operates on **entire arrays** using vectorized operations:

```swift
// ❌ WRONG: Element-wise loop (not compilable)
for i in 0..<n {
    result[i] = exp(input[i])
}

// ✅ CORRECT: Vectorized operation
let result = exp(input)  // Operates on entire array
```

#### Slicing vs Indexing

**MLX supports slicing** (returns views):
```swift
let array = MLXArray([1, 2, 3, 4, 5])

// ✅ Slicing: returns sub-array
let slice = array[1..<4]  // [2, 3, 4]

// ✅ Multi-dimensional slicing
let matrix = MLXArray(0..<12, [3, 4])  // 3×4 matrix
let row = matrix[1]       // Second row
let col = matrix[0..., 2]  // Third column
```

**But NO element assignment**:
```swift
// ❌ Does not exist in MLX
array[2] = 10  // Compiler error

// ✅ Use array operations instead
let newArray = MLXArray.where(
    condition: indices == 2,
    x: MLXArray(10),
    y: array
)
```

#### Gradient Computation: Vectorized Approach

**Goal**: Compute ∇f = (f[i+1] - f[i-1]) / (r[i+1] - r[i-1])

**Step 1**: Create shifted arrays
```swift
let f = field  // [f0, f1, f2, f3, f4]
let r = radii  // [r0, r1, r2, r3, r4]

// Shifted forward (drop first element)
let f_plus = f[1...]   // [f1, f2, f3, f4]
let r_plus = r[1...]   // [r1, r2, r3, r4]

// Shifted backward (drop last element)
let f_minus = f[..<(-1)]  // [f0, f1, f2, f3]
let r_minus = r[..<(-1)]  // [r0, r1, r2, r3]
```

**Step 2**: Compute central differences (interior points)
```swift
// Central difference for i=1 to n-2
let df_interior = f_plus[1...] - f_minus[..<(-1)]  // f[i+1] - f[i-1]
let dr_interior = r_plus[1...] - r_minus[..<(-1)]  // r[i+1] - r[i-1]
let gradient_interior = df_interior / dr_interior
```

**Step 3**: Compute boundary differences
```swift
// Forward difference at i=0
let gradient_left = (f[1] - f[0]) / (r[1] - r[0])

// Backward difference at i=n-1
let n = f.shape[0]
let gradient_right = (f[n-1] - f[n-2]) / (r[n-1] - r[n-2])
```

**Step 4**: Concatenate
```swift
let gradient = concatenated([
    gradient_left.reshaped([1]),    // [∇f[0]]
    gradient_interior,               // [∇f[1], ..., ∇f[n-2]]
    gradient_right.reshaped([1])    // [∇f[n-1]]
], axis: 0)
```

### ✅ Corrected Implementation

```swift
import MLX

/// Vectorized gradient computation for MLX arrays
public struct MLXGradient {
    /// Compute radial gradient using 2nd-order finite differences
    ///
    /// Interior: ∇f[i] = (f[i+1] - f[i-1]) / (r[i+1] - r[i-1])
    /// Left boundary: ∇f[0] = (f[1] - f[0]) / (r[1] - r[0])
    /// Right boundary: ∇f[n-1] = (f[n-1] - f[n-2]) / (r[n-1] - r[n-2])
    ///
    /// - Parameters:
    ///   - field: Field to differentiate [n]
    ///   - radii: Radial coordinates [n]
    /// - Returns: Gradient [n]
    public static func radialGradient(
        field: MLXArray,
        radii: MLXArray
    ) -> MLXArray {
        let n = field.shape[0]
        guard n >= 2 else {
            // Degenerate case
            return MLXArray.zeros([n])
        }

        if n == 2 {
            // Only two points: use simple difference
            let df = field[1] - field[0]
            let dr = radii[1] - radii[0]
            let grad = df / dr
            return stacked([grad, grad], axis: 0)
        }

        // Interior points: central difference (i = 1 to n-2)
        let f_forward = field[2...]           // f[i+1]
        let f_backward = field[..<(n-2)]      // f[i-1]
        let r_forward = radii[2...]           // r[i+1]
        let r_backward = radii[..<(n-2)]      // r[i-1]

        let df_interior = f_forward - f_backward
        let dr_interior = r_forward - r_backward
        let grad_interior = df_interior / dr_interior

        // Left boundary: forward difference
        let df_left = field[1] - field[0]
        let dr_left = radii[1] - radii[0]
        let grad_left = df_left / dr_left

        // Right boundary: backward difference
        let df_right = field[n-1] - field[n-2]
        let dr_right = radii[n-1] - radii[n-2]
        let grad_right = df_right / dr_right

        // Concatenate: [left, interior, right]
        return concatenated([
            grad_left.reshaped([1]),
            grad_interior,
            grad_right.reshaped([1])
        ], axis: 0)
    }

    /// Compute normalized gradient: a/L_T = -a(∇T/T)
    public static func normalizedGradient(
        profile: MLXArray,
        radii: MLXArray,
        minorRadius: Float
    ) -> MLXArray {
        let gradient = radialGradient(field: profile, radii: radii)
        return -(minorRadius * gradient) / profile
    }
}
```

**Key Points**:
- ✅ No loops
- ✅ Pure tensor operations
- ✅ Compilable with MLX `compile()`
- ✅ GPU-optimizable

### 🧪 Testing Vectorized Implementation

```swift
import Testing
import MLX

@Test func testRadialGradient() {
    // Linear profile: T(r) = T0 + a*r → ∇T = a
    let radii = MLXArray(0..<100) * 0.01  // [0, 0.01, 0.02, ...]
    let T0: Float = 1000.0
    let a: Float = 500.0  // Gradient
    let profile = T0 + a * radii

    let gradient = MLXGradient.radialGradient(field: profile, radii: radii)

    // Expected: gradient ≈ a everywhere
    let expected = MLXArray(a).broadcasted(to: [100])
    let diff = abs(gradient - expected)

    #expect(all(diff .< 1e-4).item(Bool.self))
}

@Test func testNormalizedGradient() {
    // Exponential profile: T(r) = T0 * exp(-r/λ) → a/L_T = a/λ
    let radii = MLXArray(0..<100) * 0.01
    let T0: Float = 1000.0
    let lambda: Float = 0.5
    let a: Float = 1.0
    let profile = T0 * exp(-radii / lambda)

    let aOverLT = MLXGradient.normalizedGradient(
        profile: profile,
        radii: radii,
        minorRadius: a
    )

    // Expected: a/L_T ≈ a/λ ≈ 2.0 everywhere
    let expected = a / lambda
    let mean = aOverLT.mean().item(Float.self)

    #expect(abs(mean - expected) < 0.1)
}
```

---

## Issue 3: Geometry Structure Insufficiency

### 🔴 Problem Statement

The existing `Geometry` struct only contains:
```swift
public struct Geometry {
    public let majorRadius: Float
    public let minorRadius: Float
    public let toroidalField: Float
    public let volume: EvaluatedArray
    public let g0, g1, g2, g3: EvaluatedArray  // FVM geometric coefficients
    public let type: GeometryType
}
```

**Missing for QLKNN**:
- ❌ Safety factor `q(r)` profile
- ❌ Poloidal magnetic field `Bp(r)` profile
- ❌ Radial coordinate array `r`
- ❌ Magnetic shear `s(r)` profile
- ❌ Any MHD equilibrium information

**The plan assumes**:
```swift
extension Geometry {
    func computeSafetyFactor(psi: MLXArray) -> MLXArray  // ❌ No formula provided
    func computeMagneticShear(q: MLXArray) -> MLXArray   // ✅ This can work
}
```

### 📚 Tutorial: Tokamak Geometry and Safety Factor

#### What is the Safety Factor q?

The **safety factor** `q(r)` is a measure of magnetic field line helicity:

```
q(r) = (number of toroidal turns) / (number of poloidal turns)
```

Physically:
- **Low q** (q < 1): Unstable to kink modes
- **Typical axis**: q₀ ≈ 1.0 - 1.5
- **Typical edge**: q_edge ≈ 3.0 - 6.0
- **Monotonic increase**: dq/dr > 0 (positive shear)

#### Calculating q: Three Levels of Complexity

**Level 1: Simple Parametric Model** (Good for initial implementation)

```
q(r) = q₀ + (q_edge - q₀) * (r/a)^α
```

Typical values:
- q₀ = 1.0 (axis)
- q_edge = 3.5 (edge)
- α = 2.0 (quadratic profile)

**Level 2: From Plasma Current**

```
q(r) = (r B_t) / (R B_p)
```

where Bp(r) is derived from current density:
```
B_p(r) = (μ₀ / 2π r) ∫₀ʳ j(r') r' dr'
```

**Level 3: Full MHD Equilibrium** (Future)

Solve Grad-Shafranov equation:
```
Δ*ψ = -μ₀ R² dp/dψ - F dF/dψ
```

where ψ is poloidal flux.

### ✅ Proposed Solution: Extend Geometry with MHD Data

**Option 1: Add Safety Factor to Geometry** (Recommended)

```swift
public struct Geometry: Sendable, Equatable {
    // Existing fields
    public let majorRadius: Float
    public let minorRadius: Float
    public let toroidalField: Float
    public let volume: EvaluatedArray
    public let g0, g1, g2, g3: EvaluatedArray

    // NEW: MHD equilibrium data
    public let radii: EvaluatedArray              // Radial coordinates [m]
    public let safetyFactor: EvaluatedArray       // q(r) profile
    public let poloidalField: EvaluatedArray?     // Bp(r) profile (optional)
    public let currentDensity: EvaluatedArray?    // j(r) profile (optional)

    public let type: GeometryType

    public init(
        majorRadius: Float,
        minorRadius: Float,
        toroidalField: Float,
        volume: EvaluatedArray,
        g0: EvaluatedArray,
        g1: EvaluatedArray,
        g2: EvaluatedArray,
        g3: EvaluatedArray,
        radii: EvaluatedArray,
        safetyFactor: EvaluatedArray,
        poloidalField: EvaluatedArray? = nil,
        currentDensity: EvaluatedArray? = nil,
        type: GeometryType
    ) {
        self.majorRadius = majorRadius
        self.minorRadius = minorRadius
        self.toroidalField = toroidalField
        self.volume = volume
        self.g0 = g0
        self.g1 = g1
        self.g2 = g2
        self.g3 = g3
        self.radii = radii
        self.safetyFactor = safetyFactor
        self.poloidalField = poloidalField
        self.currentDensity = currentDensity
        self.type = type
    }
}
```

**Initialization** (circular geometry):

```swift
extension Geometry {
    /// Create circular geometry with simple safety factor model
    public static func circular(
        majorRadius: Float,
        minorRadius: Float,
        toroidalField: Float,
        nCells: Int,
        q0: Float = 1.0,
        qEdge: Float = 3.5
    ) -> Geometry {
        // Radial grid
        let dr = minorRadius / Float(nCells)
        let r = MLXArray(0..<nCells).asType(.float32) * dr + dr / 2

        // Simple q profile: q(r) = q0 + (qEdge - q0) * (r/a)^2
        let rNorm = r / minorRadius
        let q = q0 + (qEdge - q0) * pow(rNorm, 2)

        // Compute FVM geometric coefficients
        let volume = 2 * Float.pi * Float.pi * majorRadius * r * dr
        let g0 = 2 * Float.pi * r
        let g1 = g0 * r / (dr * dr)
        // ... (existing logic)

        return Geometry(
            majorRadius: majorRadius,
            minorRadius: minorRadius,
            toroidalField: toroidalField,
            volume: EvaluatedArray(evaluating: volume),
            g0: EvaluatedArray(evaluating: g0),
            g1: EvaluatedArray(evaluating: g1),
            g2: EvaluatedArray(evaluating: g2),
            g3: EvaluatedArray(evaluating: g3),
            radii: EvaluatedArray(evaluating: r),
            safetyFactor: EvaluatedArray(evaluating: q),
            poloidalField: nil,
            currentDensity: nil,
            type: .circular
        )
    }
}
```

**Usage in QLKNN**:

```swift
// Now this works!
let q = geometry.safetyFactor.value  // MLXArray

// Compute magnetic shear
let r = geometry.radii.value
let dqdr = MLXGradient.radialGradient(field: q, radii: r)
let smag = (r / q) * dqdr
```

---

**Option 2: Separate MHD Equilibrium Structure**

```swift
/// MHD equilibrium data (separate from Geometry)
public struct MHDEquilibrium: Sendable {
    public let radii: EvaluatedArray
    public let safetyFactor: EvaluatedArray
    public let magneticShear: EvaluatedArray
    public let poloidalField: EvaluatedArray?
    public let currentDensity: EvaluatedArray?
}

/// QLKNN now requires both Geometry and MHDEquilibrium
public protocol TransportModel {
    func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        equilibrium: MHDEquilibrium,  // NEW
        params: TransportParameters
    ) -> TransportCoefficients
}
```

**Pros**:
- ✅ Separation of concerns
- ✅ Geometry unchanged (backward compatible)

**Cons**:
- ❌ Breaking change to TransportModel protocol
- ❌ All existing models need updating

**Verdict**: Option 1 is better (extends Geometry, minimal breaking changes)

---

## Issue 4: TransportConfig Extension Incompatibility

### 🔴 Problem Statement

The plan proposes:
```swift
public struct TransportConfig: Codable, Sendable, Equatable {
    public let modelType: String
    public let parameters: [String: Float]

    // NEW fields
    public let qlknnModelName: String?
    public let pythonPath: String?
    public let enableQlknnCaching: Bool?
}
```

**Problems**:

1. **Breaks existing initializers**
   ```swift
   // Existing code expects 2 parameters
   TransportConfig(modelType: "constant", parameters: [:])

   // New code requires 5 parameters
   TransportConfig(
       modelType: "constant",
       parameters: [:],
       qlknnModelName: nil,
       pythonPath: nil,
       enableQlknnCaching: nil
   )
   ```

2. **Breaks Codable tests**
   - Existing JSON files don't have new fields
   - Decoding will fail unless fields are optional

3. **Pollutes config with model-specific fields**
   - `qlknnModelName` only relevant for QLKNN
   - Other models don't need these fields

### 📚 Tutorial: Extensible Configuration Patterns

#### Pattern 1: Nested Model-Specific Config

```swift
public struct TransportConfig: Codable, Sendable, Equatable {
    public let modelType: String
    public let parameters: [String: Float]

    // Model-specific configurations
    public let qlknnConfig: QLKNNConfig?
    public let bohmConfig: BohmConfig?

    public init(
        modelType: String,
        parameters: [String: Float] = [:],
        qlknnConfig: QLKNNConfig? = nil,
        bohmConfig: BohmConfig? = nil
    ) {
        self.modelType = modelType
        self.parameters = parameters
        self.qlknnConfig = qlknnConfig
        self.bohmConfig = bohmConfig
    }
}

public struct QLKNNConfig: Codable, Sendable, Equatable {
    public let modelName: String
    public let pythonPath: String?
    public let enableCaching: Bool

    public init(
        modelName: String = "qlknn_7_11_v1",
        pythonPath: String? = nil,
        enableCaching: Bool = true
    ) {
        self.modelName = modelName
        self.pythonPath = pythonPath
        self.enableCaching = enableCaching
    }
}
```

**JSON**:
```json
{
  "transport": {
    "modelType": "qlknn",
    "qlknnConfig": {
      "modelName": "qlknn_7_11_v1",
      "enableCaching": true
    }
  }
}
```

**Backward compatible**: Old JSON without `qlknnConfig` still works (optional field)

---

#### Pattern 2: Type-Erased Model Config

```swift
public struct TransportConfig: Codable, Sendable, Equatable {
    public let modelType: String
    public let parameters: [String: Float]
    public let modelSpecificConfig: [String: AnyCodable]?  // Type-erased

    public init(
        modelType: String,
        parameters: [String: Float] = [:],
        modelSpecificConfig: [String: AnyCodable]? = nil
    ) {
        self.modelType = modelType
        self.parameters = parameters
        self.modelSpecificConfig = modelSpecificConfig
    }
}
```

**JSON**:
```json
{
  "transport": {
    "modelType": "qlknn",
    "modelSpecificConfig": {
      "qlknn_model_name": "qlknn_7_11_v1",
      "enable_caching": true
    }
  }
}
```

**Usage**:
```swift
let modelName = config.modelSpecificConfig?["qlknn_model_name"]?.string ?? "qlknn_7_11_v1"
```

**Pros**:
- ✅ Fully backward compatible
- ✅ No per-model structs

**Cons**:
- ❌ Loses type safety
- ❌ Runtime errors for invalid configs

---

#### Pattern 3: Protocol-Based Config

```swift
public protocol ModelSpecificConfig: Codable, Sendable {}

public struct TransportConfig: Codable, Sendable {
    public let modelType: String
    public let parameters: [String: Float]

    private let _modelConfig: Data?  // Encoded config

    public init<T: ModelSpecificConfig>(
        modelType: String,
        parameters: [String: Float] = [:],
        modelConfig: T? = nil
    ) throws {
        self.modelType = modelType
        self.parameters = parameters
        self._modelConfig = try modelConfig.map { try JSONEncoder().encode($0) }
    }

    public func modelConfig<T: ModelSpecificConfig>() throws -> T? {
        guard let data = _modelConfig else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// QLKNN-specific
struct QLKNNConfig: ModelSpecificConfig {
    let modelName: String
    let pythonPath: String?
}
```

**Pros**:
- ✅ Type-safe extraction
- ✅ Extensible

**Cons**:
- ⚠️ Complex implementation
- ⚠️ Double encoding (JSON → Data → JSON)

---

### ✅ Recommended Solution: Pattern 1 (Nested Config)

**Implementation**:

```swift
// Sources/TORAX/Configuration/TransportConfig.swift

public struct TransportConfig: Codable, Sendable, Equatable {
    public let modelType: String
    public let parameters: [String: Float]

    // Model-specific configurations (all optional for backward compatibility)
    public let qlknn: QLKNNConfig?

    public init(
        modelType: String,
        parameters: [String: Float] = [:],
        qlknn: QLKNNConfig? = nil
    ) {
        self.modelType = modelType
        self.parameters = parameters
        self.qlknn = qlknn
    }

    /// Convenience: QLKNN config
    public init(qlknn: QLKNNConfig, parameters: [String: Float] = [:]) {
        self.init(
            modelType: "qlknn",
            parameters: parameters,
            qlknn: qlknn
        )
    }
}

/// QLKNN-specific configuration
public struct QLKNNConfig: Codable, Sendable, Equatable {
    public let modelName: String
    public let pythonPath: String?
    public let enableCaching: Bool
    public let weightsPath: String?  // For pure Swift implementation

    public init(
        modelName: String = "qlknn_7_11_v1",
        pythonPath: String? = nil,
        enableCaching: Bool = true,
        weightsPath: String? = nil
    ) {
        self.modelName = modelName
        self.pythonPath = pythonPath
        self.enableCaching = enableCaching
        self.weightsPath = weightsPath
    }
}
```

**Example JSON configs**:

```json
// Old config (still works)
{
  "transport": {
    "modelType": "constant",
    "parameters": {"chi": 1.0}
  }
}

// QLKNN config (new)
{
  "transport": {
    "modelType": "qlknn",
    "qlknn": {
      "modelName": "qlknn_7_11_v1",
      "enableCaching": true
    }
  }
}
```

**Migration**: Zero breaking changes for existing code.

---

## Summary of Corrections

| Issue | Original Plan | Corrected Approach |
|-------|---------------|-------------------|
| **Python Dependency** | Direct swift-fusion-surrogates usage | **Option A**: Pure Swift QLKNN (recommended)<br>**Option B**: Optional Python fallback<br>**Option C**: Python-only with platform constraints |
| **MLXArray Indexing** | `for i in 1..<(n-1) { array[i] = ... }` | Fully vectorized tensor operations using slicing |
| **Geometry Structure** | Assume `computeSafetyFactor()` magically works | **Extend Geometry** with `radii`, `safetyFactor`, `poloidalField` fields |
| **TransportConfig Extension** | Add QLKNN fields directly to struct | **Nested QLKNNConfig** struct for backward compatibility |

---

## Revised Implementation Roadmap

### Phase 1: Core Infrastructure (Week 1)

1. **Extend Geometry structure**
   - Add `radii`, `safetyFactor` fields
   - Update `Geometry.circular()` factory
   - Tests for safety factor profiles

2. **Implement MLXGradient utilities**
   - Vectorized `radialGradient()`
   - Vectorized `normalizedGradient()`
   - Comprehensive unit tests

3. **Create nested TransportConfig**
   - Add `QLKNNConfig` struct
   - Backward-compatible JSON decoding
   - Update factory to handle nested config

### Phase 2: Pure Swift QLKNN (Week 2-3)

4. **Export QLKNN weights from Python** (one-time)
   - Script to extract neural network weights
   - Convert to Swift-compatible format (.npz or JSON)

5. **Implement QLKNNNetwork in Swift**
   - MLX `Module` with layers
   - Load weights from file
   - Forward pass implementation

6. **Implement QLKNNInputBuilder**
   - Fully vectorized parameter calculation
   - Input validation

7. **Implement QLKNNTransportModel**
   - Uses `QLKNNNetwork` backend
   - Flux combination logic
   - Error handling

### Phase 3: Testing & Validation (Week 3-4)

8. **Unit tests**
   - Gradient computation
   - Safety factor calculation
   - QLKNN forward pass

9. **Integration tests**
   - Full simulation with QLKNN
   - Comparison with BohmGyroBohm

10. **Validation against Python TORAX** (if available)
    - Load reference results
    - Compare transport coefficients
    - Document discrepancies

### Phase 4: Documentation & Examples (Week 4)

11. **User documentation**
    - Configuration guide
    - Example JSON files
    - Performance tuning tips

12. **Developer documentation**
    - Architecture overview
    - Adding new transport models
    - QLKNN mathematical background

---

## Conclusion

The original QLKNN integration plan had four critical design flaws that would prevent implementation:

1. ❌ **Python dependency infeasible** without platform strategy
2. ❌ **MLXArray indexing misuse** (non-compilable code)
3. ❌ **Geometry structure insufficient** (missing MHD data)
4. ❌ **TransportConfig extension incompatible** (breaking changes)

**Corrected approach**:

1. ✅ **Pure Swift QLKNN** (no Python dependency)
2. ✅ **Fully vectorized operations** (MLX-compliant)
3. ✅ **Extended Geometry** (with safety factor data)
4. ✅ **Nested configuration** (backward compatible)

**Estimated timeline**: 3-4 weeks for full implementation

**Next step**: Begin Phase 1 (Core Infrastructure)
