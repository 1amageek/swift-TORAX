# Phase 7 Implementation Plan: Automatic Differentiation Workflow

**Created**: 2025-10-21
**Status**: 🚧 In Progress
**Duration**: 4-6 months (16 weeks)
**Priority**: P2 (Important for research applications)

---

## Overview

**Goal**: Implement optimization and control capabilities using MLX's automatic differentiation for:
- Forward sensitivity analysis (∂outputs/∂parameters)
- Inverse problems (optimize actuators to maximize Q_fusion)
- Real-time control emulation (model predictive control)

**References**:
- TORAX paper: arXiv:2406.06718v2 (Section 3.3: Optimization)
- RAPTOR: Nuclear Fusion 61(1), 2021
- MLX AD Documentation: https://ml-explore.github.io/mlx/build/html/

---

## Requirements

### R7.1: Forward Sensitivity Analysis

**Capability**: Compute gradients of simulation outputs w.r.t. control parameters

```
∂Q_fusion / ∂[P_ECRH, P_ICRH, I_plasma, gas_puff, ...]
```

**Use Cases**:
1. **Parameter sensitivity analysis**: Which parameters affect Q_fusion most?
2. **Actuator ranking**: Prioritize control levers by impact
3. **Uncertainty quantification**: Propagate parameter uncertainties to outputs

**Success Criteria**:
- ✅ Gradient computation via MLX `grad()`
- ✅ Validation against finite differences (< 1% error)
- ✅ Sensitivity matrix for all key outputs (Q_fusion, τE, β_N)

### R7.2: Inverse Problems (Optimization)

**Capability**: Find optimal actuator trajectories to achieve objectives

```swift
minimize: || profiles_simulated - profiles_target ||²
w.r.t.: [P_ECRH(t), P_ICRH(t), gas_puff(t), ...]
subject to: actuator constraints (0 < P_ECRH < 30 MW, etc.)
```

**Use Cases**:
1. **Scenario optimization**: Maximize Q_fusion while satisfying constraints
2. **Profile matching**: Reproduce experimental target profiles
3. **Ramp-up/ramp-down**: Optimize current/power trajectories

**Success Criteria**:
- ✅ Q_fusion improvement > 10% over baseline
- ✅ Convergence in < 100 iterations
- ✅ Constraints satisfied (actuator limits, physics)

### R7.3: Real-Time Control Emulation

**Capability**: Gradient-based predictive control at each timestep

```
At each timestep:
1. Predict future state (forward model)
2. Compute gradient w.r.t. actuators
3. Update actuators via gradient descent
```

**Use Cases**:
1. **Model predictive control (MPC)**: Online optimization
2. **Feedforward control design**: Optimal actuator waveforms
3. **Digital twin**: Real-time simulation + control

**Success Criteria**:
- ✅ Control loop frequency > 10 Hz (< 100ms per iteration)
- ✅ Stable closed-loop control
- ✅ Tracking error < 5%

---

## Architecture

### Directory Structure

```
Sources/Gotenx/Optimization/
├── Core/
│   ├── DifferentiableSimulation.swift      # AD-compatible simulation
│   └── ActuatorTimeSeries.swift            # Differentiable control parameters
├── Sensitivity/
│   ├── ForwardSensitivity.swift            # ∂output/∂parameter
│   ├── ParameterSweep.swift                # Grid search
│   └── UncertaintyPropagation.swift        # Monte Carlo
├── Control/
│   ├── OptimizationProblem.swift           # Abstract optimization interface
│   ├── GradientDescent.swift               # Basic optimizer
│   ├── Adam.swift                          # Adam optimizer (adaptive LR)
│   └── LBFGS.swift                         # Limited-memory BFGS
├── Constraints/
│   ├── ActuatorLimits.swift                # Physical constraints
│   ├── ProfileConstraints.swift            # Physics constraints
│   └── SmoothConstraints.swift             # Differentiable constraint functions
└── Applications/
    ├── ScenarioOptimizer.swift             # Maximize Q_fusion
    ├── ProfileMatcher.swift                # Match target profiles
    └── RampOptimizer.swift                 # Optimize ramp-up/down

Tests/GotenxTests/Optimization/
├── DifferentiableSimulationTests.swift     # AD correctness
├── ForwardSensitivityTests.swift           # Gradient validation
├── AdamOptimizerTests.swift                # Optimizer convergence
└── ScenarioOptimizerTests.swift            # End-to-end optimization
```

