# Configuration Architecture Refactoring

**Date**: 2025-10-25
**Status**: Design Phase (Under Review)
**Priority**: High

## Revision History

**2025-10-25 (Rev 2)**: Critical design revision based on expert review
- ⚠️ **IMPORTANT**: Original design has fundamental flaws
- Context-dependent defaults placed in context-free layer (TransportConfig)
- Silent missing value fallback (0.0) hides configuration errors
- Key naming convention inconsistencies across sources
- No compile-time validation enforcement
- Missing default change propagation mechanism

**See "Critical Design Issues" section below for detailed analysis and revised approach.**

**2025-10-25 (Rev 1)**: Initial design

## Executive Summary

This document describes a comprehensive refactoring of the configuration system to address fundamental architectural issues discovered during test suite validation. The refactoring separates concerns between configuration loading, default value management, and validation, following SOLID principles and improving testability.

## Problem Statement

### Issue: Test Failures in ToraxConfigReaderTests

All 7 tests in `ToraxConfigReaderTests.swift` are failing with CFL (Courant-Friedrichs-Lewy) violation errors:

```
Caught error: cflViolation(
    parameter: "chi_ion",
    cfl: 10.000001,
    limit: 0.5,
    suggestion: "Reduce chi_ion to 0.049999997 m²/s or decrease dt to 5e-05 s"
)
```

### Root Cause Analysis

The failures reveal **three fundamental architectural problems**:

#### Problem 1: Ambiguous Default Value Ownership

**Current Flow**:
```
TransportConfig
  parameters: [:]  (empty dictionary allowed)
       ↓
ConfigurationValidator
  chi_ion ?? 1.0  (validator provides defaults) ← ❌ Responsibility violation
       ↓
CFL Calculation
  CFL = 1.0 × 0.001 / 0.01² = 10 >> 0.5  (violation)
```

**Issue**: Default values are embedded in the **validation layer**
- `ConfigurationValidator.swift:350` provides `chi_ion ?? 1.0`
- Validator's responsibility is **validation**, not **default value provisioning**
- This violates the Single Responsibility Principle

**Evidence from Code**:
```swift
// ConfigurationValidator.swift:350-352
let chi_ion = transport.parameters["chi_ion"] ?? 1.0
let chi_electron = transport.parameters["chi_electron"] ?? 1.0
let particleDiff = transport.parameters["particle_diffusivity"] ?? 0.1
```

#### Problem 2: Model-Dependent Defaults Not Reflected in Types

**Domain Reality**:
- `ConstantTransportModel`: Requires explicit parameters (chi_ion, chi_electron)
- `BohmGyroBohmTransportModel`: Computes parameters from plasma state (no explicit params needed)
- `QLKNNTransportModel`: Neural network computes parameters (no explicit params needed)

**Current Type System**:
```swift
struct TransportConfig {
    let modelType: TransportModelType
    let parameters: [String: Float]  // ❌ Model dependency not expressed
}
```

**Problem**: The type system doesn't distinguish between models that require parameters vs. those that compute them.

**Evidence from Production Configs**:
```json
// Examples/Configurations/minimal.json (line 36)
"transport": {
  "modelType": "constant",
  "parameters": {}  // Empty allowed but triggers validator defaults
}

// Examples/Configurations/iter_like.json (line 33-35)
"transport": {
  "modelType": "bohmGyrobohm",
  "parameters": {}  // Empty is correct for this model
}
```

#### Problem 3: Tight Coupling Between Loading and Validation

**Current Architecture**:
```swift
// GotenxConfigReader.swift:76-91
public func fetchConfiguration() async throws -> SimulationConfiguration {
    let config = SimulationConfiguration(...)

    // ❌ Validation tightly coupled to loading
    try ConfigurationValidator.validate(config)

    return config
}

// ConfigurationLoader.swift:71
try ConfigurationValidator.validate(finalConfig)  // Same issue
```

**Consequences**:
1. **Test Inflexibility**: Cannot test configuration loading without physics validation
2. **Responsibility Mixing**: Reader does both reading AND validation
3. **Test Scope Confusion**: Integration tests (ToraxConfigReaderTests) forced to satisfy physics constraints

**What Tests Actually Want to Verify**:
- ✅ JSON parsing correctness
- ✅ CLI override priority (CLI > Env > JSON > Default)
- ✅ Environment variable handling
- ❌ NOT: CFL stability, physical plausibility, numerical constraints

