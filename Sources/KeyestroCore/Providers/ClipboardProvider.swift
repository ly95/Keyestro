import Foundation
import KeyestroDomain

private actor ClipboardPasteTargetCache {
    private var targets: [String: AutoPasteTarget?] = [:]

    func replace(ids: [String], target: AutoPasteTarget?) {
        targets = Dictionary(uniqueKeysWithValues: ids.map { ($0, target) })
    }

    func target(for id: String) -> AutoPasteTarget? {
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
    private let actions: ClipboardActionService
    private let pasteTargets = ClipboardPasteTargetCache()

    public init(
        store: ClipboardStore,
        pasteboard: any PasteboardServicing,
        autoPaste: any AutoPasteServicing = MacAutoPasteService()
    ) {
        self.store = store
        actions = ClipboardActionService(store: store, pasteboard: pasteboard, autoPaste: autoPaste)
    }

    public init(store: ClipboardStore, actions: ClipboardActionService) {
        self.store = store
        self.actions = actions
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
                let target = request.context.frontmostBundleIdentifier.map {
                    AutoPasteTarget(
                        bundleIdentifier: $0,
                        processIdentifier: request.context.frontmostProcessIdentifier,
                        activationPolicy: .activateIfNeeded
                    )
                }
                await pasteTargets.replace(
                    ids: entries.map(\.id),
                    target: target
                )
                let items = entries.map { entry in
                    let itemID = ItemID(providerID: descriptor.id, providerStableID: entry.id)
                    let actions = ClipboardActionCatalog.descriptors(
                        itemID: entry.id,
                        pasteConfirmationTarget: ClipboardActionCatalog.pasteConfirmationTarget(
                            applicationName: request.context.frontmostApplicationName,
                            bundleIdentifier: request.context.frontmostBundleIdentifier
                        )
                    )
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
                        actions: actions,
                        defaultActionID: ClipboardActionKind.autoPaste.id,
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
        guard let action = ClipboardActionKind(rawValue: request.actionID.rawValue) else {
            return .failure(ErrorDescriptor(code: "clipboard.invalidAction", message: "The clipboard action is invalid."))
        }
        let target = await pasteTargets.target(for: request.itemID.providerStableID)
        return await actions.execute(
            action,
            itemID: request.itemID.providerStableID,
            target: target
        )
    }

    static func symbol(for type: ClipboardContentType) -> String {
        switch type {
        case .text: "text.alignleft"
        case .url: "link"
        case .files: "doc.on.doc"
        case .image: "photo"
        }
    }

}
