# Physics Validation Issues and Recommendations

このドキュメントは、swift-Gotenx実装における物理的妥当性の問題点と推奨される対処方法をまとめたものです。

**作成日**: 2025-10-18
**最終更新**: 2025-10-18
**ステータス**: レビュー待ち（実装前）

**参照文書**: UNIT_SYSTEM_UNIFIED.md (eV/m⁻³への単位統一が完了済み)

---

## 優先度分類

- 🔴 **Critical**: 物理的に誤った結果を生む可能性が高い
- 🟡 **High**: 特定条件下で問題になる
- 🟢 **Medium**: ドキュメント化と将来対応

---

## 🔴 Issue 1: ソース項の単位変換が未実装

### 現状認識

**単位系は既に統一済み**:
- UNIT_SYSTEM_UNIFIED.md (2025-01-18) により **eV/m⁻³** への統一が完了
- CoreProfiles.swift:13-18 で温度は明確に **[eV]** と宣言
- 電子密度は **[m⁻³]** と宣言

**問題箇所**: ソース項の単位が温度方程式の要求と不整合

### 温度方程式の次元解析

**Block1DCoeffsBuilder.swift:10-11の方程式**:
```
Ion temperature: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
```

**左辺の次元**:
```
[n_e ∂T_i/∂t] = [m⁻³] × [eV/s] = [eV/(m³·s)]
```

**拡散項の次元**:
```
[∇·(n_e χ_i ∇T_i)] = ∇·([m⁻³] × [m²/s] × [eV/m])
                    = ∇·([eV·m/s])
                    = [eV/(m³·s)]  ✅ 正しい
```

**現在のソース項の単位** (SourceTerms.swift:8-12):
```swift
/// Ion heating [MW/m^3]
public let ionHeating: EvaluatedArray
```

**問題**: 温度方程式は **[eV/(m³·s)]** を要求するが、ソース項は **[MW/m³]**

### 単位変換の必要性

**エネルギー単位変換**:
```
1 MW/m³ = 10⁶ W/m³
        = 10⁶ J/(m³·s)
        = 10⁶ J/(m³·s) × (1 eV / 1.602176634×10⁻¹⁹ J)
        = 6.2415090744×10²⁴ eV/(m³·s)
```

**つまり**:
```swift
// SourceTerms.swift の値は [MW/m³]
let Q_MW = sources.ionHeating.value  // [MW/m³]

// Block1DCoeffsBuilder.swift で使う際、変換が必要:
let Q_eV_per_m3s = Q_MW * 6.2415090744e24  // [eV/(m³·s)]
```

### 推奨される対処

#### Option A: PhysicsConstants に変換係数を追加（推奨）

**Sources/GotenxPhysics/PhysicsConstants.swift に追加**:
```swift
// MARK: - Power Density Conversions

/// Megawatts per cubic meter to eV per cubic meter per second
/// 1 MW/m³ = 10⁶ W/m³ = 10⁶ J/(m³·s) = 6.2415090744×10²⁴ eV/(m³·s)
public static let megawattsPerCubicMeterToEvPerCubicMeterPerSecond: Float = 6.2415090744e24

/// Convert power density from MW/m³ to eV/(m³·s)
public static func megawattsToEvDensity(_ megawatts: Float) -> Float {
    return megawatts * megawattsPerCubicMeterToEvPerCubicMeterPerSecond
}

/// Convert power density from MW/m³ to eV/(m³·s) (array version)
public static func megawattsToEvDensity(_ megawatts: MLXArray) -> MLXArray {
    return megawatts * megawattsPerCubicMeterToEvPerCubicMeterPerSecond
}
```

**Block1DCoeffsBuilder.swift の修正**:
```swift
// Before (line 124)
let sourceCell = sources.ionHeating.value  // [MW/m³]

// After
let sourceCell = PhysicsConstants.megawattsToEvDensity(sources.ionHeating.value)  // [eV/(m³·s)]
```

同様の変更を:
- `buildElectronEquationCoeffs` (line 176)

#### Option B: SourceTerms の単位を変更（破壊的変更）

**非推奨**:
- FusionPower.swift など既存コードが MW/m³ で出力
- プラズマ物理コミュニティでは加熱パワーは MW/m³ が標準
- 変換は使用箇所（Block1DCoeffsBuilder）で行う方が明確

### 検証方法

