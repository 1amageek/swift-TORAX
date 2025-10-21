# Phase 7 Implementation Review

**Date**: 2025-10-21
**Version**: 1.0
**Status**: 🟡 実装完了、但し重大な問題あり

---

## 実装内容サマリー

| コンポーネント | 行数 | 状態 | 重大度 |
|-------------|------|------|--------|
| ActuatorTimeSeries | 200 | ✅ 実装完了 | 🔴 High |
| DifferentiableSimulation | 320 | ✅ 実装完了 | 🔴 High |
| ForwardSensitivity | 550 | ✅ 実装完了 | 🟢 OK |
| Adam Optimizer | 260 | ✅ 実装完了 | 🟡 Medium |
| ScenarioOptimizer | 450 | ✅ 実装完了 | 🟢 OK |

---

## 発見された問題

### 🔴 問題1: actuatorがsimulationに反映されていない（最重要）

**場所**: `DifferentiableSimulation.swift:272-286`

**問題**:
```swift
private func updateDynamicParams(
    _ params: DynamicRuntimeParams,
    with actuators: ActuatorValues
) -> DynamicRuntimeParams {
    // TODO: Implement actuator → source params mapping
    // ...
    return params  // ❌ actuatorsが全く反映されていない！
}
```

**影響**:
- **最適化が機能しない** - actuatorを変更しても何も起きない
- gradientは計算されるが、物理的な効果がゼロ
- Q_fusionが常に同じ値になる

**リスク**: 🔴 **Critical** - 最適化の根幹が動作しない

**修正方法**:
```swift
private func updateDynamicParams(
    _ params: DynamicRuntimeParams,
    with actuators: ActuatorValues
) -> DynamicRuntimeParams {
    var updated = params

    // 1. Update fusion source power
    if var fusionParams = updated.sourceParams["fusion"] {
        // P_ECRH, P_ICRHを反映（要：FusionSourceParamsの拡張）
        fusionParams.params["P_ECRH"] = actuators.P_ECRH
        fusionParams.params["P_ICRH"] = actuators.P_ICRH
        updated.sourceParams["fusion"] = fusionParams
    }

    // 2. Update boundary conditions (gas puff → density)
    // gas_puffからboundary densityへのマッピング
    updated.boundaryConditions.density = calculateDensityFromGasPuff(actuators.gas_puff)

    // 3. Update current (I_plasma)
    // 電流駆動ソースへのマッピング

    return updated
}
```

**ステータス**: ⏸️ Phase 7.5で実装予定（SourceParamsの拡張が必要）

---

### 🔴 問題2: 勾配テープの切断（MLXArray ↔ [Float]変換）

**場所**: `ActuatorTimeSeries.swift:79` および多数箇所

**問題**:
```swift
public static func fromMLXArray(_ array: MLXArray, nSteps: Int) -> ActuatorTimeSeries {
    let flat = array.asArray(Float.self)  // ❌ 勾配テープ切断！
    // ...
}
```

**影響**:
- MLXArray → [Float]変換で勾配情報が失われる
- Adamオプティマイザー内で毎イテレーション変換している
- **勾配が正しく伝播しない可能性**

**リスク**: 🔴 **High** - 自動微分が壊れる

**根本原因**:
- ActuatorTimeSeriesが`[Float]`配列を使用（Swift標準型）
- MLXArrayと互換性がない
- 変換のたびに勾配テープが切れる

**修正方法（選択肢）**:

**Option A**: ActuatorTimeSeriesをMLXArray内部表現に変更
```swift
public struct ActuatorTimeSeries {
    // ❌ OLD: let P_ECRH: [Float]
    // ✅ NEW: Internal MLXArray representation
    private let data: MLXArray  // Shape: [nSteps, 4]

    public var P_ECRH: [Float] {
        // Read-only accessor (for display only)
        return data[0..., 0].asArray(Float.self)
    }

    // Differentiable operations work directly on MLXArray
}
```

