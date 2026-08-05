import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import KeyestroDomain

public protocol AutoPasteServicing: Sendable {
    func paste(intoBundleIdentifier bundleIdentifier: String?) async -> Result<Void, ErrorDescriptor>
}

/// Activates the application that was frontmost when Keyestro opened, then sends
/// Command-V. This is intentionally a separate, explicit action because synthetic
/// keyboard input requires Accessibility permission.
public struct MacAutoPasteService: AutoPasteServicing, Sendable {
    public init() {}

    public func paste(intoBundleIdentifier bundleIdentifier: String?) async -> Result<Void, ErrorDescriptor> {
        await MainActor.run {
            guard AXIsProcessTrusted() else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.autoPaste.permissionDenied",
                        message: "Accessibility permission is required for automatic paste.",
                        recoverySuggestion: "Open Settings → Permissions to grant access, then try again."
                    )
                )
            }
            guard let bundleIdentifier,
                bundleIdentifier != Bundle.main.bundleIdentifier,
                let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { !$0.isTerminated })
            else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.autoPaste.targetUnavailable",
                        message: "The previous application is no longer available."
                    )
                )
            }
            guard application.activate() else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.autoPaste.activationFailed",
                        message: "The previous application could not be activated."
                    )
                )
            }
            guard let source = CGEventSource(stateID: .hidSystemState),
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            else {
                return .failure(
                    ErrorDescriptor(code: "clipboard.autoPaste.eventFailed", message: "The paste keystroke could not be created.")
                )
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return .success(())
        }
    }
}
