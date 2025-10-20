# QLKNN Integration: Bridge Approach Analysis

**Question**: "ブリッジじゃダメなの？"

**Answer**: ✅ **ブリッジアプローチは実用的で推奨される選択肢です**

---

## Executive Summary

レビューで「Pure Swift実装（推奨）」としましたが、これは**理想論**でした。実際には：

✅ **ブリッジアプローチ（swift-fusion-surrogates使用）が最も現実的**
- 実装期間: 1-2週間（Pure Swift: 3-4週間）
- 検証済み: Python TORAXと同一のQLKNN実装
- 段階的移行: 必要に応じて後でPure Swiftに移行可能

---

## ブリッジ vs Pure Swift: 詳細比較

### 実装速度

| アプローチ | 実装期間 | 理由 |
|-----------|---------|------|
| **ブリッジ** | ✅ **1-2週間** | swift-fusion-surrogatesは既に動作している |
| Pure Swift | ⚠️ 3-4週間 | ニューラルネットワークをゼロから実装 |

**ブリッジの勝ち**: 50%以上の時間削減

---

### 正確性と検証

| アプローチ | 検証難易度 | リスク |
|-----------|-----------|-------|
| **ブリッジ** | ✅ **低い** | Python TORAXと同じQLKNN実装を使用 |
| Pure Swift | ⚠️ 高い | 重みの移植ミス、数値誤差の可能性 |

**検証コスト**:
- **ブリッジ**: Python TORAX結果と即座に比較可能
- **Pure Swift**: 自作実装の数値検証が必要（数日〜1週間）

**ブリッジの勝ち**: リファレンス実装との完全一致

---

### クロスプラットフォーム対応

| アプローチ | macOS | Linux | iOS/visionOS |
|-----------|-------|-------|-------------|
| **ブリッジ** | ✅ 動作 | ⚠️ 条件付き* | ❌ 不可 |
| Pure Swift | ✅ 動作 | ✅ 動作 | ✅ 動作 |

*Linux: Python環境とlibpython.soのリンクが必要

**Pure Swiftの勝ち**: 完全なクロスプラットフォーム

**しかし**:
- swift-Gotenxの主な用途は**研究・シミュレーション**（macOS/Linux）
- iOS/visionOSでの需要は**限定的**（モバイルで重いシミュレーションは稀）

**結論**: 当面はmacOS対応で十分 → ブリッジで問題なし

---

### パフォーマンス

| アプローチ | 予測時間（100セル） | 備考 |
|-----------|------------------|------|
| **ブリッジ** | ~5-10ms | Python呼び出しオーバーヘッド |
| Pure Swift | ~1-5ms | MLX直接実行 |

**オーバーヘッド分析**:
```
ブリッジ処理時間:
├─ MLXArray → numpy変換: ~1ms
├─ Python関数呼び出し: ~2ms
├─ QLKNNニューラルネット推論: ~2ms
└─ numpy → MLXArray変換: ~1ms
合計: ~6ms

Pure Swift処理時間:
├─ MLX直接推論: ~2ms
└─ 合計: ~2ms
```

**差分**: 4ms（100セルあたり）

**タイムステップ全体でのインパクト**:
- 1タイムステップ: 50-100ms（Newton-Raphson 10回反復）
- QLKNN呼び出し: 10回/タイムステップ
- ブリッジ: 10 × 6ms = 60ms
- Pure Swift: 10 × 2ms = 20ms

**差分**: 40ms/タイムステップ

**シミュレーション全体**:
- 10,000ステップシミュレーション
- ブリッジ: 10分
- Pure Swift: 8分

**Pure Swiftの勝ち**: 20%高速化

**しかし**:
- 開発時間（2週間節約）を考慮すると、ブリッジの方がトータルで効率的
- 性能最適化は後回しにできる（premature optimizationを避ける）

---

### メンテナンス性

