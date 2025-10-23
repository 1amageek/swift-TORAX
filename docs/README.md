# swift-Gotenx Documentation

Technical documentation and implementation guides for swift-Gotenx tokamak transport simulator.

## 📚 Documentation Guide

- **For Development**: See [CLAUDE.md](../CLAUDE.md) - Concise development guidelines
- **For Users**: See [README.md](../README.md) - Getting started and usage

---

## Core Technical Reference

Detailed technical specifications extracted from CLAUDE.md for easier reference:

### System Architecture

- **[ARCHITECTURE.md](ARCHITECTURE.md)**
  Project overview, TORAX core concepts, Swift design patterns, and future extensions.

- **[UNIT_SYSTEM.md](UNIT_SYSTEM.md)**
  SI-based unit system standard (eV, m⁻³) throughout the codebase with conversion guidelines.

- **[CONFIGURATION_SYSTEM.md](CONFIGURATION_SYSTEM.md)**
  Hierarchical configuration management using swift-configuration (CLI, env vars, JSON).

### MLX and Numerical Computing

- **[NUMERICAL_PRECISION.md](NUMERICAL_PRECISION.md)**
  Float32-only policy, Apple Silicon GPU constraints, and numerical stability strategies.

- **[MLX_BEST_PRACTICES.md](MLX_BEST_PRACTICES.md)**
  Lazy evaluation, eval() patterns, and common MLXArray pitfalls.

- **[SWIFT_CONCURRENCY.md](SWIFT_CONCURRENCY.md)**
  EvaluatedArray wrapper, actor isolation, compile() patterns, and Sendable constraints.

### Physics Models

- **[TRANSPORT_MODELS.md](TRANSPORT_MODELS.md)**
  Comparison of Constant, Bohm-GyroBohm, and QLKNN transport models.

- **[PHASE8_MHD_IMPLEMENTATION.md](PHASE8_MHD_IMPLEMENTATION.md)** ✅ **Complete**
  MHD (magnetohydrodynamics) implementation with sawtooth crash models:
  - Simple trigger model (q=1 detection + shear checking)
  - Simple redistribution model (conservation enforcement)
  - 4 critical logic fixes (density usage, boundary continuity, poloidalFlux update, shear interpolation)
  - 9 comprehensive tests with Swift Testing

  **Status**: Physically-correct implementation, ready for validation
  **Next**: Real simulation testing → Advanced trigger models (Porcelli, Kadomtsev)

- **[PHASE9_TURBULENCE_TRANSITION_IMPLEMENTATION.md](PHASE9_TURBULENCE_TRANSITION_IMPLEMENTATION.md)** ✅ **Complete**
  Density-dependent turbulence transition (ITG→RI) based on Kinoshita et al., PRL 132, 235101 (2024):
  - Resistive-Interchange (RI) turbulence model at high density
  - Sigmoid transition from ITG (low n) to RI (high n) regimes
  - Correct isotope effects: χ_D ≈ 2χ_H via ρ_s² scaling
  - 4 critical bug fixes (isotope scaling, array shapes, type generalization, redundant eval)
  - 5 test suites (13 tests) with Swift Testing

  **Status**: Cutting-edge physics implementation, validated with comprehensive tests
  **Innovation**: First implementation of 2024 experimental discovery (not in TORAX)

---

## Physics & Diagnostics

Current implementation and design documents:

- **[CONSERVATION_AND_DIAGNOSTICS_DESIGN.md](CONSERVATION_AND_DIAGNOSTICS_DESIGN.md)**
  Conservation law enforcement (particle/energy) and diagnostic computation design.

- **[TORAX_COMPARISON_AND_VALIDATION.md](TORAX_COMPARISON_AND_VALIDATION.md)**
  Validation methodology against original Python TORAX implementation.

---

## Implementation Plans

Active improvement roadmaps and design specifications:

- **[FVM_NUMERICAL_IMPROVEMENTS_PLAN.md](FVM_NUMERICAL_IMPROVEMENTS_PLAN.md)** 🔥 **PRIORITY**
  Comprehensive plan for FVM numerical enhancements:
  - Power-law scheme for convection stability (Patankar)
  - Sauter bootstrap current formula with collisionality
  - Non-uniform grid support with metric tensors
  - Per-equation tolerance configuration (eliminate hardcoded `1e-6`)
  - Integration test suite (analytical solutions, conservation, TORAX benchmark)

  **Status**: Design Complete, Ready for Implementation (40-50 hours, ~1 week)
  **Impact**: TORAX-equivalent physics accuracy + configurable numerical tolerances

---

## User Interface

- **[VISUALIZATION_DESIGN.md](VISUALIZATION_DESIGN.md)**
  GotenxUI visualization system design (Swift Charts-based 2D/3D plotting).