---

## Implementation Steps

### Week 1-4: MLX AD Integration (Step 7.1)

**Goal**: Make simulation differentiable

#### Task 7.1.1: DifferentiableSimulation Core

**File**: `Sources/Gotenx/Optimization/Core/DifferentiableSimulation.swift`

**Key Changes**:
1. **Remove `compile()`**: Compilation prevents gradient tracking
2. **Preserve gradient tape**: All operations must be MLXArray-based
3. **Differentiable timestep**: Solver must track gradients

**Critical Constraint**: Cannot use `compile()` during gradient computation

```swift
public struct DifferentiableSimulation {
    private let staticParams: StaticRuntimeParams
    private let transport: any TransportModel
    private let sources: any SourceModel
    private let geometry: Geometry

    /// Differentiable forward pass
    /// Returns (final_profiles, loss) where loss is differentiable w.r.t. actuators
    public func forward(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries,
        timeHorizon: Float,
        dt: Float
    ) -> (CoreProfiles, MLXArray) {
        var state = initialProfiles
        let nSteps = Int(timeHorizon / dt)

        // Time-stepping WITHOUT compile() to preserve gradient tape
        for step in 0..<nSteps {
            let t = Float(step) * dt

            // Apply actuators at this timestep
            let sourcesAtT = sources.compute(
                profiles: state,
                geometry: geometry,
                actuators: actuators.at(time: t)
            )

            // Differentiable timestep
            state = stepDifferentiable(
                state,
                sources: sourcesAtT,
                dt: dt
            )
        }

        // Compute loss (example: maximize Q_fusion)
        let derived = DerivedQuantitiesComputer.compute(
            profiles: state,
            geometry: geometry
        )
        let loss = -derived.Q_fusion  // Negative for maximization

        return (state, MLXArray(loss))
    }

    /// Differentiable timestep (no compile!)
    private func stepDifferentiable(
        _ profiles: CoreProfiles,
        sources: SourceTerms,
        dt: Float
    ) -> CoreProfiles {
        // Build transport coefficients
        let transportCoeffs = transport.computeCoefficients(
            profiles: profiles,
            geometry: geometry,
            params: staticParams.transport
        )

        // Build FVM coefficients
        let coeffs = Block1DCoeffsBuilder.build(
            transport: transportCoeffs,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles,
            dt: dt
        )

        // Solve (must be differentiable)
        let solver = LinearSolver(tolerance: 1e-6, maxIterations: 100)
        let newProfiles = solver.solve(
            coeffs: coeffs,
            oldProfiles: profiles
        )

        return newProfiles
    }
}
```

**Test**: `DifferentiableSimulationTests.swift`
- Verify gradient flow through timestep
- Compare to compiled simulation (should match outputs)

#### Task 7.1.2: ActuatorTimeSeries

**File**: `Sources/Gotenx/Optimization/Core/ActuatorTimeSeries.swift`

**Purpose**: Differentiable control parameters

```swift
/// Actuator time series (differentiable parameters)
public struct ActuatorTimeSeries {
    public let P_ECRH: [Float]     // ECRH power at each timestep [MW]
    public let P_ICRH: [Float]     // ICRH power [MW]
    public let gas_puff: [Float]   // Gas puff rate [particles/s]
    public let I_plasma: [Float]   // Plasma current [MA]

    public init(
        P_ECRH: [Float],
        P_ICRH: [Float],
        gas_puff: [Float],
        I_plasma: [Float]
    ) {
        precondition(P_ECRH.count == P_ICRH.count)
        precondition(P_ECRH.count == gas_puff.count)
        precondition(P_ECRH.count == I_plasma.count)

        self.P_ECRH = P_ECRH
        self.P_ICRH = P_ICRH
        self.gas_puff = gas_puff
        self.I_plasma = I_plasma
    }

    /// Convert to flat MLXArray for differentiation
    public func toMLXArray() -> MLXArray {
        let flat = P_ECRH + P_ICRH + gas_puff + I_plasma
        return MLXArray(flat)
    }

    /// Reconstruct from flat MLXArray
    public static func fromMLXArray(_ array: MLXArray, nSteps: Int) -> ActuatorTimeSeries {
        let flat = array.asArray(Float.self)
        let nActuators = 4
        precondition(flat.count == nSteps * nActuators)

        return ActuatorTimeSeries(
            P_ECRH: Array(flat[0..<nSteps]),
            P_ICRH: Array(flat[nSteps..<(2*nSteps)]),
            gas_puff: Array(flat[(2*nSteps)..<(3*nSteps)]),
            I_plasma: Array(flat[(3*nSteps)..<(4*nSteps)])
        )
    }

    /// Get actuator values at specific time
    public func at(time: Float) -> ActuatorValues {
        let idx = Int(time / dt)
        return ActuatorValues(
            P_ECRH: P_ECRH[idx],
            P_ICRH: P_ICRH[idx],
            gas_puff: gas_puff[idx],
            I_plasma: I_plasma[idx]
        )
    }

    /// Constant actuators
    public static func constant(
        P_ECRH: Float,
        P_ICRH: Float,
        gas_puff: Float,
        I_plasma: Float,
        nSteps: Int
    ) -> ActuatorTimeSeries {
        return ActuatorTimeSeries(
            P_ECRH: [Float](repeating: P_ECRH, count: nSteps),
            P_ICRH: [Float](repeating: P_ICRH, count: nSteps),
            gas_puff: [Float](repeating: gas_puff, count: nSteps),
            I_plasma: [Float](repeating: I_plasma, count: nSteps)
        )
    }
}

public struct ActuatorValues {
    public let P_ECRH: Float
    public let P_ICRH: Float
    public let gas_puff: Float
    public let I_plasma: Float
}
```