## Critical Design Issues (Rev 2)

⚠️ **The original design below has fundamental flaws identified during expert review.**

### Issue 1: Context-Dependent Defaults in Context-Free Layer

**Problem**:
The original design places CFL-dependent default values (0.05 m²/s) in `TransportConfig`, which has no access to `MeshConfig` or `TimeConfiguration`.

```swift
// FLAWED: TransportConfig doesn't know about mesh/time
static func defaultParameters(for modelType: TransportModelType) -> [String: Float] {
    case .constant:
        return ["chi_ion": 0.05]  // ❌ Assumes dx=0.01m, dt=1e-3s
}
```

**Consequence**:
```
User changes: nCells: 100 → 200
→ cellSpacing: 0.01m → 0.005m
→ CFL: 0.05 × 0.001 / 0.005² = 2.0 >> 0.5  ❌ VIOLATION!
```

**Correct Approach**:
- Move default calculation to `GotenxConfigReader` (has mesh/time context)
- Compute CFL-safe defaults: `chiMax = cflLimit * dx² / dt`
- Automatically adapts to any mesh resolution

### Issue 2: Silent Missing Value Fallback

**Problem**:
```swift
// FLAWED: Silent 0.0 fallback
func parameter(_ key: String, default: Float? = nil) -> Float {
    parameters[key] ?? defaultParams[key] ?? default ?? 0.0  // ❌
}
```

**Consequence**:
- Missing required parameter → Returns 0.0 silently
- Validator cannot distinguish "intentional zero" from "missing default"
- Error messages are unclear

**Correct Approach**:
```swift
// Return Optional - caller handles missing values explicitly
func parameter(_ key: String) -> Float?

// Or throw on required parameters
func requireParameter(_ key: String) throws -> Float
```

### Issue 3: Key Naming Convention Mismatch

**Problem**:
- JSON files: `snake_case` (`chi_ion`)
- GotenxConfigReader: Hardcoded `snake_case` keys
- Swift conventions: `camelCase` (`chiIon`)
- iOS/macOS SwiftData: Likely `camelCase`
- CLI args: `--chi-ion` vs `--chiIon` vs `--chi_ion`?

**Consequence**:
Override priority has holes if keys don't match across sources.

**Correct Approach**:
Create unified key mapping:
```swift
enum ConfigurationKeys {
    static let chiIon = Key(swift: "chi_ion", json: "chi_ion",
                           cli: "chi-ion", env: "CHI_ION")
}
```

### Issue 4: No Compile-Time Validation Enforcement

**Problem**:
```swift
// ❌ Easy to forget validation
let config = try await reader.fetchConfiguration()
try await SimulationRunner(config: config).run()  // Oops! No validation
```

**Consequence**:
- Validation is optional (runtime contract only)
- More call sites = more risk of forgetting
- Missing: SimulationPresets, test utilities, interactive notebooks

**Correct Approach**:
Type-safe wrapper:
```swift
struct ValidatedConfiguration {
    private init(_ config: SimulationConfiguration)
    static func validate(_ config: SimulationConfiguration) throws -> Self
}

// API only accepts validated configs
class SimulationRunner {
    init(config: ValidatedConfiguration)  // ✅ Compile-time guarantee
}
```

### Issue 5: No Default Change Propagation

**Problem**:
```swift
@Test func testDefaults() {
    #expect(config.parameter("chi_ion") == 0.05)  // ❌ Hardcoded
}
```

**Consequence**:
- Changing default 0.05 → 0.1 breaks all tests
- No migration guide for users
- No deprecation warnings

**Correct Approach**:
- Versioned defaults with changelog
- Deprecation detection system
- Migration documentation

## Design Principles (Revised)

### 1. Single Responsibility Principle (SRP)

Each component should have **one reason to change**:

| Component | Single Responsibility | Has Context? |
|-----------|----------------------|--------------|
| `TransportConfig` | Define domain model, parameter storage | ❌ No mesh/time |
| `GotenxConfigReader` | Read + merge sources, compute context-aware defaults | ✅ Has mesh/time |
| `ConfigurationValidator` | Validate physics and numerical constraints | ✅ Has full config |
| `ValidatedConfiguration` | Enforce compile-time validation guarantee | N/A (wrapper) |
| `TransportModel` | Compute transport coefficients from plasma state | ✅ Has plasma state |

### 2. Context-Aware Default Calculation

