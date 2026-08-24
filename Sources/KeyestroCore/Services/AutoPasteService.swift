import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import KeyestroDomain

public enum AutoPasteActivationPolicy: Equatable, Sendable {
    /// Used by an explicit history-panel action: reactivate the application that
    /// was frontmost when the panel opened.
    case activateIfNeeded
    /// Used by Quick Paste: never redirect input if focus moved after invocation.
    case requireFrontmost
}

public struct AutoPasteTarget: Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32?
    public let activationPolicy: AutoPasteActivationPolicy

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32? = nil,
        activationPolicy: AutoPasteActivationPolicy
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.activationPolicy = activationPolicy
    }
}

public protocol AutoPasteServicing: Sendable {
    func paste(intoBundleIdentifier bundleIdentifier: String?) async -> Result<Void, ErrorDescriptor>
    func validate(target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor>
    func paste(into target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor>
}

extension AutoPasteServicing {
    public func validate(target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor> {
        .success(())
    }

    public func paste(into target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor> {
        await paste(intoBundleIdentifier: target.bundleIdentifier)
    }
}

/// Activates the application that was frontmost when Keyestro opened, then sends
/// Command-V. This is intentionally a separate, explicit action because synthetic
/// keyboard input requires Accessibility permission.
public struct MacAutoPasteService: AutoPasteServicing, Sendable {
    public init() {}

    public func paste(intoBundleIdentifier bundleIdentifier: String?) async -> Result<Void, ErrorDescriptor> {
        guard let bundleIdentifier else {
            return .failure(Self.targetUnavailableError)
        }
        return await paste(
            into: AutoPasteTarget(
                bundleIdentifier: bundleIdentifier,
                activationPolicy: .activateIfNeeded
            )
        )
    }

    public func validate(target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor> {
        await MainActor.run {
            switch Self.resolveApplication(for: target) {
            case let .success(application):
                if target.activationPolicy == .requireFrontmost,
                    !Self.isFrontmost(application, target: target)
                {
                    return .failure(Self.targetChangedError)
                }
                return .success(())
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    public func paste(into target: AutoPasteTarget) async -> Result<Void, ErrorDescriptor> {
        switch await validate(target: target) {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }

        if target.activationPolicy == .activateIfNeeded {
            let activationResult = await MainActor.run { () -> Result<Void, ErrorDescriptor> in
                switch Self.resolveApplication(for: target) {
                case let .success(application):
                    guard application.activate() else {
                        return .failure(
                            ErrorDescriptor(
                                code: "clipboard.autoPaste.activationFailed",
                                message: "The target application could not be activated."
                            )
                        )
                    }
                    return .success(())
                case let .failure(error):
                    return .failure(error)
                }
            }
            if case let .failure(error) = activationResult { return .failure(error) }
            if case let .failure(error) = await Self.waitUntilFrontmost(target) {
                return .failure(error)
            }
        }

        return await MainActor.run {
            switch Self.resolveApplication(for: target) {
            case let .success(application):
                guard Self.isFrontmost(application, target: target) else {
                    return .failure(Self.targetChangedError)
                }
            case let .failure(error):
                return .failure(error)
            }
            guard let source = CGEventSource(stateID: .hidSystemState),
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: true
                ),
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: CGKeyCode(kVK_ANSI_V),
                    keyDown: false
                )
            else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.autoPaste.eventFailed",
                        message: "The paste keystroke could not be created."
                    )
                )
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return .success(())
        }
    }

    @MainActor
    private static func resolveApplication(
        for target: AutoPasteTarget
    ) -> Result<NSRunningApplication, ErrorDescriptor> {
        guard AXIsProcessTrusted() else {
            return .failure(
                ErrorDescriptor(
                    code: "clipboard.autoPaste.permissionDenied",
                    message: "Accessibility permission is required for automatic paste.",
                    recoverySuggestion: "Open Settings → Permissions to grant access, then try again."
                )
            )
        }
        guard target.bundleIdentifier != Bundle.main.bundleIdentifier,
            target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: target.bundleIdentifier
            ).first(where: { candidate in
                !candidate.isTerminated
                    && (target.processIdentifier == nil || candidate.processIdentifier == target.processIdentifier)
            })
        else {
            return .failure(targetUnavailableError)
        }
        return .success(application)
    }

    @MainActor
    private static func isFrontmost(_ application: NSRunningApplication, target: AutoPasteTarget) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.bundleIdentifier == target.bundleIdentifier,
            !frontmost.isTerminated
        else { return false }
        return target.processIdentifier == nil || frontmost.processIdentifier == application.processIdentifier
    }

    private static func waitUntilFrontmost(
        _ target: AutoPasteTarget
    ) async -> Result<Void, ErrorDescriptor> {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
        while true {
            let state = await MainActor.run { () -> Result<Bool, ErrorDescriptor> in
                switch resolveApplication(for: target) {
                case let .success(application):
                    return .success(isFrontmost(application, target: target))
                case let .failure(error):
                    return .failure(error)
                }
            }
            switch state {
            case .success(true):
                return .success(())
            case let .failure(error):
                return .failure(error)
            case .success(false):
                break
            }
            guard ContinuousClock.now < deadline else {
                return .failure(targetChangedError)
            }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return .failure(targetChangedError)
            }
        }
    }

    private static let targetUnavailableError = ErrorDescriptor(
        code: "clipboard.autoPaste.targetUnavailable",
        message: "The target application is no longer available.",
        recoverySuggestion: "Keep the destination application open and frontmost, then try again."
    )

    private static let targetChangedError = ErrorDescriptor(
        code: "clipboard.autoPaste.targetChanged",
        message: "The frontmost application changed before paste.",
        recoverySuggestion: "Return to the destination field and try again."
    )
}
