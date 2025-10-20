# Phase 4: TODO項目完全設計書

## 概要

Phase 3実装で残された3つのTODO項目について、完全な実装設計を行う。

**Phase 4対象項目**:
1. **Power balance分離**: 個別ソース貢献のトラッキング
2. **Current density積分**: 実際のj_parallelプロファイル使用
3. **CFL数計算**: 適応的タイムステップの安定性指標

**目標**: 物理的に正確で、パフォーマンスを維持し、後方互換性を保つ

---

## TODO 1: Power Balance分離

### 現状の問題

**場所**: `DerivedQuantitiesComputer.swift:259-301`

```swift
// 現状: 総加熱パワーから推定で分離
let P_total = totalHeating.item(Float.self)
let P_fusion = P_total * frac * 0.5      // ← 推定値
let P_alpha = P_fusion * 0.2             // ← 推定値
let P_ohmic = P_total * 0.1              // ← 推定値
let P_auxiliary = P_total - P_fusion - P_ohmic  // ← 残差
```

**問題点**:
1. ❌ 個別ソースの実際の寄与が不明
2. ❌ 推定比率（50%, 20%, 10%）が固定
3. ❌ ソースモデルの種類を区別できない
4. ❌ 時間変化するパワーバランスを追跡できない

**影響**:
- P_fusion、P_alpha、P_ohmic、P_auxiliaryの精度が低い
- 融合性能評価（Q値）が不正確
- エネルギー収支の診断が困難

---

### 設計アプローチ

#### 設計原則
1. **非侵襲的**: 既存のSourceModel APIを変更しない
2. **オプトイン**: 新機能は段階的に有効化
3. **型安全**: コンパイル時に種別を保証
4. **高性能**: GPU上で効率的に計算

#### アーキテクチャ

```
SourceModel (既存)
    ↓ computeTerms()
SourceTerms (既存)
    ↓ 拡張: metadata追加
SourceTermsWithMetadata (新規)
    ↓ 個別寄与を保持
PowerBalanceComputer (新規)
    ↓ 分類・集計
PowerBalance (新規構造体)
```

---

### データ構造設計

#### 1. SourceCategory列挙型（新規）

```swift
// Sources/Gotenx/Sources/SourceCategory.swift

/// Source categorization for power balance tracking
///
/// **Phase 4**: Enables accurate power component separation
public enum SourceCategory: String, Sendable, Codable {
    // Fusion heating
    case fusion = "fusion"           // DT fusion reactions
    case alphaHeating = "alpha"      // Alpha particle heating

    // External heating
    case ohmic = "ohmic"             // Ohmic heating (J·E)
    case icrh = "icrh"               // Ion Cyclotron Resonance Heating
    case ecrh = "ecrh"               // Electron Cyclotron Resonance Heating
    case nbi = "nbi"                 // Neutral Beam Injection

    // Radiation losses
    case bremsstrahlung = "brem"     // Bremsstrahlung radiation
    case synchrotron = "sync"        // Synchrotron radiation
    case lineRadiation = "line"      // Line radiation (impurities)

    // Current drive
    case bootstrap = "bootstrap"     // Bootstrap current
    case eccd = "eccd"               // ECCD
    case nbcd = "nbcd"               // NBCD

    // Other
    case ionElectronExchange = "ie_exchange"
    case custom = "custom"

    /// Whether this category contributes to fusion power
    public var isFusion: Bool {
        switch self {
        case .fusion, .alphaHeating:
            return true
        default:
            return false
        }
    }

    /// Whether this category is external auxiliary heating
    public var isAuxiliary: Bool {
        switch self {
        case .icrh, .ecrh, .nbi:
            return true
        default:
            return false
        }
    }

    /// Whether this category is radiation loss
    public var isRadiation: Bool {
        switch self {
        case .bremsstrahlung, .synchrotron, .lineRadiation:
            return true
        default:
            return false
        }
    }
}
```

#### 2. SourceMetadata構造体（新規）

```swift
// Sources/Gotenx/Sources/SourceMetadata.swift

/// Metadata for source term tracking
///
/// **Phase 4**: Enables power balance component separation
public struct SourceMetadata: Sendable, Equatable {
    /// Source category for classification
    public let category: SourceCategory

    /// Model name (e.g., "FusionPower", "OhmicHeating")
    public let modelName: String

    /// Ion heating power [MW] (integrated over volume)
    public let P_ion: Float

    /// Electron heating power [MW] (integrated over volume)
    public let P_electron: Float

    /// Particle source [particles/s] (integrated over volume)
    public let S_particle: Float

    /// Current drive [MA] (integrated over volume)
    public let I_current: Float

    /// Total power (P_ion + P_electron)
    public var P_total: Float {
        P_ion + P_electron
    }

    public init(
        category: SourceCategory,
        modelName: String,
        P_ion: Float = 0,
        P_electron: Float = 0,
        S_particle: Float = 0,
        I_current: Float = 0
    ) {
        self.category = category
        self.modelName = modelName
        self.P_ion = P_ion
        self.P_electron = P_electron
        self.S_particle = S_particle
        self.I_current = I_current
    }
}
```

#### 3. SourceTerms拡張（後方互換）

