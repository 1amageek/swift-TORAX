# Phase 6 Implementation Review

**Date**: 2025-10-21
**Version**: 1.0
**Status**: ✅ 実装完了、⚠️ 潜在的問題あり

---

## 実装内容

### 完了した実装

1. ✅ **ToraxReferenceDataLoader.swift** (157 lines)
   - SwiftNetCDF を使用した NetCDF 読み込み
   - 2D プロファイルの reshape 処理
   - エラーハンドリング

2. ✅ **ToraxReferenceDataTests.swift** (285 lines)
   - モック TORAX ファイル生成
   - データ読み込みテスト
   - 時間ユーティリティテスト

3. ✅ **ToraxDataError 拡張**
   - `fileOpenFailed`, `variableNotFound`, `invalidDimensions`, `invalidData` 追加

---

## ロジックの問題点と対策

### ⚠️ 問題1: NetCDF 変数名の仮定

**場所**: `ToraxReferenceDataLoader.swift:89-91`

**問題**:
```swift
let Ti = try read2DProfile(file: file, name: "ion_temperature", nTime: nTime, nRho: nRho)
let Te = try read2DProfile(file: file, name: "electron_temperature", nTime: nTime, nRho: nRho)
let ne = try read2DProfile(file: file, name: "electron_density", nTime: nTime, nRho: nRho)
```

変数名を決め打ちしているが、TORAX の実際の出力では異なる可能性がある:
- TORAX Python: `temp_ion`, `temp_electron`, `ne` かもしれない
- 別のコード: `Ti`, `Te`, `n_e` など

**リスク**: 🟡 中程度 - TORAX の実際の出力で変数名が異なる場合、エラー

**対策**:
1. TORAX Python を実行して実際の変数名を確認
2. 必要に応じて変数名マッピングを追加:
   ```swift
   let variableNames = [
       "ion_temperature": ["ion_temperature", "temp_ion", "Ti"],
       "electron_temperature": ["electron_temperature", "temp_electron", "Te"],
       "electron_density": ["electron_density", "ne", "n_e"]
   ]
   ```

---

### ⚠️ 問題2: 次元順序の仮定

**場所**: `ToraxReferenceDataLoader.swift:141`

**問題**:
```swift
let flatData: [Float] = try typedVar.read(offset: [0, 0], count: [nTime, nRho])
```

`[time, rho]` の順序を仮定しているが、NetCDF では `[rho, time]` の可能性もある。

**検証方法**:
```swift
// 次元名を確認
let dims = variable.dimensionsFlat
print("Dimensions: \(dims.map { $0.name })")  // ["time", "rho_tor_norm"] or ["rho_tor_norm", "time"]?
```

**リスク**: 🔴 高 - 次元順序が逆の場合、データが完全に誤る

**対策**:
1. 次元名を確認してから読み込み:
   ```swift
   let dims = variable.dimensionsFlat
   let isTimeFirst = dims[0].name == "time"

   let flatData: [Float]
   if isTimeFirst {
       flatData = try typedVar.read(offset: [0, 0], count: [nTime, nRho])
   } else {
       flatData = try typedVar.read(offset: [0, 0], count: [nRho, nTime])
       // Transpose needed
   }
   ```

2. または、次元名を明示的にチェック:
   ```swift
   guard dims[0].name == "time" && dims[1].name == "rho_tor_norm" else {
       throw ToraxDataError.invalidDimensions("Expected [time, rho_tor_norm], got \(dims.map { $0.name })")
   }
   ```

---

### ⚠️ 問題3: エッジインデックスの仮定

**場所**: `ValidationConfigMatcher.swift:78-81`

**問題**:
```swift
let edgeIdx = nCells - 1
let Ti_edge = toraxData.Ti[0][edgeIdx]  // 最後の点がエッジと仮定
```

`rho` が 0→1 の順序であることを仮定しているが:
- TORAX が 1→0 の順序の可能性
- `rho[0]` が中心、`rho[nCells-1]` がエッジ、またはその逆

