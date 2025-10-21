# MLX Best Practices

## ⚠️ MLX Lazy Evaluation and eval() - CRITICAL

### The Lazy Evaluation System

**MLX-Swift uses lazy evaluation by design**. Operations on `MLXArray` are NOT executed immediately—they are deferred until explicitly materialized with `eval()` or `asyncEval()`.

```swift
// ❌ WRONG: Operations are queued, not executed!
let result = exp(-1000.0 / temperature)
return result  // Returns unevaluated computation graph ❌

// ✅ CORRECT: Force evaluation before returning
let result = exp(-1000.0 / temperature)
eval(result)  // Executes computation graph ✅
return result
```

---

## When eval() is MANDATORY

**YOU MUST call eval() in these situations:**

### 1. At the END of a computation chain when values are actually needed

```swift
// ✅ CORRECT: Chain operations, eval at the end
func computeTransport(Ti: MLXArray, Te: MLXArray) -> (MLXArray, MLXArray) {
    let chiIon = exp(-1000.0 / Ti)          // Lazy
    let chiElectron = exp(-1000.0 / Te)     // Lazy
    // Return lazy arrays - caller decides when to eval
    return (chiIon, chiElectron)
}

// Caller evaluates when needed
let (chiIon, chiElectron) = computeTransport(Ti, Te)
eval(chiIon, chiElectron)  // ✅ Eval when values are needed
```

### 2. Before wrapping in EvaluatedArray (automatic)

```swift
// ✅ CORRECT: EvaluatedArray.init() calls eval() internally
return TransportCoefficients(
    chiIon: EvaluatedArray(evaluating: chiIon),  // eval() called here
    chiElectron: EvaluatedArray(evaluating: chiElectron)
)
```

### 3. Before crossing actor boundaries

```swift
let profiles = computeProfiles(...)
eval(profiles)  // ✅ Evaluate before sending to actor
await actor.process(profiles)
```

### 4. At the end of each time step in simulations

```swift
for step in 0..<nSteps {
    state = compiledStep(state)
    eval(state.coreProfiles)  // ✅ Evaluate per step
}
```

### 5. When accessing actual values (often implicit)

```swift
let result = compute(...)
let value = result.item(Float.self)  // Implicit eval()
let array = result.asArray(Float.self)  // Implicit eval()
```

---

## What Happens Without eval()

**Without eval(), you get:**
- ❌ **Unevaluated computation graphs** instead of actual values
- ❌ **Deferred memory allocation** - no storage for results
- ❌ **Unpredictable crashes** when graphs are accessed later
- ❌ **Incorrect numerical results** from stale or unexecuted operations
- ❌ **Memory leaks** from accumulating operation graphs

---

## Implicit Evaluation Triggers

These methods **automatically call eval() internally**:
- `array.item()` - Extracts scalar value
- `array.asArray(Type.self)` - Converts to Swift array
- `array.asData(noCopy:)` - Extracts raw data

**However**, relying on implicit evaluation is dangerous:

```swift
// ❌ BAD: Relying on implicit eval() in item()
func compute(...) -> MLXArray {
    let result = someOp(...)
    let _ = result.item()  // Triggers eval() as side effect
    return result  // But still feels hacky
}

// ✅ GOOD: Explicit eval() before return
func compute(...) -> MLXArray {
    let result = someOp(...)
    eval(result)  // Clear intent
    return result
}
```

---

## Best Practices

### ✅ DO: Chain operations, eval at the end of computation

```swift
// ✅ GOOD: Let operations chain, eval when wrapping in EvaluatedArray
public func computeOhmicHeating(
    Te: MLXArray,
    jParallel: MLXArray,
    geometry: Geometry
) -> MLXArray {
    let eta = computeResistivity(Te, geometry)  // Lazy
    let Q_ohm = eta * jParallel * jParallel     // Lazy

    // Return lazy - caller will eval when wrapping in EvaluatedArray
    return Q_ohm
}

// Caller handles evaluation
let Q_ohm = ohmic.compute(Te, jParallel, geometry)
let source = SourceTerms(
    electronHeating: EvaluatedArray(evaluating: Q_ohm)  // eval() here
)
```

### ✅ DO: Batch evaluation for efficiency

```swift
// Compute multiple results
let chiIon = exp(-1000.0 / Ti)
let chiElectron = exp(-1000.0 / Te)
let diffusivity = chiElectron * 0.5

// Batch evaluate (more efficient than 3 separate eval() calls)
eval(chiIon, chiElectron, diffusivity)

return TransportCoefficients(
    chiIon: EvaluatedArray(evaluating: chiIon),
    chiElectron: EvaluatedArray(evaluating: chiElectron),
    particleDiffusivity: EvaluatedArray(evaluating: diffusivity),
    convectionVelocity: .zeros([nCells])
)
```

