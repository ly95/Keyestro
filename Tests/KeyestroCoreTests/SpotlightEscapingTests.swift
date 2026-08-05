import Foundation
import Testing
@testable import KeyestroCore

private actor MetadataQueryStartLog {
    private var values: [Bool] = []

    func append(_ value: Bool) { values.append(value) }
    func count() -> Int { values.count }
}

@Test func metadataQueryLiteralEscapesSyntax() {
    #expect(MDSpotlightService.escapeMetadataLiteral("a\"*?\\'b") == "a\\\"\\*\\?\\\\\\'b")
}

@Test func metadataQueryLiteralDropsControlCharacters() {
    #expect(MDSpotlightService.escapeMetadataLiteral("hello\nworld") == "helloworld")
}

@Test func metadataContentQueryUsesOnlyTheEscapedHostLiteral() {
    let escaped = MDSpotlightService.escapeMetadataLiteral("report\" || kMDItemFSName == \"*")
    let query = MDSpotlightService.metadataQueryString(escapedLiteral: escaped, searchContents: true)
    #expect(query.contains("kMDItemFSName"))
    #expect(query.contains("kMDItemTextContent"))
    #expect(!query.contains("report\" ||"))
}

@Test func spotlightVisibilityOptionsKeepHiddenAndTrashExcludedByDefault() {
    let root = URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
    let hidden = root.appendingPathComponent(".private/notes.txt")
    let regular = root.appendingPathComponent("notes.txt")
    #expect(MDSpotlightService.isVisibleUserFile(regular, roots: [root], options: .init()))
    #expect(!MDSpotlightService.isVisibleUserFile(hidden, roots: [root], options: .init()))
    #expect(
        MDSpotlightService.isVisibleUserFile(
            hidden,
            roots: [root],
            options: .init(includeHiddenFiles: true)
        )
    )
}

@Test func liveMetadataQueriesNeverStartOnTheMainThread() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let (observations, observationContinuation) = AsyncStream<Bool>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let service = MDSpotlightService(
        searchScope: root,
        queryStartObserver: { observationContinuation.yield($0) }
    )
    let updates = await service.searchFileUpdates(
        containing: "keyestro-main-thread-regression",
        options: SpotlightSearchOptions(),
        limit: 1
    )
    var iterator = observations.makeAsyncIterator()
    let observation = await iterator.next()
    let startedOnMainThread = try #require(observation as Bool?)

    #expect(!startedOnMainThread)
    observationContinuation.finish()
    _ = updates
}

@Test func cancellingAnIntermediateQueryPreventsItsMetadataSessionFromStarting() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let starts = MetadataQueryStartLog()
    let service = MDSpotlightService(
        searchScope: root,
        queryStartObserver: { startedOnMainThread in
            Task { await starts.append(startedOnMainThread) }
        }
    )
    let updates = await service.searchFileUpdates(
        containing: "cancel-before-start",
        options: SpotlightSearchOptions(),
        limit: 1
    )
    let consumer = Task {
        do {
            for try await _ in updates {}
        } catch {
            // Cancellation is the expected end state for this intermediate query.
        }
    }
    await Task.yield()
    consumer.cancel()
    await consumer.value
    try await Task.sleep(for: .milliseconds(100))

    #expect(await starts.count() == 0)
}
