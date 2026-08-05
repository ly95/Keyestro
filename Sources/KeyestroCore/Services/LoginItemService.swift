import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LoginItemServicing: Sendable {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) throws
}

public struct MacLoginItemService: LoginItemServicing, Sendable {
    public init() {}

    @MainActor
    public func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    @MainActor
    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
