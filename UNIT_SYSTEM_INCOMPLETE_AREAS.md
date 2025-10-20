# Unit System Unification - Incomplete Areas

**Date**: 2025-10-18 (Analysis)
**Completed**: 2025-10-18 (Implementation)
**Status**: ✅ RESOLVED - All issues addressed
**Priority**: 🟢 Complete (was P1 - High)

---

## ⚠️ HISTORICAL DOCUMENT

This document identified gaps in the initial unit system unification. All issues have been **resolved** as of 2025-10-18.

**Current Status**: See `UNIT_SYSTEM_COMPLETE.md` for complete implementation details.

---

## Original Analysis (Now Resolved)

---

## Critical Review Findings

This document addresses critical gaps identified in the unit system unification effort. While the Gotenx core library has been unified to eV/m^-3, **two critical areas remain unconverted**, causing potential display errors of 10^3 / 10^20 magnitude.

---

## Issue 1: CLI Display Layer (User-Facing)

### Impact: HIGH - Direct User-Visible Errors

**Problem**: CLI output and plotting still label values as keV/10^20 m^-3, but the underlying data is now in eV/m^-3. This means users see values that are off by 1000× (temperature) or 10^20× (density).

### Affected Files

#### 1. PlotCommand.swift - Plot Labels

**File**: `Sources/gotenx-cli/Commands/PlotCommand.swift:245,251`

**Current Code** (INCORRECT):
```swift
static let `default` = PlotConfiguration(
    figures: [
        FigureSpec(
            name: "temperatures",
            quantities: ["ionTemperature", "electronTemperature"],
            ylabel: "Temperature (keV)",  // ❌ Data is in eV, label says keV
            xlabel: "Normalized radius"
        ),
        FigureSpec(
            name: "density",
            quantities: ["electronDensity"],
            ylabel: "Density (10^20 m^-3)",  // ❌ Data is in m^-3, label says 10^20 m^-3
            xlabel: "Normalized radius"
        ),
        // ...
    ],
    style: PlotStyle.default
)
```

**Problem**:
- If actual data is 1000 eV, plot will show "1000" with label "Temperature (keV)"
- User interprets this as 1000 keV = 1,000,000 eV (1000× error!)

**Required Fix**:
```swift
// Option 1: Change labels to match internal units
ylabel: "Temperature (eV)"
ylabel: "Density (m^-3)"

// Option 2: Scale data for display and keep conventional labels
// (requires adding conversion in plot data extraction)
```

#### 2. ProgressLogger.swift - Console Output

**File**: `Sources/gotenx-cli/Output/ProgressLogger.swift:61,73`

**Current Code** (INCORRECT):
```swift
func logFinalState(_ state: SimulationStateSummary) {
    guard logOutput else { return }

    print("""

    Ion Temperature (keV):  // ❌ Label says keV
      Min:  \(String(format: "%.3f", state.ionTemperature.min))
      Max:  \(String(format: "%.3f", state.ionTemperature.max))
      Core: \(String(format: "%.3f", state.ionTemperature.core))
      Edge: \(String(format: "%.3f", state.ionTemperature.edge))

    Electron Temperature (keV):  // ❌ Label says keV
      Min:  \(String(format: "%.3f", state.electronTemperature.min))
      Max:  \(String(format: "%.3f", state.electronTemperature.max))
      Core: \(String(format: "%.3f", state.electronTemperature.core))
      Edge: \(String(format: "%.3f", state.electronTemperature.edge))

    Electron Density (10^20 m^-3):  // ❌ Label says 10^20 m^-3
      Min:  \(String(format: "%.3f", state.electronDensity.min))
      // ...
    """)
}
```

**Problem**:
- SimulationStateSummary receives eV/m^-3 values from CoreProfiles
- Console output labels them as keV/10^20 m^-3
- User sees "100.000 keV" when actual value is 100 eV

**Required Fix**:
```swift
// Option 1: Update labels to match internal units
Ion Temperature (eV):
Electron Density (m^-3):

// Option 2: Scale values for display
Min:  \(String(format: "%.3f", state.ionTemperature.min / 1000.0))  // eV → keV
// Density scaling is more complex (scientific notation recommended)
```

### User Impact

**Severity**: Critical for usability