---

### Week 5-8: Optimization Infrastructure (Step 7.2)

#### Task 7.2.1: ForwardSensitivity

**File**: `Sources/Gotenx/Optimization/Sensitivity/ForwardSensitivity.swift`

```swift
public struct ForwardSensitivity {
    private let simulation: DifferentiableSimulation

    /// Compute ∂loss / ∂actuators
    public func computeGradient(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries,
        timeHorizon: Float,
        dt: Float
    ) -> ActuatorTimeSeries {
        let actuatorsArray = actuators.toMLXArray()

        // Define loss function
        func lossFn(_ params: MLXArray) -> MLXArray {
            let acts = ActuatorTimeSeries.fromMLXArray(params, nSteps: actuators.P_ECRH.count)
            let (_, loss) = simulation.forward(
                initialProfiles: initialProfiles,
                actuators: acts,
                timeHorizon: timeHorizon,
                dt: dt
            )
            return loss
        }

        // Compute gradient via MLX
        let gradFn = grad(lossFn)
        let gradient = gradFn(actuatorsArray)

        eval(gradient)

        // Convert back to ActuatorTimeSeries
        return ActuatorTimeSeries.fromMLXArray(gradient, nSteps: actuators.P_ECRH.count)
    }

    /// Sensitivity matrix: ∂outputs / ∂inputs
    public func computeSensitivityMatrix(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries,
        outputs: [String]  // ["Q_fusion", "tau_E", "beta_N", ...]
    ) -> [[Float]] {
        // For each output, compute gradient w.r.t. all actuators
        outputs.map { output in
            let grad = computeGradientFor(
                output: output,
                initialProfiles: initialProfiles,
                actuators: actuators
            )
            return grad.toMLXArray().asArray(Float.self)
        }
    }
}
```

**Test**: `ForwardSensitivityTests.swift`
- Validate against finite differences
- Check gradient correctness (< 1% error)

#### Task 7.2.2: Adam Optimizer

**File**: `Sources/Gotenx/Optimization/Control/Adam.swift`