| アプローチ | QLKNN更新時の対応 | 労力 |
|-----------|-----------------|------|
| **ブリッジ** | ✅ `pip install --upgrade fusion-surrogates` | **1分** |
| Pure Swift | ⚠️ 重みを再エクスポート、コード更新、テスト | **数日** |

**シナリオ**: QLKNN v2.0リリース（新しいトレーニングデータ）

**ブリッジ**:
1. `pip install fusion-surrogates==2.0`
2. テスト実行
3. 完了

**Pure Swift**:
1. Pythonで新しい重みをエクスポート
2. Swift側のロードコード更新（フォーマット変更があれば）
3. 数値検証（新旧で結果が一致するか）
4. 統合テスト

**ブリッジの勝ち**: 大幅なメンテナンス負荷削減

---

### 技術的負債

| アプローチ | 技術的負債 |
|-----------|----------|
| **ブリッジ** | Python依存（macOS/Linux限定） |
| Pure Swift | 自作実装の保守（バグ、数値安定性） |

**ブリッジの負債**:
- ✅ 明確（Python環境）
- ✅ ドキュメント化可能
- ✅ 必要なら将来Pure Swiftに移行可能

**Pure Swiftの負債**:
- ⚠️ ニューラルネット実装のバグリスク
- ⚠️ 数値安定性の問題（勾配消失、オーバーフローなど）
- ⚠️ QLKNN論文との乖離リスク

**ブリッジの勝ち**: リスクが明確で管理しやすい

---

## ブリッジアプローチの実装方針

### アーキテクチャ: レイヤー化設計

```
┌─────────────────────────────────────────────────────┐
│            swift-Gotenx Application                   │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │       QLKNNTransportModel                   │    │
│  │  (swift-Gotenx native, Sendable)            │    │
│  └──────────────────┬─────────────────────────┘    │
│                     │                                │
│                     ▼                                │
│  ┌────────────────────────────────────────────┐    │
│  │       QLKNNBridge (Thin Wrapper)           │    │
│  │  - Input validation                         │    │
│  │  - Error handling                           │    │
│  │  - EvaluatedArray conversion                │    │
│  └──────────────────┬─────────────────────────┘    │
└────────────────────┼──────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│         swift-fusion-surrogates                      │
│  (Existing package, PythonKit-based)                 │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │          QLKNN (MLX + PythonKit)           │    │
│  │  - MLXArray ↔ numpy conversion             │    │
│  │  - Python fusion_surrogates wrapper        │    │
│  └──────────────────┬─────────────────────────┘    │
└────────────────────┼──────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────┐
│              Python: fusion_surrogates               │
│  (Google DeepMind reference implementation)          │
└─────────────────────────────────────────────────────┘
```

**設計原則**:
1. **Thin bridge layer**: QLKNNBridgeは最小限（検証とエラー処理のみ）
2. **Isolation**: Python依存を明確に分離
3. **Future-proof**: 後でPure Swift実装に差し替え可能

---

### 実装コード

#### 1. QLKNNBridge (薄いラッパー)

