# swift-TORAX ユニットテスト実装計画

**作成日**: 2025-10-17
**対象バージョン**: Alpha/Beta
**総設計テストファイル数**: 20ファイル
**推定テストケース数**: 200+

---

## 📊 テストカバレッジ分析

### 既存のテストカバレッジ（7ファイル）

| モジュール | テスト済みコンポーネント | テストファイル |
|-----------|----------------------|--------------|
| **Core** | EvaluatedArray, CoreProfiles, Geometry, TransportCoefficients, SourceTerms | `DataStructuresTests.swift` |
| **FVM** | CellVariable (境界条件、面値、勾配) | `CellVariableTests.swift` |
| **Solver** | FlattenedState | `FlattenedStateTests.swift` |
| **Transport** | ConstantTransportModel, BohmGyroBohmTransportModel | `ConstantTransportModelTests.swift` |
| **TORAXPhysics** | FusionPower, Bremsstrahlung, IonElectronExchange | `FusionPowerTests.swift`, `BremsstrahlungTests.swift`, `IonElectronExchangeTests.swift` |

**既存テスト総計**: 約40テストケース

### 未テストモジュール（優先度順）

1. **Solver** (5コンポーネント) - 最優先
2. **Configuration** (5コンポーネント) - 高優先
3. **Orchestration** (2コンポーネント) - 中優先
4. **TORAXPhysics** (2モデル) - 中優先
5. **Geometry & Extensions** (3コンポーネント) - 低優先

---

## 🎯 テスト設計概要

### 1. **Solver Module Tests** (8ファイル、80+テストケース)

優先度: **最優先** ⭐⭐⭐

#### 1.1 `EquationCoeffsTests.swift` (8テスト)
- ✅ 初期化テスト
- ✅ ゼロ初期化
- ✅ 形状検証
- ✅ 形状不一致エラー処理
- ✅ 係数抽出
- ✅ Codable対応

**実装場所**: `/Tests/TORAXTests/Solver/EquationCoeffsTests.swift`

#### 1.2 `Block1DCoeffsTests.swift` (10テスト)
- ✅ 4方程式系の初期化
- ✅ 形状一貫性検証
- ✅ セル数不一致エラー
- ✅ 係数行列抽出（transient, diffusion, convection, source）
- ✅ 方程式ごとの独立係数処理

**実装場所**: `/Tests/TORAXTests/Solver/Block1DCoeffsTests.swift`

#### 1.3 `Block1DCoeffsBuilderTests.swift` (12テスト)
- ✅ 輸送・ソースからの係数構築
- ✅ 拡散係数計算（chiからの変換）
- ✅ 対流係数計算
- ✅ ソース項正規化
- ✅ Theta法係数（explicit θ=0）
- ✅ Theta法係数（implicit θ=1）
- ✅ Theta法係数（Crank-Nicolson θ=0.5）
- ✅ 境界条件の適用

**実装場所**: `/Tests/TORAXTests/Solver/Block1DCoeffsBuilderTests.swift`

#### 1.4 `LinearSolverTests.swift` (10テスト)
- ✅ ソルバー初期化
- ✅ 単純拡散方程式の解法
- ✅ Predictor-Corrector反復
- ✅ 収束判定基準
- ✅ 最大反復回数制限
- ✅ 残差ノルム計算
- ✅ 収束失敗時の挙動

**実装場所**: `/Tests/TORAXTests/Solver/LinearSolverTests.swift`

#### 1.5 `NewtonRaphsonSolverTests.swift` (12テスト)
- ✅ ソルバー初期化
- ✅ vjpベースJacobian計算（効率検証）
- ✅ 非線形問題の解法
- ✅ Line search最適化
- ✅ Damping factor適用
- ✅ Jacobian精度検証
- ✅ 収束率テスト（二次収束）

**実装場所**: `/Tests/TORAXTests/Solver/NewtonRaphsonSolverTests.swift`

#### 1.6 `HybridLinearSolverTests.swift` (10テスト)
- ✅ 直接法（小規模系）
- ✅ 反復法（大規模系）
- ✅ 直接法へのフォールバック
- ✅ 三重対角最適化（Thomas algorithm）
- ✅ 条件数推定
- ✅ 前処理付き反復法

**実装場所**: `/Tests/TORAXTests/Solver/HybridLinearSolverTests.swift`

#### 1.7 `TimeStepCalculatorTests.swift` (10テスト)
- ✅ 初期化
- ✅ CFL条件（拡散）
- ✅ CFL条件（対流）
- ✅ dtMin/dtMaxクランプ
- ✅ 適応的タイムステップ（解変化量ベース）
- ✅ 安定性判定