**Revised Principle**: Defaults that depend on context (mesh/time) must be calculated **in a layer that has access to that context**.

```
❌ WRONG: TransportConfig.defaultParameters()
   → No access to mesh/time
   → Fixed values become invalid when mesh changes

✅ CORRECT: GotenxConfigReader.computeCFLSafeDefaults(mesh, time)
   → Has mesh/time context
   → Automatically adapts to any configuration
```

### 3. Explicit Over Implicit

- Validation should be **explicitly invoked** by the caller
- Missing values should be **explicit** (Optional/throwing) not **silent** (0.0)
- Default value application should be **visible** in the code
- Dependencies should be **injected**, not hidden

### 4. Fail-Fast for Configuration Errors

**Revised Principle**: Prefer compile-time guarantees over runtime contracts.

```swift
// ❌ Runtime contract (easy to forget)
let config = try await reader.fetchConfiguration()
try ConfigurationValidator.validate(config)  // Can be forgotten

// ✅ Compile-time guarantee (enforced by type system)
let validated = try ValidatedConfiguration.validate(config)
let runner = SimulationRunner(config: validated)  // Only accepts validated
```

### 5. Separation of Concerns (Revised)

```
┌─────────────────────────────────────────────┐
│   TransportConfig (Domain Model)            │
│   - Model type, parameter storage           │
│   - NO defaults (context-free)              │
└──────────────────┬──────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────┐
│   GotenxConfigReader (Reading + Defaults)   │
│   - Read from JSON/CLI/Env                  │
│   - Compute CFL-aware defaults (w/ context) │
│   - Merge explicit values                   │
└──────────────────┬──────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────┐
│   ValidatedConfiguration (Type Wrapper)     │
│   - Runs validation (throws on error)      │
│   - Provides compile-time guarantee         │
└──────────────────┬──────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────┐
│   SimulationRunner (Execution)              │
│   - Accepts ONLY ValidatedConfiguration     │
│   - No validation responsibility            │
└─────────────────────────────────────────────┘
```

## Proposed Architecture (Revised)

### Phase 1: Remove Context-Dependent Defaults from TransportConfig

**Location**: `Sources/GotenxCore/Configuration/TransportConfig.swift`

**⚠️ IMPORTANT**: TransportConfig should NOT contain CFL-dependent defaults because it has no access to mesh/time context.

```swift
extension TransportConfig {
    /// Get parameter value (returns nil if missing)
    ///
    /// Use this when you need to handle missing values explicitly.
    ///
    /// - Parameter key: Parameter key
    /// - Returns: Parameter value or nil if not found
    public func parameter(_ key: String) -> Float? {
        parameters[key]
    }

    /// Get required parameter (throws if missing)
    ///
    /// Use this for parameters that are mandatory for the model.
    ///
    /// - Parameter key: Parameter key
    /// - Returns: Parameter value
    /// - Throws: ConfigurationError.missingRequired if parameter not found
    public func requireParameter(_ key: String) throws -> Float {
        guard let value = parameters[key] else {
            throw ConfigurationError.missingRequired(
                key: "transport.parameters.\(key) for model \(modelType)"
            )
        }
        return value
    }

    /// Get parameter with explicit default
    ///
    /// Use this when you have a context-independent fallback value.
    ///
    /// - Parameters:
    ///   - key: Parameter key
    ///   - defaultValue: Fallback value
    /// - Returns: Parameter value or default
    public func parameter(_ key: String, default defaultValue: Float) -> Float {
        parameters[key] ?? defaultValue
    }
}
```

**Rationale**:
- ✅ No context-dependent defaults in context-free layer
- ✅ Missing values return `nil` (explicit)
- ✅ Caller chooses error handling strategy (Optional, throwing, or explicit default)
- ✅ Distinguishes "missing" from "zero"

### Phase 2: CFL-Aware Defaults in Reader (REVISED)

**Location**: `Sources/GotenxCLI/Configuration/GotenxConfigReader.swift`

**Before**:
```swift
private func fetchTransportConfig() async throws -> TransportConfig {
    let modelType = try await fetchEnum(...)

    var parameters: [String: Float] = [:]

    // Only loads explicit values (no defaults)
    if let chiIon = try? await configReader.fetchDouble(forKey: "...") {
        parameters["chi_ion"] = Float(chiIon)
    }

    return TransportConfig(modelType: modelType, parameters: parameters)
}
```