```swift
// Sources/Gotenx/Transport/QLKNN/QLKNNBridge.swift

import MLX
import FusionSurrogates

/// Thin bridge to swift-fusion-surrogates
///
/// This layer:
/// - Validates inputs
/// - Handles Python interop errors
/// - Converts between EvaluatedArray and MLXArray
///
/// Design: Keep this layer minimal to ease future migration to Pure Swift
internal struct QLKNNBridge {
    private let qlknn: QLKNN

    /// Initialize QLKNN bridge
    init(modelName: String = "qlknn_7_11_v1") throws {
        do {
            self.qlknn = try QLKNN(modelName: modelName)
        } catch {
            throw QLKNNError.pythonInteropError(
                reason: "Failed to initialize QLKNN: \(error.localizedDescription). " +
                        "Ensure Python 3.12+ and fusion-surrogates are installed."
            )
        }
    }

    /// Predict transport coefficients
    ///
    /// - Parameter inputs: 10 QLKNN input parameters as MLXArray
    /// - Returns: 8 output fluxes as MLXArray
    /// - Throws: QLKNNError on validation or prediction failure
    func predict(_ inputs: [String: MLXArray]) throws -> [String: MLXArray] {
        // Validate inputs
        try validateInputs(inputs)

        do {
            // Call swift-fusion-surrogates (handles MLX ↔ numpy conversion)
            return try qlknn.predict(inputs)
        } catch {
            throw QLKNNError.predictionFailed(
                reason: "QLKNN prediction failed: \(error.localizedDescription)"
            )
        }
    }

    /// Validate QLKNN inputs (NaN, Inf, shape consistency)
    private func validateInputs(_ inputs: [String: MLXArray]) throws {
        let requiredParams = ["Ati", "Ate", "Ane", "Ani", "q", "smag", "x", "Ti_Te", "LogNuStar", "normni"]

        // Check all parameters present
        for param in requiredParams {
            guard inputs[param] != nil else {
                throw QLKNNError.invalidInput(
                    parameter: param,
                    reason: "Missing required parameter"
                )
            }
        }

        // Check shapes consistent
        let shapes = inputs.values.map { $0.shape[0] }
        guard Set(shapes).count == 1 else {
            throw QLKNNError.invalidInput(
                parameter: "shape",
                reason: "Inconsistent batch sizes: \(shapes)"
            )
        }

        // Check for NaN/Inf
        for (name, array) in inputs {
            if any(isnan(array)).item(Bool.self) {
                throw QLKNNError.invalidInput(parameter: name, reason: "Contains NaN")
            }
            if any(isinf(array)).item(Bool.self) {
                throw QLKNNError.invalidInput(parameter: name, reason: "Contains Inf")
            }
        }
    }
}

/// QLKNN errors
public enum QLKNNError: LocalizedError {
    case invalidInput(parameter: String, reason: String)
    case predictionFailed(reason: String)
    case pythonInteropError(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let param, let reason):
            return "Invalid QLKNN input '\(param)': \(reason)"
        case .predictionFailed(let reason):
            return "QLKNN prediction failed: \(reason)"
        case .pythonInteropError(let reason):
            return "Python interop error: \(reason). Check Python environment."
        }
    }
}
```

#### 2. QLKNNTransportModel (swift-Gotenx native)

