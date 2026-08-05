import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import KeyestroDomain

public enum SystemCommandID: String, Codable, CaseIterable, Sendable {
    case sleepSystem
    case openSystemSettings
    case openAccessibilitySettings
    case openScreenRecordingSettings
    case openApplicationsFolder
    case openDownloadsFolder
    case openHomeFolder
}

public protocol SystemCommandServicing: Sendable {
    @MainActor func execute(_ command: SystemCommandID) -> Result<Void, ErrorDescriptor>
}

public struct MacSystemCommandService: SystemCommandServicing, Sendable {
    public init() {}

    @MainActor
    public func execute(_ command: SystemCommandID) -> Result<Void, ErrorDescriptor> {
        switch command {
        case .sleepSystem:
            let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            guard connection != IO_OBJECT_NULL else {
                return .failure(ErrorDescriptor(code: "system.sleepUnavailable", message: "System sleep is unavailable."))
            }
            defer { IOServiceClose(connection) }
            let status = IOPMSleepSystem(connection)
            guard status == kIOReturnSuccess else {
                return .failure(ErrorDescriptor(code: "system.sleepFailed.\(status)", message: "The Mac could not be put to sleep."))
            }
            return .success(())
        case .openSystemSettings:
            return open(URL(string: "x-apple.systempreferences:"))
        case .openAccessibilitySettings:
            return open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
        case .openScreenRecordingSettings:
            return open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        case .openApplicationsFolder:
            return open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .openDownloadsFolder:
            return open(
                FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            )
        case .openHomeFolder:
            return open(FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @MainActor
    private func open(_ url: URL?) -> Result<Void, ErrorDescriptor> {
        guard let url, NSWorkspace.shared.open(url) else {
            return .failure(ErrorDescriptor(code: "system.openFailed", message: "The system location could not be opened."))
        }
        return .success(())
    }
}