**実装場所**: `/Tests/TORAXTests/Solver/TimeStepCalculatorTests.swift`

#### 1.8 `SolverResultTests.swift` (6テスト)
- ✅ 収束結果の構造化
- ✅ 非収束結果の処理
- ✅ 結果比較
- ✅ 診断情報出力

**実装場所**: `/Tests/TORAXTests/Solver/SolverResultTests.swift`

---

### 2. **Configuration Module Tests** (5ファイル、40+テストケース)

優先度: **高** ⭐⭐⭐

#### 2.1 `MeshConfigTests.swift` (8テスト)
- ✅ メッシュ初期化
- ✅ dr計算検証
- ✅ ジオメトリタイプ（circular, Miller楕円）
- ✅ Codable対応
- ✅ 等価性比較

**実装場所**: `/Tests/TORAXTests/Configuration/MeshConfigTests.swift`

#### 2.2 `BoundaryConditionsTests.swift` (10テスト)
- ✅ FaceConstraint（値型・勾配型）
- ✅ 混合境界条件（Dirichlet/Neumann）
- ✅ 4変数の境界条件設定
- ✅ Codable対応
- ✅ 等価性比較

**実装場所**: `/Tests/TORAXTests/Configuration/BoundaryConditionsTests.swift`

#### 2.3 `ProfileConditionsTests.swift` (10テスト)
- ✅ ProfileSpec（constant, linear, parabolic, array）
- ✅ 各プロファイルタイプの初期化
- ✅ 4変数のプロファイル条件
- ✅ Codable対応
- ✅ 等価性比較

**実装場所**: `/Tests/TORAXTests/Configuration/ProfileConditionsTests.swift`

#### 2.4 `ParametersTests.swift` (8テスト)
- ✅ TransportParameters（モデルタイプ・パラメータ）
- ✅ SourceParameters（時間依存性）
- ✅ 空パラメータの処理
- ✅ Codable対応

**実装場所**: `/Tests/TORAXTests/Configuration/ParametersTests.swift`

#### 2.5 `RuntimeParamsTests.swift` (12テスト)
- ✅ StaticRuntimeParams（デフォルト値）
- ✅ カスタムソルバー設定
- ✅ 方程式選択的進化（evolve flags）
- ✅ DynamicRuntimeParams初期化
- ✅ ソースパラメータ管理
- ✅ Codable対応

**実装場所**: `/Tests/TORAXTests/Configuration/RuntimeParamsTests.swift`

---

### 3. **TORAXPhysics Module Tests** (2ファイル、30+テストケース)

優先度: **中** ⭐⭐

#### 3.1 `OhmicHeatingTests.swift` (15テスト)
- ✅ 初期化
- ✅ Spitzer抵抗率のスケーリング（T^-3/2）
- ✅ Zeff依存性
- ✅ 新古典補正（trapped particles）
- ✅ オーミック加熱パワー密度計算
- ✅ j²スケーリング検証
- ✅ ソース項への適用
- ✅ ポロイダル磁束からの電流密度計算
- ✅ 平坦磁束での電流ゼロ
- ✅ 入力検証エラー処理

**実装場所**: `/Tests/TORAXPhysicsTests/HeatingTests/OhmicHeatingTests.swift`

#### 3.2 `SauterBootstrapModelTests.swift` (15テスト)
- ✅ 初期化
- ✅ Trapped particle fraction計算
- ✅ Collisionality parameter計算
- ✅ Collisionalityスケーリング（n_e/T_e²）
- ✅ Bootstrap電流計算
- ✅ 全Bootstrap電流積分
- ✅ Bootstrap fraction計算
- ✅ Collisionality regime分類（banana/plateau/collisional）
- ✅ 勾配計算検証
- ✅ F31/F32関数の特性

**実装場所**: `/Tests/TORAXPhysicsTests/NeoclassicalTests/SauterBootstrapModelTests.swift`

---

### 4. **Geometry & Extensions Tests** (3ファイル、30+テストケース)

優先度: **低** ⭐

#### 4.1 `GeometryHelpersTests.swift` (15テスト)
- ✅ メッシュ設定からジオメトリ生成
- ✅ 円形ジオメトリ体積計算
- ✅ 半径グリッド生成
- ✅ セル中心計算
- ✅ g0幾何因子（円形: g0=r）
- ✅ g1幾何因子
- ✅ セル体積計算
- ✅ 面積分検証
- ✅ 安全因子プロファイル