```swift
/// Adam optimizer (adaptive learning rate)
public struct Adam {
    public let learningRate: Float
    public let beta1: Float  // First moment decay (default: 0.9)
    public let beta2: Float  // Second moment decay (default: 0.999)
    public let epsilon: Float
    public let maxIterations: Int
    public let tolerance: Float

    public init(
        learningRate: Float = 0.001,
        beta1: Float = 0.9,
        beta2: Float = 0.999,
        epsilon: Float = 1e-8,
        maxIterations: Int = 100,
        tolerance: Float = 1e-6
    ) {
        self.learningRate = learningRate
        self.beta1 = beta1
        self.beta2 = beta2
        self.epsilon = epsilon
        self.maxIterations = maxIterations
        self.tolerance = tolerance
    }

    public func optimize(
        problem: OptimizationProblem,
        initialParams: ActuatorTimeSeries,
        constraints: ActuatorConstraints
    ) -> OptimizationResult {
        var params = initialParams
        var paramsArray = params.toMLXArray()

        // First and second moments
        var m = MLXArray.zeros(like: paramsArray)
        var v = MLXArray.zeros(like: paramsArray)

        var bestLoss = Float.infinity
        var bestParams = params

        for t in 1...maxIterations {
            // Compute gradient
            let grad = problem.gradient(params)
            let gradArray = grad.toMLXArray()

            // Update biased first moment estimate
            m = beta1 * m + (1 - beta1) * gradArray

            // Update biased second moment estimate
            v = beta2 * v + (1 - beta2) * (gradArray * gradArray)

            // Bias correction
            let mHat = m / (1 - pow(beta1, Float(t)))
            let vHat = v / (1 - pow(beta2, Float(t)))

            // Update parameters
            paramsArray = paramsArray - learningRate * mHat / (sqrt(vHat) + epsilon)

            // Convert back and apply constraints
            params = ActuatorTimeSeries.fromMLXArray(paramsArray, nSteps: params.P_ECRH.count)
            params = applyConstraints(params, constraints: constraints)
            paramsArray = params.toMLXArray()

            // Evaluate
            let loss = problem.objective(params)

            if loss < bestLoss {
                bestLoss = loss
                bestParams = params
            }

            // Log progress
            if t % 10 == 0 {
                print("Iteration \(t): loss = \(loss)")
            }

            // Check convergence
            if t > 1 && abs(loss - bestLoss) < tolerance {
                print("Converged at iteration \(t)")
                return OptimizationResult(
                    actuators: bestParams,
                    finalLoss: bestLoss,
                    iterations: t,
                    converged: true
                )
            }
        }

        return OptimizationResult(
            actuators: bestParams,
            finalLoss: bestLoss,
            iterations: maxIterations,
            converged: false
        )
    }

    private func applyConstraints(
        _ params: ActuatorTimeSeries,
        constraints: ActuatorConstraints
    ) -> ActuatorTimeSeries {
        return ActuatorTimeSeries(
            P_ECRH: params.P_ECRH.map { clamp($0, min: constraints.minECRH, max: constraints.maxECRH) },
            P_ICRH: params.P_ICRH.map { clamp($0, min: constraints.minICRH, max: constraints.maxICRH) },
            gas_puff: params.gas_puff.map { clamp($0, min: constraints.minGasPuff, max: constraints.maxGasPuff) },
            I_plasma: params.I_plasma.map { clamp($0, min: constraints.minCurrent, max: constraints.maxCurrent) }
        )
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        return Swift.max(min, Swift.min(max, value))
    }
}

public struct ActuatorConstraints {
    public let minECRH: Float
    public let maxECRH: Float
    public let minICRH: Float
    public let maxICRH: Float
    public let minCurrent: Float
    public let maxCurrent: Float
    public let minGasPuff: Float
    public let maxGasPuff: Float

    public static let iter = ActuatorConstraints(
        minECRH: 0.0, maxECRH: 30.0,      // MW
        minICRH: 0.0, maxICRH: 20.0,      // MW
        minCurrent: 5.0, maxCurrent: 20.0, // MA
        minGasPuff: 0.0, maxGasPuff: 1e21  // particles/s
    )
}

public struct OptimizationResult {
    public let actuators: ActuatorTimeSeries
    public let finalLoss: Float
    public let iterations: Int
    public let converged: Bool
}
```

---

### Week 9-12: Scenario Optimizer (Step 7.3)

#### Task 7.3.1: ScenarioOptimizer

**File**: `Sources/Gotenx/Optimization/Applications/ScenarioOptimizer.swift`