**Scenario 1**: User runs simulation with 100 eV edge temperature
- Internal: 100 eV ✅ Correct
- Console output: "Edge: 100.000 (keV)" ❌ User thinks it's 100,000 eV
- Plot: Y-axis shows "100" with label "Temperature (keV)" ❌ Same misinterpretation

**Scenario 2**: User compares with literature (typically in keV)
- Literature: "Edge temperature 0.1 keV"
- User sets config: `ionTemperature: 0.1` (thinking it's keV)
- Actual result: 0.1 eV (1000× too cold!)

---

## Issue 2: Pedestal Model API (Internal Inconsistency)

### Impact: MEDIUM - Future Integration Risk

**Problem**: PedestalModel protocol and PedestalOutput struct still specify keV/10^20 m^-3, creating inconsistency with CoreProfiles (eV/m^-3).

### Affected Files

#### PedestalModel.swift

**File**: `Sources/Gotenx/Protocols/PedestalModel.swift:6-11`

**Current Code** (INCONSISTENT):
```swift
/// Pedestal model output
public struct PedestalOutput: Sendable, Equatable {
    /// Pedestal temperature [keV]  // ❌ Inconsistent with CoreProfiles [eV]
    public let temperature: Float

    /// Pedestal density [10^20 m^-3]  // ❌ Inconsistent with CoreProfiles [m^-3]
    public let density: Float

    /// Pedestal width [m]  // ✅ OK
    public let width: Float
}
```

**Problem**:
- CoreProfiles uses eV/m^-3
- PedestalOutput claims to use keV/10^20 m^-3
- When pedestal models are implemented, this mismatch will cause 1000× errors

**Data Flow** (when pedestal is implemented):
```swift
// Hypothetical future code:
func applyPedestalBoundary() {
    let pedestal = pedestalModel.computePedestal(profiles, geometry, params)

    // ❌ BUG: pedestal.temperature is documented as keV
    // but boundary conditions expect eV
    boundaryConditions.temperature = pedestal.temperature  // 1000× error!
}
```

**Required Fix**:
```swift
/// Pedestal model output
public struct PedestalOutput: Sendable, Equatable {
    /// Pedestal temperature [eV]  // ✅ Consistent with CoreProfiles
    public let temperature: Float

    /// Pedestal density [m^-3]  // ✅ Consistent with CoreProfiles
    public let density: Float

    /// Pedestal width [m]
    public let width: Float
}
```

### Current Status

**Pedestal Implementation**: Not yet implemented (placeholder only)

**Risk Level**: Medium (future risk, not immediate)

**Reason**:
- No pedestal models are currently active
- PedestalOutput is defined but unused
- Will become critical when pedestal physics is added

---

## Summary: Incomplete Unification

### Completed Areas ✅

| Component | Units | Status |
|-----------|-------|--------|
| CoreProfiles | eV, m^-3 | ✅ Unified |
| BoundaryConditions | eV, m^-3 | ✅ Unified |
| ProfileConditions | eV, m^-3 | ✅ Unified |
| DynamicRuntimeParams | eV, m^-3 | ✅ Unified |
| SimulationRunner.generateInitialProfiles | eV, m^-3 | ✅ Unified |
| Physics Models | eV, m^-3 | ✅ Expected units |

### Incomplete Areas ⚠️

| Component | Current State | Impact | Priority |
|-----------|--------------|--------|----------|
| **PlotCommand labels** | keV, 10^20 m^-3 | User sees wrong scale | 🔴 P1 High |
| **ProgressLogger labels** | keV, 10^20 m^-3 | User sees wrong scale | 🔴 P1 High |
| **PedestalOutput docs** | keV, 10^20 m^-3 | Future integration bug | 🟡 P2 Medium |

### Why This Matters

**User-Facing Impact**: The CLI layer is the **primary user interface**. Incorrect labels directly mislead users about simulation results.

**Example of User Confusion**:
```bash
$ torax run config.json
...
Final State Summary
═══════════════════════════════════════════════════
Ion Temperature (keV):        # ❌ User thinks this is keV
  Core: 1000.000              # Actually 1000 eV = 1 keV
  Edge: 100.000               # Actually 100 eV = 0.1 keV

Electron Density (10^20 m^-3): # ❌ User thinks this is 10^20 m^-3
  Core: 30000000000000000000.000  # Actually 3e19 m^-3 = 0.3 × 10^20 m^-3
```

---

## Recommended Actions

### Immediate (P1 - High Priority)

1. **Update CLI Display Labels**
   - **Files**: PlotCommand.swift, ProgressLogger.swift
   - **Change**: Update labels to match internal eV/m^-3 units
   - **Alternative**: Add display scaling (eV→keV, m^-3→10^20 m^-3) with conversion functions

2. **Choose Display Strategy**

   **Option A**: Display in internal units (eV/m^-3)
   - ✅ Pros: Simple, no conversion, matches internal representation
   - ❌ Cons: Uncommon in tokamak literature (usually keV/10^20 m^-3)

   **Option B**: Convert for display (show keV/10^20 m^-3)
   - ✅ Pros: Matches tokamak conventions, easier for domain experts
   - ❌ Cons: Requires conversion layer, risk of conversion bugs

   **Recommendation**: **Option B** - Convert for display to match conventions
   ```swift
   // Display scaling functions
   func toDisplayUnits(temperature: Float) -> Float {
       temperature / 1000.0  // eV → keV
   }

   func toDisplayUnits(density: Float) -> Float {
       density / 1e20  // m^-3 → 10^20 m^-3
   }
   ```

### Short-Term (P2 - Medium Priority)

3. **Fix PedestalOutput Documentation**
   - **File**: PedestalModel.swift
   - **Change**: Update comments to specify eV/m^-3
   - **Impact**: Prevents future bugs when pedestal models are implemented

### Documentation Updates

4. **Update UNIT_SYSTEM_UNIFIED.md**
   - Add "Known Limitations" section
   - Document CLI display layer as incomplete
   - Document Pedestal API as incomplete

5. **Create Migration Guide**
   - Document display unit strategy decision
   - Provide conversion utilities
   - Update user-facing documentation

---

## Implementation Plan

### Phase 1: Fix Display Labels (P1)

**Estimated Effort**: 2-4 hours

**Tasks**:
1. Create display unit conversion utilities
2. Update PlotCommand.swift:
   - Keep labels as "keV" and "10^20 m^-3" (convention)
   - Add scaling: `data.map { $0 / 1000.0 }` for temperature
   - Add scaling: `data.map { $0 / 1e20 }` for density
3. Update ProgressLogger.swift:
   - Keep labels as "keV" and "10^20 m^-3"
   - Scale values before formatting
4. Add tests for display conversions

### Phase 2: Fix Pedestal API (P2)

**Estimated Effort**: 1 hour

**Tasks**:
1. Update PedestalOutput documentation
2. Verify no existing code assumes keV/10^20 m^-3 (grep check)
3. Update protocol comments

### Phase 3: Documentation

**Estimated Effort**: 1 hour

**Tasks**:
1. Update UNIT_SYSTEM_UNIFIED.md with limitations
2. Add display unit strategy to CLAUDE.md
3. Document conversion utilities

---

## Testing Strategy

### Display Unit Tests

```swift
@Test("Display unit conversions - temperature eV → keV")
func testTemperatureDisplayConversion() {
    let internalValue: Float = 1000.0  // eV
    let displayValue = toDisplayUnits(temperature: internalValue)
    #expect(abs(displayValue - 1.0) < 1e-6)  // 1 keV
}

@Test("Display unit conversions - density m^-3 → 10^20 m^-3")
func testDensityDisplayConversion() {
    let internalValue: Float = 3e19  // m^-3
    let displayValue = toDisplayUnits(density: internalValue)
    #expect(abs(displayValue - 0.3) < 1e-6)  // 0.3 × 10^20 m^-3
}
```

### Integration Tests

```swift
@Test("CLI output displays correct scaled values")
func testCLIOutputScaling() {
    let state = SimulationState(
        ionTemperature: 1000.0,  // eV internally
        // ...
    )
    let summary = createSummary(state)
    let output = formatOutput(summary)

    // Output should show "1.000 keV" not "1000.000 keV"
    #expect(output.contains("1.000"))
}
```

---

## Conclusion

The unit system unification is **functionally complete** in the Gotenx core library, but **incomplete in user-facing layers**. This creates a **critical UX issue** where users see values with incorrect magnitude labels.

**Priority**: Fix CLI display layer immediately (P1) to prevent user confusion and potential configuration errors.

**Recommended Approach**: Keep internal representation as eV/m^-3, but add display scaling to show conventional keV/10^20 m^-3 in CLI output and plots.
