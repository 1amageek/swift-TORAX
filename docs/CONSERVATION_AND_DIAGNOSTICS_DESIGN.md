# Conservation Laws and Diagnostics Design

**Version**: 1.1
**Date**: 2025-10-19
**Status**: Design Revised (Post-Review), Ready for Implementation

---

## Executive Summary

This document describes the design of conservation law enforcement and diagnostic systems for swift-TORAX. These features ensure long-term numerical accuracy and provide real-time monitoring of simulation health.

**Key Features**:
- **Conservation Enforcement**: Automatic correction of numerical drift in conserved quantities
- **Diagnostics System**: Real-time monitoring of Jacobian conditioning, transport coefficients, and physical consistency
- **GPU-First Design**: All computations execute on GPU for minimal performance overhead

**Target Performance Overhead**: < 1%

---

## Table of Contents

1. [Motivation and Requirements](#1-motivation-and-requirements)
2. [Architecture Overview](#2-architecture-overview)
3. [Conservation Law Module](#3-conservation-law-module)
4. [Diagnostics Module](#4-diagnostics-module)
5. [Integration with SimulationOrchestrator](#5-integration-with-simulationorchestrator)
6. [Performance Considerations](#6-performance-considerations)
7. [Testing Strategy](#7-testing-strategy)
8. [Implementation Plan](#8-implementation-plan)

---

## 1. Motivation and Requirements

### 1.1 Problem Statement

**Long-time numerical drift**: Over 20,000+ timesteps, floating-point round-off errors accumulate, causing violations of fundamental conservation laws:

```
Initial state:  N₀ = 1.0 × 10²¹ particles
After 20k steps: N = 0.99 × 10²¹ particles  (1% drift - UNPHYSICAL)
```

**Lack of monitoring**: Without diagnostics, numerical issues (ill-conditioned Jacobians, negative diffusivities) go undetected until catastrophic failure.

### 1.2 Requirements

#### Functional Requirements
- **FR1**: Enforce particle conservation (∫ nₑ dV = const)
- **FR2**: Monitor energy conservation (∫ (3/2 nₑ Tₑ + 3/2 nᵢ Tᵢ) dV)
- **FR3**: Detect ill-conditioned Jacobian matrices (κ > 10⁶)
- **FR4**: Monitor transport coefficient ranges and detect non-physical values
- **FR5**: Generate diagnostic reports for post-simulation analysis

#### Non-Functional Requirements
- **NFR1**: Performance overhead < 1% of total simulation time
- **NFR2**: GPU-first design (no CPU/GPU transfers in hot path)
- **NFR3**: Modular architecture (conservation and diagnostics are independent)
- **NFR4**: Type-safe and Sendable (Swift 6 concurrency compliant)

### 1.3 Design Principles

1. **Non-invasive**: Existing solver logic remains unchanged
2. **Optional**: Conservation/diagnostics can be disabled for performance
3. **Periodic**: Enforcement/diagnostics run every N steps (default: 1000)
4. **GPU-accelerated**: All computations use MLXArray operations
5. **Composable**: Multiple conservation laws can be active simultaneously

---

## 2. Architecture Overview

### 2.1 Module Structure

```
Sources/TORAX/
├── Conservation/
│   ├── ConservationLaw.swift          # Protocol definition
│   ├── ParticleConservation.swift     # ∫ nₑ dV enforcement
│   ├── EnergyConservation.swift       # ∫ E dV enforcement
│   └── ConservationEnforcer.swift     # Orchestration logic
│
├── Diagnostics/
│   ├── SimulationDiagnostics.swift    # Base protocol
│   ├── JacobianDiagnostics.swift      # Conditioning checks
│   ├── ConservationDiagnostics.swift  # Drift monitoring
│   ├── TransportDiagnostics.swift     # Coefficient validation
│   └── DiagnosticsReport.swift        # Reporting utilities
│
└── Orchestration/
    └── SimulationOrchestrator.swift   # Integration point

Tests/TORAXTests/
├── Conservation/
│   ├── ParticleConservationTests.swift
│   ├── EnergyConservationTests.swift
│   └── ConservationEnforcerTests.swift
│
└── Diagnostics/
    ├── JacobianDiagnosticsTests.swift
    ├── TransportDiagnosticsTests.swift
    └── DiagnosticsReportTests.swift
```

### 2.2 Data Flow

```
┌─────────────────────────────────────┐
│   SimulationOrchestrator.step()    │
└──────────────┬──────────────────────┘
               │
               ├─→ 1. Solve timestep (existing)
               │
               ├─→ 2. ConservationEnforcer.enforce()
               │    ├─→ Compute conserved quantities (GPU)
               │    ├─→ Check drift vs. reference
               │    └─→ Apply correction if needed (GPU)
               │
               └─→ 3. runDiagnostics()
                    ├─→ JacobianDiagnostics
                    ├─→ TransportDiagnostics
                    └─→ ConservationDiagnostics
```

### 2.3 Key Abstractions

#### ConservationLaw Protocol
```swift
public protocol ConservationLaw: Sendable {
    var name: String { get }
    var driftTolerance: Float { get }

    func computeConservedQuantity(profiles: CoreProfiles, geometry: Geometry) -> Float
    func computeCorrectionFactor(current: Float, reference: Float) -> Float
    func applyCorrection(profiles: CoreProfiles, correctionFactor: Float) -> CoreProfiles
}
```

**Design Rationale**: Protocol-oriented design allows easy addition of new conservation laws (momentum, angular momentum, etc.).

#### Diagnostics Design (Static Utilities)

**Design Decision**: Instead of using a protocol, diagnostics are implemented as **static utility functions**.

**Rationale**:
- Diagnostics need data (Jacobian, transport coefficients, profiles) as input
- Protocol with `func diagnose() -> DiagnosticResult` has no way to pass data
- Static functions provide clear, type-safe interfaces: `diagnose(jacobian:step:time:)`

**Pattern**:
```swift
public struct JacobianDiagnostics {
    public static func diagnose(
        jacobian: MLXArray,
        step: Int,
        time: Float
    ) -> DiagnosticResult { ... }
}

public struct TransportDiagnostics {
    public static func diagnose(
        coefficients: TransportCoefficients,
        step: Int,
        time: Float
    ) -> [DiagnosticResult] { ... }
}
```

**Benefits**: No state, clear dependencies, easy to test, composable via function calls.

---

## 3. Conservation Law Module

### 3.1 ConservationLaw Protocol

**File**: `Sources/TORAX/Conservation/ConservationLaw.swift`

**Purpose**: Define interface for all conservation laws.

**Key Methods**:

1. **computeConservedQuantity**: Calculate total conserved quantity
   - **Input**: Current profiles, geometry
   - **Output**: Scalar value (e.g., total particle number)
   - **Execution**: GPU (MLXArray operations)

2. **computeCorrectionFactor**: Determine correction needed
   - **Input**: Current quantity, reference quantity
   - **Output**: Multiplicative correction factor
   - **Logic**: `factor = reference / current`

3. **applyCorrection**: Modify profiles to enforce conservation
   - **Input**: Profiles, correction factor
   - **Output**: Corrected profiles
   - **Execution**: GPU (element-wise operations)

**Associated Types**:

```swift
public struct ConservationResult: Sendable {
    let lawName: String
    let referenceQuantity: Float
    let currentQuantity: Float
    let relativeDrift: Float          // |Q - Q₀| / Q₀
    let correctionFactor: Float
    let corrected: Bool
    let time: Float
    let step: Int
}
```

### 3.2 ParticleConservation

**File**: `Sources/TORAX/Conservation/ParticleConservation.swift`

**Physics**: In a closed tokamak (no particle sources at boundaries), total particle number must be constant.

**Conserved Quantity**:
```
N = ∫ nₑ dV
```

**GPU Implementation**:
```swift
let ne = profiles.electronDensity.value      // [nCells]
let volumes = geometry.cellVolumes.value     // [nCells]
let totalParticles = (ne * volumes).sum()   // Scalar
```

**Correction Method**: Uniform density scaling with safety guards
```swift
func computeCorrectionFactor(current: Float, reference: Float) -> Float {
    // Guard against zero/negative/non-finite values
    guard current > 0, current.isFinite else {
        print("[ParticleConservation] Invalid current value: \(current), no correction")
        return 1.0
    }
    guard reference > 0, reference.isFinite else {
        print("[ParticleConservation] Invalid reference value: \(reference), no correction")
        return 1.0
    }

    // Compute correction factor
    let factor = reference / current

    // Clamp to ±20% to prevent large corrections
    if abs(factor - 1.0) > 0.2 {
        print("[ParticleConservation] Large correction (\(factor)×) clamped to ±20%")
        return factor > 1.0 ? 1.2 : 0.8
    }

    return factor
}

let correctionFactor = computeCorrectionFactor(current: N, reference: N₀)
let ne_corrected = ne * correctionFactor
```

**Safety Features**:
- **Zero division protection**: Returns 1.0 (no correction) if current ≤ 0
- **Non-finite detection**: Catches NaN/Inf before correction
- **Clamping**: Limits correction to ±20% to prevent instability

**Why This Works**:
- Preserves profile shape (gradients maintained)
- Small corrections (< 1%) don't affect physics
- GPU-efficient (element-wise multiplication)
- Robust against numerical edge cases

**Tolerance**: Default 0.5% drift threshold

### 3.3 EnergyConservation

**File**: `Sources/TORAX/Conservation/EnergyConservation.swift`

**Physics**: Total thermal energy (without sources/sinks)

**Conserved Quantity**:
```
E = ∫ (3/2 nₑ Tₑ + 3/2 nᵢ Tᵢ) dV
```

**Assumptions**:
- Quasi-neutrality: nᵢ ≈ nₑ
- No heating/radiation (pure conservation test)

**GPU Implementation**:
```swift
let electronEnergy = 1.5 * ne * Te
let ionEnergy = 1.5 * ne * Ti
let totalEnergy = ((electronEnergy + ionEnergy) * volumes).sum()
```

**Correction Method**: Uniform temperature scaling
```swift
let correctionFactor = E₀ / E
let Te_corrected = Te * correctionFactor
let Ti_corrected = Ti * correctionFactor
```

**Note**: For simulations with sources, use energy balance diagnostics instead (track dE/dt = P_in - P_out).

**Tolerance**: Default 1% drift threshold

### 3.4 ConservationEnforcer

**File**: `Sources/TORAX/Conservation/ConservationEnforcer.swift`

**Purpose**: Orchestrate multiple conservation laws.

**Initialization**:
```swift
public init(
    laws: [any ConservationLaw],
    initialProfiles: CoreProfiles,
    geometry: Geometry,
    enforcementInterval: Int = 1000,
    verbose: Bool = true
)
```

**Key Behavior**:
1. Compute reference quantities at t=0
2. Every `enforcementInterval` steps:
   - Compute current quantities
   - Check drift vs. reference
   - Apply corrections if drift > tolerance
   - Log results

**Enforcement Logic**:
```swift
public func enforce(
    profiles: CoreProfiles,
    geometry: Geometry,
    step: Int,
    time: Float
) -> (profiles: CoreProfiles, results: [ConservationResult])
```

**Sequential Application**: Multiple laws applied in order (particle first, then energy).

**Performance**: O(nCells) per law, runs every 1000 steps → negligible overhead.

---

## 4. Diagnostics Module

### 4.1 DiagnosticResult

**File**: `Sources/TORAX/Diagnostics/SimulationDiagnostics.swift`

**Purpose**: Standardized format for all diagnostics.

**Structure**:
```swift
public struct DiagnosticResult: Sendable {
    let name: String
    let severity: Severity              // info, warning, error, critical
    let message: String
    let value: Float?
    let threshold: Float?
    let time: Float
    let step: Int

    enum Severity: String {
        case info = "ℹ️"
        case warning = "⚠️"
        case error = "❌"
        case critical = "🔥"
    }
}
```

**Severity Levels**:
- **info**: Normal operation, informational message
- **warning**: Potential issue, but simulation can continue
- **error**: Significant problem, results may be unreliable
- **critical**: Catastrophic failure imminent (NaN, Inf, singularity)

### 4.2 JacobianDiagnostics

**File**: `Sources/TORAX/Diagnostics/JacobianDiagnostics.swift`

**Purpose**: Monitor Jacobian matrix conditioning.

**Metric**: Condition number κ(J) = σ_max / σ_min

**Interpretation**:
- κ < 10³: Well-conditioned (excellent)
- κ ~ 10⁴ - 10⁶: Moderate (acceptable with preconditioning)
- κ > 10⁶: Ill-conditioned (numerical issues likely)
- κ = ∞: Singular matrix (σ_min = 0)

**Implementation**:
```swift
public struct JacobianDiagnostics {
    public static func diagnose(
        jacobian: MLXArray,
        step: Int,
        time: Float,
        threshold: Float = 1e6
    ) -> DiagnosticResult {
        let (_, S, _) = svd(jacobian)  // Singular Value Decomposition
        eval(S)

        let sigma_max = S.max().item(Float.self)
        let sigma_min = S.min().item(Float.self)

        // Check for singularity FIRST
        if sigma_min < 1e-12 || !sigma_min.isFinite {
            return DiagnosticResult(
                name: "JacobianConditioning",
                severity: .critical,
                message: "Singular matrix detected: σ_min = \(sigma_min)",
                value: Float.infinity,
                threshold: threshold,
                time: time,
                step: step
            )
        }

        // Compute condition number
        let kappa = sigma_max / sigma_min

        // Map severity based on condition number
        let severity: Severity
        if kappa > threshold {
            severity = .error
        } else if kappa > threshold / 10 {
            severity = .warning
        } else {
            severity = .info
        }

        return DiagnosticResult(
            name: "JacobianConditioning",
            severity: severity,
            message: "Jacobian condition number: κ = \(kappa)",
            value: kappa,
            threshold: threshold,
            time: time,
            step: step
        )
    }
}
```

**Performance Consideration**: SVD is O(n³) → expensive! Run only periodically (e.g., every 5000 steps) or on-demand for debugging.

**Configuration**:
```swift
// Optional: Enable Jacobian diagnostics (expensive, disabled by default)
public struct DiagnosticsConfig: Sendable {
    public let enableJacobianCheck: Bool = false  // Disabled by default
    public let jacobianCheckInterval: Int = 5000  // Every 5000 steps if enabled
    public let conditionThreshold: Float = 1e6
}
```

### 4.3 TransportDiagnostics

**File**: `Sources/TORAX/Diagnostics/TransportDiagnostics.swift`

**Purpose**: Validate transport coefficients.

**Checks**:

1. **Range Check**: Detect large variations
   ```swift
   let range = chiIon_max / chiIon_min
   if range > 1e4 {
       severity = .warning
       message = "Large χᵢ range: \(range)× variation"
   }
   ```

2. **Negativity Check**: Diffusivity must be ≥ 0
   ```swift
   if chiIon_min < 0 {
       severity = .error
       message = "Negative ion diffusivity: \(chiIon_min)"
   }
   ```

3. **NaN/Inf Check**: Detect numerical breakdown
   ```swift
   if chiIon_array.contains(where: { !$0.isFinite }) {
       severity = .critical
       message = "NaN or Inf detected in diffusivity"
   }
   ```

**GPU Implementation**: All checks use MLX operations
```swift
let chiIon_min = chiIon.min().item(Float.self)
let chiIon_max = chiIon.max().item(Float.self)
```

**Performance**: O(nCells) min/max operations → very fast.

### 4.4 ConservationDiagnostics

**File**: `Sources/TORAX/Diagnostics/ConservationDiagnostics.swift`

**Purpose**: Monitor conservation drift (passive monitoring, no enforcement).

**Use Case**: When conservation enforcement is disabled, still track drift for analysis.

**Implementation**:
```swift
public static func diagnoseConservation(
    results: [ConservationResult]
) -> [DiagnosticResult] {
    results.map { result in
        let severity: Severity
        if result.relativeDrift > 0.01 {
            severity = .error
        } else if result.relativeDrift > 0.005 {
            severity = .warning
        } else {
            severity = .info
        }

        return DiagnosticResult(
            name: result.lawName,
            severity: severity,
            message: "Drift: \(result.relativeDrift * 100)%",
            ...
        )
    }
}
```

### 4.5 DiagnosticsReport

**File**: `Sources/TORAX/Diagnostics/DiagnosticsReport.swift`

**Purpose**: Aggregate all diagnostics for post-simulation analysis.

**Structure**:
```swift
public struct DiagnosticsReport: Sendable, Codable {
    let results: [DiagnosticResult]
    let conservationResults: [ConservationResult]
    let startTime: Float
    let endTime: Float
    let totalSteps: Int

    func summary() -> String
    func exportJSON() throws -> Data
}

// Codable conformance for all constituent types
extension DiagnosticResult: Codable {}
extension DiagnosticResult.Severity: Codable {}
extension ConservationResult: Codable {}
```

**JSON Export Implementation**:
```swift
public func exportJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
}
```

**JSON Schema**:
```json
{
  "results": [
    {
      "name": "JacobianConditioning",
      "severity": "warning",
      "message": "Jacobian condition number: κ = 5.2e5",
      "value": 520000.0,
      "threshold": 1000000.0,
      "time": 1.234,
      "step": 12340
    }
  ],
  "conservationResults": [
    {
      "lawName": "ParticleConservation",
      "referenceQuantity": 1.0e21,
      "currentQuantity": 9.95e20,
      "relativeDrift": 0.005,
      "correctionFactor": 1.005,
      "corrected": true,
      "time": 2.0,
      "step": 20000
    }
  ],
  "startTime": 0.0,
  "endTime": 2.0,
  "totalSteps": 20000
}
```

**Summary Output Example**:
```
═══════════════════════════════════════
SIMULATION DIAGNOSTICS REPORT
═══════════════════════════════════════
Time range: [0.0, 2.0] s
Total steps: 20000

Summary:
  ❌ Errors: 2
  ⚠️  Warnings: 5
  ℹ️  Info: 18

Conservation Enforcement:
  • ParticleConservation: drift = 0.3% (corrected)
  • EnergyConservation: drift = 0.8% (corrected)

Critical Issues:
  ❌ [JacobianConditioning] Ill-conditioned Jacobian: κ = 2.3e6
  ❌ [TransportDiagnostics] Negative diffusivity at step 15000
═══════════════════════════════════════
```

---

## 5. Integration with SimulationOrchestrator

### 5.1 Modified Architecture

**File**: `Sources/TORAX/Orchestration/SimulationOrchestrator.swift`

**New Properties**:
```swift
public actor SimulationOrchestrator {
    // Existing properties...

    /// Conservation enforcer (optional)
    private var conservationEnforcer: ConservationEnforcer?

    /// Diagnostics accumulator
    private var diagnosticResults: [DiagnosticResult] = []
    private var conservationResults: [ConservationResult] = []

    /// Last computed transport coefficients (for diagnostics)
    private var lastTransportCoefficients: TransportCoefficients?
}
```

### 5.2 New Public Methods

#### Enable Conservation
```swift
public func enableConservation(
    laws: [any ConservationLaw],
    interval: Int = 1000
) {
    guard let initialProfiles = currentState?.profiles else {
        print("[Orchestrator] Cannot enable conservation: no initial state")
        return
    }

    self.conservationEnforcer = ConservationEnforcer(
        laws: laws,
        initialProfiles: initialProfiles,
        geometry: geometry,
        enforcementInterval: interval,
        verbose: true
    )
}
```

#### Get Diagnostics Report
```swift
public func getDiagnosticsReport() -> DiagnosticsReport {
    return DiagnosticsReport(
        results: diagnosticResults,
        conservationResults: conservationResults,
        startTime: 0,
        endTime: currentState?.time ?? 0,
        totalSteps: currentState?.step ?? 0
    )
}
```

### 5.3 Modified step() Method

**Integration Points**:

```swift
private func step(dt: Float) async -> SimulationState {
    // 1. Existing solve logic
    let result = solver.solve(...)
    var newState = SimulationState(profiles: result.updatedProfiles, ...)

    // 2. Conservation enforcement (if enabled)
    if let enforcer = conservationEnforcer {
        let (correctedProfiles, results) = enforcer.enforce(
            profiles: newState.profiles,
            geometry: geometry,
            step: newState.step,
            time: newState.time
        )
        newState = newState.updated(profiles: correctedProfiles)
        conservationResults.append(contentsOf: results)
    }

    // 3. Run diagnostics (periodic)
    if newState.step % 100 == 0 {
        runDiagnostics(step: newState.step, time: newState.time)
    }

    return newState
}
```

### 5.4 Diagnostics Helper (Complete Implementation)

```swift
private func runDiagnostics(
    step: Int,
    time: Float,
    jacobian: MLXArray? = nil  // Optional: Pass from Newton-Raphson solver
) {
    guard let state = currentState else { return }

    // 1. Transport coefficient diagnostics (fast, run frequently)
    if let coeffs = lastTransportCoefficients {
        let transportDiag = TransportDiagnostics.diagnose(
            coefficients: coeffs,
            step: step,
            time: time
        )
        diagnosticResults.append(contentsOf: transportDiag)
    }

    // 2. Jacobian conditioning (expensive, run only if enabled and at interval)
    if let config = diagnosticsConfig, config.enableJacobianCheck {
        if step % config.jacobianCheckInterval == 0, let J = jacobian {
            let jacobianDiag = JacobianDiagnostics.diagnose(
                jacobian: J,
                step: step,
                time: time,
                threshold: config.conditionThreshold
            )
            diagnosticResults.append(jacobianDiag)
        }
    }

    // 3. Conservation drift monitoring (passive, if enforcer is enabled)
    if !conservationResults.isEmpty {
        let recentResults = conservationResults.suffix(5)
        let conservationDiag = ConservationDiagnostics.diagnose(
            results: Array(recentResults)
        )
        diagnosticResults.append(contentsOf: conservationDiag)
    }

    // 4. Log critical issues immediately (for real-time awareness)
    for result in diagnosticResults.suffix(10) {
        if result.severity == .error || result.severity == .critical {
            print("[\(result.severity.rawValue)] \(result.name): \(result.message)")
        }
    }
}
```

**Integration with Newton-Raphson**:
```swift
// In NewtonRaphsonSolver, after computing Jacobian:
let jacobian = computeJacobianViaVJP(residualFnScaled, xScaled.values.value)

// Pass to diagnostics if needed (optional, controlled by config)
// orchestrator.runDiagnostics(step: step, time: time, jacobian: jacobian)
```

**Configuration Structure**:
```swift
/// Diagnostics configuration (optional, all disabled by default for performance)
public struct DiagnosticsConfig: Sendable {
    /// Enable expensive Jacobian SVD check (disabled by default)
    public let enableJacobianCheck: Bool

    /// Check interval for Jacobian (only if enabled)
    public let jacobianCheckInterval: Int

    /// Condition number threshold for warnings
    public let conditionThreshold: Float

    public init(
        enableJacobianCheck: Bool = false,
        jacobianCheckInterval: Int = 5000,
        conditionThreshold: Float = 1e6
    ) {
        self.enableJacobianCheck = enableJacobianCheck
        self.jacobianCheckInterval = jacobianCheckInterval
        self.conditionThreshold = conditionThreshold
    }
}
```

---

## 6. Performance Considerations

### 6.1 Computational Complexity

| Operation | Complexity | Frequency | GPU/CPU | Overhead |
|-----------|------------|-----------|---------|----------|
| Particle conservation | O(nCells) | Every 1000 steps | GPU | ~0.01% |
| Energy conservation | O(nCells) | Every 1000 steps | GPU | ~0.01% |
| Transport diagnostics | O(nCells) | Every 100 steps | GPU | ~0.1% |
| Jacobian SVD | O(n³) | Every 5000 steps | GPU | ~0.5% |

**Total Overhead**: < 1% of total simulation time

### 6.2 Memory Overhead

**Conservation Enforcer**: O(1) - only stores reference quantities
**Diagnostics**: O(steps/interval) - accumulates diagnostic results

**Mitigation**: Limit diagnostic history (e.g., last 1000 results)

### 6.3 GPU Efficiency

**Design Choices for Performance**:

1. **Batch eval()**: Evaluate multiple arrays together
   ```swift
   eval(ne_corrected, Te_corrected, Ti_corrected)
   ```

2. **Minimize CPU extraction**: Use `.item()` only for scalars
   ```swift
   let totalParticles = (ne * volumes).sum().item(Float.self)  // Single scalar
   ```

3. **Reuse geometry data**: Cell volumes computed once, cached
   ```swift
   let volumes = geometry.cellVolumes.value  // Cached in Geometry
   ```

4. **Avoid expensive operations in hot path**: SVD only every 5000 steps

### 6.4 Benchmarking Plan

**Target**: Measure overhead on ITER-like case (100 cells, 20,000 steps)

**Baseline**: Without conservation/diagnostics
**Test 1**: With particle conservation (every 1000 steps)
**Test 2**: With all diagnostics enabled

**Acceptance Criteria**: Total overhead < 1%

---

## 7. Testing Strategy

### 7.1 Unit Tests

#### ParticleConservationTests.swift
- **Test round-trip**: Apply correction, verify exact conservation
- **Test small drift**: Verify correction factor calculation
- **Test large drift**: Ensure correction handles extreme cases
- **Test zero density**: Edge case handling

#### EnergyConservationTests.swift
- **Test uniform profiles**: Energy calculation correctness
- **Test gradient profiles**: Non-uniform energy distribution
- **Test correction**: Verify temperature scaling

#### ConservationEnforcerTests.swift
- **Test multiple laws**: Sequential application
- **Test enforcement interval**: Only runs at correct steps
- **Test verbose logging**: Output validation

#### JacobianDiagnosticsTests.swift
- **Test well-conditioned**: κ < 1000
- **Test ill-conditioned**: κ > 1e6
- **Test singular**: κ = ∞

#### TransportDiagnosticsTests.swift
- **Test normal range**: No warnings
- **Test large range**: Warning triggered
- **Test negative values**: Error detection
- **Test NaN/Inf**: Critical error detection

### 7.2 Integration Tests

#### Long-Time Conservation Test
```swift
@Test("Conservation enforcement over 20k steps")
func testLongTimeConservation() async throws {
    let orchestrator = SimulationOrchestrator(...)

    await orchestrator.enableConservation(
        laws: [ParticleConservation()],
        interval: 1000
    )

    let result = try await orchestrator.run(config: config)
    let report = await orchestrator.getDiagnosticsReport()

    // Verify final drift < 0.1%
    let finalDrift = report.conservationResults.last!.relativeDrift
    #expect(finalDrift < 0.001)
}
```

#### Diagnostics Report Test
```swift
@Test("Diagnostics report generation")
func testDiagnosticsReport() async throws {
    let orchestrator = SimulationOrchestrator(...)
    let result = try await orchestrator.run(config: config)

    let report = await orchestrator.getDiagnosticsReport()
    let summary = report.summary()

    // Verify report structure
    #expect(summary.contains("DIAGNOSTICS REPORT"))
    #expect(report.results.count > 0)
}
```

### 7.3 Performance Tests

```swift
@Test("Conservation overhead < 1%")
func testConservationOverhead() async throws {
    // Run without conservation
    let start1 = Date()
    let result1 = try await orchestrator.run(config: config)
    let baseline = Date().timeIntervalSince(start1)

    // Run with conservation
    await orchestrator.enableConservation(laws: [ParticleConservation()])
    let start2 = Date()
    let result2 = try await orchestrator.run(config: config)
    let withConservation = Date().timeIntervalSince(start2)

    let overhead = (withConservation - baseline) / baseline
    #expect(overhead < 0.01)  // < 1%
}
```

---

## 8. Implementation Plan

### Phase 1: Conservation Module (Day 1 - 4 hours)

**Tasks**:
1. ✅ Create `Sources/TORAX/Conservation/` directory
2. ✅ Implement `ConservationLaw.swift` protocol
3. ✅ Implement `ParticleConservation.swift`
4. ✅ Implement `EnergyConservation.swift`
5. ✅ Implement `ConservationEnforcer.swift`
6. ✅ Write unit tests

**Deliverables**:
- [ ] 4 source files
- [ ] 3 test files
- [ ] All tests passing

### Phase 2: Diagnostics Module (Day 1 - 3 hours)

**Tasks**:
1. ✅ Create `Sources/TORAX/Diagnostics/` directory
2. ✅ Implement `SimulationDiagnostics.swift` (base)
3. ✅ Implement `JacobianDiagnostics.swift`
4. ✅ Implement `TransportDiagnostics.swift`
5. ✅ Implement `ConservationDiagnostics.swift`
6. ✅ Implement `DiagnosticsReport.swift`
7. ✅ Write unit tests

**Deliverables**:
- [ ] 5 source files
- [ ] 3 test files
- [ ] All tests passing

### Phase 3: Integration (Day 2 - 2 hours)

**Tasks**:
1. ✅ Modify `SimulationOrchestrator.swift`
2. ✅ Add `enableConservation()` method
3. ✅ Add `getDiagnosticsReport()` method
4. ✅ Integrate into `step()` method
5. ✅ Write integration tests

**Deliverables**:
- [ ] Modified orchestrator
- [ ] 2 integration tests
- [ ] All tests passing

### Phase 4: Documentation and Examples (Day 2 - 1 hour)

**Tasks**:
1. ✅ Update CLAUDE.md with conservation/diagnostics usage
2. ✅ Add example in CLI documentation
3. ✅ Create usage examples in tests

**Deliverables**:
- [ ] Updated documentation
- [ ] Example code

### Total Estimated Time: 10 hours over 2 days

---

## 9. Usage Examples

### Example 1: Enable Particle Conservation

```swift
import TORAX

let config = try SimulationConfig.loadFromJSON("iter_baseline.json")
let orchestrator = SimulationOrchestrator(config: config)

// Enable particle conservation (0.5% tolerance)
await orchestrator.enableConservation(
    laws: [
        ParticleConservation(driftTolerance: 0.005)
    ],
    interval: 1000  // Check every 1000 steps
)

let result = try await orchestrator.run(config: config)

// Get diagnostics report
let report = await orchestrator.getDiagnosticsReport()
print(report.summary())
```

### Example 2: Enable Multiple Conservation Laws

```swift
await orchestrator.enableConservation(
    laws: [
        ParticleConservation(driftTolerance: 0.005),
        EnergyConservation(driftTolerance: 0.01)
    ],
    interval: 500  // More frequent checking
)
```

### Example 3: Diagnostics Only (No Enforcement)

```swift
// Don't enable conservation, but diagnostics still run
let result = try await orchestrator.run(config: config)

// Check diagnostics
let report = await orchestrator.getDiagnosticsReport()

// Filter for errors
let errors = report.results.filter {
    $0.severity == .error || $0.severity == .critical
}
for error in errors {
    print(error.formatted())
}
```

### Example 4: Custom Conservation Law

```swift
// Implement custom conservation law
struct MomentumConservation: ConservationLaw {
    let name = "MomentumConservation"
    let driftTolerance: Float = 0.01

    func computeConservedQuantity(
        profiles: CoreProfiles,
        geometry: Geometry
    ) -> Float {
        // ∫ nₑ v dV (assuming v from flow velocity)
        // Implementation depends on whether flow is evolved
        return 0.0  // Placeholder
    }

    // ... implement other methods
}

// Use it
await orchestrator.enableConservation(
    laws: [
        ParticleConservation(),
        MomentumConservation()
    ]
)
```

---

## 10. Future Enhancements

### 10.1 Adaptive Enforcement Interval

**Idea**: Adjust enforcement frequency based on drift rate.

```swift
// If drift is accelerating, check more frequently
if currentDrift > 2 * previousDrift {
    enforcementInterval = enforcementInterval / 2
}
```

### 10.2 Predictive Diagnostics

**Idea**: Use ML to predict when numerical issues will occur.

```swift
// Train model on (condition_number, convergence_failure) pairs
let failureProbability = predictiveModel.predict(currentConditionNumber)
if failureProbability > 0.8 {
    print("⚠️  High probability of convergence failure in next 100 steps")
}
```

### 10.3 Automatic Remediation

**Idea**: Automatically reduce timestep when diagnostics detect issues.

```swift
if kappa > 1e7 {
    print("🔥 Critical Jacobian conditioning - reducing timestep by 50%")
    dt = dt * 0.5
}
```

### 10.4 Distributed Diagnostics

**Idea**: For multi-node simulations, aggregate diagnostics across nodes.

---

## 11. References

### Physics
- Wesson, J. "Tokamak Plasma: A Complex Physical System" (2004)
- Stacey, W. "Fusion Plasma Physics" (2012)

### Numerical Methods
- Higham, N. "Accuracy and Stability of Numerical Algorithms" (2002)
- Trefethen, L. "Numerical Linear Algebra" (1997)

### TORAX Documentation
- TORAX Paper: arXiv:2406.06718v2
- Original Python TORAX: https://github.com/google-deepmind/torax

---

## 12. Design Review and Revisions

### 12.1 Review Summary (2025-10-19)

The initial design (v1.0) underwent a comprehensive code review identifying 5 issues:

| Issue | Priority | Description | Status |
|-------|----------|-------------|--------|
| #1 | High | SimulationDiagnostic protocol has no way to pass data | ✅ Fixed: Removed protocol, use static functions |
| #2 | High | runDiagnostics incomplete - only calls TransportDiagnostics | ✅ Fixed: Complete implementation with all diagnostics |
| #3 | Medium | Zero division not guarded in computeCorrectionFactor | ✅ Fixed: Added guards and clamping |
| #4 | Medium | Singular matrix severity incorrect (inf → .error) | ✅ Fixed: Check singularity first, map to .critical |
| #5 | Low | exportJSON() undefined (not Codable) | ✅ Fixed: Added Codable conformance + JSON schema |

### 12.2 Key Design Changes

#### Change 1: Protocol → Static Functions
**Original Design**:
```swift
public protocol SimulationDiagnostic {
    func diagnose() -> DiagnosticResult  // No way to pass data!
}
```

**Revised Design**:
```swift
public struct JacobianDiagnostics {
    public static func diagnose(jacobian: MLXArray, step: Int, time: Float) -> DiagnosticResult
}
```

**Rationale**: Static functions provide clear dependencies, no hidden state, easy to test.

#### Change 2: Safety Guards in Conservation
**Added Safety Features**:
- Zero/negative value detection
- Non-finite (NaN/Inf) detection
- Clamping to ±20% for large corrections

**Example**:
```swift
guard current > 0, current.isFinite else { return 1.0 }
if abs(factor - 1.0) > 0.2 {
    return factor > 1.0 ? 1.2 : 0.8  // Clamp
}
```

#### Change 3: Singularity Detection
**Original**:
```swift
let kappa = sigma_max / sigma_min  // inf if sigma_min = 0
severity = kappa > 1e6 ? .error : .info  // Doesn't catch singularity!
```

**Revised**:
```swift
if sigma_min < 1e-12 || !sigma_min.isFinite {
    return DiagnosticResult(severity: .critical, value: Float.infinity, ...)
}
```

#### Change 4: Complete runDiagnostics
**Original**: Only TransportDiagnostics
**Revised**: TransportDiagnostics + JacobianDiagnostics (optional) + ConservationDiagnostics

#### Change 5: JSON Export
**Added**:
- Codable conformance for all types
- JSON schema documentation
- Pretty-printed output with sorted keys

### 12.3 Open Questions Addressed

**Q1**: Should diagnostics be optional or mandatory?
**A**: Optional by default for performance. JacobianDiagnostics expensive (O(n³)), disabled unless explicitly enabled via `DiagnosticsConfig`.

**Q2**: How to expose Jacobian to diagnostics without breaking encapsulation?
**A**: Optional parameter in `runDiagnostics(jacobian:)`. Solver can optionally pass Jacobian for monitoring. If not provided, Jacobian checks are skipped.

**Implementation**:
```swift
// In SimulationOrchestrator
private func runDiagnostics(step: Int, time: Float, jacobian: MLXArray? = nil)

// In NewtonRaphsonSolver (optional integration)
let jacobian = computeJacobianViaVJP(...)
// Pass to orchestrator if diagnostics are enabled
```

### 12.4 Version History

- **v1.0** (2025-10-19): Initial design
- **v1.1** (2025-10-19): Post-review revision
  - Removed SimulationDiagnostic protocol
  - Added safety guards for conservation
  - Fixed singular matrix detection
  - Added Codable conformance
  - Completed runDiagnostics implementation
  - Added DiagnosticsConfig for optional features

---

## Appendix A: Conservation Law Physics

### Particle Conservation

**Continuity Equation**:
```
∂nₑ/∂t + ∇·Γ = Sₙ
```

Where:
- Γ = particle flux
- Sₙ = particle source

**Integrated Form**:
```
dN/dt = ∫ Sₙ dV
```

For closed system (no sources): N = const

### Energy Conservation

**Energy Balance**:
```
∂E/∂t = P_input - P_loss
```

Where:
- E = ∫ (3/2 nₑ Tₑ + 3/2 nᵢ Tᵢ) dV
- P_input = heating power
- P_loss = radiation + transport losses

For isolated system: E = const

### Momentum Conservation

**Momentum Equation** (toroidal):
```
∂(nₑ m v)/∂t + ∇·(nₑ m v v) = F
```

Where:
- v = flow velocity
- F = forces (pressure gradient, electromagnetic)

**Note**: Flow velocity not yet evolved in swift-TORAX v0.1

---

## Appendix B: Diagnostic Thresholds

### Jacobian Condition Number

| Range | Interpretation | Action |
|-------|----------------|--------|
| κ < 10³ | Well-conditioned | None |
| 10³ < κ < 10⁵ | Moderate | Monitor |
| 10⁵ < κ < 10⁶ | Poor | Enable preconditioning |
| κ > 10⁶ | Critical | Reduce timestep / improve scaling |

### Transport Coefficient Range

| Range | Interpretation | Action |
|-------|----------------|--------|
| χ_max/χ_min < 10² | Uniform | None |
| 10² < ... < 10⁴ | Moderate variation | Monitor |
| > 10⁴ | Large variation | Check for unphysical values |

### Conservation Drift

| Drift | Interpretation | Action |
|-------|----------------|--------|
| < 0.1% | Excellent | None |
| 0.1% - 0.5% | Acceptable | Monitor |
| 0.5% - 1% | Warning | Enforce correction |
| > 1% | Critical | Investigate numerical scheme |

---

**End of Design Document**