```swift
// Sources/Gotenx/Core/SourceTerms.swift

public struct SourceTerms: Sendable, Equatable {
    // 既存フィールド（変更なし）
    public let ionHeating: EvaluatedArray
    public let electronHeating: EvaluatedArray
    public let particleSource: EvaluatedArray
    public let currentSource: EvaluatedArray

    // Phase 4: メタデータ（オプショナルで後方互換）
    /// Individual source contributions with metadata
    ///
    /// **Phase 3**: Always nil (not tracked)
    /// **Phase 4**: Populated by enhanced SourceModel protocol
    public let sourceMetadata: [SourceMetadata]?

    public init(
        ionHeating: EvaluatedArray,
        electronHeating: EvaluatedArray,
        particleSource: EvaluatedArray,
        currentSource: EvaluatedArray,
        sourceMetadata: [SourceMetadata]? = nil  // ← 後方互換
    ) {
        self.ionHeating = ionHeating
        self.electronHeating = electronHeating
        self.particleSource = particleSource
        self.currentSource = currentSource
        self.sourceMetadata = sourceMetadata
    }
}
```

#### 4. PowerBalance構造体（新規）

```swift
// Sources/Gotenx/Diagnostics/PowerBalance.swift

/// Detailed power balance components
///
/// **Phase 4**: Accurate power component separation
public struct PowerBalance: Sendable, Codable, Equatable {
    // Fusion
    public let P_fusion: Float          // Total fusion power [MW]
    public let P_alpha: Float           // Alpha heating [MW]
    public let P_neutron: Float         // Neutron power (escapes) [MW]

    // External heating
    public let P_ohmic: Float           // Ohmic heating [MW]
    public let P_icrh: Float            // ICRH power [MW]
    public let P_ecrh: Float            // ECRH power [MW]
    public let P_nbi: Float             // NBI power [MW]
    public let P_auxiliary: Float       // Total auxiliary (ICRH+ECRH+NBI)

    // Radiation losses
    public let P_bremsstrahlung: Float  // Bremsstrahlung [MW]
    public let P_synchrotron: Float     // Synchrotron [MW]
    public let P_line_radiation: Float  // Line radiation [MW]
    public let P_radiation_total: Float // Total radiation loss

    // Current drive
    public let I_bootstrap: Float       // Bootstrap current [MA]
    public let I_eccd: Float            // ECCD [MA]
    public let I_nbcd: Float            // NBCD [MA]

    // Derived quantities
    /// Total input power (auxiliary + ohmic)
    public var P_input: Float {
        P_auxiliary + P_ohmic
    }

    /// Total heating (input + alpha)
    public var P_heating: Float {
        P_input + P_alpha
    }

    /// Net power balance (heating - radiation)
    public var P_net: Float {
        P_heating - P_radiation_total
    }

    /// Fusion gain Q = P_fusion / P_input
    public var Q: Float {
        guard P_input > 1e-6 else { return 0 }
        return P_fusion / P_input
    }

    /// Fusion amplification Qplasma = P_fusion / (P_input + P_alpha)
    public var Q_plasma: Float {
        let P_loss = P_input + P_alpha
        guard P_loss > 1e-6 else { return 0 }
        return P_fusion / P_loss
    }
}
```

---

### 実装戦略

#### Phase 4.1: SourceModel Protocol拡張（オプショナル）

```swift
// Sources/Gotenx/Sources/SourceModel.swift

public protocol SourceModel: Sendable {
    var name: String { get }

    // 既存メソッド（変更なし）
    func computeTerms(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: SourceParams
    ) -> SourceTerms

    // Phase 4: オプショナルメソッド（デフォルト実装あり）
    /// Category for power balance tracking
    var category: SourceCategory { get }
}

extension SourceModel {
    // デフォルト実装: 既存モデルはcustomカテゴリ
    public var category: SourceCategory {
        .custom
    }
}
```

#### Phase 4.2: 個別SourceModelにcategory追加

```swift
// Sources/GotenxPhysics/Sources/FusionPower.swift

public struct FusionPower: SourceModel {
    public let name = "fusion"
    public let category: SourceCategory = .fusion  // ← 追加

    public func computeTerms(...) -> SourceTerms {
        // 既存実装（変更なし）
        let heating = ...

        // Phase 4: メタデータ計算
        let metadata = computeMetadata(heating: heating, geometry: geometry)

        return SourceTerms(
            ionHeating: ionHeating,
            electronHeating: electronHeating,
            particleSource: particleSource,
            currentSource: currentSource,
            sourceMetadata: [metadata]  // ← 追加
        )
    }

    private func computeMetadata(
        heating: EvaluatedArray,
        geometry: Geometry
    ) -> SourceMetadata {
        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value

        // 体積積分: MW/m³ × m³ = MW
        let P_electron = (heating.value * volumes).sum().item(Float.self)

        return SourceMetadata(
            category: .fusion,
            modelName: name,
            P_ion: 0,            // Fusion heats electrons primarily
            P_electron: P_electron,
            S_particle: 0,
            I_current: 0
        )
    }
}
```

#### Phase 4.3: PowerBalanceComputer実装

