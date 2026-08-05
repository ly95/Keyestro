import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func queryCoordinatorReplacementRemovesStaleLiveResults() async {
    let coordinator = QueryCoordinator(providers: [ReplacementProvider()])
    let stream = await coordinator.search(rawText: "report")
    var snapshots: [[String]] = []
    var lastSnapshot: QuerySnapshot?
    for await snapshot in stream {
        snapshots.append(snapshot.items.map(\.item.title))
        lastSnapshot = snapshot
    }
    #expect(snapshots.contains(["old report"]))
    #expect(snapshots.last == ["new report"])
    #expect(!snapshots.contains(where: { Set($0) == Set(["old report", "new report"]) }))
    if let snapshot = lastSnapshot, let item = snapshot.items.first?.item {
        let resolution = await coordinator.resolve(
            ActionExecutionRequest(
                generation: snapshot.generation,
                itemID: item.id,
                actionID: item.defaultActionID
            )
        )
        guard case let .success(action) = resolution else {
            Issue.record("Expected the current replacement action to resolve")
            return
        }
        #expect(action.displayedTitle == "new report")
    } else {
        Issue.record("Expected a final replacement item")
    }
}

@Test func queryCoordinatorCompletesWhenOneProviderMissesItsInitialDeadline() async throws {
    let clock = ManualClockService()
    let coordinator = QueryCoordinator(
        providers: [NeverFinalProvider()],
        clock: clock,
        providerInitialDeadline: .milliseconds(20)
    )
    let stream = await coordinator.search(rawText: "report")
    let consumer = Task { () -> QuerySnapshot? in
        for await snapshot in stream where snapshot.isComplete {
            return snapshot
        }
        return nil
    }
    await waitForPendingSleep(clock)
    await clock.advance(by: .milliseconds(20))
    let snapshot = try #require(await consumer.value)
    guard case let .failed(error)? = snapshot.statuses["never-final"] else {
        Issue.record("Expected a deadline failure status")
        return
    }
    #expect(error.code == "provider.deadlineExceeded")
}

@Test func queryCoordinatorPublishesFirstResultBeforeAnotherProviderDeadline() async throws {
    let clock = ManualClockService()
    let recorder = QuerySnapshotRecorder()
    let coordinator = QueryCoordinator(
        providers: [LoadingThenResultProvider(), NeverFinalProvider()],
        clock: clock,
        providerInitialDeadline: .seconds(60)
    )
    let stream = await coordinator.search(rawText: "report")
    let consumer = Task {
        for await snapshot in stream { await recorder.append(snapshot) }
    }

    for _ in 0..<10_000 {
        if await recorder.hasItem(named: "Immediate report") { break }
        await Task.yield()
    }
    #expect(await recorder.hasItem(named: "Immediate report"))
    #expect(await recorder.hasCompleteSnapshot == false)

    await waitForPendingSleep(clock)
    await clock.advance(by: QueryCoordinator.maximumProviderInitialDeadline)
    await consumer.value
    #expect(await recorder.hasCompleteSnapshot)
}

@Test func queryCoordinatorBoundsRawInputBeforeItCrossesTheProviderBoundary() async throws {
    let provider = RequestRecordingProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let oversized = String(repeating: "👩🏽‍💻", count: 1_000)
    let stream = await coordinator.search(rawText: oversized)
    for await _ in stream {}

    let request = try #require(await provider.requests.first)
    #expect(request.rawText.unicodeScalars.count == DomainLimits.queryUnicodeScalars)
    #expect(request.normalizedText.unicodeScalars.count <= DomainLimits.queryUnicodeScalars)
    #expect(request.limit == DomainLimits.visibleItems)
}

@Test func queryRequestAndItemSanitizationEnforceEverySharedDomainLimit() throws {
    let request = QueryRequest(
        generation: 1,
        rawText: String(repeating: "x", count: DomainLimits.queryUnicodeScalars + 50),
        normalizedText: String(repeating: "y", count: DomainLimits.queryUnicodeScalars + 50),
        mode: .all,
        limit: Int.max
    )
    #expect(request.rawText.count == DomainLimits.queryUnicodeScalars)
    #expect(request.normalizedText.count == DomainLimits.queryUnicodeScalars)
    #expect(request.limit == DomainLimits.visibleItems)

    let actions = (0..<(DomainLimits.actionsPerItem + 20)).map {
        ActionDescriptor(id: ActionID("action-\($0)"), title: "Action \($0)")
    }
    let item = LauncherItem(
        id: ItemID(providerID: "limits", providerStableID: "item"),
        providerID: "limits",
        title: String(repeating: "t", count: DomainLimits.titleUnicodeScalars + 10),
        subtitle: String(repeating: "s", count: DomainLimits.subtitleUnicodeScalars + 10),
        keywords: (0..<(DomainLimits.keywordCount + 10)).map {
            "\($0)-" + String(repeating: "k", count: DomainLimits.keywordUnicodeScalars + 10)
        },
        actions: actions,
        defaultActionID: actions[0].id
    )
    let sanitized = try #require(item.sanitized())
    #expect(sanitized.title.count == DomainLimits.titleUnicodeScalars)
    #expect(sanitized.subtitle?.count == DomainLimits.subtitleUnicodeScalars)
    #expect(sanitized.keywords.count == DomainLimits.keywordCount)
    #expect(sanitized.keywords.allSatisfy { $0.unicodeScalars.count <= DomainLimits.keywordUnicodeScalars })
    #expect(sanitized.actions.count == DomainLimits.actionsPerItem)
}

