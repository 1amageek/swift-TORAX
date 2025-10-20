# Phase 3実装の現実：理想と現実のギャップ分析

## エグゼクティブサマリー

**Phase 4設計書の問題点**: 理想的な将来像を描いたが、現在の実装との乖離が大きすぎる。

**本ドキュメントの目的**:
1. Phase 3で**実際に実装されたもの**を正確に記録
2. Phase 4設計書で**想定したが未実装のもの**を明確化
3. 実行可能な**段階的移行計画**を提示

---

## 1. Phase 3実装の現実

### 1.1 Power Balance: 実装されているもの

#### ✅ 実装済み

```swift
// DerivedQuantitiesComputer.swift:259-301
private static func computePowerBalance(
    sources: SourceTerms?,
    profiles: CoreProfiles,
    geometry: Geometry,
    volumes: MLXArray
) -> (P_fusion: Float, P_alpha: Float, P_auxiliary: Float, P_ohmic: Float) {

    guard let sources = sources else {
        return (0, 0, 0, 0)
    }

    // ✅ 実装: 総加熱パワーの積分
    let ionHeating = sources.ionHeating.value
    let electronHeating = sources.electronHeating.value
    let totalHeating = ((ionHeating + electronHeating) * volumes).sum()
    eval(totalHeating)
    let P_total = totalHeating.item(Float.self)

    // ✅ 実装: 推定比率による分離
    let electronFraction = (electronHeating * volumes).sum() / (totalHeating + 1e-10)
    eval(electronFraction)
    let frac = electronFraction.item(Float.self)

    // ⚠️ 推定値（固定比率）
    let P_fusion = P_total * frac * 0.5      // 50%を融合と推定
    let P_alpha = P_fusion * 0.2             // 20%をアルファと推定
    let P_ohmic = P_total * 0.1              // 10%をオーミックと推定
    let P_auxiliary = P_total - P_fusion - P_ohmic  // 残りを補助加熱

    return (max(0, P_fusion), max(0, P_alpha), max(0, P_auxiliary), max(0, P_ohmic))
}
```

**特徴**:
- ✅ GPU上で効率的に体積積分
- ✅ イオン/電子加熱の区別
- ⚠️ 個別ソースは区別しない（全て合算）
- ⚠️ 固定比率（50%, 20%, 10%）で推定

#### ❌ 未実装

```swift
// Phase 4で想定したが存在しないもの

// 1. SourceMetadata - 個別ソース貢献のトラッキング
struct SourceMetadata {  // ← 存在しない
    let category: SourceCategory
    let P_ion: Float
    let P_electron: Float
}

// 2. SourceTerms拡張
public struct SourceTerms {
    // ...
    public let sourceMetadata: [SourceMetadata]?  // ← 存在しない
}

// 3. PowerBalanceComputer
enum PowerBalanceComputer {  // ← 存在しない
    static func compute(sources: SourceTerms?) -> PowerBalance
}
```

**現実**:
- ❌ 個別ソースモデルの寄与を区別する機構なし
- ❌ FusionPower、OhmicHeating、Bremsstrahlungは別々に計算されるが、合算後は区別不可
- ❌ SourceModelにcategoryプロパティなし

---

### 1.2 Current Density: 実装されているもの

#### ✅ 実装済み

```swift
// DerivedQuantitiesComputer.swift:434-460
private static func computeCurrentMetrics(
    profiles: CoreProfiles,
    geometry: Geometry,
    transport: TransportCoefficients?
) -> (I_plasma: Float, I_bootstrap: Float, f_bootstrap: Float) {

    // ✅ 実装: 幾何学的推定
    let a = geometry.minorRadius
    let R0 = geometry.majorRadius
    let Bt = geometry.toroidalField
    let q_edge: Float = 3.0  // ⚠️ 固定値
    let mu0: Float = 4.0 * .pi * 1e-7

    // ⚠️ 推定式（実際のj_parallelを使用せず）
    let Ip_estimate = (2.0 * .pi * a * a * Bt) / (mu0 * R0 * q_edge)

    // ⚠️ Bootstrap電流は0（未実装）
    let I_bootstrap: Float = 0.0
    let f_bootstrap: Float = 0.0

    return (Ip_estimate, I_bootstrap, f_bootstrap)
}
```

**特徴**:
- ✅ 簡易推定式で即座に計算可能
- ⚠️ q_edge=3.0固定（実際のプロファイル不使用）
- ❌ Bootstrap電流は常に0

#### ❌ 未実装