### ✅ DO: Use EvaluatedArray for type safety

```swift
// EvaluatedArray enforces evaluation at construction
public struct EvaluatedArray: @unchecked Sendable {
    private let array: MLXArray

    public init(evaluating array: MLXArray) {
        eval(array)  // ✅ Guaranteed evaluation
        self.array = array
    }
}
```

### ❌ DON'T: Return unevaluated arrays

```swift
// ❌ WRONG: Unevaluated computation graph returned
func computeTransport(...) -> MLXArray {
    let chi = exp(-activation / temperature)
    return chi  // ❌ NO eval() - BUG!
}
```

### ❌ DON'T: Evaluate too frequently in loops

```swift
// ❌ WRONG: eval() in tight loop (inefficient)
for i in 0..<nSteps {
    let x = operation1(...)
    eval(x)  // ❌ Too frequent
    let y = operation2(x)
    eval(y)  // ❌ Too frequent
}

// ✅ CORRECT: Accumulate operations, eval once per step
for i in 0..<nSteps {
    let x = operation1(...)
    let y = operation2(x)
    eval(y)  // ✅ Once per iteration
}
```

---

## Common Bug Patterns

### Bug Pattern #1: Accessing values without ensuring evaluation

```swift
// ❌ BUG: Using result without eval() when not wrapped in EvaluatedArray
public func process(array: MLXArray) -> Float {
    let result = transform(array)
    // If result is never evaluated and we try to use it later...
    return someOtherFunction(result)  // ❌ May use unevaluated graph
}

// ✅ FIX 1: Wrap in EvaluatedArray (auto eval)
public func process(array: MLXArray) -> EvaluatedArray {
    let result = transform(array)
    return EvaluatedArray(evaluating: result)  // ✅ Auto eval
}

// ✅ FIX 2: Explicit eval when needed
public func process(array: MLXArray) -> Float {
    let result = transform(array)
    eval(result)  // ✅ Ensure evaluation
    return result.item(Float.self)
}
```

### Bug Pattern #2: Forgetting eval() in iterative solvers

```swift
// ❌ BUG: Newton-Raphson without eval()
for iteration in 0..<maxIter {
    let residual = computeResidual(x)
    let jacobian = computeJacobian(x)
    let delta = solve(jacobian, residual)
    x = x - delta
    // ❌ Missing eval(x) here
}
return x  // Returns unevaluated graph

// ✅ FIX: Evaluate in each iteration
for iteration in 0..<maxIter {
    let residual = computeResidual(x)
    let jacobian = computeJacobian(x)
    let delta = solve(jacobian, residual)
    x = x - delta
    eval(x)  // ✅ Evaluate per iteration
}
return x
```

### Bug Pattern #3: Conditional eval()

```swift
// ❌ BUG: Only evaluating sometimes
func process(array: MLXArray, shouldEval: Bool) -> MLXArray {
    let result = transform(array)
    if shouldEval {
        eval(result)
    }
    return result  // ❌ Might be unevaluated
}

// ✅ FIX: Always evaluate before return
func process(array: MLXArray) -> MLXArray {
    let result = transform(array)
    eval(result)  // ✅ Always evaluate
    return result
}
```

---

## Testing for eval() bugs

Use these techniques to catch missing eval() calls:

### 1. Check shapes immediately

```swift
let result = compute(...)
#expect(result.shape == expectedShape)  // Will fail if unevaluated
```

### 2. Extract values in tests

```swift
let result = compute(...)
let value = result.item(Float.self)  // Forces eval, catches bugs
#expect(abs(value - expected) < 1e-6)
```

### 3. Use eval() explicitly in all tests

```swift
let result = compute(...)
eval(result)  // Make it explicit
#expect(allClose(result, expected).item(Bool.self))
```

---

## Summary: eval() Checklist

✅ **ALWAYS eval() when:**
- Values are actually needed (end of computation chain)
- Wrapping in EvaluatedArray (done automatically by init)
- Crossing actor boundaries
- End of time steps in loops
- Before accessing with item() or asArray() (often implicit)

✅ **NEVER:**
- Eval too early in computation chains (breaks optimization)
- Forget eval() in iterative loops
- Rely solely on implicit evaluation without understanding it

✅ **REMEMBER:**
- MLX is lazy by default - operations queue, don't execute
- Let computations chain for better optimization
- EvaluatedArray wrapper enforces evaluation at type level
- eval() is cheap - it's a no-op if already evaluated
- When in doubt, use EvaluatedArray for type safety

---

*See also:*
- [SWIFT_CONCURRENCY.md](SWIFT_CONCURRENCY.md) for concurrency patterns with MLXArray
- [NUMERICAL_PRECISION.md](NUMERICAL_PRECISION.md) for GPU-first design principles
- [CLAUDE.md](../CLAUDE.md) for development guidelines