@Test func queryCoordinatorCoalescesBurstUpdatesAndStillPublishesTheFinalState() async throws {
    let clock = ManualClockService()
    let coordinator = QueryCoordinator(providers: [BurstProvider()], clock: clock)
    let stream = await coordinator.search(rawText: "burst")
    var snapshots: [QuerySnapshot] = []
    for await snapshot in stream { snapshots.append(snapshot) }

    let final = try #require(snapshots.last)
    #expect(final.isComplete)
    #expect(final.items.first?.item.title == "Burst 99")
    #expect(snapshots.count <= 3)
    #expect(QueryCoordinator.snapshotMergeInterval == .milliseconds(8))
}

@Test func startingANewGenerationCancelsThePriorProviderWork() async throws {
    let provider = GenerationCancellationProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let firstStream = await coordinator.search(rawText: "old")
    let firstConsumer = Task {
        for await _ in firstStream {}
    }
    await provider.waitUntilFirstGenerationStarted()

    let secondStream = await coordinator.search(rawText: "current")
    var final: QuerySnapshot?
    for await snapshot in secondStream where snapshot.isComplete { final = snapshot }
    await firstConsumer.value

    #expect(await provider.cancelledGenerations.contains(1))
    #expect(final?.generation == 2)
    #expect(final?.items.map(\.item.title) == ["Current Result"])
}

@Test func sensitiveRiskyActionWithoutANonSecretConfirmationTargetIsRejected() async throws {
    let coordinator = QueryCoordinator(providers: [UnsafeSensitiveActionProvider()])
    let stream = await coordinator.search(rawText: "secret")
    var final: QuerySnapshot?
    for await snapshot in stream where snapshot.isComplete { final = snapshot }
    let item = try #require(final?.items.first?.item)

    let resolution = await coordinator.resolve(
        ActionExecutionRequest(
            generation: try #require(final?.generation),
            itemID: item.id,
            actionID: item.defaultActionID
        )
    )
    guard case let .failure(error) = resolution else {
        Issue.record("Expected the host to reject a sensitive risky action without a safe target")
        return
    }
    #expect(error.code == "action.missingConfirmationTarget")
}

private struct ReplacementProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "replacement-test",
        displayName: "Replacement Test",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.replacement([item(id: "old", title: "old report")], isFinal: true))
            continuation.yield(.replacement([item(id: "new", title: "new report")], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }

    private func item(id: String, title: String) -> LauncherItem {
        let action = ActionDescriptor(id: "open", title: "Open")
        return LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: id),
            providerID: descriptor.id,
            title: title,
            actions: [action],
            defaultActionID: action.id
        )
    }
}

private struct NeverFinalProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "never-final",
        displayName: "Never Final",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }
}

private struct LoadingThenResultProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "loading-then-result",
        displayName: "Loading Then Result",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let action = ActionDescriptor(id: "open", title: "Open")
            let item = LauncherItem(
                id: ItemID(providerID: descriptor.id, providerStableID: "immediate"),
                providerID: descriptor.id,
                title: "Immediate report",
                actions: [action],
                defaultActionID: action.id
            )
            continuation.yield(.status(.loading))
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }
}

private actor QuerySnapshotRecorder {
    private var snapshots: [QuerySnapshot] = []

    var hasCompleteSnapshot: Bool { snapshots.contains(where: \.isComplete) }

    func append(_ snapshot: QuerySnapshot) {
        snapshots.append(snapshot)
    }

    func hasItem(named title: String) -> Bool {
        snapshots.contains { snapshot in snapshot.items.contains { $0.item.title == title } }
    }
}

private actor RequestRecordingProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "request-recording",
        displayName: "Request Recording",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    private(set) var requests: [QueryRequest] = []

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(request)
                continuation.yield(.items([], isFinal: true))
                continuation.finish()
            }
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }

    private func record(_ request: QueryRequest) { requests.append(request) }
}

private struct BurstProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "burst",
        displayName: "Burst",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            for index in 0..<100 {
                continuation.yield(.replacement([item(index)], isFinal: index == 99))
            }
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }

    private func item(_ index: Int) -> LauncherItem {
        let action = ActionDescriptor(id: "open", title: "Open")
        return LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "\(index)"),
            providerID: descriptor.id,
            title: "Burst \(index)",
            actions: [action],
            defaultActionID: action.id
        )
    }
}

private actor GenerationCancellationProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "generation-cancellation",
        displayName: "Generation Cancellation",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    private var firstStarted = false
    private(set) var cancelledGenerations = Set<UInt64>()

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if request.generation == 1 {
                    await markFirstStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await markCancelled(request.generation)
                    }
                } else {
                    let action = ActionDescriptor(id: "open", title: "Open")
                    let item = LauncherItem(
                        id: ItemID(providerID: descriptor.id, providerStableID: "current"),
                        providerID: descriptor.id,
                        title: "Current Result",
                        actions: [action],
                        defaultActionID: action.id
                    )
                    continuation.yield(.items([item], isFinal: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }

    func waitUntilFirstGenerationStarted() async {
        while !firstStarted { await Task.yield() }
    }

    private func markFirstStarted() { firstStarted = true }
    private func markCancelled(_ generation: UInt64) { cancelledGenerations.insert(generation) }
}

private struct UnsafeSensitiveActionProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "unsafe-sensitive-action",
        displayName: "Unsafe Sensitive Action",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let action = ActionDescriptor(id: "delete", title: "Delete", risk: .destructive)
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "opaque-id"),
            providerID: descriptor.id,
            title: "Secret contents",
            actions: [action],
            defaultActionID: action.id,
            privacy: .secret
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }
}