**After**:
```swift
private func fetchTransportConfig() async throws -> TransportConfig {
    let modelType = try await fetchEnum(
        forKey: "runtime.dynamic.transport.modelType",
        default: TransportModelType.constant
    )

    // ✅ Compute CFL-safe defaults WITH context
    let mesh = try await fetchMeshConfig()  // Already being fetched
    let time = try await fetchTimeConfig()  // Already being fetched
    let safeDefaults = computeCFLSafeDefaults(
        modelType: modelType,
        mesh: mesh,
        time: time
    )

    // Start with computed defaults
    var parameters = safeDefaults

    // Override with explicit JSON values (unified key handling)
    for (key, jsonKey) in Self.transportParameterKeys {
        if let value = try? await configReader.fetchDouble(forKey: jsonKey) {
            parameters[key] = Float(value)
        }
    }

    return TransportConfig(modelType: modelType, parameters: parameters)
}

/// Key mapping: internal -> JSON
private static let transportParameterKeys: [String: String] = [
    "chi_ion": "runtime.dynamic.transport.parameters.chi_ion",
    "chi_electron": "runtime.dynamic.transport.parameters.chi_electron",
    "particle_diffusivity": "runtime.dynamic.transport.parameters.particle_diffusivity"
]

/// Compute CFL-safe transport parameter defaults
///
/// Design constraint: CFL = χ * Δt / Δx² < cflLimit
///   => χ_max = cflLimit * Δx² / Δt
///
/// - Parameters:
///   - modelType: Transport model type
///   - mesh: Mesh configuration (for Δx)
///   - time: Time configuration (for Δt)
///   - cflLimit: CFL stability limit (default: 0.5)
/// - Returns: CFL-safe default parameters
private func computeCFLSafeDefaults(
    modelType: TransportModelType,
    mesh: MeshConfig,
    time: TimeConfiguration,
    cflLimit: Float = 0.5
) -> [String: Float] {
    // Calculate cell spacing
    let dx = mesh.minorRadius / Float(mesh.nCells)
    let dt = time.initialDt

    // CFL-safe maximum diffusivity
    let chiMax = cflLimit * dx * dx / dt

    switch modelType {
    case .constant:
        // Conservative defaults: Use 90% of CFL limit for safety margin
        let safetyFactor: Float = 0.9
        return [
            "chi_ion": chiMax * safetyFactor,
            "chi_electron": chiMax * safetyFactor,
            "particle_diffusivity": chiMax * safetyFactor * 0.2  // Typically lower
        ]

    case .bohmGyrobohm, .qlknn:
        // Computed by model, no explicit parameters
        return [:]

    case .densityTransition:
        // Model-specific parameters (not CFL-limited)
        return [
            "ri_coefficient": 0.5,
            "transition_density": 2.5e19,
            "transition_width": 0.5e19,
            "ion_mass_number": 2.0
        ]
    }
}
```

**Rationale**:
- ✅ Defaults computed WITH mesh/time context
- ✅ Automatically adapts to different mesh resolutions
- ✅ Safety factor (0.9) provides margin
- ✅ Centralized key mapping for consistency

**Example Behavior**:
```
Mesh: nCells=100, minorRadius=1.0m → dx=0.01m
Time: dt=1e-3s
→ chiMax = 0.5 × 0.01² / 0.001 = 0.05 m²/s
→ default chi_ion = 0.05 × 0.9 = 0.045 m²/s  (safe)

Mesh: nCells=200, minorRadius=1.0m → dx=0.005m
Time: dt=1e-3s
→ chiMax = 0.5 × 0.005² / 0.001 = 0.0125 m²/s
→ default chi_ion = 0.0125 × 0.9 = 0.01125 m²/s  (auto-adjusted!)
```

### Phase 3: Validator Uses Optional API (REVISED)

**Location**: `Sources/GotenxCore/Configuration/ConfigurationValidator.swift:344-407`

**Before**:
```swift
private static func validateCFLCondition(...) throws {
    // ❌ Validator provides defaults (responsibility violation)
    let chi_ion = transport.parameters["chi_ion"] ?? 1.0
    let chi_electron = transport.parameters["chi_electron"] ?? 1.0
    let particleDiff = transport.parameters["particle_diffusivity"] ?? 0.1

    // Validation logic...
}
```

