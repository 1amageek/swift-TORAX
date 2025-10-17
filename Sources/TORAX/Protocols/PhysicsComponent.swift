import Foundation

// MARK: - Physics Component Protocol

/// Base protocol for physics components
public protocol PhysicsComponent {
    /// Component name (for identification and configuration)
    var name: String { get }
}