**検証方法**:
```swift
// rho の順序を確認
if toraxData.rho[0] < toraxData.rho[nCells - 1] {
    // 0→1 の順序
    let edgeIdx = nCells - 1
} else {
    // 1→0 の順序
    let edgeIdx = 0
}
```

**リスク**: 🟡 中程度 - エッジ境界条件が中心値になる可能性

**対策**:
```swift
// Rho の最大値の位置を見つける（エッジ = rho ≈ 1.0）
let edgeIdx = toraxData.rho.enumerated().max(by: { $0.element < $1.element })!.offset
let Ti_edge = toraxData.Ti[0][edgeIdx]
```

---

### ⚠️ 問題4: saveInterval の計算

**場所**: `ValidationConfigMatcher.swift:66`

**問題**:
```swift
let saveInterval = (tEnd - tStart) / Float(nTimePoints - 1)
```

等間隔サンプリングを仮定しているが:
- TORAX が適応時間刻みを使用している場合、不等間隔
- この場合、平均間隔を使っても正確な再現にならない

**検証方法**:
```swift
// 時間間隔の分散を確認
let intervals = zip(toraxData.time.dropFirst(), toraxData.time).map { $0 - $1 }
let avgInterval = intervals.reduce(0, +) / Float(intervals.count)
let variance = intervals.map { pow($0 - avgInterval, 2) }.reduce(0, +) / Float(intervals.count)
print("Time interval variance: \(variance)")
// variance が小さければ等間隔、大きければ不等間隔
```

**リスク**: 🟡 中程度 - 時系列比較がずれる可能性

**対策**:
1. 最頻値を使用:
   ```swift
   let intervals = zip(toraxData.time.dropFirst(), toraxData.time).map { $0 - $1 }
   let saveInterval = intervals.min() ?? 0.02  // 最小間隔を使用
   ```

2. または、TORAX の時刻配列を直接使用して補間比較

---

### ⚠️ 問題5: 初期時刻の境界条件

**場所**: `ValidationConfigMatcher.swift:79-81`

**問題**:
```swift
let Ti_edge = toraxData.Ti[0][edgeIdx]  // 初期時刻 (t=0) のエッジ値
```

`toraxData.time[0]` が必ずしも `t=0` とは限らない:
- TORAX が `t=1.0` から開始している可能性
- 定常状態からのシミュレーション

**検証方法**:
```swift
print("TORAX start time: \(toraxData.time[0]) s")
```

**リスク**: 🟢 低 - 通常は `t=0` から開始するが、念のため確認

**対策**:
```swift
// 最も早い時刻を明示的に使用
guard toraxData.time[0] == 0.0 else {
    print("Warning: TORAX data starts at t=\(toraxData.time[0]) s, not t=0")
}
let Ti_edge = toraxData.Ti[0][edgeIdx]
```

---

### ✅ 問題6: 2D 配列の reshape ロジック

**場所**: `ToraxReferenceDataLoader.swift:149-153`

**コード**:
```swift
let profiles: [[Float]] = (0..<nTime).map { t in
    let start = t * nRho
    let end = start + nRho
    return Array(flatData[start..<end])
}
```

**検証**: ✅ 正しい

**理由**:
- NetCDF の flat 配列は row-major (C order): `[T0R0, T0R1, ..., T0Rn, T1R0, T1R1, ...]`
- `t * nRho` で時刻 `t` の開始位置を計算
- `start..<end` でその時刻の全 rho 点を抽出

**確認**:
```
flatData[0...(nRho-1)]   → Ti[0] (t=0 の全 rho)
flatData[nRho...(2*nRho-1)] → Ti[1] (t=1 の全 rho)
```

これは期待通りの動作。

---

### ✅ 問題7: 次元バリデーション

**場所**: `ToraxReferenceDataLoader.swift:84-86`

**コード**:
```swift
guard nRho >= 10 && nRho <= 200 else {
    throw ToraxDataError.invalidDimensions("rho_tor_norm must be 10-200, got \(nRho)")
}
```

**検証**: ✅ 妥当