**単体テスト追加**:
```swift
// Tests/GotenxTests/Solver/Block1DCoeffsBuilderTests.swift に追加

@Test("Source term unit conversion is correct")
func testSourceTermUnitConversion() throws {
    // Setup: Q = 1 MW/m³
    let Q_MW: Float = 1.0  // [MW/m³]

    // Expected: Q = 6.2415090744e24 eV/(m³·s)
    let Q_eV = PhysicsConstants.megawattsToEvDensity(Q_MW)

    let expected: Float = 6.2415090744e24
    let relativeError = abs(Q_eV - expected) / expected

    #expect(relativeError < 1e-6, "Power density unit conversion error")
}

@Test("Temperature equation dimensional consistency")
func testTemperatureEquationDimensions() throws {
    // Setup typical plasma parameters
    let ne: Float = 1e20      // [m⁻³]
    let chi: Float = 1.0      // [m²/s]
    let gradT: Float = 1000.0 // [eV/m]
    let Q_MW: Float = 0.5     // [MW/m³]

    // Diffusion term: ∇·(n_e χ ∇T) [eV/(m³·s)]
    // Approximation: n_e χ gradT / dr
    let dr: Float = 0.08  // [m] typical cell size
    let diffusionTerm = ne * chi * gradT / dr  // [m⁻³ × m²/s × eV/m × 1/m] = [eV/(m³·s)]

    // Source term: Q [eV/(m³·s)]
    let sourceTerm = PhysicsConstants.megawattsToEvDensity(Q_MW)

    // Both terms must have same dimension [eV/(m³·s)]
    // Check that they are comparable in magnitude
    let ratio = sourceTerm / diffusionTerm

    // For typical ITER: ratio should be O(1) to O(10)
    #expect(ratio > 0.1 && ratio < 100,
            "Source and diffusion terms have inconsistent magnitude (ratio = \(ratio))")
}
```

---

## 🟡 Issue 2: 密度フロア値の物理的妥当性

### 現状認識

**密度フロアは既に実装済み**:

1. **Block1DCoeffsBuilder.swift:112, 164**:
   ```swift
   let ne_floor: Float = 1e18  // [m⁻³]
   let ne_cell = maximum(profiles.electronDensity.value, MLXArray(ne_floor))
   ```

2. **LinearSolver.swift:350**:
   ```swift
   let safetyFloor: Float = 1e18  // [m⁻³]
   return rhs / maximum(transientCoeff, MLXArray(safetyFloor))
   ```

**問題**: フロア値 **1e18 m⁻³** の物理的妥当性を検証する必要がある

### 物理的妥当性の検証

#### 1. Debye長の制約

Debye長:
```
λ_D = 7.43 × 10³ √(T_e[eV] / n_e[m⁻³]) [m]
```

**n_e = 1e18 m⁻³, T_e = 100 eV (edge温度)の場合**:
```
λ_D = 7.43 × 10³ √(100 / 1e18) = 7.43 × 10⁻⁵ m = 74.3 μm
```

**セルサイズとの比較**:
- ITER小半径: a = 2.0 m
- セル数: 25
- セルサイズ: dr ≈ 0.08 m = 80 mm
- λ_D / dr = 74.3 μm / 80 mm ≈ **0.001**

**判定**: ✅ プラズマ近似は成立 (λ_D << dr)

#### 2. 衝突周波数の妥当性

**IonElectronExchange.swift:76**での計算:
```
ν_ei = 2.91 × 10⁻⁶ * n_e * Z_eff * ln(Λ) / T_e^(3/2)
```

**n_e = 1e18 m⁻³, T_e = 100 eV, Z_eff = 1.5の場合**:
```
ln(Λ) ≈ 15 (Coulomb対数)
ν_ei = 2.91 × 10⁻⁶ × 1e18 × 1.5 × 15 / 100^1.5
     ≈ 6.6 × 10³ Hz
```

**通常のトカマク中心部 (n_e = 1e20 m⁻³, T_e = 10 keV)の場合**:
```
ν_ei ≈ 2 × 10⁵ Hz
```

**問題点**:
- フロア密度での衝突周波数は中心部の **1/30**
- Ion-Electron熱交換が極端に遅くなる
- 非現実的な緩和時間: τ_exchange = 1/ν_ei ≈ 150 μs (中心部は5 μs)

#### 3. SOL密度との比較

