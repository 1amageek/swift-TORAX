# Phase 5-7 Implementation Plan

**Date**: 2025-10-20
**Version**: 1.0
**Status**: 📋 Planning

---

## Executive Summary

This document outlines the implementation plan for three critical features that bridge swift-Gotenx from a research-grade 1D transport simulator to an ITER-compatible integrated modeling tool:

1. **Phase 5: IMAS-Compatible I/O** (1-2 months)
2. **Phase 6: Experimental Data Cross-Validation** (1 month)
3. **Phase 7: Automatic Differentiation Workflow** (4-6 months)

These phases align with requirements from TORAX (arXiv:2406.06718v2), RAPTOR, and JINTRAC literature, enabling:
- ✅ Integration with ITER modeling framework
- ✅ Validation against experimental tokamak data
- ✅ Optimization and control applications

---

## Table of Contents

1. [Phase 5: IMAS-Compatible I/O](#phase-5-imas-compatible-io)
2. [Phase 6: Experimental Data Cross-Validation](#phase-6-experimental-data-cross-validation)
3. [Phase 7: Automatic Differentiation Workflow](#phase-7-automatic-differentiation-workflow)
4. [Cross-Phase Dependencies](#cross-phase-dependencies)
5. [Resource Requirements](#resource-requirements)
6. [Risk Assessment](#risk-assessment)

---

## Phase 5: IMAS-Compatible I/O

### Overview

**Goal**: Enable swift-Gotenx to read/write IMAS-compatible data structures via CF-1.8 compliant NetCDF-4 files.

**Priority**: P0 (Highest - enables ecosystem integration)

**Duration**: 1-2 months

**References**:
- ITER IMAS Documentation: https://imas.iter.org/
- CF Conventions 1.8: http://cfconventions.org/
- NetCDF-4: https://www.unidata.ucar.edu/software/netcdf/

### Requirements

#### R5.1: IMAS Schema Compliance

**Must Support**:
```
core_profiles/
  ├── profiles_1d/
  │   ├── grid/
  │   │   ├── rho_tor_norm [dimensionless]
  │   │   └── volume [m³]
  │   ├── electrons/
  │   │   ├── density [m⁻³]
  │   │   └── temperature [eV]
  │   ├── ion[]/
  │   │   ├── density [m⁻³]
  │   │   └── temperature [eV]
  │   └── time [s]
  ├── global_quantities/
  │   ├── energy_thermal [J]
  │   ├── current_plasma [A]
  │   └── ip [A]
  └── vacuum_toroidal_field/
      └── b0 [T]
```

#### R5.2: CF-1.8 Metadata

All variables must include:
- `long_name`: Human-readable description
- `units`: CF-compliant unit string
- `standard_name`: CF standard name (where applicable)
- `valid_min`, `valid_max`: Physical bounds

#### R5.3: Compression and Chunking

- Level 4 DEFLATE compression
- Optimal chunking for time-series access
- Target: 10× size reduction from uncompressed

#### R5.4: Backwards Compatibility

- Maintain existing JSON output (for debugging)
- Provide conversion utilities (JSON ↔ NetCDF)

### Architecture Design

#### File Structure

```
Sources/Gotenx/IO/
├── NetCDF/
│   ├── IMASWriter.swift          # IMAS-compliant NetCDF writer
│   ├── IMASReader.swift          # IMAS-compliant NetCDF reader
│   ├── IMASSchema.swift          # IMAS data structure definitions
│   └── CFMetadata.swift          # CF-1.8 metadata builders
├── Conversion/
│   ├── JSONToNetCDF.swift        # JSON → NetCDF converter
│   └── NetCDFToJSON.swift        # NetCDF → JSON converter
└── Validation/
    ├── IMASValidator.swift       # Schema compliance checker
    └── CFValidator.swift         # CF conventions checker
```

#### Data Model

```swift
/// IMAS core_profiles data structure
public struct IMASCoreProfiles: Sendable, Codable {
    /// 1D profiles on normalized toroidal flux grid
    public struct Profiles1D: Sendable, Codable {
        /// Grid definition
        public struct Grid: Sendable, Codable {
            public let rho_tor_norm: [Float]  // Normalized toroidal flux √(Φ/Φ_edge)
            public let volume: [Float]        // Cumulative volume [m³]
            public let area: [Float]          // Cross-sectional area [m²]
        }

        /// Electron profiles
        public struct Electrons: Sendable, Codable {
            public let density: [Float]      // [m⁻³]
            public let temperature: [Float]  // [eV]
            public let pressure: [Float]     // [Pa]
        }

        /// Ion species profiles
        public struct Ion: Sendable, Codable {
            public let label: String         // Species name (e.g., "D", "T")
            public let z_ion: Float          // Charge number
            public let a_ion: Float          // Mass number
            public let density: [Float]      // [m⁻³]
            public let temperature: [Float]  // [eV]
            public let pressure: [Float]     // [Pa]
        }

        public let grid: Grid
        public let electrons: Electrons
        public let ion: [Ion]
        public let time: Float  // [s]
    }

    /// Global quantities (volume-integrated)
    public struct GlobalQuantities: Sendable, Codable {
        public let energy_thermal: Float  // [J]
        public let current_plasma: Float  // [A]
        public let ip: Float              // Plasma current [A]
        public let beta_tor: Float        // Toroidal beta
        public let beta_pol: Float        // Poloidal beta
        public let beta_n: Float          // Normalized beta
    }

    public let profiles_1d: [Profiles1D]  // Time-series of profiles
    public let global_quantities: GlobalQuantities
    public let vacuum_toroidal_field: VacuumToroidalField
}
```

#### NetCDF-C Integration

Use Swift Package Manager to integrate NetCDF-C:

```swift
// Package.swift
.target(
    name: "Gotenx",
    dependencies: [
        .product(name: "NetCDF", package: "swift-netcdf")
    ]
)
```

**Note**: May need to create `swift-netcdf` wrapper around NetCDF-C library.

### Implementation Steps

#### Step 5.1: NetCDF-C PoC + 技術検証（Week 1-2）

**目的**: NetCDF-C の Swift ラッパ実現可能性を早期検証し、技術的リスクを顕在化

**Week 1: 最小限の PoC（Proof of Concept）**

1. **systemLibrary target 作成**:
   ```swift
   // Package.swift
   .systemLibrary(
       name: "CNetCDF",
       pkgConfig: "netcdf",
       providers: [
           .brew(["netcdf"]),
           .apt(["libnetcdf-dev"])
       ]
   )
   ```

2. **最小限の Swift wrapper**:
   ```swift
   // Sources/CNetCDFWrapper/NetCDFFile.swift
   public final class NetCDFFile {
       private var ncid: Int32

       public init(path: String, mode: Mode) throws {
           var ncid: Int32 = 0
           let status = nc_create(path, NC_NETCDF4, &ncid)
           guard status == NC_NOERR else {
               throw NetCDFError.createFailed(code: status)
           }
           self.ncid = ncid
       }

       public func close() throws {
           let status = nc_close(ncid)
           guard status == NC_NOERR else {
               throw NetCDFError.closeFailed(code: status)
           }
       }
   }
   ```

3. **単一変数（温度）の書き込みテスト**:
   ```swift
   @Test("PoC: Write single variable to NetCDF")
   func testMinimalNetCDFWrite() throws {
       let file = try NetCDFFile(path: "/tmp/poc_test.nc", mode: .create)

       // Dimensions
       let timeDim = try file.createDimension(name: "time", size: 5)
       let rhoDim = try file.createDimension(name: "rho_tor_norm", size: 10)

       // Variable: electron temperature
       let teVar = try file.createVariable(
           name: "electrons_temperature",
           dimensions: [timeDim, rhoDim],
           type: Float.self
       )

       // CF-1.8 metadata
       try file.putAttribute(varid: teVar, name: "long_name", value: "Electron temperature")
       try file.putAttribute(varid: teVar, name: "units", value: "eV")
       try file.putAttribute(varid: teVar, name: "standard_name", value: "electron_temperature")

       // Write data
       let data: [Float] = Array(repeating: 1000.0, count: 50)  // 5×10
       try file.putVariable(varid: teVar, data: data)

       try file.close()

       // Verify with ncdump
       let process = Process()
       process.executableURL = URL(fileURLWithPath: "/usr/bin/ncdump")
       process.arguments = ["-h", "/tmp/poc_test.nc"]
       try process.run()
       process.waitUntilExit()

       #expect(process.terminationStatus == 0, "ncdump should succeed")
   }
   ```

4. **CF-1.8 準拠チェック**:
   ```bash
   # Week 1 終了時に実行
   cfchecks /tmp/poc_test.nc

   # 期待結果:
   # ✅ CF-1.8 compliant
   # ✅ No errors
   ```

**判断基準（Week 1 終了時）**:
- ✅ NetCDF-C ライブラリがビルド可能
- ✅ 基本的なファイル作成・書き込み・クローズが動作
- ✅ cf-checker がエラーなしで通過
- ❌ 上記が失敗 → 代替案検討（純Swift NetCDF実装、または出力形式変更）

**Week 2: 複数変数 + 圧縮性能検証**

1. **IMAS core_profiles の主要変数を実装**:
   ```swift
   @Test("Write IMAS core_profiles structure")
   func testIMASCoreProfiles() throws {
       let file = try NetCDFFile(path: "/tmp/imas_test.nc", mode: .create)

       // Dimensions
       let timeDim = try file.createDimension(name: "time", size: 100)
       let rhoDim = try file.createDimension(name: "rho_tor_norm", size: 100)

       // Variables: Ti, Te, ne, psi
       let vars = [
           ("ion_temperature", "Ion temperature", "eV"),
           ("electron_temperature", "Electron temperature", "eV"),
           ("electron_density", "Electron density", "m-3"),
           ("poloidal_flux", "Poloidal flux", "Wb")
       ]

       for (name, longName, units) in vars {
           let varid = try file.createVariable(
               name: name,
               dimensions: [timeDim, rhoDim],
               type: Float.self
           )
           try file.putAttribute(varid: varid, name: "long_name", value: longName)
           try file.putAttribute(varid: varid, name: "units", value: units)

           // Write dummy data
           let data: [Float] = Array(repeating: 1000.0, count: 10000)
           try file.putVariable(varid: varid, data: data)
       }

       try file.close()
   }
   ```

2. **DEFLATE 圧縮の効果測定**:
   ```swift
   @Test("Measure compression ratio")
   func testCompressionRatio() throws {
       // Uncompressed
       let file1 = try NetCDFFile(path: "/tmp/uncompressed.nc", mode: .create)
       try writeTestData(to: file1, compression: .none)
       try file1.close()
       let size1 = try FileManager.default.attributesOfItem(atPath: "/tmp/uncompressed.nc")[.size] as! Int

       // Compressed (DEFLATE level 4)
       let file2 = try NetCDFFile(path: "/tmp/compressed.nc", mode: .create)
       try writeTestData(to: file2, compression: .deflate(level: 4))
       try file2.close()
       let size2 = try FileManager.default.attributesOfItem(atPath: "/tmp/compressed.nc")[.size] as! Int

       let ratio = Double(size1) / Double(size2)
       print("Compression ratio: \(ratio)×")

       // 期待: 10× 削減
       #expect(ratio > 8.0, "Compression ratio should be > 8×")
   }
   ```

**判断基準（Week 2 終了時）**:
- ✅ 複数変数の同時書き込みが動作
- ✅ DEFLATE圧縮で 8× 以上の削減達成
- ✅ CF-1.8 メタデータが正しく保存される
- ⚠️ 圧縮率が不足（< 8×）→ chunking パラメータ調整
- ❌ パフォーマンス問題（> 10秒/ファイル）→ バッチ書き込み検討

**Week 1-2 のリスク対応**:
| リスク | 発生確率 | 対応策 |
|--------|---------|--------|
| NetCDF-C ビルド失敗 | 低 | Homebrew/apt でインストール済み環境で検証 |
| C-Swift 相互運用の問題 | 中 | MLX-Swift の C++ wrapper を参考に実装 |
| メモリリーク | 中 | Instruments で leak detection |
| 圧縮率不足 | 中 | chunking サイズ調整、DEFLATE level 変更 |

#### Step 5.2: IMAS Schema Implementation (Week 2-3)

1. **Define IMAS data structures** (as shown in Architecture Design)

2. **Implement CF metadata builders**:
   ```swift
   // Sources/Gotenx/IO/NetCDF/CFMetadata.swift
   public struct CFMetadata {
       public static func forElectronDensity() -> [String: String] {
           [
               "long_name": "Electron density",
               "units": "m-3",
               "standard_name": "electron_number_density",
               "valid_min": "0.0",
               "valid_max": "1e22"
           ]
       }

       public static func forElectronTemperature() -> [String: String] {
           [
               "long_name": "Electron temperature",
               "units": "eV",
               "standard_name": "electron_temperature",
               "valid_min": "0.0",
               "valid_max": "100000.0"
           ]
       }

       // ... more metadata builders
   }
   ```

3. **Implement IMAS coordinate system**:
   ```swift
   // Sources/Gotenx/IO/NetCDF/IMASGrid.swift
   public struct IMASGrid {
       /// Convert Gotenx radial coordinate to IMAS rho_tor_norm
       public static func toRhoTorNorm(
           radii: [Float],
           geometry: Geometry
       ) -> [Float] {
           // rho_tor_norm = r / a
           radii.map { $0 / geometry.minorRadius }
       }

       /// Compute cumulative volume for IMAS grid
       public static func computeCumulativeVolume(
           geometry: Geometry
       ) -> [Float] {
           let volumes = GeometricFactors.from(geometry: geometry).cellVolumes.value.asArray(Float.self)
           var cumulative: [Float] = []
           var sum: Float = 0.0
           for vol in volumes {
               sum += vol
               cumulative.append(sum)
           }
           return cumulative
       }
   }
   ```

#### Step 5.3: IMASWriter Implementation (Week 3-4)

```swift
// Sources/Gotenx/IO/NetCDF/IMASWriter.swift
public final class IMASWriter {
    private let file: NetCDFFile
    private let compressionLevel: Int

    public init(path: String, compressionLevel: Int = 4) throws {
        self.file = try NetCDFFile(path: path, mode: .create)
        self.compressionLevel = compressionLevel
    }

    /// Write complete simulation result to IMAS-compatible NetCDF
    public func write(_ result: SimulationResult) throws {
        // 1. Create dimensions
        let nCells = result.geometry.nCells
        let nTime = result.states.count

        let rhoTorDim = try file.createDimension(name: "rho_tor_norm", size: nCells)
        let timeDim = try file.createDimension(name: "time", size: nTime)

        // 2. Create coordinate variables
        let rhoTorVar = try file.createVariable(
            name: "rho_tor_norm",
            dimensions: [rhoTorDim],
            type: Float.self
        )
        try file.putAttributes(varid: rhoTorVar, metadata: [
            "long_name": "Normalized toroidal flux coordinate",
            "units": "1",
            "axis": "X"
        ])

        let timeVar = try file.createVariable(
            name: "time",
            dimensions: [timeDim],
            type: Float.self
        )
        try file.putAttributes(varid: timeVar, metadata: [
            "long_name": "Time",
            "units": "s",
            "axis": "T"
        ])

        // 3. Create profile variables
        let neVar = try file.createVariable(
            name: "electrons/density",
            dimensions: [timeDim, rhoTorDim],
            type: Float.self
        )
        try file.setCompression(varid: neVar, level: compressionLevel)
        try file.setChunking(varid: neVar, chunks: [1, nCells])  // Optimize for time-series access
        try file.putAttributes(varid: neVar, metadata: CFMetadata.forElectronDensity())

        // 4. Write data
        let rhoTorNorm = IMASGrid.toRhoTorNorm(
            radii: result.geometry.radii.value.asArray(Float.self),
            geometry: result.geometry
        )
        try file.putData(varid: rhoTorVar, data: rhoTorNorm)

        let times = result.states.map { $0.time }
        try file.putData(varid: timeVar, data: times)

        // Write 2D array (time × rho_tor_norm)
        let neData = result.states.map { state in
            state.coreProfiles.electronDensity.value.asArray(Float.self)
        }
        try file.putData(varid: neVar, data: neData.flatMap { $0 })

        // 5. Write global attributes
        try file.putGlobalAttribute(name: "Conventions", value: "CF-1.8, IMAS-3.0")
        try file.putGlobalAttribute(name: "title", value: "Gotenx simulation output")
        try file.putGlobalAttribute(name: "source", value: "swift-Gotenx v0.1.0")
        try file.putGlobalAttribute(name: "history", value: "\(Date()): Created by IMASWriter")
    }

    public func close() throws {
        try file.close()
    }
}
```

#### Step 5.4: IMASReader Implementation (Week 4-5)

```swift
// Sources/Gotenx/IO/NetCDF/IMASReader.swift
public final class IMASReader {
    private let file: NetCDFFile

    public init(path: String) throws {
        self.file = try NetCDFFile(path: path, mode: .read)
    }

    /// Read IMAS core_profiles from NetCDF
    public func readCoreProfiles() throws -> IMASCoreProfiles {
        // 1. Read dimensions
        let nCells = try file.getDimensionSize(name: "rho_tor_norm")
        let nTime = try file.getDimensionSize(name: "time")

        // 2. Read coordinate variables
        let rhoTorNorm: [Float] = try file.getData(varname: "rho_tor_norm")
        let times: [Float] = try file.getData(varname: "time")

        // 3. Read profile variables
        let neData: [Float] = try file.getData(varname: "electrons/density")
        let teData: [Float] = try file.getData(varname: "electrons/temperature")

        // 4. Reshape 2D arrays → [time][rho]
        let ne2D = stride(from: 0, to: nTime, by: 1).map { t in
            Array(neData[(t*nCells)..<((t+1)*nCells)])
        }
        let te2D = stride(from: 0, to: nTime, by: 1).map { t in
            Array(teData[(t*nCells)..<((t+1)*nCells)])
        }

        // 5. Construct IMAS data structure
        let profiles1D = zip(times, zip(ne2D, te2D)).map { (time, profiles) in
            IMASCoreProfiles.Profiles1D(
                grid: IMASCoreProfiles.Profiles1D.Grid(
                    rho_tor_norm: rhoTorNorm,
                    volume: try file.getData(varname: "grid/volume"),
                    area: try file.getData(varname: "grid/area")
                ),
                electrons: IMASCoreProfiles.Profiles1D.Electrons(
                    density: profiles.0,
                    temperature: profiles.1,
                    pressure: zip(profiles.0, profiles.1).map { $0 * $1 * 1.602176634e-19 }
                ),
                ion: [], // TODO: Read ion species
                time: time
            )
        }

        return IMASCoreProfiles(
            profiles_1d: profiles1D,
            global_quantities: try readGlobalQuantities(),
            vacuum_toroidal_field: try readVacuumToroidalField()
        )
    }

    public func close() throws {
        try file.close()
    }
}
```

#### Step 5.5: Integration with OutputWriter (Week 5-6)

Extend existing `OutputWriter` to support NetCDF:

```swift
// Sources/Gotenx/Output/OutputWriter.swift (existing file)
extension OutputWriter {
    /// Write simulation result in IMAS-compatible NetCDF format
    public static func writeIMASNetCDF(
        _ result: SimulationResult,
        outputDir: String,
        compressionLevel: Int = 4
    ) throws {
        let outputPath = "\(outputDir)/gotenx_imas.nc"

        let writer = try IMASWriter(path: outputPath, compressionLevel: compressionLevel)
        defer { try? writer.close() }

        try writer.write(result)

        print("✅ IMAS NetCDF output written to: \(outputPath)")
        print("   Format: CF-1.8 compliant NetCDF-4")
        print("   Compression: Level \(compressionLevel)")
    }
}
```

#### Step 5.6: CLI Integration (Week 6)

Update `RunCommand` to support NetCDF output:

```swift
// Sources/GotenxCLI/Commands/RunCommand.swift
@Option(name: .long, help: "Output format (json|netcdf|imas)")
var outputFormat: String = "json"

mutating func run() async throws {
    // ... existing simulation code ...

    // Write output
    switch outputFormat {
    case "json":
        try OutputWriter.writeJSON(result, outputDir: outputDir)
    case "netcdf":
        try OutputWriter.writeNetCDF(result, outputDir: outputDir)
    case "imas":
        try OutputWriter.writeIMASNetCDF(result, outputDir: outputDir)
    default:
        throw ValidationError("Unknown output format: \(outputFormat)")
    }
}
```

#### Step 5.7: Validation and Testing (Week 7-8)

1. **IMAS schema compliance tests**:
   ```swift
   @Test("IMAS schema compliance")
   func testIMASSchemaCompliance() throws {
       let result = try runSimulation()
       let outputPath = "/tmp/test_imas.nc"

       let writer = try IMASWriter(path: outputPath)
       try writer.write(result)
       try writer.close()

       // Validate with IMAS validator
       let validator = IMASValidator()
       let issues = try validator.validate(path: outputPath)

       #expect(issues.isEmpty, "IMAS schema violations: \(issues)")
   }
   ```

2. **CF-1.8 compliance tests**:
   ```swift
   @Test("CF-1.8 conventions compliance")
   func testCFCompliance() throws {
       let outputPath = "/tmp/test_cf.nc"
       // ... write NetCDF ...

       let validator = CFValidator()
       let issues = try validator.validate(path: outputPath)

       #expect(issues.isEmpty, "CF violations: \(issues)")
   }
   ```

3. **Round-trip tests**:
   ```swift
   @Test("NetCDF round-trip preserves data")
   func testNetCDFRoundTrip() throws {
       let original = try runSimulation()

       // Write
       let path = "/tmp/roundtrip.nc"
       let writer = try IMASWriter(path: path)
       try writer.write(original)
       try writer.close()

       // Read
       let reader = try IMASReader(path: path)
       let restored = try reader.readCoreProfiles()
       try reader.close()

       // Compare
       #expect(allClose(original.electronDensity, restored.electronDensity, rtol: 1e-6))
   }
   ```

4. **External tool interoperability**:
   - Test with `ncdump` (NetCDF utilities)
   - Test with Python xarray: `xarray.open_dataset("gotenx_imas.nc")`
   - Test with OMFIT (if available)

### Success Criteria

- ✅ NetCDF-4 files readable by ncdump and xarray
- ✅ CF-1.8 compliant (validated by cf-checker)
- ✅ IMAS schema compliant (validated by IMAS tools)
- ✅ 10× compression ratio achieved
- ✅ Round-trip accuracy < 1e-6 relative error
- ✅ Documentation with usage examples

### Deliverables

1. `Sources/Gotenx/IO/NetCDF/` module
2. CLI support: `gotenx run --output-format imas`
3. Test suite with 95%+ coverage
4. User guide: `docs/IMAS_IO_GUIDE.md`
5. Example scripts for Python/MATLAB interoperability

---

## Phase 6: Experimental Data Cross-Validation

### Overview

**Goal**: Validate swift-Gotenx against experimental tokamak data and other transport codes (ASTRA, TRANSP, JETTO).

**Priority**: P0 (Highest - establishes credibility)

**Duration**: 1 month (overlaps with Phase 5)

**References**:
- ITER Physics Basis: Nuclear Fusion 39(12), 1999
- ASTRA validation: Nuclear Fusion 46(4), 2006
- TRANSP validation: Nuclear Fusion 48(7), 2008

### Requirements

#### R6.1: Reference Data Sources

**Primary Reference: TORAX Python Implementation** (推奨)

swift-Gotenx の主要な検証データとして、TORAX Python実装の出力を使用：

```bash
# google-deepmind/torax を実行して参照データ生成
git clone https://github.com/google-deepmind/torax.git
cd torax
python -m torax.examples.iterflatinductivescenario

# 出力: outputs/state_history.nc
# - 同じ物理モデル（BohmGyroBohm, Bremsstrahlung等）
# - NetCDF-4形式で直接比較可能
# - 温度・密度・輸送係数の時間発展データ
```

**理由**:
- ✅ **実測データ**：シミュレーション出力（目標値ではない）
- ✅ **同一物理モデル**：Swift実装の正確性を直接検証
- ✅ **NetCDF互換**：Phase 5のI/O層で直接読込可能
- ✅ **詳細プロファイル**：温度・密度の時空間発展データ

**補助的検証データ**:

1. **TORAX論文プロット値** (Figure 5-7)
   - arXiv:2406.06718v2 のグラフから値を抽出
   - WebPlotDigitizer等で数値化
   - 定性的トレンドの確認用

2. **ITER Baseline パラメータ** (物理量妥当性チェック)
   - Ip = 15 MA, Bt = 5.3 T, R0 = 6.2 m
   - Q_fusion ≈ 10, βN < 3.5
   - グローバル量の妥当性確認用（詳細プロファイル検証には使用しない）

3. **Tokamak実験データ** (拡張検証、Phase 6後半)
   - JET DT campaigns (公開データがあれば)
   - DIII-D H-mode shots (OpenFusion database)
   - ASTRA/TRANSP相互比較研究

**データ取得優先順位**:
1. TORAX Python実装（Week 1） ← **必須**
2. TORAX論文プロット（Week 1-2） ← **推奨**
3. ITER Baseline（既存） ← **参考値**
4. 実験データ（Week 3-4） ← **オプション**

#### R6.2: Comparison Metrics

For each validation case:
- **Profile L2 error**: `|| Ti_gotenx - Ti_ref ||₂ / || Ti_ref ||₂ < 0.1` (10%)
- **Global quantities**: Q_fusion, τE, βN within ±20%
- **Temporal evolution**: RMS error over time < 15%

#### R6.3: Statistical Analysis

- Mean absolute percentage error (MAPE)
- Pearson correlation coefficient (r > 0.95)
- Bland-Altman plots for systematic bias detection

### Architecture Design

```
Sources/Gotenx/Validation/
├── Datasets/
│   ├── ITERBaseline.swift        # ITER reference data
│   ├── TORACBenchmark.swift      # TORAX paper benchmarks
│   └── ExperimentalShot.swift    # Generic shot data structure
├── Comparison/
│   ├── ProfileComparator.swift   # Profile comparison utilities
│   ├── StatisticalMetrics.swift  # MAPE, correlation, etc.
│   └── PlotGenerator.swift       # Matplotlib-style plots
└── Reports/
    ├── ValidationReport.swift    # Generate markdown reports
    └── BenchmarkReport.swift     # Compare with other codes
```

### Implementation Steps

#### Step 6.0: 参照データ準備（Phase 5 と並行、Week 7-9）

**目的**: Phase 6 開始前に TORAX Python 実装を実行し、参照データを生成

**実施内容**:

1. **TORAX 環境構築** (Week 7):
   ```bash
   # Python 3.10+ 環境確認
   python --version  # >= 3.10

   # TORAX インストール
   git clone https://github.com/google-deepmind/torax.git
   cd torax
   pip install -e .

   # 依存ライブラリ
   # - jax >= 0.4.23
   # - jaxlib >= 0.4.23
   # - numpy >= 1.24
   # - netCDF4 >= 1.6.0
   ```

2. **ITER Baseline シミュレーション実行** (Week 8):
   ```bash
   cd torax/examples
   python iterflatinductivescenario.py

   # 実行時間: 約5-10分
   # 出力: outputs/state_history.nc
   ```

3. **データ検証** (Week 9):
   ```bash
   # NetCDF 構造確認
   ncdump -h outputs/state_history.nc

   # 期待される構造:
   # dimensions:
   #   time = 100
   #   rho_tor_norm = 100
   # variables:
   #   float time(time)
   #   float rho_tor_norm(rho_tor_norm)
   #   float ion_temperature(time, rho_tor_norm)
   #   float electron_temperature(time, rho_tor_norm)
   #   float electron_density(time, rho_tor_norm)
   #   float poloidal_flux(time, rho_tor_norm)

   # CF-1.8 準拠チェック
   cfchecks outputs/state_history.nc

   # 物理量の妥当性確認
   python -c "
   import netCDF4 as nc
   ds = nc.Dataset('outputs/state_history.nc')
   Ti = ds['ion_temperature'][-1, :]
   Te = ds['electron_temperature'][-1, :]
   print(f'Ti peak: {Ti.max()/1000:.1f} keV')
   print(f'Te peak: {Te.max()/1000:.1f} keV')
   # 期待: Ti/Te peak ≈ 15-20 keV
   "
   ```

**参照データの配置**:
```
Tests/GotenxTests/Validation/ReferenceData/
├── torax_iter_baseline.nc          # TORAX実行結果
├── torax_figure5_extracted.json    # 論文プロット抽出値
└── iter_physics_basis.json         # ITER設計パラメータ
```

#### Step 6.1: 参照データ読み込みとメッシュ一致（Week 10-11）

**目的**: TORAX 参照データを読み込み、swift-Gotenx のメッシュ設定と一致させる

1. **TORAX NetCDF 読み込み**:
   ```swift
   // Sources/Gotenx/Validation/Datasets/ToraxReferenceData.swift
   public struct ToraxReferenceData: Sendable {
       public let time: [Float]               // [nTime]
       public let rho: [Float]                // [nRho]
       public let Ti: [[Float]]               // [nTime, nRho]
       public let Te: [[Float]]               // [nTime, nRho]
       public let ne: [[Float]]               // [nTime, nRho]
       public let psi: [[Float]]              // [nTime, nRho]

       /// Load from TORAX NetCDF output
       public static func load(from path: String) throws -> ToraxReferenceData {
           // NetCDF reader (Phase 5で実装したIMASReader使用)
           let reader = try IMASReader(filePath: path)

           let time = try reader.readVariable(name: "time", type: Float.self)
           let rho = try reader.readVariable(name: "rho_tor_norm", type: Float.self)
           let Ti = try reader.read2DVariable(name: "ion_temperature")
           let Te = try reader.read2DVariable(name: "electron_temperature")
           let ne = try reader.read2DVariable(name: "electron_density")
           let psi = try reader.read2DVariable(name: "poloidal_flux")

           return ToraxReferenceData(
               time: time,
               rho: rho,
               Ti: Ti,
               Te: Te,
               ne: ne,
               psi: psi
           )
       }
   }
   ```

2. **メッシュ・境界条件の一致確認**:
   ```swift
   /// swift-Gotenx 設定を TORAX と一致させる
   public struct ValidationConfigMatcher {
       /// TORAX設定から swift-Gotenx 設定を生成
       public static func matchToTorax(
           _ toraxData: ToraxReferenceData
       ) throws -> SimulationConfiguration {
           // メッシュサイズを一致
           let nCells = toraxData.rho.count
           #expect(nCells == 100, "TORAX uses 100 cells")

           // ITER Baseline パラメータ
           let config = SimulationConfiguration(
               runtime: RuntimeConfiguration(
                   static: StaticConfig(
                       mesh: MeshConfig(
                           nCells: nCells,              // 100 (TORAX一致)
                           majorRadius: 6.2,            // m
                           minorRadius: 2.0,            // m
                           toroidalField: 5.3,          // T
                           geometryType: .circular
                       ),
                       evolution: EvolutionConfig(
                           ionHeat: true,
                           electronHeat: true,
                           density: true,
                           current: false
                       ),
                       solver: SolverConfig(
                           type: "newton_raphson",
                           tolerance: 1e-6,
                           maxIterations: 30
                       ),
                       scheme: SchemeConfig(theta: 1.0)
                   ),
                   dynamic: DynamicConfig(
                       boundaries: BoundaryConfig(
                           ionTemperature: 100.0,       // eV (TORAX一致)
                           electronTemperature: 100.0,  // eV
                           density: 2.0e19              // m^-3
                       ),
                       transport: TransportConfig(
                           modelType: "bohmGyrobohm",   // TORAX同一モデル
                           parameters: [:]
                       ),
                       sources: SourcesConfig(
                           ohmicHeating: true,
                           fusionPower: true,
                           ionElectronExchange: true,
                           bremsstrahlung: true
                       ),
                       pedestal: nil,
                       mhd: MHDConfig(
                           sawtoothEnabled: false,
                           sawtoothParams: SawtoothParameters(),
                           ntmEnabled: false
                       ),
                       restart: RestartConfig(doRestart: false)
                   )
               ),
               time: TimeConfiguration(
                   start: 0.0,
                   end: 2.0,                            // s (TORAX一致)
                   initialDt: 1e-3,
                   adaptive: AdaptiveTimestepConfig(
                       minDt: 1e-6,
                       maxDt: 1e-1,
                       safetyFactor: 0.9
                   )
               ),
               output: OutputConfiguration(
                   saveInterval: 0.02,                  // s (100点 = TORAX一致)
                   directory: "/tmp/gotenx_validation",
                   format: .netcdf
               )
           )

           return config
       }
   }
   ```

3. **設定一致性の自動テスト**:
   ```swift
   @Test("Configuration matches TORAX settings")
   func testConfigurationMatch() throws {
       let toraxData = try ToraxReferenceData.load(
           from: "Tests/GotenxTests/Validation/ReferenceData/torax_iter_baseline.nc"
       )

       let config = try ValidationConfigMatcher.matchToTorax(toraxData)

       // メッシュ一致
       #expect(config.runtime.static.mesh.nCells == toraxData.rho.count)

       // 時間範囲一致
       let expectedTimeSteps = toraxData.time.count
       let actualTimeSteps = Int((config.time.end - config.time.start) / config.output.saveInterval!)
       #expect(abs(actualTimeSteps - expectedTimeSteps) <= 1, "Time steps should match")

       // 物理パラメータ一致
       #expect(config.runtime.static.mesh.majorRadius == 6.2)
       #expect(config.runtime.static.mesh.toroidalField == 5.3)
   }
   ```

**Week 10-11 の成果物**:
- ✅ TORAX参照データの読み込み機能
- ✅ swift-Gotenx設定の自動生成（TORAX一致）
- ✅ メッシュ・境界条件・時間範囲の一致確認テスト
- ✅ 物理パラメータの整合性検証

#### Step 6.2: ITER Baseline data structure (補助的参照データ)

1. **ITER Physics Basis パラメータ**:
   ```swift
   // Sources/Gotenx/Validation/Datasets/ITERBaseline.swift
   public struct ITERBaselineData: Sendable {
       public let geometry: GeometryParams
       public let profiles: ReferenceProfiles
       public let globalQuantities: GlobalQuantities

       public struct ReferenceProfiles: Sendable {
           public let rho: [Float]           // Normalized radius
           public let Ti: [Float]            // Ion temperature [eV]
           public let Te: [Float]            // Electron temperature [eV]
           public let ne: [Float]            // Electron density [m⁻³]
           public let time: Float            // Time point [s]
       }

       public struct GlobalQuantities: Sendable {
           public let P_fusion: Float        // Fusion power [MW]
           public let P_alpha: Float         // Alpha power [MW]
           public let tau_E: Float           // Energy confinement time [s]
           public let beta_N: Float          // Normalized beta
           public let Q_fusion: Float        // Fusion gain
       }

       /// Load from ITER Physics Basis tables
       public static func load() -> ITERBaselineData {
           // Data from Nuclear Fusion 39(12), 1999, Table II
           let geometry = GeometryParams(
               majorRadius: 6.2,
               minorRadius: 2.0,
               elongation: 1.7,
               triangularity: 0.33,
               plasmaCurrent: 15.0,  // MA
               toroidalField: 5.3     // T
           )

           // Parabolic profiles from ITER design
           let nPoints = 50
           let rho = stride(from: 0.0, through: 1.0, by: 1.0/Float(nPoints-1)).map { Float($0) }

           let Ti = rho.map { r in
               let Ti_core: Float = 20000.0  // 20 keV
               let Ti_edge: Float = 100.0
               return Ti_edge + (Ti_core - Ti_edge) * pow(1.0 - r*r, 2.0)
           }

           let Te = Ti  // Assume Ti = Te

           let ne = rho.map { r in
               let ne_core: Float = 1.0e20
               let ne_edge: Float = 0.2e20
               return ne_edge + (ne_core - ne_edge) * pow(1.0 - r, 1.0)
           }

           let global = GlobalQuantities(
               P_fusion: 400.0,     // MW (ITER Q=10 design)
               P_alpha: 80.0,       // MW (20% of fusion)
               tau_E: 3.7,          // s (H98=1.0 scaling)
               beta_N: 1.8,         // Typical ITER value
               Q_fusion: 10.0       // Design goal
           )

           return ITERBaselineData(
               geometry: geometry,
               profiles: ReferenceProfiles(rho: rho, Ti: Ti, Te: Te, ne: ne, time: 2.0),
               globalQuantities: global
           )
       }
   }
   ```

2. **TORAX benchmark data**:
   ```swift
   // Sources/Gotenx/Validation/Datasets/TORACBenchmark.swift
   public struct TORACBenchmark: Sendable {
       /// Figure 5 from TORAX paper (arXiv:2406.06718v2)
       /// Time evolution of ITER Baseline Scenario
       public static func figure5() -> [ITERBaselineData] {
           // Digitized data from paper Figure 5
           // Time points: [0, 0.5, 1.0, 1.5, 2.0] s
           // Returns time-series of profiles
       }
   }
   ```

#### Step 6.2: Comparison Utilities (Week 2)

```swift
// Sources/Gotenx/Validation/Comparison/ProfileComparator.swift
public struct ProfileComparator {
    /// Compute L2 relative error between two profiles
    public static func l2Error(
        predicted: [Float],
        reference: [Float]
    ) -> Float {
        precondition(predicted.count == reference.count)

        let diff = zip(predicted, reference).map { $0 - $1 }
        let l2Diff = sqrt(diff.map { $0 * $0 }.reduce(0, +))
        let l2Ref = sqrt(reference.map { $0 * $0 }.reduce(0, +))

        return l2Diff / l2Ref
    }

    /// Compute mean absolute percentage error (MAPE)
    public static func mape(
        predicted: [Float],
        reference: [Float]
    ) -> Float {
        precondition(predicted.count == reference.count)

        let ape = zip(predicted, reference).map { pred, ref in
            abs((pred - ref) / ref)
        }

        return ape.reduce(0, +) / Float(ape.count) * 100.0  // Percentage
    }

    /// Compute Pearson correlation coefficient
    public static func pearsonCorrelation(
        x: [Float],
        y: [Float]
    ) -> Float {
        precondition(x.count == y.count)
        let n = Float(x.count)

        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n

        let covXY = zip(x, y).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +)
        let varX = x.map { pow($0 - meanX, 2) }.reduce(0, +)
        let varY = y.map { pow($1 - meanY, 2) }.reduce(0, +)

        return covXY / sqrt(varX * varY)
    }

    /// Generate comparison report
    public static func compare(
        gotenx: CoreProfiles,
        reference: ITERBaselineData.ReferenceProfiles,
        geometry: Geometry
    ) -> ComparisonReport {
        // Interpolate Gotenx profiles to reference grid
        let gotenxInterpolated = interpolate(
            from: geometry.radii.value.asArray(Float.self),
            to: reference.rho,
            profiles: gotenx
        )

        let tiError = l2Error(
            predicted: gotenxInterpolated.ionTemperature,
            reference: reference.Ti
        )
        let teError = l2Error(
            predicted: gotenxInterpolated.electronTemperature,
            reference: reference.Te
        )
        let neError = l2Error(
            predicted: gotenxInterpolated.electronDensity,
            reference: reference.ne
        )

        return ComparisonReport(
            tiL2Error: tiError,
            teL2Error: teError,
            neL2Error: neError,
            tiMAPE: mape(predicted: gotenxInterpolated.ionTemperature, reference: reference.Ti),
            teMAPE: mape(predicted: gotenxInterpolated.electronTemperature, reference: reference.Te),
            neMAPE: mape(predicted: gotenxInterpolated.electronDensity, reference: reference.ne),
            tiCorrelation: pearsonCorrelation(x: gotenxInterpolated.ionTemperature, y: reference.Ti),
            teCorrelation: pearsonCorrelation(x: gotenxInterpolated.electronTemperature, y: reference.Te),
            neCorrelation: pearsonCorrelation(x: gotenxInterpolated.electronDensity, y: reference.ne)
        )
    }
}

public struct ComparisonReport: Sendable {
    public let tiL2Error: Float
    public let teL2Error: Float
    public let neL2Error: Float
    public let tiMAPE: Float
    public let teMAPE: Float
    public let neMAPE: Float
    public let tiCorrelation: Float
    public let teCorrelation: Float
    public let neCorrelation: Float

    public var isValid: Bool {
        // Validation criteria: L2 error < 10%, MAPE < 15%, correlation > 0.95
        tiL2Error < 0.1 && teL2Error < 0.1 && neL2Error < 0.1 &&
        tiMAPE < 15.0 && teMAPE < 15.0 && neMAPE < 15.0 &&
        tiCorrelation > 0.95 && teCorrelation > 0.95 && neCorrelation > 0.95
    }
}
```

#### Step 6.3: Validation Tests (Week 3)

```swift
// Tests/GotenxTests/Validation/ITERBaselineValidationTests.swift
@Suite("ITER Baseline Validation")
struct ITERBaselineValidationTests {

    @Test("ITER Baseline Scenario reproduces reference profiles")
    func testITERBaselineProfiles() async throws {
        // 1. Load reference data
        let reference = ITERBaselineData.load()

        // 2. Configure Gotenx with ITER parameters
        let config = SimulationConfiguration(
            runtime: RuntimeConfiguration(
                static: StaticConfig(
                    mesh: MeshConfig(
                        nCells: 50,
                        majorRadius: reference.geometry.majorRadius,
                        minorRadius: reference.geometry.minorRadius,
                        toroidalField: reference.geometry.toroidalField,
                        geometryType: .circular
                    ),
                    evolution: EvolutionConfig.iterBaseline,
                    solver: SolverConfig.default,
                    scheme: SchemeConfig.default
                ),
                dynamic: DynamicConfig.iterBaseline
            ),
            time: TimeConfig(start: 0.0, end: 2.0, initialDt: 1e-3),
            output: OutputConfig.default
        )

        // 3. Run simulation
        let runner = SimulationRunner(config: config)
        let result = try await runner.run()

        // 4. Compare final profiles
        let finalState = result.states.last!
        let comparison = ProfileComparator.compare(
            gotenx: finalState.coreProfiles,
            reference: reference.profiles,
            geometry: result.geometry
        )

        // 5. Validate against criteria
        #expect(comparison.tiL2Error < 0.1, "Ti L2 error = \(comparison.tiL2Error) (expect < 0.1)")
        #expect(comparison.teL2Error < 0.1, "Te L2 error = \(comparison.teL2Error) (expect < 0.1)")
        #expect(comparison.neL2Error < 0.1, "ne L2 error = \(comparison.neL2Error) (expect < 0.1)")

        #expect(comparison.tiCorrelation > 0.95, "Ti correlation = \(comparison.tiCorrelation) (expect > 0.95)")
        #expect(comparison.teCorrelation > 0.95, "Te correlation = \(comparison.teCorrelation) (expect > 0.95)")
        #expect(comparison.neCorrelation > 0.95, "ne correlation = \(comparison.neCorrelation) (expect > 0.95)")

        // 6. Compare global quantities
        let derived = DerivedQuantitiesComputer.compute(
            profiles: finalState.coreProfiles,
            geometry: result.geometry
        )

        let qError = abs(derived.Q_fusion - reference.globalQuantities.Q_fusion) / reference.globalQuantities.Q_fusion
        #expect(qError < 0.2, "Q_fusion error = \(qError * 100)% (expect < 20%)")

        let tauError = abs(derived.tau_E - reference.globalQuantities.tau_E) / reference.globalQuantities.tau_E
        #expect(tauError < 0.2, "τE error = \(tauError * 100)% (expect < 20%)")

        // 7. Print report
        print("✅ ITER Baseline Validation")
        print("   Ti: L2 = \(comparison.tiL2Error), MAPE = \(comparison.tiMAPE)%, r = \(comparison.tiCorrelation)")
        print("   Te: L2 = \(comparison.teL2Error), MAPE = \(comparison.teMAPE)%, r = \(comparison.teCorrelation)")
        print("   ne: L2 = \(comparison.neL2Error), MAPE = \(comparison.neMAPE)%, r = \(comparison.neCorrelation)")
        print("   Q_fusion: \(derived.Q_fusion) vs \(reference.globalQuantities.Q_fusion) (error = \(qError * 100)%)")
        print("   τE: \(derived.tau_E) s vs \(reference.globalQuantities.tau_E) s (error = \(tauError * 100)%)")
    }

    @Test("TORAX Figure 5 time evolution comparison")
    func testTORACFigure5() async throws {
        let benchmarks = TORACBenchmark.figure5()

        for (t, reference) in benchmarks.enumerated() {
            let config = makeConfig(time: reference.profiles.time)
            let result = try await runSimulation(config: config)
            let comparison = ProfileComparator.compare(
                gotenx: result.states.last!.coreProfiles,
                reference: reference.profiles,
                geometry: result.geometry
            )

            #expect(comparison.isValid, "Failed at t=\(reference.profiles.time)s")
            print("   t=\(reference.profiles.time)s: L2(Ti)=\(comparison.tiL2Error), L2(Te)=\(comparison.teL2Error)")
        }
    }
}
```

#### Step 6.4: Validation Report Generator (Week 4)

```swift
// Sources/Gotenx/Validation/Reports/ValidationReport.swift
public struct ValidationReport {
    public static func generate(
        comparisons: [String: ComparisonReport],
        outputPath: String
    ) throws {
        var markdown = """
        # swift-Gotenx Validation Report

        **Generated**: \(Date())

        ## Summary

        """

        let passing = comparisons.values.filter { $0.isValid }.count
        let total = comparisons.count
        markdown += "**Pass Rate**: \(passing)/\(total) (\(Int(Float(passing)/Float(total)*100))%)\n\n"

        markdown += """
        ## Validation Criteria

        - L2 relative error < 10%
        - MAPE < 15%
        - Pearson correlation > 0.95

        ## Results

        | Test Case | Ti L2 | Te L2 | ne L2 | Ti MAPE | Te MAPE | ne MAPE | Status |
        |-----------|-------|-------|-------|---------|---------|---------|--------|
        """

        for (name, report) in comparisons.sorted(by: { $0.key < $1.key }) {
            let status = report.isValid ? "✅" : "❌"
            markdown += """

            | \(name) | \(String(format: "%.3f", report.tiL2Error)) | \(String(format: "%.3f", report.teL2Error)) | \(String(format: "%.3f", report.neL2Error)) | \(String(format: "%.1f%%", report.tiMAPE)) | \(String(format: "%.1f%%", report.teMAPE)) | \(String(format: "%.1f%%", report.neMAPE)) | \(status) |
            """
        }

        try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("✅ Validation report written to: \(outputPath)")
    }
}
```

### Success Criteria

- ✅ ITER Baseline Scenario: L2 error < 10%, MAPE < 15%, r > 0.95
- ✅ TORAX Figure 5 reproduction: Visual match + L2 < 10%
- ✅ Global quantities: Q_fusion, τE within ±20%
- ✅ Automated validation report generation

### Deliverables

1. `Sources/Gotenx/Validation/` module
2. Test suite: `Tests/GotenxTests/Validation/`
3. Validation report: `docs/VALIDATION_REPORT.md`
4. Comparison plots (using Python matplotlib or SwiftPlot)

---

## Phase 6.5: MLX AD性能検証（Week 13-14、Phase 6と並行可）

### Overview

**目的**: Phase 7（自動微分/最適化）の実現可能性を事前検証し、MLX ADの性能がシミュレーション最適化に適しているかを判断

**優先度**: P0（Phase 7の成功を左右する）

**期間**: 2週間（Phase 6 Week 12-13と並行実施可能）

**なぜ必要か**:
- MLX の `valueAndGrad()` 性能は**未検証**
- 400変数のヤコビアン計算が実用的速度か不明
- Phase 7開始後に手動随伴法への切替は+8週間の遅延

### Requirements

#### R6.5.1: AD性能ベンチマーク

**計測項目**:
1. Forward pass time（残差計算）
2. Gradient computation time（ヤコビアン計算）
3. メモリ使用量
4. GPU utilization

**判断基準**:
| AD性能 | 判定 | Phase 7対応 |
|--------|------|-----------|
| < 50ms/iter | ✅ 優秀 | 計画通り実装（16週） |
| 50-100ms/iter | ⚠️ 許容可 | 一部最適化（+2週） |
| 100-200ms/iter | ⚠️ 要改善 | MLX最適化調査（+4週） |
| > 200ms/iter | ❌ 不可 | 手動随伴法実装（+8週） |

#### R6.5.2: 勾配正確性検証

有限差分と比較して相対誤差 < 1%

### Implementation Steps

#### Step 6.5.1: MLX AD ベンチマークテスト（Week 13）

```swift
// Tests/GotenxTests/Optimization/MLXAutoDiffBenchmarkTests.swift

#Test("MLX AD performance benchmark")
func benchmarkMLXAutoDiffPerformance() async throws {
    let nCells = 100
    let nVars = 4  // Ti, Te, ne, psi
    let n = nCells * nVars  // 400

    // ランダムな初期状態
    let x = MLXArray.random([n], low: 0.1, high: 1.0)

    // 簡略化した残差関数（Block1DCoeffs相当の計算量）
    let residualFn: (MLXArray) -> MLXArray = { x in
        // トライ対角行列の構築（FVM discretization相当）
        let A = buildTestJacobian(x, nCells: nCells)  // [400, 400]
        let b = buildTestRHS(x, nCells: nCells)       // [400]

        // 残差: R = A·x - b
        return matmul(A, x) - b
    }

    // Newton-Raphson 典型反復数
    let iterations = 30

    print("🔬 MLX AD Performance Benchmark")
    print("  Problem size: \(n) variables (\(nCells) cells × \(nVars) vars)")
    print("  Iterations: \(iterations)")
    print()

    // 1. Forward pass benchmark
    let forwardStart = Date()
    for _ in 0..<iterations {
        let residual = residualFn(x)
        eval(residual)
    }
    let forwardElapsed = Date().timeIntervalSince(forwardStart)
    let msPerForward = (forwardElapsed * 1000.0) / Double(iterations)

    print("Forward pass:")
    print("  Total time: \(forwardElapsed)s (\(iterations) iter)")
    print("  Time per iteration: \(msPerForward)ms")
    print()

    // 2. Gradient computation benchmark
    let gradStart = Date()
    for _ in 0..<iterations {
        let (residual, jacobian) = valueAndGrad(residualFn)(x)
        eval(residual, jacobian)
    }
    let gradElapsed = Date().timeIntervalSince(gradStart)
    let msPerGrad = (gradElapsed * 1000.0) / Double(iterations)

    print("Gradient computation (AD):")
    print("  Total time: \(gradElapsed)s (\(iterations) iter)")
    print("  Time per iteration: \(msPerGrad)ms")
    print()

    // 3. Overhead ratio
    let overhead = gradElapsed / forwardElapsed
    print("Overhead: \(overhead)× slower than forward")
    print()

    // 4. 判定
    if msPerGrad < 50 {
        print("✅ 判定: 優秀")
        print("   → Phase 7を計画通り実装（16週間）")
    } else if msPerGrad < 100 {
        print("⚠️  判定: 許容可")
        print("   → Phase 7で一部最適化が必要（+2週間）")
    } else if msPerGrad < 200 {
        print("⚠️  判定: 要改善")
        print("   → MLX計算グラフ最適化を調査（+4週間）")
    } else {
        print("❌ 判定: 不可")
        print("   → 手動随伴法の実装を検討（+8週間）")
    }

    // テスト期待値: 100ms/iter以下が目標
    #expect(msPerGrad < 100, "AD performance: \(msPerGrad)ms/iter (expect < 100ms)")
}

/// Test Jacobian builder (tri-diagonal matrix)
private func buildTestJacobian(_ x: MLXArray, nCells: Int) -> MLXArray {
    let nVars = 4
    let n = nCells * nVars

    // トライ対角行列（FVM discretization）
    var diag = MLXArray.ones([n])
    var upper = MLXArray.ones([n-1]) * -0.5
    var lower = MLXArray.ones([n-1]) * -0.5

    // 状態依存の係数（非線形性）
    diag = diag + abs(x) * 0.1

    // 行列構築（simplified）
    var A = MLXArray.zeros([n, n])
    for i in 0..<n {
        A[i, i] = diag[i]
        if i < n-1 {
            A[i, i+1] = upper[i]
            A[i+1, i] = lower[i]
        }
    }

    return A
}

private func buildTestRHS(_ x: MLXArray, nCells: Int) -> MLXArray {
    let nVars = 4
    let n = nCells * nVars

    // 非線形RHS（source terms相当）
    return exp(-x / 10.0) * 100.0
}
```

#### Step 6.5.2: 勾配正確性検証（Week 14）

```swift
#Test("Gradient accuracy vs finite difference")
func testGradientAccuracy() throws {
    let nCells = 10  // 小規模問題で詳細検証
    let n = nCells * 4

    let x = MLXArray.random([n], low: 0.1, high: 1.0)

    let objectiveFn: (MLXArray) -> MLXArray = { x in
        // スカラー目的関数（最適化シナリオ相当）
        let residual = buildTestResidual(x, nCells: nCells)
        return (residual * residual).sum()  // L2 norm squared
    }

    // 1. MLX AD gradient
    let (_, gradAD) = valueAndGrad(objectiveFn)(x)
    eval(gradAD)

    // 2. Finite difference gradient (central difference)
    var gradFD = MLXArray.zeros([n])
    let h: Float = 1e-5

    for i in 0..<n {
        var x_plus = x
        var x_minus = x

        x_plus[i] = x[i] + h
        x_minus[i] = x[i] - h

        let f_plus = objectiveFn(x_plus).item(Float.self)
        let f_minus = objectiveFn(x_minus).item(Float.self)

        gradFD[i] = (f_plus - f_minus) / (2 * h)
    }
    eval(gradFD)

    // 3. 相対誤差計算
    let relativeError = abs((gradAD - gradFD) / (abs(gradFD) + 1e-10))
    let maxError = relativeError.max().item(Float.self)
    let meanError = relativeError.mean().item(Float.self)

    print("Gradient accuracy:")
    print("  Max relative error: \(maxError)")
    print("  Mean relative error: \(meanError)")

    // 期待: 相対誤差 < 1%
    #expect(maxError < 0.01, "Max gradient error: \(maxError) (expect < 0.01)")
    #expect(meanError < 0.001, "Mean gradient error: \(meanError) (expect < 0.001)")
}
```

#### Step 6.5.3: MLX最適化戦略（Week 14、性能不足時）

**MLX ADが遅い場合の改善策**:

1. **計算グラフの最適化**:
   ```swift
   // ❌ 非効率: 中間変数が多い
   let a = x * 2.0
   let b = a + 1.0
   let c = exp(b)
   let result = c * 3.0

   // ✅ 効率的: 操作を融合
   let result = exp(x * 2.0 + 1.0) * 3.0
   ```

2. **compile() の効率的使用**:
   ```swift
   // 残差関数全体をコンパイル
   let compiledResidual = compile(residualFn)

   // コンパイル済み関数のAD
   let grad = valueAndGrad(compiledResidual)
   ```

3. **メモリアクセスパターン改善**:
   - Array slicing の最小化
   - Contiguous memory layout の使用

### Success Criteria

- ✅ MLX AD性能: < 100ms/iter（30反復で3秒以内）
- ✅ 勾配正確性: 相対誤差 < 1%
- ✅ GPU利用率: > 80%（計算律速でない）
- ⚠️ 50-100ms/iter → Phase 7で最適化作業追加
- ❌ > 200ms/iter → 手動随伴法へ移行

### Deliverables

1. **ベンチマークテストスイート**: `Tests/GotenxTests/Optimization/MLXAutoDiffBenchmarkTests.swift`
2. **性能レポート**: `docs/MLX_AD_PERFORMANCE_REPORT.md`
3. **Phase 7実装方針の決定**: MLX AD継続 vs 手動随伴法

### Risk Mitigation

| リスク | 確率 | 影響 | 対応策 |
|--------|------|------|--------|
| MLX AD が遅い (> 200ms) | 中 | 高 | 手動随伴法実装（+8週） |
| 勾配精度不足 | 低 | 中 | 有限差分ハイブリッド |
| GPU利用率低下 | 中 | 中 | 計算グラフ最適化 |

---

## Phase 7: Automatic Differentiation Workflow

### Overview

**Goal**: Implement optimization and control capabilities using MLX's automatic differentiation.

**Priority**: P2 (Important for research applications)

**Duration**: 4-6 months

**References**:
- TORAX paper: arXiv:2406.06718v2 (Section 3.3: Optimization)
- RAPTOR: Nuclear Fusion 61(1), 2021
- MLX Documentation: https://ml-explore.github.io/mlx/build/html/

### Requirements

#### R7.1: Forward Sensitivity Analysis

Compute gradients of outputs w.r.t. parameters:
```
∂Q_fusion / ∂[P_ECRH, P_ICRH, I_plasma, ...]
```

Use cases:
- Parameter sensitivity analysis
- Actuator ranking (which control has most impact)
- Uncertainty quantification

#### R7.2: Inverse Problems (Optimization)

Given target profiles, find optimal actuator settings:
```
minimize: || profiles_simulated - profiles_target ||²
w.r.t.: [P_ECRH(t), P_ICRH(t), gas_puff(t), ...]
subject to: actuator constraints
```

Use cases:
- Scenario optimization (maximize Q_fusion)
- Profile control (match experimental targets)
- Ramp-up/ramp-down optimization

#### R7.3: Real-Time Control Emulation

Fast gradient-based predictive control:
```
At each timestep:
1. Predict future profiles (forward model)
2. Compute gradient w.r.t. actuators
3. Update actuators via gradient descent
```

Use cases:
- Model predictive control (MPC)
- Feedforward control design
- Digital twin applications

### Optimization Scenarios (詳細定義)

**目的**: Phase 7で実装する具体的な最適化ケースを明確化し、MLX ADの実装可能性を事前検証

#### Scenario 1: ECRH パワー配分の最適化

**目的**: Q_fusion を最大化

**最適化変数**（6次元パラメータ空間）:
```swift
public struct ECRHOptimizationParameters: Differentiable {
    @Differentiable var P_ECRH_total: Float     // 総ECRH電力 [MW]
    @Differentiable var rho_peak: Float          // ピーク位置 [0-1]
    @Differentiable var width: Float             // ガウス幅 [0.1-0.5]
    @Differentiable var P_ICRH: Float            // ICRH電力 [MW]
    @Differentiable var n_e_edge: Float          // エッジ密度 [10^19 m^-3]
    @Differentiable var impurity_fraction: Float // 不純物分率 [0-0.01]

    /// パラメータ制約チェック
    func isValid() -> Bool {
        return P_ECRH_total > 0 && P_ECRH_total < 50  // [MW]
            && rho_peak > 0.3 && rho_peak < 0.7       // 中心～エッジ間
            && width > 0.1 && width < 0.5             // 物理的妥当性
            && P_ICRH >= 0 && P_ICRH < 30             // [MW]
            && n_e_edge > 0.1e20 && n_e_edge < 1.0e20 // [m^-3]
            && impurity_fraction >= 0 && impurity_fraction < 0.01
    }
}
```

**目的関数**:
```swift
func objectiveFunction(_ params: ECRHOptimizationParameters) -> Float {
    // 1. シミュレーション実行
    let config = buildConfig(from: params)
    let result = try! runSimulation(config: config)

    // 2. 最終状態から Q_fusion 計算
    let finalState = result.states.last!
    let derived = DerivedQuantitiesComputer.compute(
        profiles: finalState.coreProfiles,
        geometry: geometry
    )

    // 3. 最大化: Q_fusion (目的関数は最小化なので符号反転)
    return -derived.Q_fusion
}
```

**制約条件**（ペナルティ関数で実装）:
```swift
func constraintPenalty(_ params: ECRHOptimizationParameters, _ result: SimulationResult) -> Float {
    var penalty: Float = 0.0

    // 物理的実現可能性
    if result.finalProfiles.ionTemperature.value.min().item(Float.self) < 100 {
        penalty += 1e6  // 境界温度 > 100 eV
    }

    if result.derivedQuantities.beta_N > 3.5 {
        penalty += 1e6 * (result.derivedQuantities.beta_N - 3.5)  // MHD安定性
    }

    // 加熱容量制約
    let P_total = params.P_ECRH_total + params.P_ICRH
    if P_total > 50 {
        penalty += 1e6 * (P_total - 50)  // ITER加熱容量
    }

    return penalty
}

// 総目的関数
func totalObjective(_ params: ECRHOptimizationParameters) -> Float {
    let result = runSimulation(from: params)
    return objectiveFunction(params) + constraintPenalty(params, result)
}
```

**期待結果**:
- Q_fusion: 10 → 12-15 （20-50%改善）
- τE: 3.7s → 4.5s （20%改善）
- 最適パラメータ: `P_ECRH = 35 MW, rho_peak = 0.45, width = 0.25, ...`

**MLX AD の実装可能性**:
- ✅ 全変数が連続値（勾配計算可能）
- ✅ 制約はペナルティ関数で微分可能
- ⚠️ シミュレーション1回 = 2秒、勾配計算 = 10秒（Phase 6.5で検証）
  - 100反復 → 約15分（許容範囲）
- ⚠️ 制約: MLX の control-flow (if文) は微分不可
  - 解決策: `soft_constraint()` 関数で smooth approximation

```swift
// ❌ 微分不可: if文
if beta_N > 3.5 {
    penalty += large_value
}

// ✅ 微分可能: smooth step function
let penalty = smoothReLU(beta_N - 3.5) * large_value

func smoothReLU(_ x: Float) -> Float {
    // ReLU の smooth approximation
    return log(1 + exp(x * 10)) / 10
}
```

#### Scenario 2: ガス注入率の最適化（H-mode遷移）

**目的**: H-mode 遷移に必要な加熱電力を最小化

**最適化変数**（3次元パラメータ空間）:
```swift
public struct GasPuffOptimizationParameters: Differentiable {
    @Differentiable var puff_rate: Float         // 注入率 [Pa·m³/s]
    @Differentiable var puff_location: Float     // 注入位置（rho）
    @Differentiable var P_heating: Float         // 加熱電力 [MW]

    func isValid() -> Bool {
        return puff_rate > 0 && puff_rate < 100      // [Pa·m³/s]
            && puff_location > 0.8 && puff_location < 1.0  // エッジ注入
            && P_heating > 10 && P_heating < 50      // [MW]
    }
}
```

**目的関数**（加熱電力を最小化）:
```swift
func objectiveFunction(_ params: GasPuffOptimizationParameters) -> Float {
    let result = runSimulation(from: params)

    // H-mode遷移の判定: Te_edge > 200 eV
    let Te_edge = result.finalProfiles.electronTemperature.value[-1].item(Float.self)

    if Te_edge > 200 {
        // H-mode達成: 加熱電力を最小化
        return params.P_heating
    } else {
        // H-mode未達: 大きなペナルティ
        return params.P_heating + 1e6 * (200 - Te_edge)
    }
}
```

**制約条件**:
- Te_edge > 200 eV （H-mode判定）
- 10 MW < P_heating < 50 MW （加熱範囲）
- n_e_average = 10^20 m^-3 （密度固定）

**期待結果**:
- P_L-H_threshold: 30 MW → 25 MW （17%削減）
- 最適ガス注入: `puff_rate = 45 Pa·m³/s, location = 0.95`

**MLX AD の制約対応**:
- ⚠️ H-mode判定は不連続（Te_edge > 200 eV）
  - 解決策: Sigmoid smooth approximation

```swift
// ❌ 微分不可: if文で分岐
if Te_edge > 200 {
    return P_heating
} else {
    return P_heating + penalty
}

// ✅ 微分可能: sigmoid で smooth transition
let h_mode_weight = sigmoid((Te_edge - 200) / 10)  // smooth step
return P_heating + (1 - h_mode_weight) * penalty

func sigmoid(_ x: Float) -> Float {
    return 1 / (1 + exp(-x))
}
```

#### Scenario 3: プロファイル形状の最適化

**目的**: 目標温度プロファイルに合わせた加熱配分

**最適化変数**（10次元：時空間加熱パターン）:
```swift
public struct ProfileOptimizationParameters: Differentiable {
    // ECRH パワー分布（5点スプライン制御点）
    @Differentiable var ecrh_power: [Float]  // [P_0, P_1, P_2, P_3, P_4] at rho = [0.2, 0.4, 0.6, 0.8, 1.0]

    // ICRH パワー分布（5点スプライン制御点）
    @Differentiable var icrh_power: [Float]  // 同様

    init() {
        self.ecrh_power = Array(repeating: 5.0, count: 5)  // 初期値 5 MW各点
        self.icrh_power = Array(repeating: 3.0, count: 5)
    }
}
```

**目的関数**（L2誤差最小化）:
```swift
func objectiveFunction(
    _ params: ProfileOptimizationParameters,
    target: TargetProfile
) -> Float {
    let result = runSimulation(from: params)
    let simulated = result.finalProfiles.ionTemperature.value

    // L2 誤差
    let diff = simulated - target.Ti
    return (diff * diff).mean().item(Float.self)
}
```

**期待結果**:
- プロファイル一致度: L2誤差 < 5%
- 反復回数: 50-100回

**MLX AD の実装可能性**:
- ✅ 全変数が連続値
- ✅ L2誤差は微分可能
- ⚠️ 高次元最適化（10変数）→ Adam optimizer 使用推奨

### Optimization Scenarios の実装優先順位

| Scenario | 優先度 | 理由 | 実装週 |
|----------|-------|------|-------|
| **Scenario 1: ECRH最適化** | P0 | Q_fusion改善は主要目標 | Week 23-26 |
| **Scenario 2: ガス注入最適化** | P1 | H-mode遷移は実用的 | Week 27-28 |
| **Scenario 3: プロファイル最適化** | P2 | 制御応用の基盤 | Week 29-30 |

### Architecture Design

```
Sources/Gotenx/Optimization/
├── Sensitivity/
│   ├── ForwardSensitivity.swift      # ∂output/∂parameter
│   ├── ParameterSweep.swift          # Grid search
│   └── UncertaintyPropagation.swift  # Monte Carlo
├── Control/
│   ├── OptimizationProblem.swift     # Abstract optimization interface
│   ├── GradientDescent.swift         # Basic optimizer
│   ├── Adam.swift                    # Adam optimizer
│   └── LBFGS.swift                   # Limited-memory BFGS
├── Constraints/
│   ├── ActuatorLimits.swift          # Physical constraints
│   ├── ProfileConstraints.swift      # Physics constraints
│   └── PowerConstraints.swift        # Power balance constraints
└── Applications/
    ├── ScenarioOptimizer.swift       # Maximize Q_fusion
    ├── ProfileMatcher.swift          # Match target profiles
    └── RampOptimizer.swift           # Optimize ramp-up/down
```

### Implementation Steps

#### Step 7.1: MLX AD Integration (Week 1-4)

1. **Make simulation differentiable**:

Currently, `compile()` optimizes but doesn't track gradients. We need to restructure for AD:

```swift
// Sources/Gotenx/Optimization/Sensitivity/DifferentiableSimulation.swift
public struct DifferentiableSimulation {
    private let staticParams: StaticRuntimeParams
    private let transport: any TransportModel
    private let sources: any SourceModel

    /// Differentiable forward pass
    /// Returns (final_profiles, loss) where loss is differentiable w.r.t. params
    public func forward(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries
    ) -> (CoreProfiles, MLXArray) {
        var state = initialProfiles

        // Time-stepping (not compiled, to preserve gradient tape)
        for t in stride(from: 0.0, to: 2.0, by: 0.01) {
            // Apply actuators at this timestep
            let sources = applyActuators(actuators, time: t)

            // One timestep (differentiable)
            state = stepDifferentiable(state, sources: sources, dt: 0.01)
        }

        // Compute loss (example: maximize Q_fusion)
        let derived = DerivedQuantitiesComputer.compute(
            profiles: state,
            geometry: geometry
        )
        let loss = -derived.Q_fusion  // Negative for maximization

        return (state, MLXArray(loss))
    }

    /// Differentiable timestep (no compile())
    private func stepDifferentiable(
        _ profiles: CoreProfiles,
        sources: SourceTerms,
        dt: Float
    ) -> CoreProfiles {
        // Build coefficients (must be differentiable)
        let transportCoeffs = transport.computeCoefficients(
            profiles: profiles,
            geometry: geometry,
            params: transportParams
        )

        let coeffs = buildBlock1DCoeffs(
            transport: transportCoeffs,
            sources: sources,
            geometry: geometry,
            staticParams: staticParams,
            profiles: profiles
        )

        // Solve (must be differentiable - use iterative solver, not LU)
        let newProfiles = solveNewtonRaphson(
            coeffs: coeffs,
            oldProfiles: profiles,
            dt: dt
        )

        return newProfiles
    }
}

/// Actuator time series (differentiable parameters)
public struct ActuatorTimeSeries {
    public let P_ECRH: [Float]     // ECRH power at each timestep [MW]
    public let P_ICRH: [Float]     // ICRH power [MW]
    public let gas_puff: [Float]   // Gas puff rate [particles/s]
    public let I_plasma: [Float]   // Plasma current [MA]

    /// Convert to MLXArray for differentiation
    public func toMLXArray() -> MLXArray {
        let flat = P_ECRH + P_ICRH + gas_puff + I_plasma
        return MLXArray(flat)
    }

    public static func fromMLXArray(_ array: MLXArray, nSteps: Int) -> ActuatorTimeSeries {
        let flat = array.asArray(Float.self)
        let nActuators = 4
        precondition(flat.count == nSteps * nActuators)

        return ActuatorTimeSeries(
            P_ECRH: Array(flat[0..<nSteps]),
            P_ICRH: Array(flat[nSteps..<(2*nSteps)]),
            gas_puff: Array(flat[(2*nSteps)..<(3*nSteps)]),
            I_plasma: Array(flat[(3*nSteps)..<(4*nSteps)])
        )
    }
}
```

2. **Compute gradients via MLX**:

```swift
// Sources/Gotenx/Optimization/Sensitivity/ForwardSensitivity.swift
public struct ForwardSensitivity {
    private let simulation: DifferentiableSimulation

    /// Compute ∂Q_fusion / ∂actuators
    public func computeGradient(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries
    ) -> ActuatorTimeSeries {
        let actuatorsArray = actuators.toMLXArray()

        // Define loss function
        func lossFn(_ params: MLXArray) -> MLXArray {
            let acts = ActuatorTimeSeries.fromMLXArray(params, nSteps: actuators.P_ECRH.count)
            let (_, loss) = simulation.forward(
                initialProfiles: initialProfiles,
                actuators: acts
            )
            return loss
        }

        // Compute gradient via MLX
        let gradFn = grad(lossFn)
        let gradient = gradFn(actuatorsArray)

        eval(gradient)

        // Convert back to ActuatorTimeSeries
        return ActuatorTimeSeries.fromMLXArray(gradient, nSteps: actuators.P_ECRH.count)
    }

    /// Sensitivity matrix: ∂outputs / ∂inputs
    public func computeSensitivityMatrix(
        initialProfiles: CoreProfiles,
        actuators: ActuatorTimeSeries,
        outputs: [String]  // ["Q_fusion", "tau_E", "beta_N", ...]
    ) -> [[Float]] {
        // For each output, compute gradient w.r.t. all actuators
        outputs.map { output in
            let grad = computeGradient(
                initialProfiles: initialProfiles,
                actuators: actuators,
                targetOutput: output
            )
            return grad.toMLXArray().asArray(Float.self)
        }
    }
}
```

#### Step 7.2: Optimization Infrastructure (Week 5-8)

```swift
// Sources/Gotenx/Optimization/Control/OptimizationProblem.swift
public protocol OptimizationProblem {
    associatedtype Parameters
    associatedtype Constraints

    /// Objective function (to minimize)
    func objective(_ params: Parameters) -> Float

    /// Gradient of objective w.r.t. parameters
    func gradient(_ params: Parameters) -> Parameters

    /// Constraints (return 0 if satisfied, positive if violated)
    func constraints(_ params: Parameters, _ constraints: Constraints) -> [Float]
}

/// Gradient descent optimizer
public struct GradientDescent {
    public let learningRate: Float
    public let maxIterations: Int
    public let tolerance: Float

    public func optimize<P: OptimizationProblem>(
        problem: P,
        initialParams: P.Parameters,
        constraints: P.Constraints
    ) -> (P.Parameters, Float) {
        var params = initialParams
        var bestParams = params
        var bestLoss = problem.objective(params)

        for iter in 0..<maxIterations {
            // Compute gradient
            let grad = problem.gradient(params)

            // Update parameters
            params = params - learningRate * grad

            // Project onto constraints
            params = project(params, onto: constraints, using: problem)

            // Evaluate
            let loss = problem.objective(params)

            if loss < bestLoss {
                bestLoss = loss
                bestParams = params
            }

            // Check convergence
            if abs(loss - bestLoss) < tolerance {
                print("Converged at iteration \(iter)")
                break
            }

            if iter % 10 == 0 {
                print("Iteration \(iter): loss = \(loss)")
            }
        }

        return (bestParams, bestLoss)
    }
}

/// Adam optimizer (adaptive learning rate)
public struct Adam {
    public let learningRate: Float
    public let beta1: Float  // First moment decay
    public let beta2: Float  // Second moment decay
    public let epsilon: Float
    public let maxIterations: Int

    public init(
        learningRate: Float = 0.001,
        beta1: Float = 0.9,
        beta2: Float = 0.999,
        epsilon: Float = 1e-8,
        maxIterations: Int = 1000
    ) {
        self.learningRate = learningRate
        self.beta1 = beta1
        self.beta2 = beta2
        self.epsilon = epsilon
        self.maxIterations = maxIterations
    }

    public func optimize<P: OptimizationProblem>(
        problem: P,
        initialParams: P.Parameters,
        constraints: P.Constraints
    ) -> (P.Parameters, Float) {
        var params = initialParams
        var m = P.Parameters.zeros(like: params)  // First moment
        var v = P.Parameters.zeros(like: params)  // Second moment

        for t in 1...maxIterations {
            let grad = problem.gradient(params)

            // Update biased first moment estimate
            m = beta1 * m + (1 - beta1) * grad

            // Update biased second moment estimate
            v = beta2 * v + (1 - beta2) * (grad * grad)

            // Bias correction
            let mHat = m / (1 - pow(beta1, Float(t)))
            let vHat = v / (1 - pow(beta2, Float(t)))

            // Update parameters
            params = params - learningRate * mHat / (sqrt(vHat) + epsilon)

            // Project onto constraints
            params = project(params, onto: constraints, using: problem)

            if t % 10 == 0 {
                let loss = problem.objective(params)
                print("Iteration \(t): loss = \(loss)")
            }
        }

        return (params, problem.objective(params))
    }
}
```

#### Step 7.3: Scenario Optimizer (Week 9-12)

```swift
// Sources/Gotenx/Optimization/Applications/ScenarioOptimizer.swift
public struct ScenarioOptimizer {
    /// Optimize actuator trajectory to maximize Q_fusion
    public static func maximizeQFusion(
        initialProfiles: CoreProfiles,
        geometry: Geometry,
        timeHorizon: Float,
        constraints: ActuatorConstraints
    ) throws -> OptimizationResult {
        let nSteps = Int(timeHorizon / 0.01)

        // Initial guess: constant actuators
        let initialActuators = ActuatorTimeSeries(
            P_ECRH: [Float](repeating: 10.0, count: nSteps),   // 10 MW
            P_ICRH: [Float](repeating: 5.0, count: nSteps),    // 5 MW
            gas_puff: [Float](repeating: 1e20, count: nSteps), // 10²⁰ particles/s
            I_plasma: [Float](repeating: 15.0, count: nSteps)  // 15 MA
        )

        // Define optimization problem
        let problem = QFusionMaximization(
            simulation: DifferentiableSimulation(geometry: geometry),
            initialProfiles: initialProfiles
        )

        // Optimize using Adam
        let optimizer = Adam(learningRate: 0.01, maxIterations: 100)
        let (optimalActuators, finalQFusion) = optimizer.optimize(
            problem: problem,
            initialParams: initialActuators,
            constraints: constraints
        )

        return OptimizationResult(
            actuators: optimalActuators,
            Q_fusion: -finalQFusion,  // Negative because we minimized -Q
            converged: true
        )
    }
}

struct QFusionMaximization: OptimizationProblem {
    let simulation: DifferentiableSimulation
    let initialProfiles: CoreProfiles

    func objective(_ actuators: ActuatorTimeSeries) -> Float {
        let (finalProfiles, loss) = simulation.forward(
            initialProfiles: initialProfiles,
            actuators: actuators
        )
        return loss.item(Float.self)
    }

    func gradient(_ actuators: ActuatorTimeSeries) -> ActuatorTimeSeries {
        let sensitivity = ForwardSensitivity(simulation: simulation)
        return sensitivity.computeGradient(
            initialProfiles: initialProfiles,
            actuators: actuators
        )
    }

    func constraints(_ actuators: ActuatorTimeSeries, _ limits: ActuatorConstraints) -> [Float] {
        var violations: [Float] = []

        // Power constraints
        for P in actuators.P_ECRH {
            violations.append(max(0, P - limits.maxECRH))
            violations.append(max(0, limits.minECRH - P))
        }

        // Current constraints
        for I in actuators.I_plasma {
            violations.append(max(0, I - limits.maxCurrent))
            violations.append(max(0, limits.minCurrent - I))
        }

        return violations
    }
}

public struct ActuatorConstraints {
    public let minECRH: Float = 0.0
    public let maxECRH: Float = 30.0  // MW
    public let minICRH: Float = 0.0
    public let maxICRH: Float = 20.0  // MW
    public let minCurrent: Float = 5.0  // MA
    public let maxCurrent: Float = 20.0  // MA
    public let minGasPuff: Float = 0.0
    public let maxGasPuff: Float = 1e21  // particles/s
}
```

#### Step 7.4: Testing and Validation (Week 13-16)

```swift
@Test("Gradient correctness via finite differences")
func testGradientCorrectness() throws {
    let simulation = DifferentiableSimulation(...)
    let sensitivity = ForwardSensitivity(simulation: simulation)

    let actuators = ActuatorTimeSeries(...)

    // Analytical gradient via AD
    let analyticalGrad = sensitivity.computeGradient(
        initialProfiles: initialProfiles,
        actuators: actuators
    )

    // Numerical gradient via finite differences
    let epsilon: Float = 1e-4
    let numericalGrad = computeNumericalGradient(
        actuators: actuators,
        epsilon: epsilon
    )

    // Compare
    let relativeError = l2Error(
        predicted: analyticalGrad.toMLXArray().asArray(Float.self),
        reference: numericalGrad.toMLXArray().asArray(Float.self)
    )

    #expect(relativeError < 0.01, "Gradient error = \(relativeError) (expect < 0.01)")
}

@Test("Scenario optimization improves Q_fusion")
func testScenarioOptimization() async throws {
    let initialProfiles = makeITERProfiles()
    let geometry = makeITERGeometry()

    // Baseline: constant actuators
    let baselineActuators = ActuatorTimeSeries.constant(
        P_ECRH: 10.0,
        P_ICRH: 5.0,
        gas_puff: 1e20,
        I_plasma: 15.0,
        nSteps: 200
    )

    let baselineResult = try await runSimulation(
        initialProfiles: initialProfiles,
        actuators: baselineActuators
    )
    let baselineQ = baselineResult.Q_fusion

    // Optimized: maximize Q_fusion
    let optimizationResult = try ScenarioOptimizer.maximizeQFusion(
        initialProfiles: initialProfiles,
        geometry: geometry,
        timeHorizon: 2.0,
        constraints: ActuatorConstraints()
    )

    let optimizedQ = optimizationResult.Q_fusion

    // Verify improvement
    #expect(optimizedQ > baselineQ, "Optimized Q = \(optimizedQ) vs baseline Q = \(baselineQ)")
    print("Q_fusion improvement: \(optimizedQ / baselineQ)×")
}
```

### Success Criteria

- ✅ Gradient correctness: AD vs finite differences < 1% error
- ✅ Optimization convergence: Reaches local optimum in < 100 iterations
- ✅ Q_fusion improvement: Optimized scenario achieves ≥ 1.5× baseline
- ✅ Performance: Gradient computation < 5× forward pass time

### Deliverables

1. `Sources/Gotenx/Optimization/` module
2. Example: Maximize Q_fusion for ITER Baseline
3. User guide: `docs/OPTIMIZATION_GUIDE.md`
4. Test suite with gradient verification

---

## Cross-Phase Dependencies

### Phase 5 → Phase 6
- **Blocker**: IMAS I/O needed to export results for external comparison
- **Timeline**: Phase 6 Week 3-4 depends on Phase 5 completion

### Phase 5 → Phase 7
- **Soft dependency**: NetCDF output useful for debugging optimization
- **Workaround**: Can use JSON during development

### Phase 6 → Phase 7
- **Validation**: Optimization results should be validated against experimental feasibility
- **Timeline**: Phase 7 testing benefits from Phase 6 benchmarks

### Parallel Work
- Phase 5 Week 1-6 and Phase 6 Week 1-2 can run in parallel
- Phase 7 is independent and can start immediately (longest duration)

---

## Resource Requirements

### Development Effort

| Phase | Duration | Complexity | FTE |
|-------|----------|------------|-----|
| Phase 5 | 8 weeks | Medium | 1.0 |
| Phase 6 | 4 weeks | Low | 0.5 |
| Phase 7 | 16 weeks | High | 1.0 |

**Total**: ~6 months with 1 FTE

### External Dependencies

1. **NetCDF-C library** (Phase 5)
   - Install via Homebrew: `brew install netcdf`
   - Swift wrapper creation required

2. **Python ecosystem** (Phase 6)
   - xarray, matplotlib for validation plots
   - Optional: OMFIT integration

3. **IMAS tools** (Phase 5)
   - Optional: IMAS Python library for validation
   - Can proceed without if using manual validation

### Hardware Requirements

- **Development**: Apple Silicon Mac (M1+) with 16GB+ RAM
- **Testing**: 32GB+ RAM for large-scale optimizations
- **Production**: Same as current requirements

---

## Risk Assessment

### High Risk

#### R.H.1: MLX AD Performance
**Risk**: MLX automatic differentiation may be 10-100× slower than forward pass, making optimization impractical.

**Mitigation**:
- Benchmark early (Phase 7 Week 1)
- Use `compile()` on inner loops where possible
- Consider hybrid approach: JAX for optimization, MLX for simulation

**Contingency**: If MLX AD is too slow, implement manual adjoint method for key operations.

#### R.H.2: IMAS Schema Changes
**Risk**: IMAS specification may change, breaking compatibility.

**Mitigation**:
- Pin to specific IMAS version (3.0)
- Implement version detection in IMASReader
- Provide migration utilities

**Contingency**: Maintain multiple schema versions.

### Medium Risk

#### R.M.1: Reference Data Availability
**Risk**: Experimental tokamak data may not be publicly available or well-documented.

**Mitigation**:
- Focus on ITER Baseline (well-documented)
- Use TORAX benchmarks (published in paper)
- Contact authors for additional data

**Contingency**: Use synthetic reference data from other codes.

#### R.M.2: Optimization Convergence
**Risk**: Gradient-based optimization may get stuck in local minima.

**Mitigation**:
- Use multiple initial guesses
- Implement global optimization (e.g., CMA-ES) as fallback
- Add regularization to objective function

**Contingency**: Provide manual tuning tools if optimization fails.

### Low Risk

#### R.L.1: NetCDF Integration Issues
**Risk**: Swift-C interop issues with NetCDF library.

**Mitigation**:
- Use established Swift-C patterns
- Test incrementally with simple NetCDF operations
- Leverage community Swift-NetCDF packages if available

**Contingency**: Write minimal custom wrapper (only needed features).

---

## Success Metrics

### Phase 5 (IMAS I/O)
- ✅ CF-checker passes with 0 errors
- ✅ Python xarray can read files without warnings
- ✅ File size reduction ≥ 10× via compression
- ✅ Round-trip accuracy < 1e-6 relative error

### Phase 6 (Validation)
- ✅ ITER Baseline: L2 error < 10%, MAPE < 15%, r > 0.95
- ✅ TORAX Figure 5 reproduction: Visual match
- ✅ Automated validation report generation

### Phase 7 (AD/Optimization)
- ✅ Gradient correctness < 1% vs finite differences
- ✅ Q_fusion optimization: ≥ 1.5× baseline improvement
- ✅ Gradient computation < 5× forward pass time
- ✅ Optimization converges in < 100 iterations

---

## Timeline Summary

### 全体スケジュール（30週間、約7.5ヶ月）

| Phase | 期間 | 内容 | リスクバッファ |
|-------|------|------|--------------|
| **Phase 5** | **9週間** | IMAS I/O実装 | CF-1.8メタデータ調整に+1週 |
| **Phase 6.5** | **2週間** | MLX AD性能検証 | Phase 6と並行実施可能 |
| **Phase 6** | **5週間** | クロスバリデーション | レポート生成・調整に+1週 |
| **Phase 7** | **16週間** | AD/最適化 | MLX性能により+8週の可能性 |
| **合計** | **30週間** | | 実質28週（並行作業あり） |

### 詳細週次スケジュール

```
Week 1-2:   Phase 5 - NetCDF-C Swift wrapper
Week 3-5:   Phase 5 - IMASWriter + CF-1.8メタデータ (+1週バッファ)
Week 6:     Phase 5 - IMASReader実装
Week 7-9:   Phase 5 - CLI統合・自動テスト

Week 10-11: Phase 6 - 参照データ取得（TORAX実行、論文値抽出）
            └─ Phase 6.5と並行: MLX ADベンチマーク準備
Week 12:    Phase 6 - 比較ユーティリティ実装
Week 13-14: Phase 6.5 - MLX AD性能検証（Phase 6と並行可）
Week 15:    Phase 6 - 基本レポート生成
Week 16:    Phase 6 - レポート拡張（プロット、HTML）

Week 17-18: Phase 7 - 最適化インフラ基盤
Week 19-22: Phase 7 - Adam, L-BFGS実装
Week 23-26: Phase 7 - シナリオ実験（Q最大化、τE最適化）
Week 27-30: Phase 7 - 勾配検証・感度解析
Week 31-32: Phase 7 - ドキュメント・論文準備

※ Phase 6.5は Phase 6 と並行実施可能（実質期間短縮）
※ MLX AD性能が不足する場合、Phase 7は+8週間（手動随伴法実装）
```

**Critical Path**:
1. Phase 5 (Week 1-9) → Phase 6データ取得の前提
2. Phase 6.5 (Week 13-14) → Phase 7実装方針の決定
3. Phase 6検証完了 (Week 16) → Phase 7最適化の正当性担保

---

## References

1. TORAX: arXiv:2406.06718v2 - "TORAX: A Fast and Differentiable Tokamak Transport Simulator"
2. RAPTOR: Nuclear Fusion 61(1), 2021 - "Real-time capable modeling of tokamak plasma"
3. IMAS Documentation: https://imas.iter.org/
4. CF Conventions: http://cfconventions.org/cf-conventions/cf-conventions.html
5. MLX Documentation: https://ml-explore.github.io/mlx/
6. ITER Physics Basis: Nuclear Fusion 39(12), 1999

---

**Document Status**: ✅ Ready for Implementation
**Next Action**: Begin Phase 5 Step 5.1 (NetCDF-C Swift Wrapper)