```swift
// Sources/Gotenx/Diagnostics/PowerBalanceComputer.swift

public enum PowerBalanceComputer {

    /// Compute detailed power balance from source metadata
    ///
    /// **Phase 4**: Accurate component separation using source tracking
    ///
    /// - Parameter sources: Source terms with metadata
    /// - Returns: Detailed power balance
    public static func compute(sources: SourceTerms?) -> PowerBalance {
        guard let metadata = sources?.sourceMetadata, !metadata.isEmpty else {
            // Fallback: Phase 3 estimation
            return computeFallback(sources: sources)
        }

        // Aggregate by category
        var P_fusion: Float = 0
        var P_alpha: Float = 0
        var P_ohmic: Float = 0
        var P_icrh: Float = 0
        var P_ecrh: Float = 0
        var P_nbi: Float = 0
        var P_brem: Float = 0
        var P_sync: Float = 0
        var P_line: Float = 0
        var I_bootstrap: Float = 0
        var I_eccd: Float = 0
        var I_nbcd: Float = 0

        for meta in metadata {
            switch meta.category {
            case .fusion:
                P_fusion += meta.P_total
            case .alphaHeating:
                P_alpha += meta.P_total
            case .ohmic:
                P_ohmic += meta.P_total
            case .icrh:
                P_icrh += meta.P_total
            case .ecrh:
                P_ecrh += meta.P_total
            case .nbi:
                P_nbi += meta.P_total
            case .bremsstrahlung:
                P_brem += meta.P_total
            case .synchrotron:
                P_sync += meta.P_total
            case .lineRadiation:
                P_line += meta.P_total
            case .bootstrap:
                I_bootstrap += meta.I_current
            case .eccd:
                I_eccd += meta.I_current
            case .nbcd:
                I_nbcd += meta.I_current
            default:
                break
            }
        }

        // DT fusion: 17.6 MeV total, 3.5 MeV alpha, 14.1 MeV neutron
        let P_neutron = P_fusion * 0.8  // 14.1/17.6 ≈ 0.8

        return PowerBalance(
            P_fusion: P_fusion,
            P_alpha: P_alpha,
            P_neutron: P_neutron,
            P_ohmic: P_ohmic,
            P_icrh: P_icrh,
            P_ecrh: P_ecrh,
            P_nbi: P_nbi,
            P_auxiliary: P_icrh + P_ecrh + P_nbi,
            P_bremsstrahlung: P_brem,
            P_synchrotron: P_sync,
            P_line_radiation: P_line,
            P_radiation_total: P_brem + P_sync + P_line,
            I_bootstrap: I_bootstrap,
            I_eccd: I_eccd,
            I_nbcd: I_nbcd
        )
    }

    /// Fallback: Phase 3 estimation (for backward compatibility)
    private static func computeFallback(sources: SourceTerms?) -> PowerBalance {
        // 既存のPhase 3ロジックを使用
        // ...
    }
}
```

#### Phase 4.4: DerivedQuantitiesComputer統合

```swift
// Sources/Gotenx/Diagnostics/DerivedQuantitiesComputer.swift

private static func computePowerBalance(
    sources: SourceTerms?,
    profiles: CoreProfiles,
    geometry: Geometry,
    volumes: MLXArray
) -> (P_fusion: Float, P_alpha: Float, P_auxiliary: Float, P_ohmic: Float) {

    // Phase 4: Use PowerBalanceComputer
    let balance = PowerBalanceComputer.compute(sources: sources)

    return (
        P_fusion: balance.P_fusion,
        P_alpha: balance.P_alpha,
        P_auxiliary: balance.P_auxiliary,
        P_ohmic: balance.P_ohmic
    )
}
```

---

### マイグレーション計画

#### Phase 4.1: 基盤実装
- SourceCategory列挙型
- SourceMetadata構造体
- PowerBalance構造体
- PowerBalanceComputer（fallback実装含む）

#### Phase 4.2: 既存モデル更新
- FusionPower → `.fusion`
- OhmicHeating → `.ohmic`
- Bremsstrahlung → `.bremsstrahlung`
- IonElectronExchange → `.ionElectronExchange`

#### Phase 4.3: 新規モデル対応
- ICRH → `.icrh`
- ECRH → `.ecrh`
- Bootstrap → `.bootstrap`

#### Phase 4.4: 統合・テスト
- DerivedQuantitiesComputer統合
- 後方互換性テスト
- 精度検証テスト

---

## TODO 2: Current Density積分

### 現状の問題

**場所**: `DerivedQuantitiesComputer.swift:434-460`

```swift
// 現状: 幾何学的推定
let q_edge: Float = 3.0  // ← 仮定値
let Ip_estimate = (2.0 * .pi * a * a * Bt) / (mu0 * R0 * q_edge)  // ← 推定式
```

**問題点**:
1. ❌ 実際のj_parallel(r)プロファイルを使用していない
2. ❌ q_edgeが固定値（3.0）
3. ❌ Bootstrap電流、ECCD等の寄与が不明
4. ❌ 電流分布の時間発展を追跡できない

**影響**:
- βN計算の精度低下（βN = β × a × Bt / **Ip**）
- 電流駆動効率の評価不可
- MHD安定性解析に使えない

---

### 設計アプローチ

#### 物理式

プラズマ電流の正確な計算:

```
I_plasma = ∫∫ j_parallel(r,θ) dS
         = ∫ j_parallel(r) × 2π R(r) dr

where:
  j_parallel = j_ohmic + j_bootstrap + j_ECCD + j_NBCD + ...
```

