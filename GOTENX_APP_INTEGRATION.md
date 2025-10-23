# Gotenx App Integration Guide

**Version**: 1.0
**Date**: 2025-10-22
**Purpose**: Required changes to swift-gotenx for Gotenx App integration

---

## Overview

This document outlines the necessary modifications to **swift-gotenx** to support the **Gotenx App** macOS/iOS application. The app requires additional APIs for snapshot-based visualization and real-time progress callbacks.

---

## Required Changes

### 1. PlotData Initialization from Snapshots

**File**: `Sources/GotenxUI/Models/PlotData.swift`

**Current Limitation**: `PlotData` can only be initialized from `SimulationResult`

**Required Addition**: Support initialization from array of snapshots

```swift
extension PlotData {
    /// Create PlotData from array of SimulationSnapshots
    ///
    /// This enables visualization of saved simulation history in the Gotenx App.
    ///
    /// - Parameter snapshots: Ordered array of snapshots (sorted by ascending time)
    /// - Throws: PlotDataError if snapshots are empty or have inconsistent shapes
    ///
    /// **Usage**:
    /// ```swift
    /// let snapshots: [SimulationSnapshot] = simulation.snapshots
    /// let plotData = try PlotData(from: snapshots)
    /// ```
    public init(from snapshots: [SimulationSnapshot]) throws {
        guard !snapshots.isEmpty else {
            throw PlotDataError.missingTimeSeries
        }

        // Decode all snapshots
        let decodedSnapshots: [(time: Float, profiles: CoreProfiles, derived: DerivedQuantities?)]

        decodedSnapshots = try snapshots.map { snapshot in
            let profiles = try JSONDecoder().decode(CoreProfiles.self, from: snapshot.profiles)
            let derived = snapshot.derivedQuantities.flatMap {
                try? JSONDecoder().decode(DerivedQuantities.self, from: $0)
            }
            return (snapshot.time, profiles, derived)
        }

        let nTime = decodedSnapshots.count
        let nCells = decodedSnapshots[0].profiles.ionTemperature.count

        // Validate consistent cell count
        for (index, snapshot) in decodedSnapshots.enumerated() {
            guard snapshot.profiles.ionTemperature.count == nCells else {
                throw PlotDataError.inconsistentDataShape
            }
        }

        // Generate rho coordinate
        self.rho = (0..<nCells).map { Float($0) / Float(max(nCells - 1, 1)) }

        // Extract time array
        self.time = decodedSnapshots.map { $0.time }

        // Convert temperature profiles: eV → keV
        self.Ti = decodedSnapshots.map { snapshot in
            snapshot.profiles.ionTemperature.map { $0 / 1000.0 }
        }
        self.Te = decodedSnapshots.map { snapshot in
            snapshot.profiles.electronTemperature.map { $0 / 1000.0 }
        }

        // Convert density profiles: m^-3 → 10^20 m^-3
        self.ne = decodedSnapshots.map { snapshot in
            snapshot.profiles.electronDensity.map { $0 / 1e20 }
        }

        // Poloidal flux (no conversion)
        self.psi = decodedSnapshots.map { $0.profiles.poloidalFlux }

        // Placeholder for unimplemented fields
        let zeroProfile = Array(repeating: Float(0.0), count: nCells)
        let zeroProfiles = Array(repeating: zeroProfile, count: nTime)

        self.q = zeroProfiles
        self.magneticShear = zeroProfiles
        self.chiTotalIon = zeroProfiles
        self.chiTotalElectron = zeroProfiles
        self.chiTurbIon = zeroProfiles
        self.chiTurbElectron = zeroProfiles
        self.dFace = zeroProfiles
        self.jTotal = zeroProfiles
        self.jOhmic = zeroProfiles
        self.jBootstrap = zeroProfiles
        self.jECRH = zeroProfiles
        self.ohmicHeatSource = zeroProfiles
        self.fusionHeatSource = zeroProfiles
        self.pICRHIon = zeroProfiles
        self.pICRHElectron = zeroProfiles
        self.pECRHElectron = zeroProfiles

        // Extract derived quantities if available
        let hasDerived = decodedSnapshots.contains { $0.derived != nil }

        if hasDerived {
            self.IpProfile = decodedSnapshots.map { $0.derived?.I_plasma ?? 0.0 }
            self.IBootstrap = decodedSnapshots.map { $0.derived?.I_bootstrap ?? 0.0 }
            self.IECRH = Array(repeating: Float(0.0), count: nTime)

            self.qFusion = decodedSnapshots.map { snapshot in
                guard let derived = snapshot.derived else { return 0.0 }
                let P_input = derived.P_auxiliary + derived.P_ohmic + 1e-10
                return derived.P_fusion / P_input
            }

            self.pAuxiliary = decodedSnapshots.map { $0.derived?.P_auxiliary ?? 0.0 }
            self.pOhmicE = decodedSnapshots.map { $0.derived?.P_ohmic ?? 0.0 }
            self.pAlphaTotal = decodedSnapshots.map { $0.derived?.P_alpha ?? 0.0 }
            self.pBremsstrahlung = Array(repeating: Float(0.0), count: nTime)
            self.pRadiation = Array(repeating: Float(0.0), count: nTime)
        } else {
            let zeroScalar = Array(repeating: Float(0.0), count: nTime)
            self.IpProfile = zeroScalar
            self.IBootstrap = zeroScalar
            self.IECRH = zeroScalar
            self.qFusion = zeroScalar
            self.pAuxiliary = zeroScalar
            self.pOhmicE = zeroScalar
            self.pAlphaTotal = zeroScalar
            self.pBremsstrahlung = zeroScalar
            self.pRadiation = zeroScalar
        }
    }
}
```

**Note**: This requires `SimulationSnapshot` to be defined. The Gotenx App defines this model, but swift-gotenx doesn't need to know about it directly—it only needs to accept `Data` for JSON-encoded profiles.

---

### 2. ProgressInfo Struct

**File**: `Sources/Gotenx/Orchestration/SimulationOrchestrator.swift`

**Current Limitation**: No structured progress information

**Required Addition**: `ProgressInfo` struct for real-time callbacks

```swift
/// Progress information for real-time simulation monitoring
///
/// Passed to `progressCallback` during simulation execution to enable
/// real-time UI updates in applications like Gotenx App.
public struct ProgressInfo: Sendable {
    /// Current step number (0-indexed)
    public let step: Int