**Option B**: 勾配計算時のみMLXArrayを使用
```swift
// ForwardSensitivityでのみMLXArray操作
// ActuatorTimeSeriesは表示・設定用のまま
// 最適化ループはMLXArray空間で完結
```

**推奨**: Option B（影響範囲が小さい）

**ステータス**: ⏸️ 要検討・修正

---

### 🟡 問題3: 未使用の`coeffs`変数

**場所**: `DifferentiableSimulation.swift:164`

**問題**:
```swift
// 3. Build Block1D coefficients (differentiable)
let coeffs = buildBlock1DCoeffs(  // ❌ 計算するが使用しない
    transport: transportCoeffs,
    sources: sourceTerms,
    geometry: geometry,
    staticParams: staticParams,
    profiles: profiles
)

// 4. Build CoeffsCallback (for solver)
let coeffsCallback: CoeffsCallback = { ... }  // ここで再計算
```

**影響**:
- 無駄な計算（performance低下）
- CoeffsCallback内で同じ計算を再度実行

**リスク**: 🟡 Medium - パフォーマンス問題

**修正方法**:
```swift
// Option 1: coeffsを削除
// let coeffs = buildBlock1DCoeffs(...)  // 削除

// Option 2: coeffsをCoeffsCallbackで使用
let coeffs = buildBlock1DCoeffs(...)
let coeffsCallback: CoeffsCallback = { _, _ in coeffs }  // キャプチャして再利用
```

**推奨**: Option 1（シンプル）

**ステータス**: ⏸️ 簡単な修正

---

### 🟡 問題4: 制約適用のタイミング

**場所**: `Adam.swift:159-161`

**問題**:
```swift
// Apply constraints (hard clipping)
params = constraints.apply(to: params)        // [Float]配列で制約
paramsArray = params.toMLXArray()            // 再変換
```

**影響**:
- MLXArray → ActuatorTimeSeries → MLXArrayの往復変換
- 勾配テープが切れる可能性
- 効率が悪い

**リスク**: 🟡 Medium - 勾配伝播の不確実性

**修正方法**:
```swift
// MLXArray上で直接制約を適用
paramsArray = clampMLXArray(
    paramsArray,
    min: constraintsMin,  // MLXArray形式の制約
    max: constraintsMax
)

func clampMLXArray(_ array: MLXArray, min: MLXArray, max: MLXArray) -> MLXArray {
    return MLX.minimum(MLX.maximum(array, min), max)
}
```

**ステータス**: ⏸️ 推奨される改善

---

### 🟢 問題5: SourceModelsが空配列

**場所**: `ScenarioOptimizer.swift:250-261`

**問題**:
```swift
private static func createSourceModels(from params: DynamicRuntimeParams) -> [any SourceModel] {
    // Return empty for now to avoid circular dependency
    return []  // ❌ 物理ソースが無効
}
```

**影響**:
- Fusion power, Ohmic heating, 等のソースが全て無効
- Q_fusionが常にゼロまたは非現実的な値

**リスク**: 🟢 Low - 実装未完了（TODO）だが明示的

**修正方法**:
```swift
import GotenxPhysics  // 循環依存を解決

private static func createSourceModels(...) -> [any SourceModel] {
    var sources: [any SourceModel] = []

    if params.sourceParams["fusion"] != nil {
        sources.append(FusionPowerSource())
    }
    if params.sourceParams["ohmic"] != nil {
        sources.append(OhmicHeatingSource())
    }
    // ...

    return sources
}
```

**ステータス**: ⏸️ 実装保留（依存関係の設計が必要）

---

## アーキテクチャ上の懸念

### A. MLXArrayとSwift標準型の混在

**現状**:
- ActuatorTimeSeries: Swift `[Float]`配列
- CoreProfiles: MLX `EvaluatedArray`（内部はMLXArray）
- DifferentiableSimulation: MLXArrayベース

**問題**:
- 型変換が頻繁に発生（勾配テープ切断のリスク）
- パフォーマンスオーバーヘッド
- 勾配の流れが追いにくい