#### 実装戦略

```
SourceTerms.currentSource  [MA/m²]
    ↓ 体積積分
CurrentDensityIntegrator (新規)
    ↓ 幾何学因子を考慮
CurrentMetrics (拡張)
    ↓ 個別成分を保持
```

---

### データ構造設計

#### 1. CurrentMetrics拡張

```swift
// Sources/Gotenx/Diagnostics/CurrentMetrics.swift (新規)

/// Current density metrics
///
/// **Phase 4**: Accurate current integration from profiles
public struct CurrentMetrics: Sendable, Codable, Equatable {
    // Total currents
    public let I_plasma: Float          // Total plasma current [MA]
    public let I_ohmic: Float           // Ohmic current [MA]
    public let I_bootstrap: Float       // Bootstrap current [MA]
    public let I_eccd: Float            // ECCD [MA]
    public let I_nbcd: Float            // NBCD [MA]

    // Derived quantities
    /// Non-inductive current (bootstrap + CD)
    public var I_noninductive: Float {
        I_bootstrap + I_eccd + I_nbcd
    }

    /// Bootstrap fraction
    public var f_bootstrap: Float {
        guard I_plasma > 1e-6 else { return 0 }
        return I_bootstrap / I_plasma
    }

    /// Non-inductive fraction
    public var f_noninductive: Float {
        guard I_plasma > 1e-6 else { return 0 }
        return I_noninductive / I_plasma
    }

    // Profile metrics
    public let q_95: Float              // Safety factor at 95% flux
    public let q_min: Float             // Minimum safety factor
    public let r_q_min: Float           // Radius of q_min [m]
    public let li_internal: Float       // Internal inductance

    public init(
        I_plasma: Float,
        I_ohmic: Float = 0,
        I_bootstrap: Float = 0,
        I_eccd: Float = 0,
        I_nbcd: Float = 0,
        q_95: Float = 0,
        q_min: Float = 0,
        r_q_min: Float = 0,
        li_internal: Float = 0
    ) {
        self.I_plasma = I_plasma
        self.I_ohmic = I_ohmic
        self.I_bootstrap = I_bootstrap
        self.I_eccd = I_eccd
        self.I_nbcd = I_nbcd
        self.q_95 = q_95
        self.q_min = q_min
        self.r_q_min = r_q_min
        self.li_internal = li_internal
    }
}
```

#### 2. CurrentDensityIntegrator実装

```swift
// Sources/Gotenx/Diagnostics/CurrentDensityIntegrator.swift (新規)

public enum CurrentDensityIntegrator {

    /// Integrate current density over plasma cross-section
    ///
    /// **Phase 4**: Accurate integration using actual j_parallel profiles
    ///
    /// Computes: I = ∫ j_parallel(r) × 2πR(r) dr
    ///
    /// - Parameters:
    ///   - currentDensity: Current density profile [MA/m²]
    ///   - geometry: Tokamak geometry
    ///   - sourceMetadata: Individual source contributions (optional)
    /// - Returns: Current metrics with component breakdown
    public static func integrate(
        currentDensity: EvaluatedArray,
        geometry: Geometry,
        sourceMetadata: [SourceMetadata]?
    ) -> CurrentMetrics {

        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let radii = geometry.radii.value  // [m]
        let R0 = geometry.majorRadius

        // Current density: j [MA/m²]
        let j_parallel = currentDensity.value

        // Cross-sectional area element: dS = 2πR dr
        // For circular geometry: R(r) ≈ R0
        let dS = 2.0 * .pi * R0 * geometricFactors.dr.value

        // Total current: I = ∫ j dS
        let I_total = (j_parallel * dS).sum()
        eval(I_total)

        let I_plasma = I_total.item(Float.self)

        // Component breakdown from metadata
        var I_ohmic: Float = 0
        var I_bootstrap: Float = 0
        var I_eccd: Float = 0
        var I_nbcd: Float = 0

        if let metadata = sourceMetadata {
            for meta in metadata {
                switch meta.category {
                case .ohmic:
                    I_ohmic += meta.I_current
                case .bootstrap:
                    I_bootstrap += meta.I_current
                case .eccd:
                    I_eccd += meta.I_current
                case .nbcd:
                    I_nbcd += meta.I_current
                default:
                    break
                }
            }
        }

        // Safety factor metrics
        let qMetrics = computeSafetyFactorMetrics(
            geometry: geometry,
            currentDensity: j_parallel
        )

        return CurrentMetrics(
            I_plasma: I_plasma,
            I_ohmic: I_ohmic,
            I_bootstrap: I_bootstrap,
            I_eccd: I_eccd,
            I_nbcd: I_nbcd,
            q_95: qMetrics.q_95,
            q_min: qMetrics.q_min,
            r_q_min: qMetrics.r_q_min,
            li_internal: qMetrics.li
        )
    }

    /// Compute safety factor metrics
    private static func computeSafetyFactorMetrics(
        geometry: Geometry,
        currentDensity: MLXArray
    ) -> (q_95: Float, q_min: Float, r_q_min: Float, li: Float) {

        // Extract safety factor from geometry
        let q_profile = geometry.safetyFactor.value
        eval(q_profile)

        // q at 95% flux surface
        let nCells = q_profile.shape[0]
        let idx_95 = Int(Float(nCells) * 0.95)
        let q_95 = q_profile[idx_95].item(Float.self)

        // Minimum q and its location
        let q_array = q_profile.asArray(Float.self)
        let q_min = q_array.min() ?? 0
        let idx_min = q_array.firstIndex(of: q_min) ?? 0
        let r_q_min = geometry.radii.value[idx_min].item(Float.self)

        // Internal inductance (normalized stored magnetic energy)
        // li = (2/μ0I²) ∫ Bp² dV ≈ (1 + 0.5 * <j²> / <j>²)
        let li = computeInternalInductance(
            currentDensity: currentDensity,
            geometry: geometry
        )

        return (q_95, q_min, r_q_min, li)
    }

    /// Compute internal inductance
    private static func computeInternalInductance(
        currentDensity: MLXArray,
        geometry: Geometry
    ) -> Float {
        // Simplified formula for circular geometry
        // li ≈ 0.5 + log(8*R/a) - 1.25 + <j²>/<j>²

        let geometricFactors = GeometricFactors.from(geometry: geometry)
        let volumes = geometricFactors.cellVolumes.value

        let j = currentDensity
        let j_squared = j * j

        let j_avg = (j * volumes).sum() / volumes.sum()
        let j_squared_avg = (j_squared * volumes).sum() / volumes.sum()

        eval(j_avg, j_squared_avg)

        let j_avg_val = j_avg.item(Float.self)
        let j_squared_avg_val = j_squared_avg.item(Float.self)

        let peaking = j_squared_avg_val / (j_avg_val * j_avg_val + 1e-20)

        let R0 = geometry.majorRadius
        let a = geometry.minorRadius
        let geometric_term = log(8.0 * R0 / a) - 1.25

        let li = 0.5 + geometric_term + peaking

        return li
    }
}
```