    /// Total estimated number of steps
    ///
    /// Note: May change during simulation due to adaptive time-stepping
    public let totalSteps: Int

    /// Current simulation time [s]
    public let currentTime: Float

    /// Current plasma profiles
    public let profiles: CoreProfiles

    /// Derived quantities (if computed)
    ///
    /// May be nil during early steps or if computation is disabled
    public let derivedQuantities: DerivedQuantities?

    public init(
        step: Int,
        totalSteps: Int,
        currentTime: Float,
        profiles: CoreProfiles,
        derivedQuantities: DerivedQuantities? = nil
    ) {
        self.step = step
        self.totalSteps = totalSteps
        self.currentTime = currentTime
        self.profiles = profiles
        self.derivedQuantities = derivedQuantities
    }
}
```

**Update SimulationOrchestrator API**:

```swift
public actor SimulationOrchestrator {
    // ... existing properties ...

    /// Run simulation with optional real-time progress callbacks
    ///
    /// - Parameters:
    ///   - config: Simulation configuration
    ///   - progressCallback: Optional async callback for progress updates
    ///                       Called periodically (e.g., every 10 steps) during execution
    ///
    /// - Returns: Final simulation result
    /// - Throws: SimulationError on failure
    ///
    /// **Example**:
    /// ```swift
    /// let orchestrator = SimulationOrchestrator()
    /// let result = try await orchestrator.run(
    ///     config: config,
    ///     progressCallback: { progress in
    ///         print("Step \(progress.step)/\(progress.totalSteps), t=\(progress.currentTime)s")
    ///         await updateUI(with: progress.profiles)
    ///     }
    /// )
    /// ```
    public func run(
        config: SimulationConfiguration,
        progressCallback: ((ProgressInfo) async -> Void)? = nil
    ) async throws -> SimulationResult {
        // ... existing initialization ...

        var currentStep = 0
        let estimatedTotalSteps = Int((config.time.end - config.time.start) / config.time.initialDt)

        while currentTime < endTime {
            // ... existing step logic ...

            // Progress callback (throttled to avoid overhead)
            if currentStep % 10 == 0, let callback = progressCallback {
                let progress = ProgressInfo(
                    step: currentStep,
                    totalSteps: estimatedTotalSteps,
                    currentTime: currentTime,
                    profiles: currentProfiles,
                    derivedQuantities: currentDerived
                )
                await callback(progress)
            }

            currentStep += 1
        }

        // ... existing finalization ...
    }
}
```

---

### 3. CoreProfiles and DerivedQuantities Codable Conformance

**Files**:
- `Sources/Gotenx/Core/CoreProfiles.swift`
- `Sources/Gotenx/Core/DerivedQuantities.swift`

**Current Status**: Check if `Codable` conformance exists

**Required**: Both types must conform to `Codable` for JSON encoding/decoding

```swift
// CoreProfiles.swift
public struct CoreProfiles: Sendable, Codable {
    // ... existing properties ...
}