**推奨アプローチ**:
1. **最適化ループ内部**: 全てMLXArrayで統一
2. **入出力インターフェース**: Swift標準型（ユーザビリティ）
3. **境界で1回だけ変換**: eval()で確定

### B. compile()の回避

**現状**: ✅ 正しく実装されている
- DifferentiableSimulation は compile() を使用しない
- 勾配テープが保持される

**検証必要**:
- LinearSolver内部でcompile()を使っていないか？
- TransportModel/SourceModel内でcompile()を使っていないか？

### C. 固定タイムステップ

**現状**: ✅ 正しく実装されている
- `dt`は固定値として渡される
- 適応タイムステップは使用しない（勾配を壊すため）

---

## テストの必要性

### 必須テスト

1. **勾配の正確性テスト**
   ```swift
   @Test("Gradient correctness via finite differences")
   func testGradientCorrectness() {
       let analytical = sensitivity.computeGradient(...)
       let numerical = computeFiniteDifferences(...)
       #expect(relativeError(analytical, numerical) < 0.01)
   }
   ```

2. **Actuator反映テスト**
   ```swift
   @Test("Actuators affect simulation output")
   func testActuatorEffect() {
       let baseline = simulate(actuators: constant(10.0))
       let increased = simulate(actuators: constant(20.0))
       #expect(increased.Q_fusion > baseline.Q_fusion)  // ❌ 現在失敗の可能性
   }
   ```

3. **勾配伝播テスト**
   ```swift
   @Test("Gradient flows through optimization")
   func testGradientFlow() {
       let grad = optimizer.computeGradient(...)
       #expect(!grad.P_ECRH.allSatisfy { $0.isNaN })
       #expect(grad.P_ECRH.contains { abs($0) > 1e-6 })  // 非ゼロ勾配
   }
   ```

---

## 優先度付き修正リスト

### 優先度: P0 (Critical - 機能しない)

1. ✅ **問題1を修正**: actuatorをsimulationに反映
   - 所要時間: 1-2日
   - 必要作業: SourceParamsの拡張、マッピング実装

### 優先度: P1 (High - 正確性に影響)

2. ✅ **問題2を対処**: 勾配テープ切断を防ぐ
   - 所要時間: 2-3日
   - 選択肢検討が必要

### 優先度: P2 (Medium - パフォーマンス/品質)

3. ✅ **問題3を修正**: 未使用変数の削除
   - 所要時間: 5分

4. ✅ **問題4を改善**: 制約をMLXArray上で適用
   - 所要時間: 1時間

### 優先度: P3 (Low - 既知のTODO)

5. ✅ **問題5を実装**: SourceModels配線
   - 所要時間: 半日
   - 依存関係の整理が必要

---

## 結論

### ✅ 良い点

1. **アーキテクチャは正しい**
   - compile()を回避している
   - 固定タイムステップを使用
   - MLX grad()を正しく使用

2. **Adamアルゴリズムは正確**
   - バイアス補正が実装されている
   - 収束判定が適切

3. **型安全性が高い**
   - プロトコルベースの設計
   - Sendable準拠

### ⚠️ 重大な懸念

1. **🔴 最適化が機能しない**
   - actuatorが反映されていない（問題1）
   - これが修正されるまで、全体が動作しない

2. **🔴 勾配の正確性が不明**
   - asArray()による勾配切断（問題2）
   - テストで検証が必須

### 📋 Next Steps

#### Immediate (今すぐ)

1. **問題3を修正** (5分で完了)
2. **勾配テストを作成** (検証が最優先)

#### Short-term (1週間以内)

3. **問題1を修正** - Phase 7.5として実装
4. **問題2を対処** - 設計レビュー後に実装

#### Medium-term (2週間以内)

5. **問題4, 5を実装**
6. **エンドツーエンドテスト**

---

**評価**: 🟡 **実装は60%完了、但し動作検証は0%**

**推奨**: 問題1を修正してから統合テストを実施

---

**レビュー日**: 2025-10-21
**レビュアー**: Claude Code
**ステータス**: Phase 7実装レビュー完了、修正リスト作成済み