**After**:
```swift
private static func validateCFLCondition(
    transport: TransportConfig,
    dt: Float,
    cellSpacing: Float
) throws {
    // ✅ Use optional API - explicit missing value handling
    guard let chiIon = transport.parameter("chi_ion") else {
        throw ConfigurationValidationError.missingRequiredParameter(
            parameter: "chi_ion",
            modelType: transport.modelType,
            suggestion: "Specify chi_ion in transport.parameters or use a model that computes it"
        )
    }

    guard let chiElectron = transport.parameter("chi_electron") else {
        throw ConfigurationValidationError.missingRequiredParameter(
            parameter: "chi_electron",
            modelType: transport.modelType,
            suggestion: "Specify chi_electron in transport.parameters or use a model that computes it"
        )
    }

    // particle_diffusivity is optional for some models
    let particleDiff = transport.parameter("particle_diffusivity", default: 0.0)

    // ✅ Validation only - no default provisioning
    if chiIon <= 0 {
        throw ConfigurationValidationError.invalidParameter(
            parameter: "chi_ion",
            value: chiIon,
            reason: "Must be positive"
        )
    }

    if chiElectron <= 0 {
        throw ConfigurationValidationError.invalidParameter(
            parameter: "chi_electron",
            value: chiElectron,
            reason: "Must be positive"
        )
    }

    if particleDiff < 0 {
        throw ConfigurationValidationError.invalidParameter(
            parameter: "particle_diffusivity",
            value: particleDiff,
            reason: "Must be non-negative"
        )
    }

    // Compute CFL numbers
    let CFL_ion = chiIon * dt / (cellSpacing * cellSpacing)
    let CFL_electron = chiElectron * dt / (cellSpacing * cellSpacing)
    let CFL_particle = particleDiff * dt / (cellSpacing * cellSpacing)

    if CFL_ion > 0.5 {
        throw ConfigurationValidationError.cflViolation(
            parameter: "chi_ion",
            cfl: CFL_ion,
            limit: 0.5,
            suggestion: "Reduce chi_ion to \(chiIon * 0.5 / CFL_ion) m²/s or decrease dt to \(dt * 0.5 / CFL_ion) s"
        )
    }

    // ... (similar for chi_electron, particle_diffusivity)
}
```

**Rationale**:
- ✅ Explicit error for missing required parameters
- ✅ Distinguishes "missing" from "zero"
- ✅ Clear error messages with suggestions
- ✅ Validator only validates, never provides defaults

    if chi_electron <= 0 {
        throw ConfigurationValidationError.negativeTransportCoefficient(
            parameter: "chi_electron",
            value: chi_electron
        )
    }

    if particleDiff < 0 {
        throw ConfigurationValidationError.negativeTransportCoefficient(
            parameter: "particle_diffusivity",
            value: particleDiff
        )
    }

    // Compute CFL numbers
    let CFL_ion = chi_ion * dt / (cellSpacing * cellSpacing)
    let CFL_electron = chi_electron * dt / (cellSpacing * cellSpacing)
    let CFL_particle = particleDiff * dt / (cellSpacing * cellSpacing)

    if CFL_ion > 0.5 {
        throw ConfigurationValidationError.cflViolation(
            parameter: "chi_ion",
            cfl: CFL_ion,
            limit: 0.5,
            suggestion: "Reduce chi_ion to \(chi_ion * 0.5 / CFL_ion) m²/s or decrease dt to \(dt * 0.5 / CFL_ion) s"
        )
    }

    // ... (similar for chi_electron, particle_diffusivity)
}
```

**Rationale**:
- Validator only **validates**, never **provides** defaults
- Uses domain model's API (`.parameter()`)
- Single Responsibility Principle maintained

### Phase 4: Decouple Loading from Validation

**Location**: `Sources/GotenxCLI/Configuration/GotenxConfigReader.swift:76-91`

**Before**:
```swift
public func fetchConfiguration() async throws -> SimulationConfiguration {
    let runtime = try await fetchRuntimeConfig()
    let time = try await fetchTimeConfig()
    let output = try await fetchOutputConfig()

    let config = SimulationConfiguration(
        runtime: runtime,
        time: time,
        output: output
    )

    // ❌ Validation coupled to loading
    try ConfigurationValidator.validate(config)

    return config
}
```

**After**:
```swift
public func fetchConfiguration() async throws -> SimulationConfiguration {
    let runtime = try await fetchRuntimeConfig()
    let time = try await fetchTimeConfig()
    let output = try await fetchOutputConfig()

    let config = SimulationConfiguration(
        runtime: runtime,
        time: time,
        output: output
    )

    // ✅ No validation - let caller decide
    return config
}
```

**Location**: `Sources/GotenxCore/Configuration/ConfigurationLoader.swift:71`

**Before**:
```swift
public func load() async throws -> SimulationConfiguration {
    // ... loading logic

    try ConfigurationValidator.validate(finalConfig)
    return finalConfig
}
```

**After**:
```swift
public func load() async throws -> SimulationConfiguration {
    // ... loading logic

    // ✅ No validation - return raw loaded config
    return finalConfig
}
```

**Rationale**:
- **Separation of Concerns**: Reading ≠ Validation
- **Testability**: Can test loading without validation
- **Flexibility**: Caller chooses when/if to validate

### Phase 5: Explicit Validation in Production Code

**Location**: `Sources/GotenxCLI/Commands/RunCommand.swift`

**After**:
```swift
let reader = try await GotenxConfigReader.create(
    jsonPath: configPath,
    cliOverrides: cliOverrides
)
let config = try await reader.fetchConfiguration()

