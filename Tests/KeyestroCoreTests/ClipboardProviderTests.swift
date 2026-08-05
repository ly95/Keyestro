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