// DerivedQuantities.swift
public struct DerivedQuantities: Sendable, Codable {
    // ... existing properties ...
}
```

**Verification**:
```swift
// Test encoding/decoding
let profiles = CoreProfiles(/* ... */)
let data = try JSONEncoder().encode(profiles)
let decoded = try JSONDecoder().decode(CoreProfiles.self, from: data)
```

---

## Implementation Priority

### Priority 1 (Critical for MVP)
1. ✅ **ProgressInfo struct** - Required for real-time monitoring
2. ✅ **SimulationOrchestrator callback API** - Required for live updates
3. ✅ **CoreProfiles/DerivedQuantities Codable** - Required for persistence

### Priority 2 (Important for visualization)
4. ⏳ **PlotData(from: snapshots)** - Required for historical data viewing

### Priority 3 (Nice to have)
5. ⏳ Pause/Resume functionality in `SimulationOrchestrator`
6. ⏳ Enhanced progress information (ETA, memory usage)

---

## Testing Strategy

### Unit Tests

**File**: `Tests/GotenxTests/PlotDataSnapshotTests.swift`

```swift
import XCTest
@testable import GotenxUI

final class PlotDataSnapshotTests: XCTestCase {
    func testInitFromSnapshots() throws {
        // Create mock snapshots
        let snapshots: [MockSnapshot] = [
            MockSnapshot(time: 0.0, Ti: [10.0, 8.0, 6.0]),
            MockSnapshot(time: 1.0, Ti: [12.0, 9.0, 7.0]),
            MockSnapshot(time: 2.0, Ti: [14.0, 10.0, 8.0])
        ]

        // Convert to Data
        let snapshotData = snapshots.map { snapshot in
            let profiles = CoreProfiles(
                ionTemperature: snapshot.Ti,
                electronTemperature: snapshot.Ti,
                electronDensity: Array(repeating: 5e19, count: snapshot.Ti.count),
                poloidalFlux: Array(repeating: 0.0, count: snapshot.Ti.count)
            )
            return (snapshot.time, try! JSONEncoder().encode(profiles))
        }

        // Create PlotData
        let plotData = try PlotData(from: snapshotData)

        // Assertions
        XCTAssertEqual(plotData.nTime, 3)
        XCTAssertEqual(plotData.nCells, 3)
        XCTAssertEqual(plotData.time, [0.0, 1.0, 2.0])

        // Check temperature conversion (eV → keV)
        XCTAssertEqual(plotData.Ti[0][0], 10.0 / 1000.0, accuracy: 1e-6)
    }

    func testEmptySnapshotsThrows() {
        XCTAssertThrowsError(try PlotData(from: [])) { error in
            XCTAssertEqual(error as? PlotDataError, .missingTimeSeries)
        }
    }
}
```

**File**: `Tests/GotenxTests/SimulationOrchestratorProgressTests.swift`

```swift
import XCTest
@testable import Gotenx