```swift
// Phase 4で想定したが存在しないもの

// 1. SourceTerms.currentSource の実際の値
// 現状: sources.currentSource は存在するが、ほとんど0
// 理由: CurrentDriveモデル（Bootstrap, ECCD）が未実装

// 2. CurrentDensityIntegrator
enum CurrentDensityIntegrator {  // ← 存在しない
    static func integrate(
        currentDensity: EvaluatedArray,
        geometry: Geometry
    ) -> CurrentMetrics
}

// 3. Safety factor計算
// 現状: geometry.safetyFactorは存在するが、j_parallelから計算されていない
```

**現実**:
- ❌ j_parallel(r)プロファイルを積分する機構なし
- ❌ SourceTerms.currentSourceはほぼ未使用（Bootstrapモデル未実装）
- ❌ Safety factorは初期化時に与えられた固定プロファイル

---

### 1.3 CFL Number: 実装されているもの

#### ✅ 実装済み

```swift
// TimeStepCalculator.swift
public struct TimeStepCalculator {
    public func compute(
        transportCoeffs: TransportCoefficients,
        dr: Float
    ) -> Float {
        // ✅ 実装: 輸送係数に基づくタイムステップ計算
        let chi_max = max(
            transportCoeffs.chiIon.value.max().item(Float.self),
            transportCoeffs.chiElectron.value.max().item(Float.self),
            transportCoeffs.particleDiffusivity.value.max().item(Float.self)
        )

        // ✅ 実装: CFL条件に基づく制限
        let dt_diffusion = stabilityFactor * dr * dr / (chi_max + 1e-20)

        return min(max(dt_diffusion, minTimestep), maxTimestep)
    }
}
```

**特徴**:
- ✅ CFL条件を**暗黙的に**使用（stabilityFactor ≈ CFL limit）
- ✅ 適応的タイムステップ計算

#### ❌ 未実装

```swift
// Phase 4で想定したが存在しないもの

// 1. CFL数の明示的計算と報告
// 現状: タイムステップは計算されるが、CFL数自体は記録されない

// 2. CFLComputer
enum CFLComputer {  // ← 存在しない
    static func compute(
        transport: TransportCoefficients,
        dt: Float,
        dr: Float
    ) -> CFLMetrics
}

// 3. NumericalDiagnostics.cfl_number
// 現状: フィールドは存在するが常に0
diagnostics = NumericalDiagnosticsCollector.collect(
    from: solverResult,
    dt: state.dt,
    wallTime: stepWallTime,
    cflNumber: 0  // ← 常に0
)
```

**現実**:
- ✅ CFL条件は**実装されている**（TimeStepCalculator内部）
- ❌ CFL数の**可視化・記録**がない
- ❌ CFL数による**警告システム**がない

---

## 2. Phase 4設計書との乖離

### 2.1 Power Balance

| 項目 | Phase 3現実 | Phase 4設計 | ギャップ |
|------|-------------|-------------|----------|
| **総加熱パワー** | ✅ 実装済み | ✅ 同じ | なし |
| **成分分離** | ⚠️ 固定比率推定 | ✅ 実測値 | **大** |
| **SourceMetadata** | ❌ 不在 | ✅ 実装想定 | **大** |
| **個別ソース区別** | ❌ 不可 | ✅ 可能 | **大** |
| **PowerBalanceComputer** | ❌ 不在 | ✅ 実装想定 | **中** |

**実装難易度**: 🔴 高（アーキテクチャ変更必要）

**理由**:
- SourceModel全体にcategoryプロパティ追加が必要
- 各SourceModelでメタデータ計算機構を実装
- SourceTermsの構造拡張（後方互換性維持が課題）

---

### 2.2 Current Density

| 項目 | Phase 3現実 | Phase 4設計 | ギャップ |
|------|-------------|-------------|----------|
| **Ip推定** | ✅ 幾何推定 | ✅ 実測積分 | **大** |
| **j_parallel積分** | ❌ 不在 | ✅ 実装想定 | **大** |
| **Bootstrap電流** | ❌ 常に0 | ✅ 計算可能 | **大** |
| **Safety factor** | ⚠️ 固定 | ✅ 動的計算 | **中** |
| **CurrentDensityIntegrator** | ❌ 不在 | ✅ 実装想定 | **中** |

**実装難易度**: 🟡 中（Bootstrap/ECCDモデル実装が前提）

**理由**:
- CurrentDensityIntegratorは比較的単純（体積積分のみ）
- しかしBootstrapModelやECCDモデルが未実装
- currentSourceが実際の値を持つ前提が必要

---

### 2.3 CFL Number