**典型的なSOL (Scrape-Off Layer) 密度**:
- ITER separatrixでの密度: **5 × 10¹⁸ - 1 × 10¹⁹ m⁻³**
- SOL内の密度: 1 × 10¹⁸ - 5 × 10¹⁸ m⁻³

フロア値 1e18 m⁻³は**SOLの下限**に相当します。

### 推奨される対処

#### 推奨: 密度フロアを1e19 m⁻³に引き上げ

**変更箇所**:

1. **Block1DCoeffsBuilder.swift**:
   ```swift
   // Before (line 112)
   let ne_floor: Float = 1e18  // [m⁻³]

   // After
   let ne_floor: Float = 1e19  // [m⁻³] - 物理的下限（SOL separatrix付近）
   ```
   同じ変更を line 164 にも適用

2. **LinearSolver.swift**:
   ```swift
   // Before (line 350)
   let safetyFloor: Float = 1e18  // [m⁻³]

   // After
   let safetyFloor: Float = 1e19  // [m⁻³]
   ```

3. **IMPLEMENTATION_NOTES.md の更新** (Section 3, line 131-151):
   ```markdown
   ### Recommended Action
   ✅ **Implemented** (2025-10-18) - Density floor updated:

   **Implementation locations**:
   1. **Block1DCoeffsBuilder.swift** (lines ~113, ~165):
   ```swift
   // In buildIonEquationCoeffs / buildElectronEquationCoeffs
   let ne_floor: Float = 1e19  // [m⁻³] - Updated from 1e18
   let ne_cell = maximum(profiles.electronDensity.value, MLXArray(ne_floor))
   ```

   2. **LinearSolver.swift** (line ~351):
   ```swift
   // In applyOperatorToVariable
   let safetyFloor: Float = 1e19  // [m⁻³] - Updated from 1e18
   return rhs / maximum(transientCoeff, MLXArray(safetyFloor))
   ```

   **Rationale**: Density floor at 1e19 m⁻³ ensures physically meaningful collision physics:
   - Typical ITER separatrix density: 5-10 × 10¹⁸ m⁻³
   - Collision frequency ν_ei > 10⁴ Hz (physically meaningful)
   - 10× safety margin below typical core density (1e20 m⁻³)
   - Ensures λ_D / dr < 0.001 (plasma approximation valid)
   ```

**影響範囲の検証**:

現在のP0テスト設定:
```swift
// P0IntegrationTest.swift:106
let ne = n0 * (1.0 - 0.9 * rho * rho)  // n0 = 1e20
```

最小密度（edge, rho=1）:
```
ne_min = 1e20 × (1 - 0.9) = 1e19 m⁻³
```

**結論**: ✅ P0設定はフロア変更の影響を受けない（ちょうど境界値）

### 検証方法

**Block1DCoeffsBuilderTests.swift に既存のテストがある**:
- `testDensityFloor()` (line 112-186): フロア値の適用を検証
- `testNormalDensityUnchanged()` (line 189-264): 通常密度への影響なしを検証

**必要な更新**:
```swift
// Tests/GotenxTests/Solver/Block1DCoeffsBuilderTests.swift:176
// Update expected floor value
let densityFloor: Float = 1e19  // Updated from 1e18
```

---

## 🟢 Issue 3: 非保存形の系統的エネルギー誤差（文書化済み）

### 現状認識

**既にドキュメント化されている**:

IMPLEMENTATION_NOTES.md Section 5 (line 202-249) に詳細な説明あり:
- 非保存形を採用していることを明記
- Python TORAX との互換性のための意図的選択
- トレードオフを文書化

### 物理的影響の整理

**現在の実装** (Block1DCoeffsBuilder.swift:10-11):
```
Ion temperature: n_e ∂T_i/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
```

**物理的に正しい保存形**:
```
∂(n_e T_i)/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
展開: n_e ∂T_i/∂t + T_i ∂n_e/∂t = ∇·(n_e χ_i ∇T_i) + Q_i
```

**欠落している項**:
```
T_i × ∂n_e/∂t
```

### 定量的影響の評価

#### ケース1: P0設定（evolveDensity = false）

**StaticRuntimeParams**:
```swift
evolveDensity: false  // P0: fix density
```

この場合:
```
∂n_e/∂t = 0  （厳密）
```

**結論**: ✅ **誤差ゼロ**（非保存形と保存形が一致）