final class SimulationOrchestratorProgressTests: XCTestCase {
    func testProgressCallback() async throws {
        let config = SimulationConfiguration(/* minimal config */)

        var receivedProgress: [ProgressInfo] = []

        let orchestrator = SimulationOrchestrator()
        _ = try await orchestrator.run(config: config) { progress in
            receivedProgress.append(progress)
        }

        // Assertions
        XCTAssertFalse(receivedProgress.isEmpty)
        XCTAssertEqual(receivedProgress.first?.step, 0)
        XCTAssertLessThan(receivedProgress.last!.currentTime, config.time.end + 0.01)
    }
}
```

---

## Integration Checklist

- [ ] Add `ProgressInfo` struct to `SimulationOrchestrator.swift`
- [ ] Update `SimulationOrchestrator.run()` signature
- [ ] Implement progress callback in simulation loop
- [ ] Verify `CoreProfiles` is `Codable`
- [ ] Verify `DerivedQuantities` is `Codable`
- [ ] Add `PlotData(from: snapshots)` initializer
- [ ] Write unit tests for new APIs
- [ ] Update `CLAUDE.md` documentation
- [ ] Add examples to `README.md`

---

## Example Usage (Gotenx App)

```swift
import SwiftUI
import Gotenx
import GotenxUI

@MainActor
class AppViewModel: ObservableObject {
    @Published var liveProfiles: CoreProfiles?
    @Published var progress: Double = 0.0

    func runSimulation(_ config: SimulationConfiguration) async throws {
        let orchestrator = SimulationOrchestrator()

        let result = try await orchestrator.run(
            config: config,
            progressCallback: { [weak self] progress in
                await MainActor.run {
                    self?.liveProfiles = progress.profiles
                    self?.progress = Double(progress.step) / Double(progress.totalSteps)
                }
            }
        )

        // Save snapshots to SwiftData
        if let timeSeries = result.timeSeries {
            for timePoint in timeSeries {
                let snapshot = SimulationSnapshot(
                    time: timePoint.time,
                    profiles: try! JSONEncoder().encode(timePoint.profiles),
                    derived: timePoint.derived.flatMap { try? JSONEncoder().encode($0) }
                )
                modelContext.insert(snapshot)
            }
        }
    }

    func visualizeSnapshots(_ snapshots: [SimulationSnapshot]) throws {
        let plotData = try PlotData(from: snapshots)

        // Display in GotenxPlotView
        GotenxPlotView(data: plotData, config: .tempDensityProfile)
    }
}
```

---

## Backward Compatibility

All changes maintain backward compatibility:

- `ProgressInfo` is a new type
- `progressCallback` parameter is **optional** (default: `nil`)
- Existing code without callbacks continues to work:
  ```swift
  // Still valid
  let result = try await orchestrator.run(config: config)
  ```

---

## Documentation Updates

### CLAUDE.md

Add section:

```markdown
## Real-time Progress Monitoring

The `SimulationOrchestrator` supports real-time progress callbacks for UI integration:

```swift
let orchestrator = SimulationOrchestrator()
let result = try await orchestrator.run(
    config: config,
    progressCallback: { progress in
        print("Step \(progress.step), t=\(progress.currentTime)s")
        // Update UI with progress.profiles
    }
)
```

**ProgressInfo** contains:
- `step`: Current step number
- `totalSteps`: Estimated total steps
- `currentTime`: Simulation time [s]
- `profiles`: Current `CoreProfiles`
- `derivedQuantities`: Optional `DerivedQuantities`

Callbacks are throttled (every 10 steps) to minimize overhead.
```

### README.md

Add to "Quick Start" section:

```markdown
### Real-time Monitoring

```bash
# CLI with progress logging
.build/release/GotenxCLI run \
  --config config.json \
  --log-progress
```

```swift
// Swift API with progress callbacks
let orchestrator = SimulationOrchestrator()
try await orchestrator.run(config: config) { progress in
    await updateUI(progress)
}
```

---

## Timeline