#### 3. DerivedQuantitiesComputer統合

```swift
// Sources/Gotenx/Diagnostics/DerivedQuantitiesComputer.swift

private static func computeCurrentMetrics(
    profiles: CoreProfiles,
    geometry: Geometry,
    transport: TransportCoefficients?,
    sources: SourceTerms?
) -> CurrentMetrics {

    // Phase 4: Use CurrentDensityIntegrator
    if let sources = sources {
        return CurrentDensityIntegrator.integrate(
            currentDensity: sources.currentSource,
            geometry: geometry,
            sourceMetadata: sources.sourceMetadata
        )
    } else {
        // Fallback: Geometric estimation
        return estimateCurrentGeometric(geometry: geometry)
    }
}

/// Fallback: Phase 3 geometric estimation
private static func estimateCurrentGeometric(
    geometry: Geometry
) -> CurrentMetrics {
    let a = geometry.minorRadius
    let R0 = geometry.majorRadius
    let Bt = geometry.toroidalField
    let q_edge: Float = 3.0
    let mu0: Float = 4.0 * .pi * 1e-7

    let Ip_estimate = (2.0 * .pi * a * a * Bt) / (mu0 * R0 * q_edge)

    return CurrentMetrics(
        I_plasma: Ip_estimate,
        I_ohmic: Ip_estimate,  // Assume all ohmic in fallback
        q_95: q_edge
    )
}
```

---

### テスト戦略

```swift
// Tests/GotenxTests/Diagnostics/CurrentDensityIntegratorTests.swift

@Test("Flat current profile integration")
func testFlatCurrentProfile() {
    let geometry = createCircularGeometry(R0: 6.2, a: 2.0)
    let j_flat: Float = 1.0  // [MA/m²]
    let currentDensity = EvaluatedArray.constant(j_flat, shape: [100])

    let metrics = CurrentDensityIntegrator.integrate(
        currentDensity: currentDensity,
        geometry: geometry,
        sourceMetadata: nil
    )

    // Expected: I = j × 2πR × πa² = 1.0 × 2π×6.2 × π×2² ≈ 155 MA
    let expected: Float = j_flat * 2.0 * .pi * 6.2 * .pi * 2.0 * 2.0
    #expect(abs(metrics.I_plasma - expected) / expected < 0.05)
}

@Test("Peaked current profile")
func testPeakedCurrentProfile() {
    let geometry = createCircularGeometry(R0: 6.2, a: 2.0)

    // Parabolic profile: j(r) = j0 * (1 - (r/a)²)²
    let nCells = 100
    let radii = (0..<nCells).map { Float($0) / Float(nCells - 1) * 2.0 }
    let j_profile = radii.map { r in
        let normalized = r / 2.0
        return 2.0 * (1.0 - normalized * normalized) * (1.0 - normalized * normalized)
    }

    let currentDensity = EvaluatedArray(evaluating: MLXArray(j_profile))

    let metrics = CurrentDensityIntegrator.integrate(
        currentDensity: currentDensity,
        geometry: geometry,
        sourceMetadata: nil
    )

    // Should have lower q_min (more peaked) and higher internal inductance
    #expect(metrics.q_min < 1.5)
    #expect(metrics.li_internal > 0.5)
}
```

---

## TODO 3: CFL数計算

### 現状の問題