// ✅ Explicit validation before use
try ConfigurationValidator.validate(config)

let runner = try await SimulationRunner(config: config)
try await runner.run()
```

**Location**: `Sources/GotenxCLI/Commands/InteractiveMenu.swift:302`

**After**:
```swift
currentConfig = builder.build()

// ✅ Explicit validation with clear error handling
try ConfigurationValidator.validate(currentConfig)

print("✓ Configuration updated")
```

**Rationale**:
- Validation is **explicit** and **visible** at call sites
- Error handling can be customized per use case
- Clear control flow

### Phase 6: Tests Without Validation

**Location**: `Tests/GotenxTests/Configuration/ToraxConfigReaderTests.swift`

**After**:
```swift
@Test("Load minimal configuration from JSON")
func testLoadMinimalConfig() async throws {
    let configPath = try createTestConfig(nCells: 100)
    defer { try? FileManager.default.removeItem(atPath: configPath) }

    let reader = try await GotenxConfigReader.create(
        jsonPath: configPath,
        cliOverrides: [:]
    )

    let config = try await reader.fetchConfiguration()

    // ✅ Test configuration loading only (no validation)
    #expect(config.runtime.static.mesh.nCells > 0)
    #expect(config.time.end > config.time.start)
    #expect(config.time.initialDt > 0)

    // ✅ Test that defaults were applied
    #expect(config.runtime.dynamic.transport.parameter("chi_ion") == 0.05)

    // ❌ No physics validation - that's a separate concern
}

@Test("Validation catches CFL violations")
func testCFLValidation() throws {
    // Separate test for validation logic
    let config = SimulationConfiguration(...)  // Invalid CFL

    #expect(throws: ConfigurationValidationError.self) {
        try ConfigurationValidator.validate(config)
    }
}
```

**Rationale**:
- **Unit Test Clarity**: Each test has a single concern
- **Fast Tests**: No physics validation overhead
- **Separate Validation Tests**: Explicit tests for validator

## Implementation Plan

### Task Breakdown

| Phase | Task | File | Status |
|-------|------|------|--------|
| 1 | Add `defaultParameters(for:)` static method | `TransportConfig.swift` | Pending |
| 1 | Add `parameter(_:default:)` instance method | `TransportConfig.swift` | Pending |
| 1 | Add `withDefaults(modelType:overrides:)` factory | `TransportConfig.swift` | Pending |
| 2 | Update `fetchTransportConfig()` to apply defaults | `GotenxConfigReader.swift` | Pending |
| 3 | Update `validateCFLCondition()` to use `parameter()` | `ConfigurationValidator.swift` | Pending |
| 3 | Remove default value fallbacks from validator | `ConfigurationValidator.swift` | Pending |
| 4 | Remove validation from `fetchConfiguration()` | `GotenxConfigReader.swift` | Pending |
| 4 | Remove validation from `ConfigurationLoader.load()` | `ConfigurationLoader.swift` | Pending |
| 5 | Add explicit validation to `RunCommand.run()` | `RunCommand.swift` | Pending |
| 5 | Add explicit validation to `InteractiveMenu` | `InteractiveMenu.swift` | Pending |
| 6 | Update `ToraxConfigReaderTests` to skip validation | `ToraxConfigReaderTests.swift` | Pending |
| 6 | Add dedicated validation tests | `ConfigurationValidatorTests.swift` | Pending |
| 7 | Run full test suite | All tests | Pending |
| 7 | Verify existing configs still work | Production configs | Pending |

### Migration Strategy

**Step 1: Add New APIs (Non-Breaking)**
- Add `TransportConfig.defaultParameters(for:)`
- Add `TransportConfig.parameter(_:default:)`
- Add `TransportConfig.withDefaults(modelType:overrides:)`

**Step 2: Update Internal Implementations**
- Update `GotenxConfigReader.fetchTransportConfig()`
- Update `ConfigurationValidator.validateCFLCondition()`

**Step 3: Remove Validation Coupling**
- Remove `validate()` calls from readers
- Add explicit `validate()` calls in production code

**Step 4: Update Tests**
- Remove validation expectations from reader tests
- Add dedicated validation tests

**Step 5: Verification**
- Run full test suite
- Test all example configurations
- Verify CLI still works

### Backward Compatibility

**Existing JSON Files**: ✅ **No changes required**

All existing configuration files remain valid:

```json
// Still works - defaults applied automatically
{
  "transport": {
    "modelType": "constant",
    "parameters": {}
  }
}

