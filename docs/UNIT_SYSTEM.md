# Unit System Standard

**CRITICAL**: swift-Gotenx uses a **consistent SI-based unit system** throughout the codebase to match physics models and prevent 1000× errors.

## Standard Units

| Quantity | Unit | Symbol | Notes |
|----------|------|--------|-------|
| **Temperature** | electron volt | **eV** | NOT keV (common in tokamak literature) |
| **Density** | particles per cubic meter | **m⁻³** | NOT 10²⁰ m⁻³ (common in tokamak literature) |
| **Time** | seconds | s | SI base unit |
| **Length** | meters | m | SI base unit |
| **Magnetic Field** | tesla | T | SI derived unit |
| **Energy** | joules | J | Physics calculations |
| **Power** | megawatts per cubic meter | MW/m³ | Source terms |
| **Current Density** | megaamperes per square meter | MA/m² | Plasma current |

## Data Flow

```
JSON Config (eV, m^-3)
    ↓
BoundaryConfig (eV, m^-3)
    ↓ no conversion
BoundaryConditions (eV, m^-3)
    ↓ no conversion
CoreProfiles (eV, m^-3)
    ↓ no conversion
Physics Models (W/m³ or MW/m³ for heating)
    ↓ return SourceTerms [MW/m³]
CompositeSourceModel [MW/m³]
    ↓ aggregates all sources
Block1DCoeffsBuilder
    ↓ CONVERTS: MW/m³ → eV/(m³·s)
    ↓ (factor: 6.2415×10²⁴)
PDE Solver [eV/(m³·s)]
    ↓ solves equations
Results CoreProfiles (eV, m^-3)
```

**Critical**: SourceTerms uses **MW/m³** for heating (plasma physics standard). Conversion to **eV/(m³·s)** (PDE solver units) happens exclusively in `Block1DCoeffsBuilder` via `UnitConversions.megawattsToEvDensity()`. This centralization prevents unit mixing bugs.

## Why eV and m^-3 for CoreProfiles?

1. **Physics model consistency**: All physics models (`FusionPower`, `IonElectronExchange`, `OhmicHeating`, `Bremsstrahlung`) use eV and m^-3 for profiles
2. **Centralized conversion**: Single conversion point (Block1DCoeffsBuilder) eliminates distributed conversion bugs
3. **TORAX compatibility**: Original Python TORAX uses similar unit boundaries
4. **Type safety**: Units enforced through documentation and validation

## Why MW/m³ for SourceTerms?

1. **Plasma physics standard**: Heating is universally reported in MW/m³ in tokamak literature
2. **Aggregation safety**: CompositeSourceModel can safely add sources (all same unit)
3. **Barrier pattern**: Block1DCoeffsBuilder acts as single conversion barrier to solver domain
4. **Error prevention**: Prevents unit mixing when combining multiple sources (ECRH + Fusion + Ohmic)

## Display Units (Output Only)

For user-facing output (CLI, logs, plots), display units MAY differ:
- Temperature: keV (via `/1000`)
- Density: 10²⁰ m^-3 (via `/1e20`)

**Example** (`ProgressLogger.swift`):
```swift
func logFinalState(_ summary: SimulationStateSummary) {
    // Display conversion for user readability
    print("  Ti_core: \(summary.ionTemperature.core / 1000.0) keV")
    print("  ne_core: \(summary.electronDensity.core / 1e20) × 10^20 m^-3")
}
```

## ProfileConditions Exception

`ProfileConditions` is an **intermediate representation** used for configuration-driven profile generation:
- Uses keV and 10²⁰ m^-3 for user convenience
- Converted to eV and m^-3 when materializing `CoreProfiles`
- Clearly documented as different from runtime units

---

*See also: [CLAUDE.md](../CLAUDE.md) for development guidelines*
