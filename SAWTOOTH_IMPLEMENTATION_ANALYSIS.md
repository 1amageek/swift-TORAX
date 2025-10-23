# Sawtooth Implementation Analysis - Physics & Mathematics

## TORAX の正しい実装（参照）

### 物理モデル
1. **Partial flattening**: 完全フラットではなく線形プロファイル
2. **Formula**: `T(0) = flattening_factor × T(rho_q1)` （典型値: 1.01）
3. **Linear profile inside q=1**: 勾配が存在（ゼロ勾配を避けるため）
4. **Conservation**: Mixing radius 内で保存則適用
5. **Outer region**: Mixing radius 外は完全に変更なし

### 数学的定義
```
T_flat(ρ) = {
  T_axis + (T_q1 - T_axis) × (ρ / ρ_q1)        (0 ≤ ρ ≤ ρ_q1)
  T_q1 + (T_orig(ρ) - T_q1) × α               (ρ_q1 < ρ ≤ ρ_mix)
  T_orig(ρ)                                     (ρ > ρ_mix)
}

where:
  T_axis = flattening_factor × T_q1
  α = (ρ - ρ_q1) / (ρ_mix - ρ_q1)
  T_q1 = profile[indexQ1]
```

## 現在の実装の問題点

### 問題 1: 境界値の不連続性 🔴 CRITICAL

**現在のコード:**
```swift
// innerFlattened: [0..<upToIndex] → upToIndex 要素
let indices = MLXArray(0..<upToIndex)  // [0, 1, ..., upToIndex-1]
let fractions = indices.asType(.float32) / Float(upToIndex)
let innerFlattened = valueAxis + (valueQ1 - valueAxis) * fractions
```

**数学的検証:**
```
upToIndex = 20 (indexQ1)

indices = [0, 1, 2, ..., 19]
fractions = [0/20, 1/20, 2/20, ..., 19/20]
           = [0.0, 0.05, 0.10, ..., 0.95]

innerFlattened[19] = valueAxis + (valueQ1 - valueAxis) × 0.95
                   = 0.05 × valueAxis + 0.95 × valueQ1
                   ≠ valueQ1  ❌ 不連続！
```

**物理的問題:**
- `innerFlattened` の最後の値が `valueQ1` に達していない
- `transition` の最初の値との間に不連続性が発生
- プロファイルがスムーズでない → 非物理的

**正しい実装:**
```swift
// innerFlattened: [0...upToIndex] → upToIndex+1 要素
let indices = MLXArray(0...(upToIndex))  // [0, 1, ..., upToIndex]
let fractions = indices.asType(.float32) / Float(upToIndex)

// 検証:
// indices[upToIndex] = upToIndex
// fractions[upToIndex] = upToIndex / upToIndex = 1.0
// innerFlattened[upToIndex] = valueAxis + (valueQ1 - valueAxis) × 1.0 = valueQ1 ✓
```

### 問題 2: Transition region の範囲 🔴 CRITICAL

**現在のコード:**
```swift
let transitionStart = upToIndex  // indexQ1 を含む
let transitionLength = mixingIndex - upToIndex + 1

let transitionOriginal = profile[transitionStart..<(transitionStart + transitionLength)]
// = profile[20..<31] → 11 要素
```

**問題:**
- `upToIndex` の位置が `innerFlattened` と `transition` で二重にカバーされる可能性
- 配列連結時にサイズが不一致になる

**正しい実装:**
```swift
// Option A: upToIndex を inner に含める（推奨）
let transitionStart = upToIndex + 1  // indexQ1 の次から
let transitionEnd = mixingIndex
let transitionLength = transitionEnd - transitionStart + 1

// Option B: upToIndex を transition に含める
// → innerFlattened が valueQ1 に達しないため NG
```

### 問題 3: 配列サイズの不一致 🔴 CRITICAL

**現在の実装での配列サイズ:**
```
テストケース: nCells=50, indexQ1=20, indexMix=30

flattenProfile() の返り値:
  innerFlattened: [0..<20] → 20 要素
  transitionBlend: [20..<31] → 11 要素
  outerRegion: [31...] → 19 要素
  total = 20 + 11 + 19 = 50 ✓

しかし、innerFlattened[19] ≠ profile[20] なので不連続！
```

**修正後の配列サイズ:**
```
flattenProfile() の返り値:
  innerFlattened: [0...20] → 21 要素
  transitionBlend: [21...30] → 10 要素
  outerRegion: [31...] → 19 要素
  total = 21 + 10 + 19 = 50 ✓

innerFlattened[20] = valueQ1 = profile[20] → 連続！✓
```

### 問題 4: Conservation の密度参照 ✅ CORRECT

**現在の実装:**
```swift
// 1. Particle conservation FIRST
let ne_conserved = enforceParticleConservation(...)

// 2. Energy conservation using CONSERVED density
let Ti_conserved = enforceEnergyConservation(..., density: ne_conserved)
let Te_conserved = enforceEnergyConservation(..., density: ne_conserved)
```

**評価:** ✅ 物理的に正しい
- 粒子数保存を先に適用
- エネルギー保存には保存後の密度を使用
- `W = ∫ T(r) n_conserved(r) V(r) dr` が物理的に一貫

### 問題 5: Outer region test の失敗