// Still works - explicit values override defaults
{
  "transport": {
    "modelType": "constant",
    "parameters": {
      "chi_ion": 1.0,
      "chi_electron": 1.0
    }
  }
}
```

**Existing Code**: ⚠️ **Minimal breaking changes**

Code that directly creates `TransportConfig` is unaffected. Only code that relied on implicit validation needs updating:

```swift
// Before (implicit validation)
let config = try await reader.fetchConfiguration()  // Throws if invalid

// After (explicit validation)
let config = try await reader.fetchConfiguration()
try ConfigurationValidator.validate(config)  // Explicit call
```

## Benefits

### 1. Architectural Clarity

```
Before: Reader → Config (with implicit validation)
After:  Reader → Config → Explicit Validation
```

Each component has a single, clear responsibility.

### 2. Improved Testability

```swift
// Can now test loading independently
let config = try await reader.fetchConfiguration()
#expect(config.mesh.nCells == 100)

// Can now test validation independently
#expect(throws: Error.self) {
    try ConfigurationValidator.validate(invalidConfig)
}
```

### 3. Domain Model Encapsulation

```swift
// Domain knowledge lives in domain model
let defaults = TransportConfig.defaultParameters(for: .constant)
// => ["chi_ion": 0.05, "chi_electron": 0.05, ...]
```

### 4. Explicit Control Flow

```swift
// Clear intent at call sites
let config = try await reader.fetchConfiguration()
try ConfigurationValidator.validate(config)  // Explicit validation
```

### 5. Better Error Messages

Since defaults are model-aware, error messages can be more specific:

```
Before: "chi_ion not found, using default 1.0"
After:  "chi_ion not specified for constant model, using CFL-safe default 0.05 m²/s"
```

## Risks and Mitigations

### Risk 1: Breaking Existing Code

**Mitigation**:
- Staged rollout (add APIs first, then migrate)
- Comprehensive test coverage
- Document migration guide

### Risk 2: Test Suite Disruption

**Mitigation**:
- Update tests incrementally
- Keep validation tests separate
- Maintain existing test coverage

### Risk 3: Default Value Changes

**Mitigation**:
- Document default value changes clearly
- Add migration notes for users
- Provide override mechanism

## Testing Strategy

### Unit Tests

```swift
// Test default values
@Test("TransportConfig provides CFL-safe defaults for constant model")
func testConstantModelDefaults() {
    let defaults = TransportConfig.defaultParameters(for: .constant)
    #expect(defaults["chi_ion"] == 0.05)
    #expect(defaults["chi_electron"] == 0.05)
}

// Test parameter fallback
@Test("TransportConfig.parameter() uses fallback chain")
func testParameterFallback() {
    let config = TransportConfig(modelType: .constant, parameters: [:])
    #expect(config.parameter("chi_ion") == 0.05)  // Model default
    #expect(config.parameter("custom", default: 0.1) == 0.1)  // Provided default
}

// Test reading without validation
@Test("GotenxConfigReader loads without validation")
func testLoadWithoutValidation() async throws {
    let reader = try await GotenxConfigReader.create(...)
    let config = try await reader.fetchConfiguration()
    // No validation error even with invalid CFL
}