**実装場所**: `/Tests/TORAXTests/Geometry/GeometryHelpersTests.swift`

#### 4.2 `CoreProfilesExtensionsTests.swift` (10テスト)
- ✅ Parabolicプロファイル生成
- ✅ Linearプロファイル生成
- ✅ Arrayプロファイル生成
- ✅ タプル抽出（Ti, Te, ne, psi）
- ✅ プロファイル正規化（keV, 10^20 m^-3）
- ✅ プロファイル積分

**実装場所**: `/Tests/TORAXTests/Extensions/CoreProfilesExtensionsTests.swift`

#### 4.3 `GeometryExtensionsTests.swift` (10テスト)
- ✅ アスペクト比計算
- ✅ 逆アスペクト比プロファイル
- ✅ ポロイダル磁場計算
- ✅ 全磁場計算
- ✅ 磁気シア計算
- ✅ ジオメトリスケーリング

**実装場所**: `/Tests/TORAXTests/Extensions/GeometryExtensionsTests.swift`

---

## 📋 実装優先順位

### フェーズ1: 最優先（1-2週間）
1. **Solver Module Tests** (8ファイル)
   - NewtonRaphsonSolver, LinearSolver, Block1DCoeffs系
   - 理由: シミュレーションコアの信頼性確保

### フェーズ2: 高優先（1週間）
2. **Configuration Module Tests** (5ファイル)
   - RuntimeParams, BoundaryConditions, ProfileConditions
   - 理由: パラメータ管理の正確性確保

### フェーズ3: 中優先（1週間）
3. **TORAXPhysics Module Tests** (2ファイル)
   - OhmicHeating, SauterBootstrapModel
   - 理由: 物理モデルの妥当性検証

### フェーズ4: 低優先（1週間）
4. **Geometry & Extensions Tests** (3ファイル)
   - GeometryHelpers, Extensions
   - 理由: 補助的機能の完全性確保

---

## 🛠 テスト実装ガイドライン

### テストフレームワーク
- **Swift Testing** (@Test, @Suite マクロ)
- **MLX-Swift** テンソル演算
- **Testing assertions**: `#expect()`, `#expect(throws:)`

### 命名規則
```swift
@Suite("ComponentName Tests")
struct ComponentNameTests {

    @Test("Feature description")
    func testFeatureName() {
        // Arrange
        let input = ...

        // Act
        let result = ...

        // Assert
        #expect(result == expected)
    }
}
```

### MLX配列の比較
```swift
// 浮動小数点近似比較
#expect(allClose(actual, expected, atol: 1e-6).item(Bool.self))

// 形状検証
#expect(array.shape == [10, 5])

// 範囲検証
#expect(array.min().item(Float.self) > 0)
```

### エラーハンドリング
```swift
// エラー発生の検証
#expect(throws: PhysicsError.self) {
    try model.compute(invalidInput)
}

// 特定エラー型の検証
#expect(throws: FlattenedState.FlattenedStateError.invalidCellCount) {
    try FlattenedState.StateLayout(nCells: -1)
}
```

### 物理量の検証
```swift
// スケーリング法則の検証
let ratio = (output2 / output1).item(Float.self)
let expected: Float = pow(inputRatio, exponent)
#expect(abs(ratio - expected) / expected < 0.1, "Should scale as x^n")

// 単調性の検証
let values = array.asArray(Float.self)
for i in 0..<(values.count-1) {
    #expect(values[i+1] >= values[i], "Should be monotonically increasing")
}
```

---

## 📊 テストカバレッジ目標

| モジュール | 現在のカバレッジ | 目標カバレッジ | 新規テスト数 |
|-----------|----------------|--------------|------------|
| Core | 90% | 95% | 5 |
| FVM | 80% | 95% | 10 |
| Solver | 10% | 90% | 80 |
| Configuration | 0% | 90% | 40 |
| Transport | 70% | 90% | 10 |
| TORAXPhysics | 40% | 85% | 30 |
| Geometry | 30% | 85% | 25 |
| Extensions | 0% | 80% | 20 |
| **全体** | **35%** | **88%** | **220** |

---

## ✅ 成功基準

### 機能的基準
- ✅ すべてのソルバーが既知の解析解で検証されている
- ✅ 物理モデルが文献値と一致（±10%以内）
- ✅ 境界条件が正しく適用されている
- ✅ 数値安定性が確認されている（CFL条件、収束性）