| Task | Estimated Time | Priority |
|------|---------------|----------|
| Add `ProgressInfo` struct | 30 min | P1 |
| Update `SimulationOrchestrator.run()` | 1 hour | P1 |
| Verify `Codable` conformance | 30 min | P1 |
| Add `PlotData(from: snapshots)` | 1-2 hours | P2 |
| Write unit tests | 2 hours | P1 |
| Update documentation | 1 hour | P2 |
| **Total** | **6-7 hours** | |

---

## Questions & Decisions

### Q1: Callback Throttling Frequency?

**Current**: Every 10 steps
**Rationale**: Balance between UI responsiveness and performance overhead

**Alternative**: Make configurable?
```swift
public struct SimulationOptions {
    var progressCallbackInterval: Int = 10  // Steps between callbacks
}
```

### Q2: Should ProgressInfo include memory stats?

**Current**: No
**Future**: Could add `memoryUsage`, `estimatedTimeRemaining`

### Q3: Pause/Resume support?

**Status**: ✅ **IMPLEMENTED** (2025-10-23)

See Phase 1 implementation summary above.

---

## 8. Protocol-Based Architecture for Testability

**File**: `Sources/GotenxCore/Protocols/SimulationRunnable.swift`

**Status**: ✅ **IMPLEMENTED** (2025-10-23)

### Purpose

Enable dependency injection for testing by defining a protocol for simulation execution. This allows the Gotenx App to use mock implementations during testing without running actual physics simulations.

### SimulationRunnable Protocol

```swift
/// Protocol for simulation execution
public protocol SimulationRunnable: Actor {
    /// Initialize simulation with physics models
    func initialize(
        transportModel: any TransportModel,
        sourceModels: [any SourceModel],
        mhdModels: [any MHDModel]?
    ) async throws

    /// Run simulation with progress callback
    func run(
        progressCallback: (@Sendable (Float, ProgressInfo) -> Void)?
    ) async throws -> SimulationResult

    /// Pause the simulation
    func pause() async

    /// Resume the simulation
    func resume() async

    /// Check if simulation is paused
    func isPaused() async -> Bool
}
```

### SimulationRunner Conformance

```swift
// SimulationRunner now conforms to SimulationRunnable
public actor SimulationRunner: SimulationRunnable {
    // ... existing implementation (no changes required)
}
```

### App Integration (Dependency Injection)

```swift
// Gotenx/ViewModels/AppViewModel.swift

@MainActor
@Observable
final class AppViewModel {
    private var currentRunner: (any SimulationRunnable)?

    // ✅ Dependency injection for testing
    private let runnerFactory: @Sendable (SimulationConfiguration) -> any SimulationRunnable

    init(
        workspace: Workspace,
        runnerFactory: @Sendable @escaping (SimulationConfiguration) -> any SimulationRunnable = { config in
            SimulationRunner(config: config)  // Default: real implementation
        }
    ) {
        self.workspace = workspace
        self.runnerFactory = runnerFactory
    }

    func runSimulation(_ simulation: Simulation) {
        simulationTask = Task {
            // ...

            // ✅ Use factory instead of direct instantiation
            let runner = runnerFactory(config)
            await MainActor.run {
                currentRunner = runner
            }

            // ... rest unchanged
        }
    }
}
```

### MockSimulationRunner (App Test Target)