**場所**: `SimulationOrchestrator.swift:453`

```swift
diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
    from: solverResult,
    dt: state.dt,
    wallTime: stepWallTime,
    cflNumber: 0,  // ← TODO: Compute CFL number
    ...
)
```

**問題点**:
1. ❌ タイムステップの安定性指標がない
2. ❌ 適応的タイムステップの妥当性を検証できない
3. ❌ 数値不安定性の早期警告ができない

**影響**:
- タイムステップが大きすぎて不安定になる可能性
- 保守的すぎて計算効率が悪い可能性
- 数値的異常の原因特定が困難

---

### 設計アプローチ

#### 物理的定義

Courant-Friedrichs-Lewy (CFL) 条件:

```
CFL = (χ × dt) / (Δr²)

where:
  χ = max(χ_ion, χ_electron, D_particle)  [m²/s]
  dt = timestep [s]
  Δr = grid spacing [m]

Stability criterion:
  CFL < CFL_max ≈ 0.5 (explicit methods)
  CFL < 1.0 (implicit methods, less strict)
```

#### 実装戦略

```
TransportCoefficients
    ↓ Extract max(χ, D)
CFLComputer (新規)
    ↓ Compute CFL number
NumericalDiagnostics
    ↓ Track CFL evolution
```

---

### データ構造設計

#### 1. CFLMetrics構造体（新規）

```swift
// Sources/Gotenx/Diagnostics/CFLMetrics.swift (新規)

/// CFL stability metrics
///
/// **Phase 4**: Timestep stability monitoring
public struct CFLMetrics: Sendable, Equatable {
    /// CFL number based on ion heat diffusivity
    public let cfl_ion: Float

    /// CFL number based on electron heat diffusivity
    public let cfl_electron: Float

    /// CFL number based on particle diffusivity
    public let cfl_particle: Float

    /// Maximum CFL number (limiting factor)
    public var cfl_max: Float {
        max(cfl_ion, cfl_electron, cfl_particle)
    }

    /// Limiting transport coefficient type
    public var limiting_coefficient: String {
        if cfl_ion >= max(cfl_electron, cfl_particle) {
            return "chi_ion"
        } else if cfl_electron >= cfl_particle {
            return "chi_electron"
        } else {
            return "D_particle"
        }
    }

    /// Stability status
    public var isStable: Bool {
        cfl_max < 1.0  // Conservative for implicit methods
    }

    /// Warning level (0: safe, 1: warning, 2: critical)
    public var warningLevel: Int {
        if cfl_max < 0.5 {
            return 0  // Safe
        } else if cfl_max < 1.0 {
            return 1  // Warning (approaching limit)
        } else {
            return 2  // Critical (unstable)
        }
    }
}
```

#### 2. CFLComputer実装

```swift
// Sources/Gotenx/Diagnostics/CFLComputer.swift (新規)

public enum CFLComputer {

    /// Compute CFL numbers from transport coefficients
    ///
    /// **Phase 4**: Timestep stability analysis
    ///
    /// CFL = (χ × dt) / (Δr²)
    ///
    /// - Parameters:
    ///   - transport: Transport coefficients
    ///   - dt: Current timestep [s]
    ///   - dr: Grid spacing [m]
    /// - Returns: CFL metrics
    public static func compute(
        transport: TransportCoefficients,
        dt: Float,
        dr: Float
    ) -> CFLMetrics {

        // Extract maximum diffusivities (worst case)
        let chi_ion_max = transport.chiIon.value.max().item(Float.self)
        let chi_electron_max = transport.chiElectron.value.max().item(Float.self)
        let D_particle_max = transport.particleDiffusivity.value.max().item(Float.self)

        // CFL = (χ * dt) / dr²
        let dr_squared = dr * dr

        let cfl_ion = (chi_ion_max * dt) / dr_squared
        let cfl_electron = (chi_electron_max * dt) / dr_squared
        let cfl_particle = (D_particle_max * dt) / dr_squared

        return CFLMetrics(
            cfl_ion: cfl_ion,
            cfl_electron: cfl_electron,
            cfl_particle: cfl_particle
        )
    }

    /// Recommend optimal timestep based on target CFL
    ///
    /// - Parameters:
    ///   - transport: Transport coefficients
    ///   - dr: Grid spacing [m]
    ///   - targetCFL: Target CFL number (default: 0.5)
    /// - Returns: Recommended timestep [s]
    public static func recommendTimestep(
        transport: TransportCoefficients,
        dr: Float,
        targetCFL: Float = 0.5
    ) -> Float {

        // Find maximum diffusivity
        let chi_ion_max = transport.chiIon.value.max().item(Float.self)
        let chi_electron_max = transport.chiElectron.value.max().item(Float.self)
        let D_particle_max = transport.particleDiffusivity.value.max().item(Float.self)

        let chi_max = max(chi_ion_max, chi_electron_max, D_particle_max)

        // dt = (CFL * dr²) / χ
        let dr_squared = dr * dr
        let dt_recommended = (targetCFL * dr_squared) / (chi_max + 1e-20)

        return dt_recommended
    }
}
```

#### 3. NumericalDiagnostics拡張

