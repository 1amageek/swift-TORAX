# RI Turbulence Physics - Critical Parameter Ranges

## Physical Regime for RI Turbulence

### **Valid Parameter Range**
- **Temperature**: 1-3 keV (collisional regime)
- **Density**: > 2.5×10¹⁹ m⁻³ (above transition)
- **C_RI coefficient**: 10-50 (empirical tuning parameter)

### **Why High Temperature (10 keV) Fails**

**Spitzer Resistivity Scaling**: η ∝ T^(-3/2)

At T = 10 keV:
```
η_spitzer ≈ 8.8×10⁻⁹ Ω⋅m  (very low - nearly collisionless)
τ_R = μ₀ × a² / η ≈ 5.7×10⁵ s  (extremely long diffusion time)
χ_RI = C_RI × ρ_s² / τ_R ≈ 3.5×10⁻¹² m²/s  (below clipping minimum!)
```

At T = 2.5 keV:
```
η_spitzer ≈ 7.1×10⁻⁸ Ω⋅m  (8× higher - collisional)
τ_R ≈ 7.1×10⁴ s  (8× shorter)
χ_RI = 20.0 × ρ_s² / τ_R ≈ 2.8×10⁻⁷ m²/s  (observable with C_RI=20)
```

### **Physical Interpretation**

**RI turbulence is a collisional instability**:
- Requires finite resistivity for magnetic reconnection
- At high T: resistivity too low → instability suppressed
- At moderate T: resistivity adequate → instability active

**Contrast with ITG/TEM**:
- ITG/TEM are kinetic instabilities
- Operate in collisionless regime (high T)
- Not suppressed by low resistivity

### **Implications for Tokamak Operation**

**Low-Confinement Mode (L-mode)**:
- Edge temperature: 0.5-1 keV
- RI turbulence may dominate edge transport
- Collisional, resistive plasma

**High-Confinement Mode (H-mode)**:
- Core temperature: 10-20 keV
- ITG/TEM turbulence dominates core
- Nearly collisionless plasma
- RI turbulence negligible in hot core

**Density Transition**:
- Below n_trans: ITG (works at all T)
- Above n_trans: RI (only at moderate T)
- At high T and high n: different turbulence regime (need different model)

### **Test Parameter Selection**

For RI isotope scaling tests:
```swift
// ✅ CORRECT: Moderate temperature for collisional regime
let Te = MLXArray(Float(2500.0)) * (1.0 - 0.5 * rhoNorm²)  // 2.5 keV
let C_RI = 20.0  // Compensates for τ_R ~ 10⁴-10⁵ s

// ❌ WRONG: High temperature gives negligible RI
let Te = MLXArray(Float(10000.0)) * (1.0 - 0.5 * rhoNorm²)  // 10 keV
let C_RI = 0.5   // χ_RI < 1e-12 m²/s → unobservable
```

### **Critical: Bohm vs GyroBohm Isotope Scaling**

**Physics**:
- **Bohm diffusivity**: χ_Bohm = (c × T_e)/(e × B) → **NO ion mass dependence**
- **GyroBohm diffusivity**: χ_GB = (ρ_s/a)² × χ_Bohm → ρ_s² ∝ m_i → **HAS isotope scaling**

**Magnitude Comparison** (at 2.5 keV, a=2m, B=5.3T):
```
χ_Bohm ≈ 8.8 m²/s
ρ_s ≈ 0.96 mm
χ_GB ≈ (0.96mm / 2m)² × 8.8 ≈ 2×10⁻⁶ m²/s

Ratio: χ_GB / χ_Bohm ≈ 10⁻⁶ (GyroBohm is negligible!)
```

**Implication for Isotope Tests**:
- If using default `BohmGyroBohmTransportModel()` with bohmCoeff=1.0, gyroBhohmCoeff=1.0
- χ_total ≈ χ_Bohm (no isotope effect observable)
- **Solution**: Use pure GyroBohm (bohmCoeff=0.0, gyroBhohmCoeff=1.0) for tests

```swift
// ❌ WRONG: Bohm term dominates, no isotope effect
let model = BohmGyroBohmTransportModel()  // Default: bohm=1.0, gyrobohm=1.0
// χ_H = χ_D ≈ 8.8 m²/s (GyroBohm contribution invisible)

// ✅ CORRECT: Pure GyroBohm shows isotope scaling
let model = BohmGyroBohmTransportModel(
    bohmCoeff: 0.0,      // Turn off Bohm term
    gyroBhohmCoeff: 1.0,
    ionMassNumber: massNumber
)
// χ_D / χ_H ≈ 2.0 ✓
```

### **Future Model Improvements**

**Automatic Regime Detection**:
```swift
if T > 5000.0 && regime == .RI {
    // Warn: RI turbulence negligible at high T
    // Suggest: Switch to ITG/TEM model
}
```

**Collisionality-Dependent Coefficient**:
```swift
let nu_star = collisionality(T, n, B, R)
let C_RI_effective = C_RI * collisionalityFactor(nu_star)
// Smoothly turn off RI at low collisionality
```

---

**Reference**: Kinoshita et al., Phys. Rev. Lett. 132, 235101 (2024)
**Last Updated**: 2025-10-23
