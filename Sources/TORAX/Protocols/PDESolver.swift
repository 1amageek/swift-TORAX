import MLX
import Foundation

// MARK: - CoeffsCallback

/// Coefficient calculation callback (synchronous, thread-safe)
///
/// The callback accepts only (CoreProfiles, Geometry) as parameters.
/// Additional context (dynamicParams, staticParams, etc.) is provided via closure capture.
public typealias CoeffsCallback = @Sendable (CoreProfiles, Geometry) -> Block1DCoeffs

// MARK: - PDE Solver Protocol

/// PDE solver protocol for solving the transport equations
public protocol PDESolver {
    /// Solver type
    var solverType: SolverType { get }

    /// Solve PDE system for one timestep
    ///
    /// - Parameters:
    ///   - dt: Time step [s]
    ///   - staticParams: Static runtime parameters
    ///   - dynamicParamsT: Dynamic parameters at time t
    ///   - dynamicParamsTplusDt: Dynamic parameters at time t+dt
    ///   - geometryT: Geometry at time t
    ///   - geometryTplusDt: Geometry at time t+dt
    ///   - xOld: Old state (Ti, Te, ne, psi) as CellVariable tuple
    ///   - coreProfilesT: Core profiles at time t
    ///   - coreProfilesTplusDt: Core profiles at time t+dt (initial guess)
    ///   - coeffsCallback: Callback for computing coefficients
    /// - Returns: Solver result with updated profiles
    func solve(
        dt: Float,
        staticParams: StaticRuntimeParams,
        dynamicParamsT: DynamicRuntimeParams,
        dynamicParamsTplusDt: DynamicRuntimeParams,
        geometryT: Geometry,
        geometryTplusDt: Geometry,
        xOld: (CellVariable, CellVariable, CellVariable, CellVariable),
        coreProfilesT: CoreProfiles,
        coreProfilesTplusDt: CoreProfiles,
        coeffsCallback: @escaping CoeffsCallback
    ) -> SolverResult
}