// Test validation separately
@Test("ConfigurationValidator catches CFL violations")
func testCFLValidation() throws {
    let config = createInvalidConfig()  // CFL > 0.5
    #expect(throws: ConfigurationValidationError.cflViolation) {
        try ConfigurationValidator.validate(config)
    }
}
```

### Integration Tests

```swift
@Test("Full workflow with explicit validation")
func testFullWorkflow() async throws {
    let reader = try await GotenxConfigReader.create(...)
    let config = try await reader.fetchConfiguration()

    // Explicit validation before use
    try ConfigurationValidator.validate(config)

    let runner = try await SimulationRunner(config: config)
    try await runner.run()
}
```

## Success Criteria

✅ **All existing tests pass** with minimal modifications
✅ **All example configurations work** without changes
✅ **ToraxConfigReaderTests pass** without CFL violations
✅ **Validation tests** explicitly cover physics constraints
✅ **Code coverage** maintained or improved
✅ **Documentation** updated to reflect new architecture

## References

### Related Documents
- [CONFIGURATION_SYSTEM.md](../docs/CONFIGURATION_SYSTEM.md) - Current configuration documentation
- [CONFIGURATION_VALIDATION_SPEC.md](./CONFIGURATION_VALIDATION_SPEC.md) - Validation specification

### Design Patterns
- **Single Responsibility Principle** (SOLID)
- **Separation of Concerns**
- **Domain-Driven Design** (defaults as domain knowledge)
- **Explicit over Implicit** (The Zen of Python)

### Code References
- `Sources/GotenxCore/Configuration/TransportConfig.swift` - Domain model
- `Sources/GotenxCLI/Configuration/GotenxConfigReader.swift` - Configuration reader
- `Sources/GotenxCore/Configuration/ConfigurationValidator.swift` - Validation logic
- `Tests/GotenxTests/Configuration/ToraxConfigReaderTests.swift` - Failing tests

## Appendix A: Complete Example

### Before (Current State)

```swift
// TransportConfig.swift
struct TransportConfig {
    let modelType: TransportModelType
    let parameters: [String: Float]  // No defaults
}

// ConfigurationValidator.swift
let chi_ion = transport.parameters["chi_ion"] ?? 1.0  // ❌ Validator provides defaults

// GotenxConfigReader.swift
let config = try await reader.fetchConfiguration()  // ❌ Implicit validation

// ToraxConfigReaderTests.swift
let config = try await reader.fetchConfiguration()
// ❌ Fails: CFL = 10 >> 0.5
```

### After (Proposed State)

```swift
// TransportConfig.swift
extension TransportConfig {
    static func defaultParameters(for modelType: TransportModelType) -> [String: Float] {
        switch modelType {
        case .constant: return ["chi_ion": 0.05, "chi_electron": 0.05]
        case .bohmGyrobohm: return [:]
        // ...
        }
    }

    func parameter(_ key: String, default: Float? = nil) -> Float {
        parameters[key] ?? Self.defaultParameters(for: modelType)[key] ?? default ?? 0.0
    }
}

// ConfigurationValidator.swift
let chi_ion = transport.parameter("chi_ion")  // ✅ Uses domain model API

// GotenxConfigReader.swift
private func fetchTransportConfig() -> TransportConfig {
    var params = TransportConfig.defaultParameters(for: modelType)  // ✅ Apply defaults
    // ... merge with JSON values
    return TransportConfig(modelType: modelType, parameters: params)
}

// RunCommand.swift
let config = try await reader.fetchConfiguration()
try ConfigurationValidator.validate(config)  // ✅ Explicit validation

// ToraxConfigReaderTests.swift
let config = try await reader.fetchConfiguration()
#expect(config.runtime.dynamic.transport.parameter("chi_ion") == 0.05)
// ✅ Passes: Tests loading logic, not validation
```

## Appendix B: CFL-Safe Default Calculation

For numerical stability, the CFL condition must be satisfied:

```
CFL = χ * Δt / Δx² < 0.5
```

For typical test scenarios:
- `Δt = 1e-3 s` (1 millisecond timestep)
- `dx = minorRadius / nCells = 1.0 / 100 = 0.01 m`

Therefore:
```
χ_max = 0.5 * Δx² / Δt
      = 0.5 * (0.01)² / 0.001
      = 0.5 * 0.0001 / 0.001
      = 0.05 m²/s
```

Hence the default value `chi_ion = 0.05 m²/s` for the constant transport model.

---

**Document Version**: 1.0
**Last Updated**: 2025-10-25
**Author**: Claude Code Assistant
**Review Status**: Pending