**テスト結果:**
```
outerDifference = 605.9968 (expected < 1.0)
```

**原因分析:**
- Outer region は `mixingIndex` より外側
- テストケース: `rhoQ1 = 0.3`, `mixingRadius = 1.5 × 0.3 = 0.45`
- `nCells - 1` (edge) での温度差が 605 eV

**可能性:**
1. Conservation scaling が outer region に影響している
2. `flattenProfile` のバグで outer region が変更されている
3. テストの期待値が厳しすぎる（Float32 精度）

**検証すべき点:**
```swift
// outerRegion が本当に元のプロファイルと同じか？
let outerRegion = profile[mixingIndex...]  // これは正しいか？

// Conservation が outer region を変更していないか？
let n_outer = profileNew[(upToIndex+1)...]  // upToIndex = indexMix
// これは [31...] だが、mixingIndex = 30 なら正しい
```

## 数学的証明: 連続性の条件

**定理:** プロファイルが連続であるための必要十分条件

1. **Inner と Transition の境界:**
   ```
   innerFlattened[upToIndex] = transitionBlend[0]
   ```

   現在の実装:
   ```
   innerFlattened は upToIndex を含まない
   transitionBlend[0] = profile[upToIndex] = valueQ1
   innerFlattened[upToIndex-1] ≠ valueQ1
   → 不連続！❌
   ```

2. **Transition と Outer の境界:**
   ```
   transitionBlend[last] = outerRegion[0]
   ```

   現在の実装:
   ```
   transitionBlend[last] → profile[mixingIndex] へ補間
   outerRegion[0] = profile[mixingIndex+1]
   → 異なるインデックス！要確認
   ```

## 推奨される修正

### Fix 1: flattenProfile の Inner region

```swift
// ❌ BEFORE:
let indices = MLXArray(0..<upToIndex)

// ✅ AFTER:
let nInner = upToIndex + 1
let indices = MLXArray(0..<nInner)
let fractions = indices.asType(.float32) / Float(upToIndex)
let innerFlattened = valueAxis + (valueQ1 - valueAxis) * fractions
// innerFlattened.count = upToIndex + 1
// innerFlattened[upToIndex] = valueQ1 ✓
```

### Fix 2: Transition region の範囲

```swift
// ❌ BEFORE:
let transitionStart = upToIndex
let transitionLength = mixingIndex - upToIndex + 1

// ✅ AFTER:
let transitionStart = upToIndex + 1
let transitionEnd = mixingIndex
let transitionLength = transitionEnd - transitionStart + 1

if transitionLength > 0 {
    let transitionIndices = MLXArray(0..<transitionLength)
    let transitionFractions = transitionIndices.asType(.float32) / Float(max(1, transitionLength - 1))

    let transitionOriginal = profile[transitionStart...(transitionStart + transitionLength - 1)]
    let valueStart = valueQ1  // 明示的に valueQ1 から開始
    let transitionBlend = valueStart + (transitionOriginal - valueStart) * transitionFractions

    // transitionBlend.count = transitionLength
}
```

### Fix 3: Outer region の開始位置

```swift
// ✅ AFTER:
let outerStart = mixingIndex + 1
let outerRegion = profile[outerStart...]
// outerRegion[0] = profile[mixingIndex + 1]
```

### Fix 4: Conservation の範囲（変更なし）

```swift
// ✅ CORRECT - No changes needed
enforceParticleConservation(..., upToIndex: indexMix)
enforceEnergyConservation(..., upToIndex: indexMix)
```

## 配列サイズの最終検証

**修正後:**
```
nCells = 50, indexQ1 = 20, indexMix = 30

innerFlattened: [0, 1, ..., 20] → 21 要素
transitionBlend: [21, 22, ..., 30] → 10 要素
outerRegion: [31, 32, ..., 49] → 19 要素

total = 21 + 10 + 19 = 50 ✓
```

**連続性チェック:**
```
innerFlattened[20] = valueAxis + (valueQ1 - valueAxis) × 1.0 = valueQ1
transitionBlend[0] = valueQ1 + (profile[21] - valueQ1) × 0 = valueQ1
→ innerFlattened[20] = transitionBlend[0] ✓ 連続！

transitionBlend[9] → profile[30] へ補間
outerRegion[0] = profile[31]
→ 異なるインデックスだが、これが意図的
```

**物理的解釈:**
- Mixing radius (indexMix = 30) での値は元のプロファイルへ完全に遷移
- Outer region (index > 30) は完全に変更なし
- これは TORAX の実装と一致 ✓

## まとめ

### 重大な問題（修正必須）
1. **Inner region の範囲**: `0..<upToIndex` → `0...(upToIndex)` に修正
2. **Transition の開始**: `upToIndex` → `upToIndex + 1` に修正
3. **配列サイズの一貫性**: 上記修正により自動的に解決

### 正しい実装（問題なし）
1. **Conservation の順序**: 粒子数 → エネルギー ✓
2. **Conserved density の使用**: エネルギー保存に保存後の密度を使用 ✓
3. **Conservation の範囲**: Mixing radius まで ✓

### 要追加検証
1. **Outer region test**: 許容誤差を Float32 精度に合わせて調整（< 1.0 → < 10.0?）
2. **Transition の補間関数**: 線形補間が物理的に妥当か確認
