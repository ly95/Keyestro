import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func clipboardAutoPasteIsExplicitAndUsesTheCapturedFrontmostApplication() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-provider-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-provider-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let keys = InstallationKeyManager(
        keychain: InMemoryKeychainService(),
        service: "com.keyestro.clipboard-provider-tests"
    )
    let store = ClipboardStore(database: database, keyManager: keys)
    await store.initialize(enabled: true)
    let itemID = try #require((await store.capture(.text("paste me"), sourceBundleIdentifier: nil)).successValue)

    let pasteboard = FakePasteboard()
    let autoPaste = RecordingAutoPasteService()
    let provider = ClipboardProvider(store: store, pasteboard: pasteboard, autoPaste: autoPaste)
    let request = QueryRequest(
        generation: 1,
        rawText: "paste",
        normalizedText: "paste",
        mode: .all,
        context: QueryContext(
            frontmostBundleIdentifier: "com.example.target",
            frontmostApplicationName: "Target Editor"
        )
    )
    var items: [LauncherItem] = []
    for try await event in provider.search(request: request) {
        if case let .items(batch, _) = event { items = batch }
    }
    let item = try #require(items.first)
    #expect(item.id.providerStableID == itemID)
    #expect(item.defaultActionID == "copy")
    let autoPasteAction = item.actions.first(where: { $0.id == "autoPaste" })
    #expect(autoPasteAction?.risk == .externalSideEffect)
    #expect(autoPasteAction?.confirmationTarget == "Target Editor (com.example.target)")
    #expect(item.actions.first(where: { $0.id == "delete" })?.confirmationTarget == "ID \(itemID)")

    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: item.id,
            actionID: "autoPaste",
            arguments: [:]
        )
    )
    #expect(result == .success())
    #expect(await autoPaste.lastTarget == "com.example.target")
    #expect(await pasteboard.writtenContent == .text("paste me"))
}

@Test func clipboardProviderFailsClosedForEmptyUnavailableAndInvalidRequests() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-provider-boundaries-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-provider-boundary-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let store = ClipboardStore(
        database: database,
        keyManager: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.clipboard-provider-boundary-tests"
        )
    )
    let pasteboard = FakePasteboard()
    let actions = ClipboardActionService(store: store, pasteboard: pasteboard, autoPaste: RecordingAutoPasteService())
    let provider = ClipboardProvider(store: store, actions: actions)

    let emptyEvents = try await collectedClipboardEvents(
        provider.search(
            request: QueryRequest(generation: 1, rawText: "", normalizedText: "", mode: .all)
        )
    )
    #expect(emptyEvents.count == 1)
    #expect(
        emptyEvents.contains { event in
            if case let .items(items, isFinal) = event { return items.isEmpty && isFinal }
            return false
        })

    let unavailableEvents = try await collectedClipboardEvents(
        provider.search(
            request: QueryRequest(generation: 2, rawText: "x", normalizedText: "x", mode: .all)
        )
    )
    #expect(
        unavailableEvents.contains { event in
            if case .status(.unavailable) = event { return true }
            return false
        })

    let invalidItem = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "other", providerStableID: "item"),
            actionID: "copy",
            arguments: [:]
        )
    )
    #expect(invalidItem == .failure(ErrorDescriptor(code: "clipboard.invalidItem", message: "The clipboard item is invalid.")))

    let invalidAction = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: "item"),
            actionID: "unknown",
            arguments: [:]
        )
    )
    #expect(invalidAction == .failure(ErrorDescriptor(code: "clipboard.invalidAction", message: "The clipboard action is invalid.")))
    #expect(ClipboardProvider.symbol(for: .text) == "text.alignleft")
    #expect(ClipboardProvider.symbol(for: .url) == "link")
    #expect(ClipboardProvider.symbol(for: .files) == "doc.on.doc")
    #expect(ClipboardProvider.symbol(for: .image) == "photo")
    await database.close()
}

@MainActor
private final class FakePasteboard: PasteboardServicing, @unchecked Sendable {
    var changeCount = 0
    var writtenContent: ClipboardContent?

    func readSupportedContent() -> ClipboardContent? { nil }

    func write(_ content: ClipboardContent) -> Bool {
        writtenContent = content
        return true
    }
}

private actor RecordingAutoPasteService: AutoPasteServicing {
    private(set) var lastTarget: String?

    func paste(intoBundleIdentifier bundleIdentifier: String?) -> Result<Void, ErrorDescriptor> {
        lastTarget = bundleIdentifier
        return .success(())
    }
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self { return value }
        return nil
    }
}

private func collectedClipboardEvents(
    _ stream: AsyncThrowingStream<ProviderEvent, any Error>
) async throws -> [ProviderEvent] {
    var events: [ProviderEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