#### ケース2: 密度時間発展シナリオ

**典型的なパラメータ**:
- 粒子閉じ込め時間: τ_p ~ 1 s
- 密度変化率: ∂n_e/∂t ~ n_e / τ_p ~ 10²⁰ / 1 = 10²⁰ m⁻³/s
- イオン温度: T_i ~ 10 keV = 10⁴ eV

**欠落項の大きさ**:
```
T_i × ∂n_e/∂t = 10⁴ eV × 10²⁰ m⁻³/s
                = 10²⁴ eV/(m³·s)
                = 1.6 × 10⁵ W/m³
                = 0.16 MW/m³
```

**主要な加熱項との比較**:
```
Q_fusion ~ 1-10 MW/m³ (ITER)
Q_ie ~ 0.1-1 MW/m³ (ion-electron exchange)
```

**相対誤差**:
```
欠落項 / 主要項 ~ 0.16 / 1 ~ 10-20%
```

### IMPLEMENTATION_NOTES.md の記述レビュー

**現在の記述 (Section 5, line 219-233) は適切**:
```markdown
**Non-conservation form** (current):
- ✅ Simpler implementation
- ✅ Matches Python TORAX exactly
- ✅ Adequate for slow density evolution
- ❌ May have energy conservation errors when density changes rapidly (pellets, gas puff)

**Conservation form**:
- ✅ Better energy conservation
- ✅ Handles rapid density changes correctly
- ❌ More complex implementation (requires ∂n_e/∂t term)
- ❌ Harder to validate against Python TORAX
```

### 推奨される対処

#### 当面の対応: 文書化の強化（推奨）

**IMPLEMENTATION_NOTES.md Section 5 に定量的評価を追加**:

```markdown
### Quantitative Error Analysis

| Scenario | ∂n_e/∂t [m⁻³/s] | T [eV] | Missing Term [MW/m³] | Relative Error |
|----------|-----------------|--------|----------------------|----------------|
| **P0 (fixed density)** | 0 | 10⁴ | 0 | **0%** ✅ |
| **Steady-state diffusion** | 10²⁰ | 10⁴ | 0.16 | **~10-20%** ⚠️ |
| **Pellet injection** | 10²¹ | 10⁴ | 1.6 | **~50-100%** ❌ |
| **Gas puff** | 5×10²⁰ | 10⁴ | 0.8 | **~30-50%** ❌ |

### Current Status (SI Units)
**P0 configuration** (fixed density):
- Non-conservation form is **exact** since `∂n_e/∂t = 0`
- Density: `n_e ~ 1e20 m⁻³` (realistic SI value)
- No rapid density changes, so conservation errors are negligible

**Future density evolution scenarios**:
- Pellet injection, gas puff: Rapid `∂n_e/∂t` → 10-100% energy error expected
- Edge density variations: Need to validate energy conservation
- **Recommendation**: Implement conservation form when enabling density evolution
```

**StaticRuntimeParams.swift にバリデーション追加** (オプション):
```swift
public func validate() throws {
    // Warn if evolving both density and temperature (non-conservation form issue)
    if evolveDensity && (evolveIonHeat || evolveElectronHeat) {
        // Log warning (not error - allow execution)
        print("""
            WARNING: Non-conservation form with density evolution

            Current implementation neglects T × ∂n_e/∂t term.
            Expect 10-100% energy conservation error during rapid density changes.

            For accurate density evolution scenarios, conservation form is recommended.
            """)
    }
}
```

#### 将来の対応: 保存形への移行（密度時間発展実装時）

**タイミング**: 密度時間発展（evolveDensity = true）を実装する際に同時実施

**実装方針**: IMPLEMENTATION_NOTES.md Section 5 に既に記載済み

---

## 検証計画

### Phase 1: ソース項単位変換（最優先、即座）

**目的**: 温度方程式の次元を物理的に正しくする

1. 🔲 **レビュー**: このドキュメントの承認
2. 🔲 **PhysicsConstants.swift に変換関数追加**
3. 🔲 **Block1DCoeffsBuilder.swift でソース項を変換**
4. 🔲 **単体テスト作成**: 次元一貫性チェック
5. 🔲 **P0IntegrationTest 実行**: 既存テストが通ることを確認

**期待される効果**:
- 温度方程式の全項が [eV/(m³·s)] に統一
- 加熱パワーの効果が物理的に正しく反映される

