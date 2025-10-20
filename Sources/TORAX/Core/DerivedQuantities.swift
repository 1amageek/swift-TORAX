// DerivedQuantities.swift
// Derived scalar quantities for performance monitoring and visualization
//
// Phase 1 Implementation: Minimal structure with default values
// Phase 2 Implementation: Actual computation from CoreProfiles
// Phase 3 Implementation: Advanced metrics using transport/sources

import Foundation
import MLX

/// Derived scalar quantities computed from simulation state
///
/// **Design Philosophy**:
/// - All quantities are scalars (0D) - cheap to compute and store
/// - Computed at every timestep for real-time monitoring
/// - Independent of transport models (Phase 1-2) or dependent (Phase 3)
///
/// **Implementation Phases**:
/// - Phase 1 (Current): Returns default values (zeros)
/// - Phase 2: Computes central values, volume averages, total energies
/// - Phase 3: Computes confinement metrics (τE, Q, βN) using transport/sources
public struct DerivedQuantities: Sendable, Codable, Equatable {
    // MARK: - Central Values

    /// Ion temperature at magnetic axis (ρ=0) [eV]
    ///
    /// **Unit**: eV (TORAX internal standard, NOT keV)
    public let Ti_core: Float

    /// Electron temperature at magnetic axis (ρ=0) [eV]
    ///
    /// **Unit**: eV (TORAX internal standard, NOT keV)
    public let Te_core: Float

    /// Electron density at magnetic axis (ρ=0) [m^-3]
    ///
    /// **Unit**: m^-3 (TORAX internal standard, NOT 10^20 m^-3)
    public let ne_core: Float

    // MARK: - Volume Averages

    /// Volume-averaged electron density [m^-3]
    ///
    /// **Unit**: m^-3 (TORAX internal standard, NOT 10^20 m^-3)
    public let ne_avg: Float

    /// Volume-averaged ion temperature [eV]
    ///
    /// **Unit**: eV (TORAX internal standard, NOT keV)
    public let Ti_avg: Float

    /// Volume-averaged electron temperature [eV]
    ///
    /// **Unit**: eV (TORAX internal standard, NOT keV)
    public let Te_avg: Float

    // MARK: - Total Energies

    /// Total thermal energy [MJ]
    public let W_thermal: Float

    /// Ion thermal energy [MJ]
    public let W_ion: Float

    /// Electron thermal energy [MJ]
    public let W_electron: Float

    // MARK: - Fusion Performance

    /// Fusion power [MW]
    public let P_fusion: Float

    /// Alpha particle heating power [MW]
    public let P_alpha: Float

    /// Auxiliary heating power [MW]
    public let P_auxiliary: Float

    /// Ohmic heating power [MW]
    ///
    /// **Added**: For complete Q = P_fusion / (P_auxiliary + P_ohmic) calculation
    public let P_ohmic: Float

    // MARK: - Confinement Metrics

    /// Energy confinement time [s]
    public let tau_E: Float

    /// Energy confinement time from scaling law [s]
    public let tau_E_scaling: Float

    /// H-factor (τE / τE_scaling)
    public let H_factor: Float

    // MARK: - Beta Limits

    /// Toroidal beta [%]
    public let beta_toroidal: Float

    /// Poloidal beta
    public let beta_poloidal: Float

    /// Normalized beta βN = β(%) × a(m) × B(T) / Ip(MA)
    public let beta_N: Float

    /// Troyon beta limit
    public let beta_N_limit: Float

    // MARK: - Current Drive

    /// Total plasma current [MA]
    public let I_plasma: Float

    /// Bootstrap current [MA]
    public let I_bootstrap: Float

    /// Bootstrap fraction f_bs = I_bootstrap / I_plasma
    public let f_bootstrap: Float

    // MARK: - Triple Product

    /// Lawson triple product n⟨T⟩τE [eV s m^-3]
    ///
    /// **Unit**: eV s m^-3 (TORAX internal standard)
    ///
    /// **Note**: Commonly displayed as 10^21 keV s m^-3 in literature.
    /// For conversion: value_displayed = n_T_tau / 1e24
    public let n_T_tau: Float

    // MARK: - Initialization

    public init(
        Ti_core: Float,
        Te_core: Float,
        ne_core: Float,
        ne_avg: Float,
        Ti_avg: Float,
        Te_avg: Float,
        W_thermal: Float,
        W_ion: Float,
        W_electron: Float,
        P_fusion: Float,
        P_alpha: Float,
        P_auxiliary: Float,
        P_ohmic: Float,
        tau_E: Float,
        tau_E_scaling: Float,
        H_factor: Float,
        beta_toroidal: Float,
        beta_poloidal: Float,
        beta_N: Float,
        beta_N_limit: Float,
        I_plasma: Float,
        I_bootstrap: Float,
        f_bootstrap: Float,
        n_T_tau: Float
    ) {
        self.Ti_core = Ti_core
        self.Te_core = Te_core
        self.ne_core = ne_core
        self.ne_avg = ne_avg
        self.Ti_avg = Ti_avg
        self.Te_avg = Te_avg
        self.W_thermal = W_thermal
        self.W_ion = W_ion
        self.W_electron = W_electron
        self.P_fusion = P_fusion
        self.P_alpha = P_alpha
        self.P_auxiliary = P_auxiliary
        self.P_ohmic = P_ohmic
        self.tau_E = tau_E
        self.tau_E_scaling = tau_E_scaling
        self.H_factor = H_factor
        self.beta_toroidal = beta_toroidal
        self.beta_poloidal = beta_poloidal
        self.beta_N = beta_N
        self.beta_N_limit = beta_N_limit
        self.I_plasma = I_plasma
        self.I_bootstrap = I_bootstrap
        self.f_bootstrap = f_bootstrap
        self.n_T_tau = n_T_tau
    }
}

// MARK: - Phase 1: Default Values

extension DerivedQuantities {
    /// Phase 1 implementation: Return default zeros
    ///
    /// **Rationale**: Allows compilation and testing without breaking existing code.
    /// Actual computation will be implemented in Phase 2.
    public static let zero = DerivedQuantities(
        Ti_core: 0,
        Te_core: 0,
        ne_core: 0,
        ne_avg: 0,
        Ti_avg: 0,
        Te_avg: 0,
        W_thermal: 0,
        W_ion: 0,
        W_electron: 0,
        P_fusion: 0,
        P_alpha: 0,
        P_auxiliary: 0,
        P_ohmic: 0,
        tau_E: 0,
        tau_E_scaling: 0,
        H_factor: 0,
        beta_toroidal: 0,
        beta_poloidal: 0,
        beta_N: 0,
        beta_N_limit: 0,
        I_plasma: 0,
        I_bootstrap: 0,
        f_bootstrap: 0,
        n_T_tau: 0
    )
}
