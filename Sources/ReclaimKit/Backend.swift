import Foundation

/// A supported Docker runtime backend on macOS.
public enum Backend: String, CaseIterable, Codable, Equatable {
    case colima
    case orbstack
    case rancherDesktop
    case dockerDesktop

    /// Human-readable name for CLI/UI display.
    public var displayName: String {
        switch self {
        case .colima: return "Colima"
        case .orbstack: return "OrbStack"
        case .rancherDesktop: return "Rancher Desktop"
        case .dockerDesktop: return "Docker Desktop"
        }
    }
}

/// A backend that was detected as live (socket exists and responded to `/_ping`).
public struct DetectedBackend: Equatable {
    public let backend: Backend
    public let socketPath: String

    public init(backend: Backend, socketPath: String) {
        self.backend = backend
        self.socketPath = socketPath
    }
}