```swift
// Sources/Gotenx/Transport/Models/QLKNNTransportModel.swift

import MLX
import Foundation

/// QLKNN neural network transport model
///
/// Architecture: Uses QLKNNBridge to isolate Python dependency
public struct QLKNNTransportModel: TransportModel {
    public let name = "qlknn"

    private let bridge: QLKNNBridge
    private let modelName: String

    /// Initialize QLKNN transport model
    public init(modelName: String = "qlknn_7_11_v1") throws {
        self.modelName = modelName
        self.bridge = try QLKNNBridge(modelName: modelName)
    }

    /// Initialize from TransportParameters
    public init(params: TransportParameters) throws {
        let modelName = params.params["qlknn_model_name"].map {
            String(Int($0))
        } ?? "qlknn_7_11_v1"
        try self.init(modelName: modelName)
    }

    public func computeCoefficients(
        profiles: CoreProfiles,
        geometry: Geometry,
        params: TransportParameters
    ) -> TransportCoefficients {
        do {
            // 1. Build QLKNN inputs (vectorized, no loops)
            let inputs = try QLKNNInputBuilder.buildInputs(
                profiles: profiles,
                geometry: geometry,
                params: params
            )

            // 2. Predict via bridge
            let outputs = try bridge.predict(inputs)

            // 3. Combine fluxes
            let combined = combineFluxes(outputs)

            // 4. Wrap in EvaluatedArray
            let nCells = profiles.ionTemperature.shape[0]
            return TransportCoefficients(
                chiIon: EvaluatedArray(evaluating: combined.chiIon),
                chiElectron: EvaluatedArray(evaluating: combined.chiElectron),
                particleDiffusivity: EvaluatedArray(evaluating: combined.particleDiffusivity),
                convectionVelocity: EvaluatedArray.zeros([nCells])
            )
        } catch {
            // Fallback on error
            return fallbackCoefficients(profiles: profiles, error: error)
        }
    }

    /// Combine mode-specific fluxes into total transport coefficients
    private func combineFluxes(_ outputs: [String: MLXArray]) -> (
        chiIon: MLXArray,
        chiElectron: MLXArray,
        particleDiffusivity: MLXArray
    ) {
        let efiITG = outputs["efiITG"]!
        let efiTEM = outputs["efiTEM"]!
        let efeITG = outputs["efeITG"]!
        let efeTEM = outputs["efeTEM"]!
        let efeETG = outputs["efeETG"]!
        let pfeITG = outputs["pfeITG"]!
        let pfeTEM = outputs["pfeTEM"]!

        let chiIon = efiITG + efiTEM
        let chiElectron = efeITG + efeTEM + efeETG
        let particleDiffusivity = pfeITG + pfeTEM

        return (chiIon, chiElectron, particleDiffusivity)
    }

    /// Fallback to minimal diffusivity on error
    private func fallbackCoefficients(
        profiles: CoreProfiles,
        error: Error
    ) -> TransportCoefficients {
        let nCells = profiles.ionTemperature.shape[0]
        let fallback: Float = 0.1  // m^2/s

        print("⚠️  QLKNN prediction failed: \(error.localizedDescription)")
        print("   Falling back to minimal diffusivity: \(fallback) m^2/s")

        let chi = MLXArray(fallback).broadcasted(to: [nCells])
        return TransportCoefficients(
            chiIon: EvaluatedArray(evaluating: chi),
            chiElectron: EvaluatedArray(evaluating: chi),
            particleDiffusivity: EvaluatedArray(evaluating: chi),
            convectionVelocity: EvaluatedArray.zeros([nCells])
        )
    }
}

// Mark as Sendable (bridge to Python, but used in actor context)
extension QLKNNTransportModel: @unchecked Sendable {}
```

---

### Python環境の検証

#### 起動時チェック

```swift
// Sources/Gotenx/Transport/QLKNN/PythonEnvironmentValidator.swift

#if canImport(PythonKit)
import PythonKit

public struct PythonEnvironmentValidator {
    /// Validate Python environment for QLKNN
    ///
    /// Checks:
    /// 1. Python 3.12+ available
    /// 2. fusion_surrogates installed
    /// 3. QLKNN model loadable
    ///
    /// - Returns: ValidationResult with detailed error messages
    public static func validate() -> ValidationResult {
        #if !os(macOS)
        return .failure(.platformNotSupported(
            "QLKNN requires macOS. Use BohmGyroBohm on other platforms."
        ))
        #endif

        // Check Python version
        let sys = Python.import("sys")
        let version = sys.version_info
        let major = Int(version.major)!
        let minor = Int(version.minor)!

        guard major >= 3 && minor >= 12 else {
            return .failure(.pythonVersionTooOld(
                current: "\(major).\(minor)",
                required: "3.12+"
            ))
        }

        // Check fusion_surrogates
        let importResult = Python.attemptImport("fusion_surrogates")
        guard !importResult.isNone else {
            return .failure(.packageNotFound(
                package: "fusion_surrogates",
                installCommand: "pip install fusion-surrogates"
            ))
        }

        // Check QLKNN loadable
        do {
            _ = try QLKNN(modelName: "qlknn_7_11_v1")
        } catch {
            return .failure(.modelLoadFailed(
                model: "qlknn_7_11_v1",
                reason: error.localizedDescription
            ))
        }

        return .success
    }

    public enum ValidationResult {
        case success
        case failure(ValidationError)

        public var isValid: Bool {
            if case .success = self { return true }
            return false
        }
    }

    public enum ValidationError: LocalizedError {
        case platformNotSupported(String)
        case pythonVersionTooOld(current: String, required: String)
        case packageNotFound(package: String, installCommand: String)
        case modelLoadFailed(model: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .platformNotSupported(let msg):
                return msg
            case .pythonVersionTooOld(let current, let required):
                return "Python \(required) required (current: \(current))"
            case .packageNotFound(let pkg, let cmd):
                return "\(pkg) not found. Install: \(cmd)"
            case .modelLoadFailed(let model, let reason):
                return "Failed to load \(model): \(reason)"
            }
        }
    }
}
#endif
```