### 品質基準
- ✅ テストカバレッジ ≥ 88%
- ✅ すべてのpublicメソッドにテストが存在
- ✅ エラーケースが適切に処理されている
- ✅ エッジケース（ゼロ除算、空配列等）がカバーされている

### パフォーマンス基準
- ✅ 単体テストは1秒以内に完了
- ✅ テストスイート全体は10分以内に完了
- ✅ CI/CDパイプラインで自動実行可能

---

## 🚀 実装開始手順

### ステップ1: 環境準備
```bash
cd /Users/1amageek/Desktop/swift-TORAX

# ディレクトリ構造作成
mkdir -p Tests/TORAXTests/Solver
mkdir -p Tests/TORAXTests/Configuration
mkdir -p Tests/TORAXTests/Geometry
mkdir -p Tests/TORAXTests/Extensions
mkdir -p Tests/TORAXPhysicsTests/NeoclassicalTests
```

### ステップ2: フェーズ1実装
```bash
# EquationCoeffsTests.swift を作成
touch Tests/TORAXTests/Solver/EquationCoeffsTests.swift

# Block1DCoeffsTests.swift を作成
touch Tests/TORAXTests/Solver/Block1DCoeffsTests.swift

# ... 続く
```

### ステップ3: テスト実行
```bash
# 全テスト実行
swift test

# 特定モジュールのみ
swift test --filter TORAXTests

# 特定テストケースのみ
swift test --filter EquationCoeffsTests
```

### ステップ4: カバレッジ測定
```bash
# Xcodeでカバレッジ有効化
swift test --enable-code-coverage

# カバレッジレポート生成
xcrun llvm-cov report ...
```

---

## 📚 参考資料

### TORAX関連
- Original TORAX: https://github.com/google-deepmind/torax
- TORAX Paper: arXiv:2406.06718v2
- DeepWiki TORAX: https://deepwiki.com/google-deepmind/torax

### MLX-Swift
- MLX-Swift GitHub: https://github.com/ml-explore/mlx-swift
- DeepWiki MLX: https://deepwiki.com/ml-explore/mlx-swift
- MLX自動微分: https://ml-explore.github.io/mlx-swift/MLX/documentation/mlx/automatic-differentiation

### Swift Testing
- Swift Testing Documentation
- Swift 6 Concurrency Guide

---

## 📝 進捗トラッキング

### チェックリスト

#### フェーズ1: Solver Tests
- [ ] `EquationCoeffsTests.swift` (8テスト)
- [ ] `Block1DCoeffsTests.swift` (10テスト)
- [ ] `Block1DCoeffsBuilderTests.swift` (12テスト)
- [ ] `LinearSolverTests.swift` (10テスト)
- [ ] `NewtonRaphsonSolverTests.swift` (12テスト)
- [ ] `HybridLinearSolverTests.swift` (10テスト)
- [ ] `TimeStepCalculatorTests.swift` (10テスト)
- [ ] `SolverResultTests.swift` (6テスト)

#### フェーズ2: Configuration Tests
- [ ] `MeshConfigTests.swift` (8テスト)
- [ ] `BoundaryConditionsTests.swift` (10テスト)
- [ ] `ProfileConditionsTests.swift` (10テスト)
- [ ] `ParametersTests.swift` (8テスト)
- [ ] `RuntimeParamsTests.swift` (12テスト)

#### フェーズ3: Physics Tests
- [ ] `OhmicHeatingTests.swift` (15テスト)
- [ ] `SauterBootstrapModelTests.swift` (15テスト)

#### フェーズ4: Geometry & Extensions
- [ ] `GeometryHelpersTests.swift` (15テスト)
- [ ] `CoreProfilesExtensionsTests.swift` (10テスト)
- [ ] `GeometryExtensionsTests.swift` (10テスト)

---

## 🔧 CI/CD統合

### GitHub Actions設定例
```yaml
name: Swift Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: swift test --enable-code-coverage
      - name: Upload coverage
        uses: codecov/codecov-action@v3
```

### 自動化目標
- ✅ プルリクエストごとにテスト実行
- ✅ カバレッジレポート自動生成
- ✅ ビルド失敗時の通知
- ✅ パフォーマンス回帰検出

---

## 📞 サポート

### 質問・問題報告
- GitHub Issues: https://github.com/[username]/swift-TORAX/issues
- Discussions: フォーラムでのディスカッション

### コントリビューション
- テスト設計への提案歓迎
- 新規物理モデルのテストケース提供
- カバレッジ向上への貢献

---

**最終更新**: 2025-10-17
**ステータス**: 設計完了、実装準備完了
**次のアクション**: フェーズ1実装開始
