import Foundation
import KeyestroDomain

private actor ClipboardPasteTargetCache {
    private var targets: [String: String?] = [:]

    func replace(ids: [String], targetBundleIdentifier: String?) {
        targets = Dictionary(uniqueKeysWithValues: ids.map { ($0, targetBundleIdentifier) })
    }

    func target(for id: String) -> String? {
        targets[id] ?? nil
    }
}

public struct ClipboardProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "clipboard",
        displayName: "Clipboard",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    private let store: ClipboardStore
    private let pasteboard: any PasteboardServicing
    private let autoPaste: any AutoPasteServicing
    private let pasteTargets = ClipboardPasteTargetCache()

    public init(
        store: ClipboardStore,
        pasteboard: any PasteboardServicing,
        autoPaste: any AutoPasteServicing = MacAutoPasteService()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.autoPaste = autoPaste
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let task = Task {
            guard !request.normalizedText.isEmpty else {
                continuation.yield(.items([], isFinal: true))
                continuation.finish()
                return
            }
            switch await store.search(request.normalizedText, limit: request.limit) {
            case let .success(entries):
                let formatter = RelativeDateTimeFormatter()
                await pasteTargets.replace(
                    ids: entries.map(\.id),
                    targetBundleIdentifier: request.context.frontmostBundleIdentifier
                )
                let items = entries.map { entry in
                    let itemID = ItemID(providerID: descriptor.id, providerStableID: entry.id)
                    let copy = ActionDescriptor(id: "copy", title: "Copy to Clipboard", icon: .systemSymbol("doc.on.clipboard"))
                    return LauncherItem(
                        id: itemID,
                        providerID: descriptor.id,
                        title: entry.title,
                        subtitle: [
                            entry.subtitle,
                            entry.sourceBundleIdentifier,
                            formatter.localizedString(for: entry.lastCopiedAt, relativeTo: Date()),
                        ].compactMap { $0 }.joined(separator: " · "),
                        icon: entry.thumbnailPNG.map(IconReference.thumbnailPNG)
                            ?? .systemSymbol(Self.symbol(for: entry.contentType)),
                        canonicalResource: .command("clipboard:\(entry.id)"),
                        keywords: [entry.contentType.rawValue, "clipboard", "copied"],
                        actions: [
                            copy,
                            ActionDescriptor(
                                id: "autoPaste",
                                title: "Paste into Previous App",
                                icon: .systemSymbol("arrowshape.turn.up.left"),
                                behavior: .closeLauncher,
                                risk: .externalSideEffect,
                                confirmationTarget: Self.pasteConfirmationTarget(for: request.context)
                            ),
                            ActionDescriptor(
                                id: "delete",
                                title: "Delete from History",
                                icon: .systemSymbol("trash"),
                                behavior: .keepLauncherOpen,
                                risk: .destructive,
                                confirmationTarget: "ID \(entry.id)"
                            ),
                        ],
                        defaultActionID: copy.id,
                        scoreFeatures: ScoreFeatures(lastUsedAt: entry.lastCopiedAt, providerPrior: 0.35),
                        privacy: entry.isSensitive ? .sensitive : .normal
                    )
                }
                continuation.yield(.items(items, isFinal: true))
            case let .failure(error):
                continuation.yield(.status(.unavailable(error)))
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id else {
            return .failure(ErrorDescriptor(code: "clipboard.invalidItem", message: "The clipboard item is invalid."))
        }
        switch request.actionID.rawValue {
        case "copy", "autoPaste":
            switch await store.content(id: request.itemID.providerStableID) {
            case let .success(content):
                guard await pasteboard.write(content) else {
                    return .failure(
                        ErrorDescriptor(code: "clipboard.writeFailed", message: "The item could not be written to the clipboard.")
                    )
                }
                guard request.actionID == "autoPaste" else { return .success(message: "Copied") }
                let target = await pasteTargets.target(for: request.itemID.providerStableID)
                switch await autoPaste.paste(intoBundleIdentifier: target) {
                case .success: return .success()
                case let .failure(error): return .failure(error)
                }
            case let .failure(error): return .failure(error)
            }
        case "delete":
            switch await store.delete(id: request.itemID.providerStableID) {
            case .success: return .success(message: "Clipboard item deleted")
            case let .failure(error): return .failure(error)
            }
        default:
            return .failure(ErrorDescriptor(code: "clipboard.invalidAction", message: "The clipboard action is invalid."))
        }
    }

    private static func symbol(for type: ClipboardContentType) -> String {
        switch type {
        case .text: "text.alignleft"
        case .url: "link"
        case .files: "doc.on.doc"
        case .image: "photo"
        }
    }

    private static func pasteConfirmationTarget(for context: QueryContext) -> String {
        switch (context.frontmostApplicationName, context.frontmostBundleIdentifier) {
        case let (name?, bundleIdentifier?):
            return "\(name) (\(bundleIdentifier))"
        case let (name?, nil):
            return name
        case let (nil, bundleIdentifier?):
            return bundleIdentifier
        case (nil, nil):
            return "Previous application (currently unavailable)"
        }
    }
}
