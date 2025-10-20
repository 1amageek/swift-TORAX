# Repository Guidelines
swift-Gotenx is a SwiftPM workspace for a differentiable tokamak transport solver. Use this guide to navigate layout, tooling, and expectations before contributing.

## Project Structure & Module Organization
- `Sources/Gotenx/Core`, `Solver`, `Transport`, `Orchestration`, `Configuration` hold runtime pipelines; keep files focused on one concept.
- `Sources/GotenxPhysics/...` hosts heating, radiation, and neoclassical utilities feeding transport terms.
- `Tests/GotenxTests/<Area>` mirrors source modules; `Tests/GotenxPhysicsTests` covers physics regressions.
- Root docs (`ARCHITECTURE.md`, `SOLVER_IMPLEMENTATION_STRATEGY.md`, `TEST_IMPLEMENTATION_PLAN.md`) capture design intent and planned tests—review before altering APIs.

## Build, Test & Development Commands
- `swift package resolve` refreshes dependencies after toolchain changes.
- `swift build` compiles targets and validates manifests.
- `swift test` runs the Swift Testing suite; use `swift test --filter CellVariableTests/testFaceValueWithGradConstraint` for focus.
- `swift run gotenx-cli --help` exercises the CLI stub when wiring orchestration changes.

## Coding Style & Naming Conventions
- Follow Swift API guidelines: four-space indent, soft 120-col limit, `CamelCase` types, `lowerCamelCase` members.
- Keep physics constants in `Sources/GotenxPhysics/Utilities/PhysicsConstants.swift` with descriptive names like `bootstrapCurrentDensity`.
- Structure large files with `// MARK: -` and document preconditions for `MLXArray` shapes.
- Prefer value semantics; reserve `actor`s for `Sources/Gotenx/Orchestration`.

## Testing Guidelines
- Tests use the Swift `Testing` package (`@Test`). Mirror source directories and suffix files `ComponentTests.swift`.
- Materialize MLX tensors with `eval(...)` before numeric assertions; check shape and value.
- Grow coverage in the order noted in `TEST_IMPLEMENTATION_PLAN.md`, starting with solver coefficient builders and configuration parsing.
- Capture new failure modes with targeted tests and keep fixtures lean for quick runs.

## Commit & Pull Request Guidelines
- Use imperative, capitalized commit subjects (`Add hybrid solver fallback`) under 72 characters.
- Include bodies when behavior shifts to summarize motivation, touched modules, and doc updates.
- PRs must supply a summary, related issues or docs, proof that `swift test` passed, and any performance or numerical notes.
- Update documentation alongside user-facing or API changes so reviewers can trace rationale.

## Environment & Tooling Tips
- Develop on Apple Silicon with Swift 6.2/Xcode 16; rerun `swift package resolve` after switching toolchains.
- Keep Xcode command-line tools current so MLX continues to reach Metal during `swift test`.
- Manage dependencies through `Package.swift`; run `swift package update` only when you intend to refresh `Package.resolved`.