```swift
// Sources/Gotenx/Solver/NumericalDiagnostics.swift

public struct NumericalDiagnostics: Sendable, Codable, Equatable {
    // 既存フィールド（変更なし）
    public let residual_norm: Float
    public let newton_iterations: Int
    // ...

    // Phase 3
    public let cfl_number: Float  // ← 単一の値（Phase 3）

    // Phase 4: 詳細CFL metrics（オプショナル）
    /// Detailed CFL stability metrics
    ///
    /// **Phase 3**: Always nil (only single cfl_number)
    /// **Phase 4**: Populated with component breakdown
    public let cfl_metrics: CFLMetrics?

    public init(
        residual_norm: Float,
        newton_iterations: Int,
        // ... 既存パラメータ
        cfl_number: Float,
        cfl_metrics: CFLMetrics? = nil  // ← Phase 4追加
    ) {
        self.residual_norm = residual_norm
        self.newton_iterations = newton_iterations
        // ...
        self.cfl_number = cfl_number
        self.cfl_metrics = cfl_metrics
    }
}
```

#### 4. SimulationOrchestrator統合

```swift
// Sources/Gotenx/Orchestration/SimulationOrchestrator.swift

private func updateStateWithDiagnostics(stepWallTime: Float) {
    var derived: DerivedQuantities? = nil
    var diagnostics: NumericalDiagnostics? = nil

    // ...

    // Phase 4: Compute CFL number
    if samplingConfig.enableDiagnostics, let solverResult = lastSolverResult {
        var cflNumber: Float = 0
        var cflMetrics: CFLMetrics? = nil

        if let transport = state.transport {
            let metrics = CFLComputer.compute(
                transport: transport,
                dt: state.dt,
                dr: staticParams.mesh.dr
            )
            cflNumber = metrics.cfl_max
            cflMetrics = metrics

            // Warning if approaching instability
            if metrics.warningLevel > 0 {
                checkCFLStability(metrics)
            }
        }

        diagnostics = NumericalDiagnosticsCollector.collectWithConservation(
            from: solverResult,
            dt: state.dt,
            wallTime: stepWallTime,
            cflNumber: cflNumber,
            cflMetrics: cflMetrics,  // ← Phase 4追加
            currentProfiles: state.profiles,
            initialProfiles: initialState?.profiles,
            geometry: geometry
        )
    }

    // ...
}

/// Monitor CFL stability and emit warnings
private func checkCFLStability(_ metrics: CFLMetrics) {
    switch metrics.warningLevel {
    case 1:
        // Warning: Approaching stability limit
        if state.step % 1000 == 0 {
            print("[Warning] CFL approaching limit at step \(state.step):")
            print("  CFL_max = \(metrics.cfl_max) (limit: 1.0)")
            print("  Limiting coefficient: \(metrics.limiting_coefficient)")
        }

    case 2:
        // Critical: Exceeded stability limit
        print("[CRITICAL] CFL exceeded stability limit at step \(state.step):")
        print("  CFL_max = \(metrics.cfl_max) (limit: 1.0)")
        print("  CFL_ion = \(metrics.cfl_ion)")
        print("  CFL_electron = \(metrics.cfl_electron)")
        print("  CFL_particle = \(metrics.cfl_particle)")
        print("  Recommendation: Reduce timestep to \(state.dt * 0.5)s")

    default:
        break
    }
}
```

---

### テスト戦略

```swift
// Tests/GotenxTests/Diagnostics/CFLComputerTests.swift

@Test("CFL computation with typical transport coefficients")
func testCFLComputation() {
    let nCells = 100
    let chi_ion: Float = 1.0  // [m²/s]
    let chi_electron: Float = 2.0  // [m²/s]
    let D_particle: Float = 0.5  // [m²/s]

    let transport = TransportCoefficients(
        chiIon: EvaluatedArray.constant(chi_ion, shape: [nCells]),
        chiElectron: EvaluatedArray.constant(chi_electron, shape: [nCells]),
        particleDiffusivity: EvaluatedArray.constant(D_particle, shape: [nCells]),
        convectionVelocity: EvaluatedArray.zeros([nCells])
    )

    let dt: Float = 1e-4  // [s]
    let dr: Float = 0.02  // [m]

    let metrics = CFLComputer.compute(
        transport: transport,
        dt: dt,
        dr: dr
    )

    // Expected: CFL = (2.0 * 1e-4) / (0.02²) = 0.5
    #expect(abs(metrics.cfl_electron - 0.5) < 1e-6)

    // Maximum should be electron (chi_electron = 2.0)
    #expect(metrics.cfl_max == metrics.cfl_electron)
    #expect(metrics.limiting_coefficient == "chi_electron")

    // Should be stable
    #expect(metrics.isStable == true)
    #expect(metrics.warningLevel == 0)
}

@Test("CFL warning thresholds")
func testCFLWarningLevels() {
    let nCells = 100
    let transport = TransportCoefficients(
        chiIon: EvaluatedArray.constant(10.0, shape: [nCells]),
        chiElectron: EvaluatedArray.constant(10.0, shape: [nCells]),
        particleDiffusivity: EvaluatedArray.constant(10.0, shape: [nCells]),
        convectionVelocity: EvaluatedArray.zeros([nCells])
    )

    let dr: Float = 0.02

    // Safe: CFL = 0.2
    let dt_safe = (0.2 * dr * dr) / 10.0
    let metrics_safe = CFLComputer.compute(transport: transport, dt: dt_safe, dr: dr)
    #expect(metrics_safe.warningLevel == 0)

    // Warning: CFL = 0.7
    let dt_warn = (0.7 * dr * dr) / 10.0
    let metrics_warn = CFLComputer.compute(transport: transport, dt: dt_warn, dr: dr)
    #expect(metrics_warn.warningLevel == 1)

    // Critical: CFL = 1.5
    let dt_crit = (1.5 * dr * dr) / 10.0
    let metrics_crit = CFLComputer.compute(transport: transport, dt: dt_crit, dr: dr)
    #expect(metrics_crit.warningLevel == 2)
    #expect(metrics_crit.isStable == false)
}

@Test("Timestep recommendation")
func testTimestepRecommendation() {
    let nCells = 100
    let chi_max: Float = 5.0  // [m²/s]
    let transport = TransportCoefficients(
        chiIon: EvaluatedArray.constant(chi_max, shape: [nCells]),
        chiElectron: EvaluatedArray.constant(chi_max, shape: [nCells]),
        particleDiffusivity: EvaluatedArray.constant(1.0, shape: [nCells]),
        convectionVelocity: EvaluatedArray.zeros([nCells])
    )

    let dr: Float = 0.02
    let targetCFL: Float = 0.5

    let dt_recommended = CFLComputer.recommendTimestep(
        transport: transport,
        dr: dr,
        targetCFL: targetCFL
    )

    // Expected: dt = (0.5 * 0.02²) / 5.0 = 4e-5
    let dt_expected = (targetCFL * dr * dr) / chi_max
    #expect(abs(dt_recommended - dt_expected) < 1e-10)

    // Verify it actually gives target CFL
    let metrics = CFLComputer.compute(
        transport: transport,
        dt: dt_recommended,
        dr: dr
    )
    #expect(abs(metrics.cfl_max - targetCFL) < 1e-6)
}
```

