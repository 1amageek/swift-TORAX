# Sawtooth Redistribution Logic Review

## 問題の特定

### エラー内容
1. **Broadcast shape error**: Shapes (51) and (50) cannot be broadcast
2. **Outer region test failure**: outerDifference = 605.9968 (expected < 1.0)

### 配列サイズの数学的分析

#### 入力パラメータ（テストケース）
```
nCells = 50
rhoQ1 = 0.4  → indexQ1 ≈ 20
rhoMix = 0.6 (= 1.5 × 0.4) → indexMix ≈ 30
```

#### `flattenProfile()` の配列サイズ計算

**現在の実装:**
```swift
// innerFlattened: [0..<upToIndex] → upToIndex 要素
let indices = MLXArray(0..<upToIndex)  // upToIndex = indexQ1 = 20
// → 20 要素 [0, 1, 2, ..., 19]

// transitionBlend: [upToIndex..<(upToIndex+transitionLength)]
let transitionStart = upToIndex  // = 20
let transitionLength = mixingIndex - upToIndex + 1  // = 30 - 20 + 1 = 11
let transitionOriginal = profile[transitionStart..<(transitionStart + transitionLength)]
// = profile[20..<31] → 11 要素 [20, 21, ..., 30]

// outerRegion: [(mixingIndex + 1)...]
let outerRegion = profile[(mixingIndex + 1)...]
// = profile[31...] → 50 - 31 = 19 要素 [31, 32, ..., 49]

// 合計サイズ
total = 20 + 11 + 19 = 50 ✓
```

**問題点 1: インデックスの重複チェック**
- innerFlattened は [0, 1, ..., 19] をカバー
- transitionBlend は [20, 21, ..., 30] をカバー
- outerRegion は [31, 32, ..., 49] をカバー
- → 重複なし、ギャップなし ✓

#### `enforceParticleConservation()` の配列サイズ計算

**現在の実装:**
```swift
// upToIndex パラメータには indexMix (= 30) が渡される

// n_inner_conserved: profileNew[...upToIndex]
let n_new = profileNew[...upToIndex]  // profileNew[0...30]
// → 31 要素 [0, 1, 2, ..., 30]

// n_outer: profileNew[(upToIndex+1)...]
let n_outer = profileNew[(upToIndex+1)...]  // profileNew[31...]
// → 50 - 31 = 19 要素 [31, 32, ..., 49]

// 合計サイズ
total = 31 + 19 = 50 ✓
```

**問題点 2: 配列サイズは正しいが、flattenProfile との一貫性**
- `flattenProfile` は 50 要素を返す
- `enforceParticleConservation` も 50 要素を返す
- → サイズは一致 ✓

しかし、なぜ broadcast error が発生するのか？

### 根本原因の特定

**仮説 1: `flattenProfile` が 51 要素を返している**

`transitionLength` の計算を再確認：
```swift
let transitionLength = mixingIndex - upToIndex + 1
```

これは間違いです！物理的には：
- upToIndex (indexQ1) の位置の値は元のプロファイルのまま保持すべき
- transition は upToIndex の**次**から始まるべき

**修正すべき実装:**
```swift
// innerFlattened should be [0..<upToIndex]
// transitionBlend should be [upToIndex..<(mixingIndex+1)]
// outerRegion should be [(mixingIndex+1)...]
```

しかし、これでは upToIndex の位置が二重にカウントされます。

**物理的に正しい実装:**

1. **Core region** (0 to upToIndex-1): 完全フラット化
   - 値: T_axis から T(upToIndex) へ線形補間

2. **Q=1 surface** (upToIndex): 境界値、変更なしまたは遷移の起点

3. **Transition region** (upToIndex+1 to mixingIndex): 元のプロファイルへ遷移

4. **Outer region** (mixingIndex+1 to end): 完全に変更なし

### 数学的矛盾の発見

**問題点 3: Transition の開始位置**

現在の実装:
```swift
let transitionStart = upToIndex  // transition includes upToIndex
let transitionLength = mixingIndex - upToIndex + 1  // includes both endpoints
```

これは upToIndex を transition に含めています。しかし、innerFlattened の最後の値は：
```swift
let fractions = indices.asType(.float32) / Float(upToIndex)
// When i = upToIndex-1: fraction = (upToIndex-1) / upToIndex
let innerFlattened = valueAxis + (valueQ1 - valueAxis) * fractions
// innerFlattened[upToIndex-1] = valueAxis + (valueQ1 - valueAxis) * (upToIndex-1)/upToIndex
// ≠ valueQ1
```

つまり、innerFlattened[upToIndex-1] は valueQ1 に**達していません**。

これは物理的に間違っています！q=1 surface での値は連続であるべきです。

### 正しい物理モデル

**Kadomtsev モデル（1975）:**

Sawtooth crash 時：
1. q < 1 の領域（core）で磁気再結合が発生
2. プロファイルは q=1 surface まで**完全にフラット化**
3. q=1 surface での値 = フラット化後の値（保存則により決定）
4. Mixing radius (≈ 1.5 × r_q1) まで影響

**正しい実装:**

```
T_flat(r) = {
  T_0                           (r < r_q1, フラット領域)
  T_0 + (T_orig(r) - T_0) * α   (r_q1 ≤ r ≤ r_mix, 遷移領域)
  T_orig(r)                     (r > r_mix, 外側領域)
}

where:
  α = (r - r_q1) / (r_mix - r_q1)  (遷移関数)
  T_0 = 保存則から決定される中心温度
```

### 配列インデックスの正しいマッピング

**修正案:**

```swift
// Region 1: [0, 1, ..., upToIndex] をフラット化
// 全て同じ値 valueFlat に設定（保存則適用後に決定）

// Region 2: [upToIndex+1, upToIndex+2, ..., mixingIndex] 遷移
// Linear blend from valueFlat to original profile

// Region 3: [mixingIndex+1, ..., nCells-1] 変更なし
```

### 保存則の適用範囲

**現在の実装:**
```swift
enforceParticleConservation(..., upToIndex: indexMix)
```

これは 0 から indexMix まで保存則を適用します。

**物理的に正しい範囲:**
- 保存則は**全体**（0 から nCells-1）で適用すべき
- または、少なくとも mixing radius まで

しかし、outer region を変更しないなら、mixing radius までの適用が妥当です。

### 結論

**数学的矛盾:**
1. `flattenProfile` の innerFlattened が valueQ1 に達していない
2. Transition の開始点が不明確（upToIndex を含むか含まないか）
3. 配列連結時のサイズ計算に off-by-one error の可能性

**物理的矛盾:**
1. Sawtooth crash は q=1 surface まで**完全フラット化**すべきだが、線形勾配が残っている
2. Outer region test で 605.9968 の差 → 外側領域が大きく変化している（物理的に間違い）

**推奨される修正:**

1. **完全フラット化の実装:**
   ```swift
   // innerFlattened: すべて同じ値 valueQ1 に設定
   let innerFlattened = MLXArray.full([upToIndex + 1], values: valueQ1)
   ```

2. **Transition の明確化:**
   ```swift
   // Transition: upToIndex+1 から mixingIndex まで
   let transitionStart = upToIndex + 1
   let transitionEnd = mixingIndex
   let transitionLength = transitionEnd - transitionStart + 1
   ```

3. **Outer region の保護:**
   ```swift
   // Outer region は完全に変更なし
   let outerStart = mixingIndex + 1
   let outerRegion = profile[outerStart...]
   ```

4. **Conservation の全体適用:**
   ```swift
   // 保存則は全体で適用（外側を固定しない）
   // または mixing radius までに制限
   ```