```swift
public struct ScenarioOptimizer {
    /// Optimize actuator trajectory to maximize Q_fusion
    public static func maximizeQFusion(
        initialProfiles: CoreProfiles,
        geometry: Geometry,
        timeHorizon: Float,
        dt: Float,
        constraints: ActuatorConstraints
    ) throws -> ScenarioOptimizationResult {
        let nSteps = Int(timeHorizon / dt)

        // Initial guess: constant baseline actuators
        let initialActuators = ActuatorTimeSeries.constant(
            P_ECRH: 15.0,   // 15 MW
            P_ICRH: 7.5,    // 7.5 MW
            gas_puff: 5e20, // 5×10²⁰ particles/s
            I_plasma: 15.0, // 15 MA
            nSteps: nSteps
        )

        // Define optimization problem
        let problem = QFusionMaximization(
            simulation: DifferentiableSimulation(
                staticParams: makeStaticParams(),
                transport: BohmGyrobohmModel(),
                sources: FusionSourceModel(),
                geometry: geometry
            ),
            initialProfiles: initialProfiles,
            timeHorizon: timeHorizon,
            dt: dt
        )

        // Optimize using Adam
        let optimizer = Adam(
            learningRate: 0.01,
            maxIterations: 100,
            tolerance: 1e-4
        )

        let result = optimizer.optimize(
            problem: problem,
            initialParams: initialActuators,
            constraints: constraints
        )

        return ScenarioOptimizationResult(
            actuators: result.actuators,
            Q_fusion: -result.finalLoss,  // Negative because we minimized -Q
            iterations: result.iterations,
            converged: result.converged
        )
    }
}

struct QFusionMaximization: OptimizationProblem {
    let simulation: DifferentiableSimulation
    let initialProfiles: CoreProfiles
    let timeHorizon: Float
    let dt: Float

    func objective(_ actuators: ActuatorTimeSeries) -> Float {
        let (_, loss) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: actuators,
            timeHorizon: timeHorizon,
            dt: dt
        )
        return loss.item(Float.self)
    }

    func gradient(_ actuators: ActuatorTimeSeries) -> ActuatorTimeSeries {
        let sensitivity = ForwardSensitivity(simulation: simulation)
        return sensitivity.computeGradient(
            initialProfiles: initialProfiles,
            actuators: actuators,
            timeHorizon: timeHorizon,
            dt: dt
        )
    }
}

public struct ScenarioOptimizationResult {
    public let actuators: ActuatorTimeSeries
    public let Q_fusion: Float
    public let iterations: Int
    public let converged: Bool
}
```

---

### Week 13-16: Testing and Validation (Step 7.4)

#### Task 7.4.1: Gradient Correctness Tests

**File**: `Tests/GotenxTests/Optimization/ForwardSensitivityTests.swift`

```swift
@Test("Gradient correctness via finite differences")
func testGradientCorrectness() throws {
    let geometry = makeCircularGeometry(nCells: 50)
    let simulation = DifferentiableSimulation(...)
    let sensitivity = ForwardSensitivity(simulation: simulation)

    let actuators = ActuatorTimeSeries.constant(
        P_ECRH: 10.0,
        P_ICRH: 5.0,
        gas_puff: 1e20,
        I_plasma: 15.0,
        nSteps: 10
    )

    // Analytical gradient via AD
    let analyticalGrad = sensitivity.computeGradient(
        initialProfiles: makeITERProfiles(),
        actuators: actuators,
        timeHorizon: 0.1,
        dt: 0.01
    )

    // Numerical gradient via finite differences
    let epsilon: Float = 1e-4
    let numericalGrad = computeNumericalGradient(
        simulation: simulation,
        actuators: actuators,
        epsilon: epsilon
    )

    // Compare
    let relativeError = l2Error(
        predicted: analyticalGrad.toMLXArray().asArray(Float.self),
        reference: numericalGrad.toMLXArray().asArray(Float.self)
    )

    #expect(relativeError < 0.01, "Gradient error = \(relativeError) (expect < 0.01)")
}

func computeNumericalGradient(
    simulation: DifferentiableSimulation,
    actuators: ActuatorTimeSeries,
    epsilon: Float
) -> ActuatorTimeSeries {
    let baseline = simulation.forward(...)

    var gradients: [Float] = []

    // Perturb each parameter
    for i in 0..<actuators.P_ECRH.count {
        var perturbed = actuators
        perturbed.P_ECRH[i] += epsilon

        let perturbedResult = simulation.forward(...)
        let gradient = (perturbedResult.loss - baseline.loss) / epsilon
        gradients.append(gradient)
    }

    // ... repeat for all actuators

    return ActuatorTimeSeries.fromMLXArray(MLXArray(gradients), nSteps: actuators.P_ECRH.count)
}
```

#### Task 7.4.2: Scenario Optimization Tests

**File**: `Tests/GotenxTests/Optimization/ScenarioOptimizerTests.swift`