| 項目 | Phase 3現実 | Phase 4設計 | ギャップ |
|------|-------------|-------------|----------|
| **CFL条件使用** | ✅ 暗黙的 | ✅ 明示的 | **小** |
| **CFL数計算** | ❌ 不在 | ✅ 実装想定 | **小** |
| **CFL数記録** | ❌ 常に0 | ✅ 記録 | **小** |
| **警告システム** | ❌ 不在 | ✅ 実装想定 | **小** |
| **CFLComputer** | ❌ 不在 | ✅ 実装想定 | **小** |

**実装難易度**: 🟢 低（既存ロジックの可視化のみ）

**理由**:
- TimeStepCalculatorは既にCFL条件を使用
- CFLComputerは計算式を明示化するだけ
- 新規アーキテクチャ変更不要

---

## 3. オープンな論点への回答

### 論点1: SourceModelのメタデータ提供方法

**問題**: 各SourceModelがPhase 4移行時にメタデータをどう提供するか？

**提案**: 段階的プロトコル拡張

```swift
// Step 1: オプショナルプロトコル拡張（Phase 4.0）
public protocol SourceModel: Sendable {
    var name: String { get }

    func computeTerms(...) -> SourceTerms

    // Phase 4: オプショナル（デフォルト実装あり）
    var category: SourceCategory { get }
    func computeMetadata(...) -> SourceMetadata?
}

extension SourceModel {
    // デフォルト: メタデータなし（Phase 3互換）
    public var category: SourceCategory { .custom }
    public func computeMetadata(...) -> SourceMetadata? { nil }
}

// Step 2: 既存モデルを1つずつ移行
extension FusionPower {
    public var category: SourceCategory { .fusion }

    public func computeMetadata(
        heating: EvaluatedArray,
        geometry: Geometry
    ) -> SourceMetadata {
        let volumes = GeometricFactors.from(geometry: geometry).cellVolumes.value
        let P_electron = (heating.value * volumes).sum().item(Float.self)
        return SourceMetadata(
            category: .fusion,
            modelName: name,
            P_electron: P_electron
        )
    }
}

// Step 3: SimulationOrchestratorで収集
let sourceTerms = sources.reduce(...) { total, model in
    let terms = model.computeTerms(...)
    let metadata = model.computeMetadata(...)  // ← 新規
    return total + terms.with(metadata: metadata)
}
```

**利点**:
- ✅ 後方互換性100%（デフォルト実装）
- ✅ 段階的移行可能（モデルごとに）
- ✅ 型安全

**課題**:
- 各モデルで体積積分を重複実装する可能性
- メタデータ収集のオーバーヘッド（ただし軽微）

---

### 論点2: Current density積分の精度

**問題**: 幾何係数、Bootstrap、ECCDのプロファイル扱いをどこまで実装？

**段階的アプローチ**:

#### Phase 4.2a: 基本積分（1日）

```swift
// 円形幾何近似での単純積分
I_plasma = ∫ j_parallel(r) × 2πR₀ dr

// 必要なもの:
// - GeometricFactors.cellVolumes（既存）
// - SourceTerms.currentSource（既存、値は未整備）
```

#### Phase 4.2b: Bootstrap電流モデル（3日）

```swift
// Sauter-Angioni Bootstrapモデル（簡易版）
j_bootstrap ∝ ∇p × f_trapped

// 必要なもの:
// - 圧力勾配 ∇(nT)
// - Trapped particle fraction
// - Neoclassical係数
```

#### Phase 4.2c: 高精度幾何（将来）

```swift
// 真の幾何係数考慮
I_plasma = ∫∫ j_parallel × |∇ψ|⁻¹ dS
```

**推奨**: Phase 4.2aから開始（円形幾何で十分）

---

### 論点3: CFL計算の具体的定義

**問題**: 一次元（半径方向）だけで十分か？各方程式ごとに上限をとるか？

**提案**: 方程式ごとのCFL、最大値を採用

```swift
// Ion temperature equation
CFL_Ti = (χ_ion × dt) / (Δr²)

// Electron temperature equation
CFL_Te = (χ_electron × dt) / (Δr²)

// Density equation
CFL_ne = (D_particle × dt) / (Δr²)

// Overall stability
CFL_max = max(CFL_Ti, CFL_Te, CFL_ne)
```

**理由**:
1. トカマクは準1次元（半径方向支配的）
2. 各方程式の拡散係数が異なる
3. 最も不安定な方程式がボトルネック

**実装**:
- TimeStepCalculatorは既にこのロジック
- CFLComputerは可視化するだけ

---

### 論点4: 段階的ロールアウトと既存テストの互換性

**問題**: 既存テストがPhase 3の暫定ロジックを前提にしている

**戦略**: テストの段階的更新