---

## Phase 4実装計画

### 優先度と依存関係

```
Priority 0 (基盤):
  ├─ SourceCategory列挙型
  ├─ SourceMetadata構造体
  └─ 後方互換性テスト

Priority 1 (Power Balance):
  ├─ PowerBalance構造体
  ├─ PowerBalanceComputer
  ├─ SourceTerms拡張
  ├─ 既存モデル更新（Fusion, Ohmic, Brem）
  └─ DerivedQuantities統合

Priority 2 (Current Density):
  ├─ CurrentMetrics拡張
  ├─ CurrentDensityIntegrator
  ├─ Safety factor計算
  └─ DerivedQuantities統合

Priority 3 (CFL):
  ├─ CFLMetrics構造体
  ├─ CFLComputer
  ├─ NumericalDiagnostics拡張
  └─ SimulationOrchestrator統合

Priority 4 (検証):
  ├─ 統合テスト
  ├─ ベンチマークテスト
  └─ ドキュメント更新
```

### マイルストーン

| フェーズ | 内容 | 期間 | 成果物 |
|---------|------|------|--------|
| **4.0** | 基盤実装 | 1日 | SourceCategory, SourceMetadata, 後方互換性確保 |
| **4.1** | Power Balance | 2日 | PowerBalance, PowerBalanceComputer, 既存モデル更新 |
| **4.2** | Current Density | 2日 | CurrentMetrics, CurrentDensityIntegrator, q profile |
| **4.3** | CFL Number | 1日 | CFLMetrics, CFLComputer, 警告システム |
| **4.4** | 統合・検証 | 1日 | 統合テスト, ベンチマーク, ドキュメント |

**合計**: 7日（1週間）

---

## 後方互換性保証

### 設計原則

1. **オプショナルフィールド**: 全ての新フィールドはnil許容
2. **デフォルト実装**: プロトコル拡張でデフォルト動作提供
3. **フォールバック**: 新機能未対応でもPhase 3動作維持
4. **段階的移行**: 既存コードを段階的に更新可能

### 互換性マトリクス

| コンポーネント | Phase 3（既存） | Phase 4（拡張後） | 互換性 |
|--------------|----------------|------------------|--------|
| SourceTerms | metadata = nil | metadata有り | ✅ 完全互換 |
| PowerBalance | 推定値 | 実測値 | ✅ 改善のみ |
| CurrentMetrics | 幾何推定 | 実測値 | ✅ 改善のみ |
| NumericalDiagnostics | cfl_number=0 | cfl_metrics有り | ✅ 完全互換 |

---

## まとめ

Phase 4では、Phase 3で残された3つのTODO項目を完全に実装します。

**主要な改善点**:
1. ✅ **Power Balance**: 推定→実測（個別ソーストラッキング）
2. ✅ **Current Density**: 幾何推定→プロファイル積分
3. ✅ **CFL Number**: 0固定→動的計算＋警告

**設計の特徴**:
- 後方互換性100%維持
- GPU最適化を継続
- 段階的マイグレーション可能
- 包括的テストカバレッジ

**期待される効果**:
- 物理的精度の大幅向上
- 数値安定性の可視化
- MHD解析への対応
- 融合性能評価の信頼性向上

これにより、swift-Gotenxは研究グレードの精度と信頼性を獲得します。