### Phase 2: 密度フロア値調整（Phase 1完了後）

**目的**: 衝突物理の妥当性を確保

1. 🔲 **フロア値変更**: 1e18 → 1e19 m⁻³
   - Block1DCoeffsBuilder.swift (lines 112, 164)
   - LinearSolver.swift (line 350)
2. 🔲 **テスト更新**: Block1DCoeffsBuilderTests.swift:176
3. 🔲 **P0IntegrationTest 実行**: 影響なしを確認
4. 🔲 **IMPLEMENTATION_NOTES.md 更新**: Section 3

**期待される効果**:
- 衝突周波数が物理的に意味のある範囲（> 10⁴ Hz）に維持
- SOL separatrix 付近の密度と整合

### Phase 3: 非保存形の文書強化（Phase 2完了後）

**目的**: 既知の制限事項を明確化

1. 🔲 **IMPLEMENTATION_NOTES.md Section 5 に定量的評価追加**
2. 🔲 **README.md に制限事項を明記**
3. 🔲 **StaticRuntimeParams.validate() に警告追加** (オプション)

**期待される効果**:
- 密度時間発展シナリオでの誤差を事前に理解
- 将来の保存形実装への明確な道筋

---

## 依存関係

```
Phase 1 (ソース項変換) ← 最優先、他に依存しない
    ↓
Phase 2 (密度フロア) ← Phase 1完了後（単位系が確定しているため）
    ↓
Phase 3 (文書化) ← Phase 2完了後（実装が安定してから）
```

---

## レビューポイント

このドキュメントをレビューする際、以下の点を確認してください:

### 1. ソース項単位変換
- [ ] MW/m³ → eV/(m³·s) 変換係数 (6.2415090744e24) は正しいか？
- [ ] PhysicsConstants に変換関数を追加する方針で良いか？
- [ ] Block1DCoeffsBuilder での変換位置は適切か？

### 2. 密度フロアの値
- [ ] 1e19 m⁻³への引き上げに同意するか？
- [ ] 物理的根拠（衝突周波数、SOL密度）は妥当か？
- [ ] P0テストへの影響評価は正しいか？

### 3. 非保存形の扱い
- [ ] 当面はドキュメント化のみで良いか？
- [ ] 定量的誤差評価（10-100%）は妥当か？
- [ ] 密度時間発展実装時に保存形へ移行する方針で良いか？

### 4. 優先順位
- [ ] Phase 1（ソース項）を最優先とする判断は適切か？
- [ ] Phase 1 → 2 → 3の順序は適切か？

---

## 修正履歴

### 2025-10-18 (初版)
- Issue 1-3 を特定

### 2025-10-18 (第2版)
**ユーザーレビューに基づく全面改訂**:

**Issue 1 修正**:
- ❌ 削除: 「温度単位が不明瞭」という誤った認識
- ❌ 削除: 拡散係数に `PhysicsConstants.eV` を掛ける提案（次元を壊す）
- ✅ 追加: ソース項の単位変換 MW/m³ → eV/(m³·s) が真の問題
- ✅ 追加: 正しい次元解析による根拠

**Issue 2 修正**:
- ❌ 削除: 「密度フロアを導入する」という表現（既に実装済み）
- ✅ 修正: 「密度フロア値を調整する」（1e18 → 1e19）
- ✅ 明確化: 既存実装の行番号を具体的に記載

**参照文書修正**:
- ❌ 削除: UNIT_SYSTEM_COMPLETE.md への言及（存在しない文書）
- ✅ 追加: UNIT_SYSTEM_UNIFIED.md への正しい参照

**認識の訂正**:
- 温度単位は **既に eV で統一済み** (CoreProfiles.swift:13-18)
- 単位系統一は **完了済み** (UNIT_SYSTEM_UNIFIED.md)
- 密度フロアは **既に実装済み** (Block1DCoeffsBuilder.swift:112, 164)

---

## 次のステップ

1. **このドキュメント（第2版）のレビュー**
2. **方針決定** (特にソース項変換の実装方法)
3. **Phase 1の実装承認**: ソース項の単位変換
4. **Phase 2以降**: レビュー結果に基づき順次実施

**重要**: このドキュメント承認後、Phase 1から順に実装を進めます。各Phaseの実装前に再度確認を行います。