#### Phase 4.0: 互換性テスト追加

```swift
@Test("Phase 3 fallback compatibility")
func testPhase3Fallback() {
    // sourceMetadata = nil の場合、Phase 3動作を保証
    let sources = SourceTerms(
        ionHeating: ...,
        electronHeating: ...,
        particleSource: ...,
        currentSource: ...,
        sourceMetadata: nil  // ← Phase 3互換
    )

    let derived = DerivedQuantitiesComputer.compute(
        profiles: profiles,
        geometry: geometry,
        sources: sources
    )

    // Phase 3ロジックで計算された値と一致することを確認
    #expect(derived.P_fusion > 0)  // 推定値でもOK
}
```

#### Phase 4.1+: 新機能テスト追加

```swift
@Test("Phase 4 metadata-based power balance")
func testPhase4PowerBalance() {
    // sourceMetadata ありの場合、Phase 4動作
    let metadata = [
        SourceMetadata(category: .fusion, P_electron: 50.0),
        SourceMetadata(category: .ohmic, P_electron: 10.0)
    ]

    let sources = SourceTerms(
        ionHeating: ...,
        electronHeating: ...,
        particleSource: ...,
        currentSource: ...,
        sourceMetadata: metadata  // ← Phase 4
    )

    let derived = DerivedQuantitiesComputer.compute(...)

    // 実測値が使われることを確認
    #expect(derived.P_fusion == 50.0)
    #expect(derived.P_ohmic == 10.0)
}
```

**既存テストの扱い**:
- ✅ Phase 3テストはそのまま維持（fallback動作を検証）
- ✅ Phase 4テストを追加（新機能を検証）
- ❌ Phase 3テストを削除しない

---

## 4. 修正されたPhase 4実装計画

### 実装優先度（再評価）

| Priority | 項目 | 難易度 | 期間 | 依存 | 効果 |
|----------|------|--------|------|------|------|
| **P0** | CFL数計算・可視化 | 🟢 低 | 1日 | なし | 即座に役立つ |
| **P1** | SourceMetadata基盤 | 🟡 中 | 1日 | なし | 後続の基盤 |
| **P2** | FusionPower metadata | 🟢 低 | 0.5日 | P1 | 融合パワー精度向上 |
| **P3** | OhmicHeating metadata | 🟢 低 | 0.5日 | P1 | オーミック精度向上 |
| **P4** | PowerBalanceComputer | 🟡 中 | 1日 | P1-P3 | 成分分離完成 |
| **P5** | CurrentDensityIntegrator | 🟡 中 | 1日 | Bootstrap未実装 | 精度向上（限定的） |
| **P6** | Bootstrap電流モデル | 🔴 高 | 3日 | P5 | 電流計算完成 |

**推奨ロールアウト順序**:

```
Phase 4a (2日): P0 + P1
  → CFL可視化 + SourceMetadata基盤
  → 即座に役立つ + 将来の基盤

Phase 4b (2日): P2 + P3 + P4
  → Power Balance完成
  → 融合性能評価の精度向上

Phase 4c (4日): P5 + P6
  → Current積分 + Bootstrapモデル
  → MHD解析対応（研究用途）
```

---

## 5. 結論

### Phase 3の実態

**実装されているもの**:
- ✅ GPU最適化された体積積分
- ✅ 基本的な導出量計算（中心値、平均、エネルギー）
- ✅ ITER98y2スケーリング則
- ✅ 保存則drift監視
- ✅ 適応的タイムステップ（CFL条件内包）

**実装されていないもの**:
- ❌ 個別ソース貢献のトラッキング
- ❌ 電流密度の実測積分
- ❌ CFL数の可視化
- ❌ Bootstrap電流モデル

### Phase 4設計書の問題

**問題点**:
1. 🔴 実装との乖離が大きすぎる
2. 🔴 依存関係（Bootstrap等）を考慮していない
3. 🔴 実装難易度の見積もりが甘い

**修正方針**:
1. ✅ 段階的ロールアウト（Phase 4a/b/c）
2. ✅ 後方互換性100%維持
3. ✅ 実装難易度を正確に評価

### 推奨される次のステップ

**即座に実装可能** (Phase 4a - 2日):
1. CFL数計算・可視化（難易度: 低）
2. SourceMetadata基盤（難易度: 中）

**効果が大きい** (Phase 4b - 2日):
3. Power Balance完成（FusionPower, OhmicHeating metadata追加）

**研究用途** (Phase 4c - 4日):
4. Current積分 + Bootstrapモデル

---

**Phase 3は実用レベル、Phase 4は研究グレードへの進化と位置付けるべき。**
