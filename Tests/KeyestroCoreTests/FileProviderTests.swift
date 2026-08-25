import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func fileProviderLabelsContentMatchesAndForwardsSearchPreferences() async throws {
    let spotlight = RecordingSpotlightService()
    let preferences = FileSearchPreferences(
        FileSearchConfiguration(
            isEnabled: true,
            options: SpotlightSearchOptions(
                searchContents: true,
                includeHiddenFiles: true,
                includeSystemLocations: true,
                includeTrash: true
            )
        )
    )
    let provider = FileProvider(
        spotlight: spotlight,
        actions: NoopFileActions(),
        preferences: preferences
    )
    let request = QueryRequest(
        generation: 1,
        rawText: "needle",
        normalizedText: "needle",
        mode: .files
    )
    var items: [LauncherItem] = []
    for try await event in provider.search(request: request) {
        if case let .replacement(batch, _) = event { items = batch }
    }
    let item = try #require(items.first)
    #expect(item.subtitle?.hasPrefix("Content match · ") == true)
    #expect(item.keywords.contains("needle"))
    let received = await spotlight.lastOptions
    #expect(received?.searchContents == true)
    #expect(received?.includeHiddenFiles == true)
    #expect(received?.includeSystemLocations == true)
    #expect(received?.includeTrash == true)
}

@Test func fileProviderDoesNotContactSpotlightUntilFileSearchIsExplicitlyEnabled() async throws {
    let spotlight = RecordingSpotlightService()
    let preferences = FileSearchPreferences()
    let provider = FileProvider(
        spotlight: spotlight,
        actions: NoopFileActions(),
        preferences: preferences
    )
    let request = QueryRequest(
        generation: 1,
        rawText: "report",
        normalizedText: "report",
        mode: .files
    )

    #expect(try await replacementTitles(from: provider.search(request: request)).isEmpty)
    #expect(await spotlight.requestCount == 0)

    await preferences.update(FileSearchConfiguration(isEnabled: true))
    #expect(try await replacementTitles(from: provider.search(request: request)) == [["report.txt"]])
    #expect(await spotlight.requestCount == 1)
}

@Test func fileProviderStopsBeforeInspectingAStaleFileAfterConsentIsRevoked() async throws {
    let preferences = FileSearchPreferences(FileSearchConfiguration(isEnabled: true))
    let provider = FileProvider(
        spotlight: RecordingSpotlightService(),
        actions: NoopFileActions(),
        preferences: preferences
    )
    let request = QueryRequest(
        generation: 1,
        rawText: "report",
        normalizedText: "report",
        mode: .files
    )
    var foundItem: LauncherItem?
    for try await event in provider.search(request: request) {
        if case let .replacement(items, _) = event { foundItem = items.first }
    }
    let item = try #require(foundItem)

    await preferences.update(FileSearchConfiguration())
    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: item.id,
            actionID: "open",
            arguments: [:]
        )
    )

    guard case let .failure(error) = result else {
        Issue.record("A file action executed after file-search consent was revoked")
        return
    }
    #expect(error.code == "files.searchDisabled")
}

@Test func fileProviderPublishesInitialAndLiveReplacementBatches() async throws {
    let provider = FileProvider(
        spotlight: UpdatingSpotlightService(),
        actions: NoopFileActions(),
        preferences: FileSearchPreferences(FileSearchConfiguration(isEnabled: true))
    )
    let request = QueryRequest(generation: 1, rawText: "report", normalizedText: "report", mode: .files)
    var batches: [[String]] = []
    for try await event in provider.search(request: request) {
        if case let .replacement(items, _) = event {
            batches.append(items.map(\.title))
        }
    }
    #expect(batches == [["old-report.txt"], ["new-report.txt"]])
}

@Test func fileProviderReturnsBoundedRecentCacheBeforeSpotlightAndExpiresItDeterministically() async throws {
    let clock = ManualClockService()
    let spotlight = SequencedSpotlightService()
    let provider = FileProvider(
        spotlight: spotlight,
        actions: NoopFileActions(),
        preferences: FileSearchPreferences(FileSearchConfiguration(isEnabled: true)),
        recentCacheLifetime: .seconds(10),
        clock: clock
    )
    let request = QueryRequest(generation: 1, rawText: "report", normalizedText: "report", mode: .files)

    let first = try await replacementTitles(from: provider.search(request: request))
    #expect(first == [["cached-report.txt"]])

    let second = try await replacementTitles(from: provider.search(request: request))
    #expect(second == [["cached-report.txt"], ["spotlight-report.txt"]])

    await clock.advance(by: .seconds(11))
    let third = try await replacementTitles(from: provider.search(request: request))
    #expect(third == [["fresh-report.txt"]])
    #expect(await spotlight.requestCount == 3)
}

private func replacementTitles(
    from stream: AsyncThrowingStream<ProviderEvent, any Error>
) async throws -> [[String]] {
    var output: [[String]] = []
    for try await event in stream {
        if case let .replacement(items, _) = event { output.append(items.map(\.title)) }
    }
    return output
}

private actor RecordingSpotlightService: SpotlightServicing {
    private(set) var lastOptions: SpotlightSearchOptions?
    private(set) var requestCount = 0

    func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) -> [SpotlightRecord] {
        requestCount += 1
        lastOptions = options
        return [
            SpotlightRecord(
                url: URL(fileURLWithPath: "/tmp/report.txt"),
                displayName: "report.txt",
                contentType: "public.plain-text",
                modifiedAt: nil,
                matchKind: .content
            )
        ]
    }
}

private struct UpdatingSpotlightService: SpotlightServicing {
    func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async throws -> [SpotlightRecord] {
        []
    }

    func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                SpotlightSearchBatch(
                    records: [
                        SpotlightRecord(
                            url: URL(fileURLWithPath: "/tmp/old-report.txt"),
                            displayName: "old-report.txt",
                            contentType: "public.plain-text",
                            modifiedAt: nil
                        )
                    ],
                    phase: .initial
                )
            )
            continuation.yield(
                SpotlightSearchBatch(
                    records: [
                        SpotlightRecord(
                            url: URL(fileURLWithPath: "/tmp/new-report.txt"),
                            displayName: "new-report.txt",
                            contentType: "public.plain-text",
                            modifiedAt: nil
                        )
                    ],
                    phase: .liveUpdate
                )
            )
            continuation.finish()
        }
    }
}

private actor SequencedSpotlightService: SpotlightServicing {
    private(set) var requestCount = 0

    func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) -> [SpotlightRecord] { [] }

    func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        requestCount += 1
        let title: String
        switch requestCount {
        case 1: title = "cached-report.txt"
        case 2: title = "spotlight-report.txt"
        default: title = "fresh-report.txt"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(
                SpotlightSearchBatch(
                    records: [
                        SpotlightRecord(
                            url: URL(fileURLWithPath: "/tmp/\(title)"),
                            displayName: title,
                            contentType: "public.plain-text",
                            modifiedAt: Date(timeIntervalSince1970: TimeInterval(requestCount))
                        )
                    ],
                    phase: .initial
                )
            )
            continuation.finish()
        }
    }
}

@MainActor
private final class NoopFileActions: FileActionServicing, @unchecked Sendable {
    func open(_ url: URL) -> Bool { true }
    func reveal(_ url: URL) {}
    func copy(_ value: String) {}
    func preview(_ url: URL) -> Bool { true }
}
