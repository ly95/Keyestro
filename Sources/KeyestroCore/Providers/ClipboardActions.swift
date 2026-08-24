import Foundation
import KeyestroDomain

public enum ClipboardActionKind: String, CaseIterable, Sendable {
    case copy
    case autoPaste
    case delete

    public var id: ActionID { ActionID(rawValue) }
}

public enum ClipboardActionCatalog {
    public static func pasteConfirmationTarget(
        applicationName: String?,
        bundleIdentifier: String?
    ) -> String {
        switch (applicationName, bundleIdentifier) {
        case let (name?, bundleIdentifier?): "\(name) (\(bundleIdentifier))"
        case let (name?, nil): name
        case let (nil, bundleIdentifier?): bundleIdentifier
        case (nil, nil): "Previous application (currently unavailable)"
        }
    }

    public static func descriptors(
        itemID: String,
        pasteConfirmationTarget: String
    ) -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: ClipboardActionKind.autoPaste.id,
                title: "Paste to Active App",
                icon: .systemSymbol("arrowshape.turn.up.left"),
                behavior: .closeLauncher,
                confirmationTarget: pasteConfirmationTarget
            ),
            ActionDescriptor(
                id: ClipboardActionKind.copy.id,
                title: "Copy to Clipboard",
                icon: .systemSymbol("doc.on.clipboard"),
                shortcut: KeyEquivalent(key: "return", modifiers: [.command])
            ),
            ActionDescriptor(
                id: ClipboardActionKind.delete.id,
                title: "Delete from History",
                icon: .systemSymbol("trash"),
                behavior: .keepLauncherOpen,
                risk: .destructive,
                confirmationTarget: "ID \(itemID)"
            ),
        ]
    }
}

public struct ClipboardActionService: Sendable {
    private let store: ClipboardStore
    private let pasteboard: any PasteboardServicing
    private let autoPaste: any AutoPasteServicing

    public init(
        store: ClipboardStore,
        pasteboard: any PasteboardServicing,
        autoPaste: any AutoPasteServicing = MacAutoPasteService()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.autoPaste = autoPaste
    }

    public func execute(
        _ action: ClipboardActionKind,
        itemID: String,
        targetBundleIdentifier: String?
    ) async -> ActionResult {
        let target = targetBundleIdentifier.map {
            AutoPasteTarget(bundleIdentifier: $0, activationPolicy: .activateIfNeeded)
        }
        return await execute(action, itemID: itemID, target: target)
    }

    public func execute(
        _ action: ClipboardActionKind,
        itemID: String,
        target: AutoPasteTarget?
    ) async -> ActionResult {
        switch action {
        case .copy:
            switch await store.content(id: itemID) {
            case let .success(content):
                guard await writeToPasteboard(content) else {
                    return .failure(
                        ErrorDescriptor(
                            code: "clipboard.writeFailed",
                            message: "The item could not be written to the clipboard."
                        )
                    )
                }
                return .success(message: "Copied")
            case let .failure(error):
                return .failure(error)
            }
        case .autoPaste:
            guard let target else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.autoPaste.targetUnavailable",
                        message: "The target application is no longer available."
                    )
                )
            }
            return await writeAndPaste(itemID: itemID, target: target)
        case .delete:
            switch await store.delete(id: itemID) {
            case .success: return .success(message: "Clipboard item deleted")
            case let .failure(error): return .failure(error)
            }
        }
    }

    /// Executes the fail-closed Quick Paste path. The target is validated before
    /// the pasteboard changes and again immediately before Command-V is posted.
    public func quickPaste(itemID: String, target: AutoPasteTarget) async -> ActionResult {
        await writeAndPaste(itemID: itemID, target: target)
    }

    private func writeAndPaste(itemID: String, target: AutoPasteTarget) async -> ActionResult {
        switch await autoPaste.validate(target: target) {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }
        switch await store.content(id: itemID) {
        case let .success(content):
            guard await writeToPasteboard(content) else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.writeFailed",
                        message: "The item could not be written to the clipboard."
                    )
                )
            }
            switch await autoPaste.paste(into: target) {
            case .success: return .success()
            case let .failure(error): return .failure(error)
            }
        case let .failure(error):
            return .failure(error)
        }
    }

    private func writeToPasteboard(_ content: ClipboardContent) async -> Bool {
        await MainActor.run { pasteboard.write(content) }
    }
}