```swift
// GotenxTests/Mocks/MockSimulationRunner.swift

actor MockSimulationRunner: SimulationRunnable {
    // Test control
    var shouldFail: Bool = false
    var simulationDuration: TimeInterval = 0.1  // Fast for tests
    var progressUpdatesCount: Int = 10

    // State tracking
    private(set) var isInitialized: Bool = false
    private(set) var initializeCallCount: Int = 0
    private(set) var runCallCount: Int = 0
    private var _isPaused: Bool = false

    func initialize(
        transportModel: any TransportModel,
        sourceModels: [any SourceModel],
        mhdModels: [any MHDModel]?
    ) async throws {
        initializeCallCount += 1

        if shouldFail {
            throw SimulationError.modelInitializationFailed(
                modelName: "Mock",
                reason: "Test failure"
            )
        }

        isInitialized = true
    }

    func run(
        progressCallback: (@Sendable (Float, ProgressInfo) -> Void)?
    ) async throws -> SimulationResult {
        runCallCount += 1

        guard isInitialized else {
            throw SimulationError.notInitialized
        }

        if shouldFail {
            throw SimulationError.executionFailed("Test failure")
        }

        // Simulate progress updates
        let stepDuration = simulationDuration / Double(progressUpdatesCount)
        for i in 0..<progressUpdatesCount {
            try Task.checkCancellation()

            let fraction = Float(i) / Float(progressUpdatesCount)
            let progressInfo = ProgressInfo(
                currentTime: fraction,
                totalSteps: i,
                lastDt: 1e-4,
                converged: true
            )

            progressCallback?(fraction, progressInfo)
            try await Task.sleep(for: .seconds(stepDuration))
        }

        // Return mock result
        return SimulationResult(
            finalProfiles: SerializableProfiles(/* mock data */),
            statistics: SimulationStatistics(
                totalIterations: 100,
                totalSteps: 100,
                converged: true,
                maxResidualNorm: 1e-8,
                wallTime: Float(simulationDuration)
            )
        )
    }

    func pause() async { _isPaused = true }
    func resume() async { _isPaused = false }
    func isPaused() async -> Bool { _isPaused }
}
```

### Testing Example

```swift
// GotenxTests/ViewModels/AppViewModelTests.swift

import Testing
@testable import Gotenx

@Suite("AppViewModel Tests")
@MainActor
struct AppViewModelTests {
    @Test("Simulation runs successfully")
    func simulationSuccess() async throws {
        // Setup
        let workspace = Workspace(name: "Test")
        let mockRunner = MockSimulationRunner()

        let viewModel = AppViewModel(workspace: workspace) { _ in
            mockRunner  // Inject mock
        }

        let simulation = Simulation(
            name: "Test Sim",
            configurationData: createTestConfig()
        )
        workspace.simulations.append(simulation)
        viewModel.selectedSimulation = simulation

        // Execute
        viewModel.runSimulation(simulation)

        // Wait for completion
        try await Task.sleep(for: .milliseconds(500))

        // Verify
        let isPaused = await mockRunner.isPaused()
        #expect(!isPaused)
        #expect(await mockRunner.runCallCount == 1)
        #expect(simulation.status == .completed)
    }

    @Test("Simulation can be cancelled")
    func simulationCancellation() async throws {
        let workspace = Workspace(name: "Test")
        let mockRunner = MockSimulationRunner()
        mockRunner.simulationDuration = 10.0  // Long simulation

        let viewModel = AppViewModel(workspace: workspace) { _ in mockRunner }

        let simulation = Simulation(
            name: "Test Sim",
            configurationData: createTestConfig()
        )
        viewModel.selectedSimulation = simulation

        // Start simulation
        viewModel.runSimulation(simulation)
        try await Task.sleep(for: .milliseconds(100))

        // Cancel
        viewModel.stopSimulation()
        try await Task.sleep(for: .milliseconds(200))

        // Verify
        #expect(simulation.status == .cancelled)
    }
}
```

### Benefits

1. **Testability**
   - AppViewModel can be tested without running actual simulations (100x faster)
   - Test various scenarios: success, failure, cancellation, pause/resume
   - CI/CD friendly

2. **Decoupling**
   - AppViewModel doesn't depend on SimulationRunner implementation details
   - Easy to switch implementations in the future

3. **Extensibility**
   - `RemoteSimulationRunner`: Cloud execution
   - `CachedSimulationRunner`: Result caching
   - `LoggingSimulationRunner`: Debug wrapper

4. **Backward Compatibility**
   - Existing SimulationRunner code unchanged
   - Only added `: SimulationRunnable` conformance

---

## Contact

For questions or discussions about this integration:
- GitHub Issues: https://github.com/yourusername/swift-gotenx/issues
- Documentation: See `CLAUDE.md` in swift-gotenx repository

---

**Document Version**: 2.0
**Last Updated**: 2025-10-23