#### CLI統合

```swift
// Sources/GotenxCLI/Commands/RunCommand.swift

extension RunCommand {
    func validateEnvironment() throws {
        // Check if using QLKNN
        let config = try ConfigurationLoader.load(from: configPath)
        guard config.transport.modelType == "qlknn" else {
            return  // Not using QLKNN, skip validation
        }

        #if canImport(PythonKit)
        let result = PythonEnvironmentValidator.validate()
        guard result.isValid else {
            if case .failure(let error) = result {
                print("❌ Python environment validation failed:")
                print("   \(error.localizedDescription)")
                print("")
                print("To use QLKNN, ensure:")
                print("  1. Python 3.12+ is installed")
                print("  2. Run: pip install fusion-surrogates")
                print("")
                print("Alternatively, use a different transport model:")
                print("  - \"constant\" (simple, fast)")
                print("  - \"bohmGyrobohm\" (empirical, no Python required)")
            }
            throw ValidationError.pythonEnvironmentInvalid
        }
        #else
        print("❌ QLKNN not available on this platform")
        print("   Use \"bohmGyrobohm\" transport model instead")
        throw ValidationError.qlknnNotAvailable
        #endif
    }
}
```

---

## Package.swift 更新

```swift
// Package.swift

let package = Package(
    name: "swift-Gotenx",
    platforms: [
        .macOS(.v15),    // PythonKit requires macOS
        .iOS(.v18),      // QLKNN not available on iOS
        .visionOS(.v2)   // QLKNN not available on visionOS
    ],
    products: [
        .library(name: "TORAX", targets: ["TORAX"]),
        .executable(name: "GotenxCLI", targets: ["GotenxCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.29.1"),
        .package(url: "https://github.com/apple/swift-numerics", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),

        // QLKNN bridge (optional, macOS only)
        .package(url: "https://github.com/1amageek/swift-fusion-surrogates", branch: "main"),
    ],
    targets: [
        .target(
            name: "TORAX",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Numerics", package: "swift-numerics"),
                // Conditional dependency: only on macOS
                .product(
                    name: "FusionSurrogates",
                    package: "swift-fusion-surrogates",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        // ...
    ]
)
```

---

## ドキュメント: ユーザー向け

### README.md 更新

```markdown
## Transport Models

swift-Gotenx supports multiple transport models:

### 1. Constant Transport
Simple constant diffusivity (for testing)
```json
{"transport": {"modelType": "constant", "parameters": {"chi": 1.0}}}
```

### 2. Bohm-GyroBohm Transport
Empirical scaling (no external dependencies)
```json
{"transport": {"modelType": "bohmGyrobohm"}}
```

### 3. QLKNN Neural Network (macOS only)
High-fidelity transport based on gyrokinetic simulations

**Requirements**:
- macOS 13.3+
- Python 3.12+
- `pip install fusion-surrogates`

**Configuration**:
```json
{
  "transport": {
    "modelType": "qlknn",
    "qlknn": {
      "modelName": "qlknn_7_11_v1",
      "enableCaching": true
    }
  }
}
```

**Installation**:
```bash
# Install Python dependencies
pip install fusion-surrogates