**理由**:
- 10 cells 未満: 数値精度が低すぎる
- 200 cells 超: 通常の TORAX シミュレーションでは稀
- ITER Baseline は通常 50-100 cells

---

## 統合テスト時の確認項目

### 実際の TORAX データを使用する際に確認すべき点

1. **変数名の確認** (最優先):
   ```bash
   ncdump -h torax_output.nc | grep "float"
   ```
   期待: `float ion_temperature(time, rho_tor_norm)`

2. **次元順序の確認** (最優先):
   ```bash
   ncdump -h torax_output.nc | grep "dimensions"
   ```
   期待: `ion_temperature(time, rho_tor_norm)` (この順序)

3. **座標配列の確認**:
   ```bash
   ncdump -v rho_tor_norm torax_output.nc | head -20
   ```
   期待: `rho_tor_norm = 0, 0.01, 0.02, ..., 1.0` (昇順)

4. **時間配列の確認**:
   ```bash
   ncdump -v time torax_output.nc | head -20
   ```
   期待: `time = 0, 0.02, 0.04, ..., 2.0`

5. **データ値の妥当性**:
   ```bash
   ncdump -v ion_temperature torax_output.nc | grep "ion_temperature ="
   ```
   期待: 温度 ~100-20000 eV, 密度 ~1e19-1e20 m⁻³

---

## 推奨される修正

### 優先度: 高

**次元順序の明示的確認**:

```swift
// ToraxReferenceDataLoader.swift の read2DProfile に追加
private static func read2DProfile(
    file: Group,
    name: String,
    nTime: Int,
    nRho: Int
) throws -> [[Float]] {
    // ... existing code ...

    // 次元順序を確認
    let dims = variable.dimensionsFlat
    guard dims.count == 2 else {
        throw ToraxDataError.invalidDimensions("\(name) must be 2D, got \(dims.count)D")
    }

    // 次元名を確認（time が最初であることを期待）
    let dimNames = dims.map { $0.name }
    guard dimNames[0] == "time" else {
        throw ToraxDataError.invalidDimensions(
            "\(name) dimensions: expected [time, rho_tor_norm], got \(dimNames)"
        )
    }

    // ... rest of existing code ...
}
```

### 優先度: 中

**エッジインデックスの動的検出**:

```swift
// ValidationConfigMatcher.swift の matchToTorax に追加
// Find edge index (rho ≈ 1.0)
let edgeIdx = toraxData.rho.enumerated().max(by: { $0.element < $1.element })!.offset

// Verify edge value is close to 1.0
let edgeRho = toraxData.rho[edgeIdx]
guard abs(edgeRho - 1.0) < 0.01 else {
    print("Warning: Edge rho = \(edgeRho), expected ~1.0")
}
```

### 優先度: 低

**変数名のフォールバック**:

```swift
// ToraxReferenceDataLoader.swift
private static func findVariable(file: Group, candidates: [String]) -> Variable? {
    for name in candidates {
        if let variable = file.getVariable(name: name) {
            return variable
        }
    }
    return nil
}

// 使用例
let tiCandidates = ["ion_temperature", "temp_ion", "Ti"]
guard let tiVar = findVariable(file: file, candidates: tiCandidates) else {
    throw ToraxDataError.variableNotFound("ion_temperature (or alternatives)")
}
```

---

## 結論

### ✅ 実装は基本的に正しい

- 2D 配列の reshape ロジックは正確
- エラーハンドリングは適切
- テストカバレッジは良好

### ⚠️ 実データ使用時の注意点

1. **最優先**: 次元順序の確認（`[time, rho]` を仮定）
2. **重要**: 変数名の確認（TORAX の実際の出力で検証）
3. **推奨**: エッジインデックスの動的検出

### 📋 次のステップ

1. ✅ TORAX Python を実行して実際の NetCDF 出力を生成
2. ✅ `ncdump` で変数名と次元順序を確認
3. ✅ 必要に応じて上記の修正を適用
4. ✅ 実データでテスト実行

---

**評価日**: 2025-10-21
**評価者**: Claude Code
**ステータス**: ⚠️ 実装完了、実データ検証待ち