```swift
@Test("Scenario optimization improves Q_fusion")
func testScenarioOptimization() async throws {
    let geometry = makeITERGeometry()
    let initialProfiles = makeITERProfiles()

    // Baseline: constant actuators
    let baselineActuators = ActuatorTimeSeries.constant(
        P_ECRH: 10.0,
        P_ICRH: 5.0,
        gas_puff: 1e20,
        I_plasma: 15.0,
        nSteps: 200
    )

    let baselineResult = runSimulation(
        initialProfiles: initialProfiles,
        actuators: baselineActuators
    )
    let baselineQ = computeQFusion(baselineResult.finalProfiles, geometry)

    // Optimized: maximize Q_fusion
    let optimizationResult = try ScenarioOptimizer.maximizeQFusion(
        initialProfiles: initialProfiles,
        geometry: geometry,
        timeHorizon: 2.0,
        dt: 0.01,
        constraints: .iter
    )

    let optimizedQ = optimizationResult.Q_fusion

    // Verify improvement
    #expect(optimizedQ > baselineQ, "Optimized Q = \(optimizedQ) vs baseline Q = \(baselineQ)")

    let improvement = (optimizedQ / baselineQ - 1.0) * 100
    print("Q_fusion improvement: \(improvement)%")

    // Expect at least 10% improvement
    #expect(improvement > 10.0, "Expected > 10% improvement, got \(improvement)%")
}
```

---

## Critical Constraints

### 1. MLX Control-Flow Limitation

**Problem**: MLX cannot differentiate through `if` statements or control flow

```swift
// ❌ NOT DIFFERENTIABLE
if beta_N > 3.5 {
    penalty += 1e6
}
```

**Solution**: Use smooth approximations

```swift
// ✅ DIFFERENTIABLE
let penalty = smoothReLU(beta_N - 3.5) * 1e6

func smoothReLU(_ x: Float) -> Float {
    // Smooth approximation of ReLU
    return log(1 + exp(x * 10)) / 10
}

func sigmoid(_ x: Float) -> Float {
    return 1 / (1 + exp(-x))
}
```

### 2. Compilation vs Gradient Tracking

**Problem**: `compile()` optimizes but erases gradient tape

**Solution**: Use two simulation modes:
- **Production mode**: `compile()` for speed (no gradients)
- **Optimization mode**: No `compile()` (preserves gradients)

### 3. Memory Constraints

**Problem**: Gradient tape grows with simulation length

**Solution**:
- Use short time horizons (< 2 seconds)
- Checkpoint/restart for long simulations
- Truncated backpropagation through time

---

## Success Criteria

### Phase 7 Completion Checklist

- [ ] **R7.1: Forward Sensitivity**
  - [ ] Gradient computation works
  - [ ] Validation against finite differences (< 1% error)
  - [ ] Sensitivity matrix for Q_fusion, τE, β_N

- [ ] **R7.2: Optimization**
  - [ ] Adam optimizer implemented
  - [ ] ScenarioOptimizer maximizes Q_fusion
  - [ ] Q_fusion improvement > 10%
  - [ ] Constraints satisfied

- [ ] **R7.3: Control Emulation**
  - [ ] MPC framework implemented
  - [ ] Control loop < 100ms per iteration
  - [ ] Stable closed-loop control

- [ ] **Testing**
  - [ ] 10+ gradient correctness tests
  - [ ] 5+ optimization scenario tests
  - [ ] Performance benchmarks

### Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Gradient computation | < 10s | TBD |
| Optimization convergence | < 100 iterations | TBD |
| Q_fusion improvement | > 10% | TBD |
| Gradient error vs finite diff | < 1% | TBD |

---

## Implementation Timeline

| Week | Tasks | Deliverables |
|------|-------|--------------|
| 1-2 | DifferentiableSimulation, ActuatorTimeSeries | Core AD infrastructure |
| 3-4 | ForwardSensitivity | Gradient computation |
| 5-6 | Adam optimizer | Optimization infrastructure |
| 7-8 | Constraints, smooth approximations | Constraint handling |
| 9-10 | ScenarioOptimizer | Q_fusion maximization |
| 11-12 | ProfileMatcher, RampOptimizer | Additional scenarios |
| 13-14 | Gradient correctness tests | Validation suite |
| 15-16 | Integration tests, benchmarks | Final validation |

---

## Next Steps

1. ✅ Create Phase 7 implementation plan (this document)
2. ⏳ Implement `DifferentiableSimulation.swift`
3. ⏳ Implement `ActuatorTimeSeries.swift`
4. ⏳ Create first gradient test
5. ⏳ Implement `ForwardSensitivity.swift`

---

**Created**: 2025-10-21
**Last Updated**: 2025-10-21
**Status**: 🚧 Week 1 - Starting DifferentiableSimulation implementation