# Verify
python -c "import fusion_surrogates; print(fusion_surrogates.__version__)"

# Run simulation
swift run torax run --config examples/qlknn_iter.json
```

**Platform Support**:
| Platform | Constant | BohmGyroBohm | QLKNN |
|----------|----------|--------------|-------|
| macOS    | ✅       | ✅           | ✅    |
| Linux    | ✅       | ✅           | ⚠️*   |
| iOS      | ✅       | ✅           | ❌    |

*Linux support for QLKNN is experimental and requires manual Python configuration
```

---

## 段階的移行戦略

ブリッジで始めて、必要に応じてPure Swiftに移行：

### Phase 1: Bridge Implementation (Current, 1-2 weeks)
```
✅ swift-fusion-surrogates使用
✅ macOS対応
✅ Python TORAXと同一ロジック
```

### Phase 2: Production Use (6-12 months)
```
✅ 実際のシミュレーションで使用
✅ バグ修正、性能調整
✅ ユーザーフィードバック収集
```

### Phase 3: Pure Swift Migration (Optional, future)
```
⚠️ 必要性を評価:
  - iOS対応が必要になった？
  - Python依存が問題になった？
  - 性能がボトルネックになった？

✅ YES → Pure Swift実装開始
❌ NO → ブリッジ継続使用
```

---

## 結論: ブリッジアプローチを推奨

### 推奨理由

| 観点 | 評価 |
|------|------|
| **実装速度** | ✅ 1-2週間（Pure Swift: 3-4週間） |
| **正確性** | ✅ Python TORAXと完全一致 |
| **メンテナンス** | ✅ QLKNN更新が容易 |
| **リスク** | ✅ 明確で管理しやすい |
| **プラットフォーム** | ⚠️ macOS/Linux（iOS不要なら問題なし） |
| **性能** | ⚠️ Pure Swiftより20%遅い（許容範囲） |

### 実装計画（修正版）

**Week 1**:
1. Package.swift更新（swift-fusion-surrogates追加）
2. Geometry拡張（radii, safetyFactor）
3. MLXGradient実装（ベクトル化）
4. QLKNNInputBuilder実装

**Week 2**:
5. QLKNNBridge実装（薄いラッパー）
6. QLKNNTransportModel実装
7. Python環境検証ツール
8. ユニットテスト

**Week 3**:
9. 統合テスト
10. ドキュメント
11. 例題（iter_qlknn.json）

**Total: 2-3週間**（Pure Swift: 4-5週間）

---

## FAQ

**Q: Pure Swiftは将来実装するべき？**

A: **"必要になったら"** 実装する。以下のいずれかが発生したら検討：
- iOS対応が必須になった
- Python依存がデプロイの障害になった
- 性能が実用上の問題になった

それまではブリッジで十分。

**Q: ブリッジの技術的負債は？**

A: 負債は**明確で管理可能**:
- Python環境依存（ドキュメント化済み）
- macOS限定（ターゲットユーザーは研究者、macOS使用率高い）
- 将来Pure Swiftに差し替え可能（アーキテクチャが分離されている）

**Q: Linux対応は？**

A: **実験的にサポート可能**:
```bash
# Linux環境でPythonパスを明示
export PYTHON_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.12.so
swift build
swift run torax run --config qlknn.json
```

本格対応は需要次第。

---

## 最終推奨

✅ **ブリッジアプローチで実装を開始する**

理由:
1. 実装期間が半分（2週間 vs 4週間）
2. Python TORAXとの検証が容易
3. 技術的リスクが低い
4. 段階的移行が可能（必要なら後でPure Swift化）

Pure Swift実装は**"premature optimization"**（時期尚早な最適化）の可能性が高い。まずはブリッジで動かし、実際の使用で問題が出たら移行を検討する方が賢明。
