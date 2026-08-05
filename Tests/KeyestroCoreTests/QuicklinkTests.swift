import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func quicklinkRemovalRejectsAStaleReviewedDefinitionAtomically() async throws {
    let original = try QuicklinkDefinition(
        id: "stale-delete",
        title: "Original",
        urlTemplate: "https://example.com/original",
        arguments: []
    )
    let current = try QuicklinkDefinition(
        id: original.id,
        title: "Current",
        urlTemplate: "https://example.com/current",
        arguments: [],
        createdAt: original.createdAt,
        updatedAt: original.updatedAt.addingTimeInterval(1)
    )
    let store = InMemoryQuicklinkStore(definitions: [original])
    await store.saveQuicklink(current)

    #expect(await store.deleteQuicklink(ifUnchanged: original) == false)
    #expect(await store.quicklink(id: original.id) == current)
    #expect(await store.deleteQuicklink(ifUnchanged: current))
    #expect(await store.quicklink(id: original.id) == nil)
}

@MainActor
private final class RecordingURLOpener: URLOpening {
    private(set) var openedURLs: [URL] = []
    private(set) var browserBundleIdentifiers: [String?] = []

    func open(_ url: URL, browserBundleIdentifier: String?) async -> Bool {
        openedURLs.append(url)
        browserBundleIdentifiers.append(browserBundleIdentifier)
        return true
    }

    func count() -> Int { openedURLs.count }
    func browsers() -> [String?] { browserBundleIdentifiers }
}

@Test func quicklinkCanTargetAValidatedSpecificBrowser() async throws {
    let link = try QuicklinkDefinition(
        id: "browser-specific",
        title: "Open in Browser",
        urlTemplate: "https://example.com",
        arguments: [],
        browserBundleIdentifier: "com.apple.Safari"
    )
    let opener = RecordingURLOpener()
    let provider = QuicklinkProvider(
        store: InMemoryQuicklinkStore(definitions: [link]),
        urlOpener: opener
    )
    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: link.id),
            actionID: "open",
            arguments: [:]
        )
    )

    #expect(result == .success())
    #expect(await opener.browsers() == ["com.apple.Safari"])
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkDefinition(
            id: "invalid-browser",
            title: "Invalid Browser",
            urlTemplate: "https://example.com",
            arguments: [],
            browserBundleIdentifier: "com.apple.Safari;open"
        )
    }
}

@Test func quicklinkEncodesArgumentsWithoutQueryInjection() throws {
    let link = try QuicklinkDefinition.inferred(
        id: "docs",
        title: "Docs",
        urlTemplate: "https://example.com/search?q={query}"
    )
    let url = try QuicklinkProvider.render(
        definition: link,
        values: ["query": .text("a&admin=true / 中文")]
    )
    #expect(url.absoluteString == "https://example.com/search?q=a%26admin%3Dtrue%20%2F%20%E4%B8%AD%E6%96%87")
}

@Test func quicklinkRequiresDefinedArguments() throws {
    let link = try QuicklinkDefinition.inferred(
        id: "docs",
        title: "Docs",
        urlTemplate: "https://example.com/{query}"
    )
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkProvider.render(definition: link, values: [:])
    }
}

@Test func quicklinkRejectsArgumentsThatCannotCrossAURLBoundarySafely() throws {
    let link = try QuicklinkDefinition.inferred(
        id: "bounded",
        title: "Bounded",
        urlTemplate: "https://example.com/{query}"
    )
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkProvider.render(definition: link, values: ["query": .text("before\u{0}after")])
    }
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkProvider.render(
            definition: link,
            values: ["query": .text(String(repeating: "x", count: 8_193))]
        )
    }
}

@Test func quicklinkRejectsMalformedPlaceholderSyntax() {
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkDefinition(
            id: "invalid-placeholder",
            title: "Invalid",
            urlTemplate: "https://example.com/{bad:name}",
            arguments: []
        )
    }
}

@Test func quicklinkRejectsEmbeddedCredentialsButAllowsSecretPlaceholders() throws {
    #expect(throws: (any Error).self) {
        try QuicklinkDefinition.inferred(title: "Credentials", urlTemplate: "https://user:password@example.com")
    }
    #expect(throws: (any Error).self) {
        try QuicklinkDefinition.inferred(title: "API key", urlTemplate: "https://example.com/?api_key=top-secret")
    }

    let placeholder = try QuicklinkDefinition.inferred(
        title: "API key prompt",
        urlTemplate: "https://example.com/?api_key={token}"
    )
    #expect(placeholder.arguments.map(\.id) == ["token"])
}

@Test func quicklinkCustomSchemeRequiresFirstUseConfirmationAndThenRemainsApproved() async throws {
    let link = try QuicklinkDefinition(
        id: "editor",
        title: "Open Editor",
        urlTemplate: "editor://open/{path}",
        arguments: [ArgumentDefinition(id: "path", title: "Path", kind: .text, required: true)]
    )
    let store = InMemoryQuicklinkStore(definitions: [link])
    let opener = RecordingURLOpener()
    let authorization = InMemoryURLSchemeAuthorization()
    let provider = QuicklinkProvider(
        store: store,
        urlOpener: opener,
        schemeAuthorization: authorization
    )

    let first = await quicklinkItems(from: provider)
    #expect(first.first?.actions.first?.risk == .externalSideEffect)
    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: link.id),
            actionID: "open",
            arguments: ["path": .text("folder/file")]
        )
    )
    #expect(result == .success())
    #expect(await opener.count() == 1)

    let second = await quicklinkItems(from: provider)
    #expect(second.first?.actions.first?.risk == .safe)
}

private func quicklinkItems(from provider: QuicklinkProvider) async -> [LauncherItem] {
    let request = QueryRequest(generation: 1, rawText: "", normalizedText: "", mode: .all)
    let stream = provider.search(request: request)
    do {
        for try await event in stream {
            if case let .items(items, true) = event { return items }
        }
    } catch {
        return []
    }
    return []
}

@Test func sqliteQuicklinkRoundTripUsesVersionedSchema() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let link = try QuicklinkDefinition(
        id: "docs",
        title: "Docs",
        urlTemplate: "https://example.com/{query}",
        arguments: [ArgumentDefinition(id: "query", title: "Query", kind: .password, required: true)],
        keywords: ["documentation"],
        iconName: "book.closed",
        browserBundleIdentifier: "com.apple.Safari"
    )
    try await database.saveQuicklink(link)
    let loaded = try #require(await database.quicklink(id: "docs"))
    #expect(loaded.id == link.id)
    #expect(loaded.title == link.title)
    #expect(loaded.urlTemplate == link.urlTemplate)
    #expect(loaded.arguments == link.arguments)
    #expect(loaded.keywords == link.keywords)
    #expect(loaded.iconName == "book.closed")
    #expect(loaded.browserBundleIdentifier == "com.apple.Safari")
    #expect(abs(loaded.createdAt.timeIntervalSince1970 - link.createdAt.timeIntervalSince1970) < 0.001)
    #expect(abs(loaded.updatedAt.timeIntervalSince1970 - link.updatedAt.timeIntervalSince1970) < 0.001)
    #expect(try await database.integrityCheck())
    try await database.deleteQuicklink(id: "docs")
    #expect(try await database.allQuicklinks().isEmpty)
}