- **[GotenxUI_Requirements.md](GotenxUI_Requirements.md)**
  Detailed UI requirements for tokamak plasma visualization.

- **[GUI_APPLICATION_DESIGN.md](GUI_APPLICATION_DESIGN.md)**
  Future macOS GUI application design (SwiftUI-based).

---

## Future Roadmap

- **[PHASE5_7_IMPLEMENTATION_PLAN.md](PHASE5_7_IMPLEMENTATION_PLAN.md)**
  Phases 5-7 implementation plan:
  - Phase 5: IMAS-compatible I/O (ITER integration)
  - Phase 6: Experimental data validation
  - Phase 7: Automatic differentiation for optimization

---

## Quick Reference

| Topic | Document | Status |
|-------|----------|--------|
| **Development** | [CLAUDE.md](../CLAUDE.md) | ✅ Active |
| **Architecture** | [ARCHITECTURE.md](ARCHITECTURE.md) | ✅ Reference |
| **Unit System** | [UNIT_SYSTEM.md](UNIT_SYSTEM.md) | ✅ Reference |
| **Configuration** | [CONFIGURATION_SYSTEM.md](CONFIGURATION_SYSTEM.md) | ✅ Reference |
| **Numerical Precision** | [NUMERICAL_PRECISION.md](NUMERICAL_PRECISION.md) | ✅ Reference |
| **MLX Best Practices** | [MLX_BEST_PRACTICES.md](MLX_BEST_PRACTICES.md) | ✅ Reference |
| **Swift Concurrency** | [SWIFT_CONCURRENCY.md](SWIFT_CONCURRENCY.md) | ✅ Reference |
| **Transport Models** | [TRANSPORT_MODELS.md](TRANSPORT_MODELS.md) | ✅ Reference |
| **MHD Implementation** | [PHASE8_MHD_IMPLEMENTATION.md](PHASE8_MHD_IMPLEMENTATION.md) | ✅ Complete |
| Conservation Laws | [CONSERVATION_AND_DIAGNOSTICS_DESIGN.md](CONSERVATION_AND_DIAGNOSTICS_DESIGN.md) | ✅ Implemented |
| **FVM Improvements** | [FVM_NUMERICAL_IMPROVEMENTS_PLAN.md](FVM_NUMERICAL_IMPROVEMENTS_PLAN.md) | 🔥 **Priority** |
| Visualization | [VISUALIZATION_DESIGN.md](VISUALIZATION_DESIGN.md) | 🚧 In Progress |
| TORAX Validation | [TORAX_COMPARISON_AND_VALIDATION.md](TORAX_COMPARISON_AND_VALIDATION.md) | 📋 Planned |
| Future Phases (5-7) | [PHASE5_7_IMPLEMENTATION_PLAN.md](PHASE5_7_IMPLEMENTATION_PLAN.md) | 📋 Roadmap |

---

## Document Organization

### Development vs. User Documentation

| Purpose | Location | Audience |
|---------|----------|----------|
| **Active development guidance** | `CLAUDE.md` | Claude Code, Contributors |
| **Technical specifications** | `docs/*.md` | Developers, Maintainers |
| **User guides** | `README.md`, `Examples/` | End Users |

### When to Consult Which Document

**Starting a new feature?**
→ Start with [CLAUDE.md](../CLAUDE.md) for architecture patterns and constraints.

**Improving FVM numerics?** 🔥
→ See [FVM_NUMERICAL_IMPROVEMENTS_PLAN.md](FVM_NUMERICAL_IMPROVEMENTS_PLAN.md) for power-law scheme, Sauter bootstrap, and tolerance configuration.

**Implementing conservation laws?**
→ See [CONSERVATION_AND_DIAGNOSTICS_DESIGN.md](CONSERVATION_AND_DIAGNOSTICS_DESIGN.md).

**Working on MHD models?**
→ See [PHASE8_MHD_IMPLEMENTATION.md](PHASE8_MHD_IMPLEMENTATION.md) for sawtooth implementation and physics.

**Adding visualization?**
→ Check [VISUALIZATION_DESIGN.md](VISUALIZATION_DESIGN.md) and [GotenxUI_Requirements.md](GotenxUI_Requirements.md).

**Planning future work?**
→ Review [PHASE5_7_IMPLEMENTATION_PLAN.md](PHASE5_7_IMPLEMENTATION_PLAN.md).

---

## Contributing Documentation

When adding new documentation:

1. **Technical Design Docs** → Place in `docs/` with descriptive name
2. **Update This Index** → Add link to appropriate section
3. **Reference from CLAUDE.md** → If relevant for active development

---

*Last updated: 2025-10-23* (Added Phase 8 MHD Implementation)
