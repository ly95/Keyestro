import Foundation
import KeyestroDomain

private enum ProviderEnvelope: Sendable {
    case event(providerID: ProviderID, ProviderEvent)
    case failed(providerID: ProviderID, ErrorDescriptor)
    case deadline(providerID: ProviderID)
    case finished(providerID: ProviderID)
}

/// Owns query generations, provider tasks, aggregation, deduplication, and the current resolvable result set.
public actor QueryCoordinator {
    static let snapshotMergeInterval: Duration = .milliseconds(8)
    static let maximumProviderInitialDeadline: Duration = .seconds(2)

    private let providers: [ProviderID: any LauncherProvider]
    private let ranker: Ranker
    private let rankingStore: (any RankingServicing)?
    private let rankingLearning: any RankingLearningServicing
    private let performance: any PerformanceRecording
    private let clock: any ClockServicing
    private let providerInitialDeadline: Duration
    private var generation: UInt64 = 0
    private var currentTask: Task<Void, Never>?
    private var currentRequest: QueryRequest?
    private var providerItems: [ProviderID: [ItemID: LauncherItem]] = [:]
    private var visibleItems: [ItemID: LauncherItem] = [:]

    public init(
        providers: [any LauncherProvider],
        ranker: Ranker = Ranker(),
        rankingStore: (any RankingServicing)? = nil,
        rankingLearning: any RankingLearningServicing = RankingLearningPreferences(),
        performance: any PerformanceRecording = PerformanceRecorder.shared,
        clock: any ClockServicing = SystemClockService(),
        providerInitialDeadline: Duration = .seconds(2)
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
        self.ranker = ranker
        self.rankingStore = rankingStore
        self.rankingLearning = rankingLearning
        self.performance = performance
        self.clock = clock
        self.providerInitialDeadline = min(
            max(providerInitialDeadline, .milliseconds(1)),
            Self.maximumProviderInitialDeadline
        )
    }

    deinit {
        currentTask?.cancel()
    }

    /// Starts a new monotonic generation and immediately emits a loading snapshot.
    public func search(
        rawText: String,
        isComposing: Bool = false,
        prefixesEnabled: Bool = true,
        context: QueryContext = QueryContext(),
        locale: Locale = .current
    ) async -> AsyncStream<QuerySnapshot> {
        currentTask?.cancel()
        generation &+= 1
        let startedAt = await clock.now()

        let boundedRawText = rawText.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        let parsed = QueryParser.parse(boundedRawText, isComposing: isComposing, prefixesEnabled: prefixesEnabled)
        let request = QueryRequest(
            generation: generation,
            rawText: boundedRawText,
            normalizedText: TextNormalizer.normalize(parsed.searchText, locale: locale),
            mode: parsed.mode,
            context: context,
            startedAt: startedAt
        )
        currentRequest = request
        providerItems = [:]
        visibleItems = [:]

        let eligibleProviders = providers.values
            .filter { provider in
                let descriptor = provider.descriptor
                guard descriptor.supportedModes.contains(request.mode) else {
                    return false
                }
                if request.normalizedText.isEmpty && !descriptor.supportsEmptyQuery { return false }
                if request.normalizedText.isEmpty && descriptor.isNetworkProvider { return false }
                return true
            }
            .sorted { $0.descriptor.id < $1.descriptor.id }

        let (stream, continuation) = AsyncStream<QuerySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        let task = Task {
            await runSearch(
                request: request,
                providers: eligibleProviders,
                locale: locale,
                startedAt: startedAt,
                continuation: continuation
            )
        }
        currentTask = task
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func cancelCurrentSearch() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Resolves stable IDs against the current generation immediately before execution.
    public func resolve(_ request: ActionExecutionRequest) -> Result<ResolvedAction, ErrorDescriptor> {
        guard let currentRequest, currentRequest.generation == request.generation else {
            return .failure(
                ErrorDescriptor(
                    code: "action.staleGeneration",
                    message: "The search result is no longer current.",
                    recoverySuggestion: "Run the search again and choose the current result."
                )
            )
        }
        guard let visibleItem = visibleItems[request.itemID],
            let displayedAction = visibleItem.actions.first(where: { $0.id == request.actionID })
        else {
            return .failure(
                ErrorDescriptor(
                    code: "action.missingTarget",
                    message: "The selected item or action is no longer available.",
                    recoverySuggestion: "Refresh the results and try again."
                )
            )
        }
        guard
            displayedAction.risk == .safe
                || visibleItem.privacy == .normal
                || displayedAction.confirmationTarget != nil
        else {
            return .failure(
                ErrorDescriptor(
                    code: "action.missingConfirmationTarget",
                    message: "The sensitive action does not identify a safe confirmation target.",
                    recoverySuggestion: "Refresh the results or use a different action."
                )
            )
        }

        if let route = displayedAction.route {
            guard let routedItem = providerItems[route.providerID]?[route.itemID],
                routedItem.actions.contains(where: { $0.id == route.actionID })
            else {
                return .failure(
                    ErrorDescriptor(
                        code: "action.staleRoute",
                        message: "The merged action target is no longer available.",
                        recoverySuggestion: "Refresh the results and try again."
                    )
                )
            }
            return .success(
                ResolvedAction(
                    providerID: route.providerID,
                    itemID: route.itemID,
                    actionID: route.actionID,
                    descriptor: displayedAction,
                    displayedTitle: visibleItem.title,
                    displayedSubtitle: visibleItem.subtitle,
                    privacy: visibleItem.privacy
                )
            )
        }

        return .success(
            ResolvedAction(
                providerID: visibleItem.providerID,
                itemID: visibleItem.id,
                actionID: displayedAction.id,
                descriptor: displayedAction,
                displayedTitle: visibleItem.title,
                displayedSubtitle: visibleItem.subtitle,
                privacy: visibleItem.privacy
            )
        )
    }

    private func runSearch(
        request: QueryRequest,
        providers eligibleProviders: [any LauncherProvider],
        locale: Locale,
        startedAt: ContinuousClock.Instant,
        continuation: AsyncStream<QuerySnapshot>.Continuation
    ) async {
        var statuses = Dictionary(
            uniqueKeysWithValues: eligibleProviders.map { ($0.descriptor.id, ProviderStatus.loading) }
        )
        let initialSnapshot = QuerySnapshot(
            requestID: request.id,
            generation: request.generation,
            items: [],
            statuses: statuses,
            isComplete: eligibleProviders.isEmpty
        )
        continuation.yield(initialSnapshot)

        guard !eligibleProviders.isEmpty else {
            await performance.record(.queryComplete, duration: startedAt.duration(to: await clock.now()))
            PerformanceSignposts.queryCompleted()
            continuation.finish()
            return
        }

        let (events, eventsContinuation) = AsyncStream<ProviderEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let providerDeadline = providerInitialDeadline
        var deadlineTasks: [ProviderID: Task<Void, Never>] = [:]
        for provider in eligibleProviders {
            let providerID = provider.descriptor.id
            deadlineTasks[providerID] = Task {
                do {
                    try await clock.sleep(for: providerDeadline)
                    eventsContinuation.yield(.deadline(providerID: providerID))
                } catch {
                    // The provider completed or its query generation was cancelled.
                }
            }
        }
        var providerTasks: [ProviderID: Task<Void, Never>] = [:]
        for provider in eligibleProviders {
            let providerID = provider.descriptor.id
            providerTasks[providerID] = Task {
                do {
                    let stream = provider.search(request: request)
                    for try await event in stream {
                        try Task.checkCancellation()
                        eventsContinuation.yield(.event(providerID: providerID, event))
                    }
                } catch is CancellationError {
                    // Cancellation is expected after a deadline or when a newer generation starts.
                } catch {
                    eventsContinuation.yield(
                        .failed(
                            providerID: providerID,
                            ErrorDescriptor(
                                code: "provider.searchFailed",
                                message: "A search provider could not complete the search.",
                                recoverySuggestion: "Try again."
                            )
                        )
                    )
                }
                eventsContinuation.yield(.finished(providerID: providerID))
            }
        }
        let providerTaskValues = Array(providerTasks.values)
        let producer = Task {
            for task in providerTaskValues { await task.value }
            eventsContinuation.finish()
        }
        eventsContinuation.onTermination = { @Sendable _ in
            providerTaskValues.forEach { $0.cancel() }
            producer.cancel()
        }

        var completed = Set<ProviderID>()
        var timedOut = Set<ProviderID>()
        var recordedFirstResult = false
        var recordedCompletion = false
        var lastEmittedSnapshot: QuerySnapshot? = initialSnapshot
        var lastSnapshotYieldAt: ContinuousClock.Instant? = startedAt
        for await envelope in events {
            guard !Task.isCancelled, generation == request.generation else { break }

            switch envelope {
            case let .event(providerID, event):
                guard !timedOut.contains(providerID) else { continue }
                switch event {
                case let .items(batch, isFinal):
                    let items = Self.accumulate(
                        batch,
                        providerID: providerID,
                        existing: providerItems[providerID] ?? [:]
                    )
                    providerItems[providerID] = items
                    if isFinal {
                        deadlineTasks[providerID]?.cancel()
                        deadlineTasks[providerID] = nil
                        if !Self.isProblemStatus(statuses[providerID]) {
                            statuses[providerID] = items.isEmpty ? .empty : .ready
                        }
                        completed.insert(providerID)
                    }
                case let .replacement(batch, isFinal):
                    let items = Self.accumulate(batch, providerID: providerID, existing: [:])
                    providerItems[providerID] = items
                    if isFinal {
                        deadlineTasks[providerID]?.cancel()
                        deadlineTasks[providerID] = nil
                        if !Self.isProblemStatus(statuses[providerID]) {
                            statuses[providerID] = items.isEmpty ? .empty : .ready
                        }
                        completed.insert(providerID)
                    }
                case let .status(status):
                    statuses[providerID] = status
                }
            case let .failed(providerID, error):
                deadlineTasks[providerID]?.cancel()
                deadlineTasks[providerID] = nil
                statuses[providerID] = .failed(error)
                completed.insert(providerID)
            case let .deadline(providerID):
                guard !completed.contains(providerID) else { continue }
                deadlineTasks[providerID] = nil
                providerTasks[providerID]?.cancel()
                timedOut.insert(providerID)
                statuses[providerID] = .failed(
                    ErrorDescriptor(
                        code: "provider.deadlineExceeded",
                        message: "A search provider did not return in time.",
                        recoverySuggestion: "Try again or disable this provider."
                    )
                )
                completed.insert(providerID)
            case let .finished(providerID):
                deadlineTasks[providerID]?.cancel()
                deadlineTasks[providerID] = nil
                if !completed.contains(providerID) {
                    statuses[providerID] = (providerItems[providerID]?.isEmpty == false) ? .ready : .empty
                    completed.insert(providerID)
                }
            }

            let snapshot = await makeSnapshot(
                request: request,
                statuses: statuses,
                isComplete: completed.count == eligibleProviders.count,
                locale: locale
            )
            let snapshotTime = await clock.now()
            let mergeIntervalElapsed: Bool
            if let lastSnapshotYieldAt {
                mergeIntervalElapsed = lastSnapshotYieldAt.duration(to: snapshotTime) >= Self.snapshotMergeInterval
            } else {
                mergeIntervalElapsed = true
            }
            let exposesFirstResult = lastEmittedSnapshot?.items.isEmpty == true && !snapshot.items.isEmpty
            let exposesProblem =
                snapshot.statuses != lastEmittedSnapshot?.statuses
                && snapshot.statuses.values.contains(where: Self.isProblemStatus)
            let shouldYield = snapshot.isComplete || exposesFirstResult || exposesProblem || mergeIntervalElapsed
            guard shouldYield, snapshot != lastEmittedSnapshot else { continue }
            if !recordedFirstResult, !snapshot.items.isEmpty {
                recordedFirstResult = true
                await performance.record(.queryToFirstResult, duration: startedAt.duration(to: snapshotTime))
                PerformanceSignposts.firstResult()
            }
            if !recordedCompletion, snapshot.isComplete {
                recordedCompletion = true
                await performance.record(.queryComplete, duration: startedAt.duration(to: snapshotTime))
                PerformanceSignposts.queryCompleted()
            }
            lastEmittedSnapshot = snapshot
            lastSnapshotYieldAt = snapshotTime
            continuation.yield(snapshot)
        }

        producer.cancel()
        providerTaskValues.forEach { $0.cancel() }
        deadlineTasks.values.forEach { $0.cancel() }
        continuation.finish()
    }

    private func makeSnapshot(
        request: QueryRequest,
        statuses: [ProviderID: ProviderStatus],
        isComplete: Bool,
        locale: Locale
    ) async -> QuerySnapshot {
        let rawItems =
            providerItems
            .sorted { $0.key < $1.key }
            .flatMap { _, items in items.values.sorted { $0.id < $1.id } }
            .prefix(DomainLimits.aggregateCandidates)
        let allItems: [LauncherItem]
        if let rankingStore,
            let enriched = try? await rankingStore.enrich(
                Array(rawItems),
                includeLearning: rankingLearning.isEnabled()
            )
        {
            allItems = enriched
        } else {
            allItems = Array(rawItems)
        }
        let ranked = ranker.rank(allItems, for: request, now: await clock.wallTime(), locale: locale)
        let deduplicated = Array(ItemDeduplicator.deduplicate(ranked).prefix(request.limit))
        visibleItems = Dictionary(uniqueKeysWithValues: deduplicated.map { ($0.id, $0.item) })
        return QuerySnapshot(
            requestID: request.id,
            generation: request.generation,
            items: deduplicated,
            statuses: statuses,
            isComplete: isComplete
        )
    }

    private static func isProblemStatus(_ status: ProviderStatus?) -> Bool {
        switch status {
        case .permissionDenied, .unavailable, .failed: true
        default: false
        }
    }

    private static func accumulate(
        _ batch: [LauncherItem],
        providerID: ProviderID,
        existing: [ItemID: LauncherItem]
    ) -> [ItemID: LauncherItem] {
        var items = existing
        for item in batch.prefix(DomainLimits.itemsPerBatch) {
            guard item.providerID == providerID,
                item.id.providerID == providerID,
                let sanitized = item.sanitized()
            else { continue }
            items[sanitized.id] = sanitized
        }
        if items.count > DomainLimits.candidatesPerProvider {
            let allowed = items.values.sorted { $0.id < $1.id }.prefix(DomainLimits.candidatesPerProvider)
            items = Dictionary(uniqueKeysWithValues: allowed.map { ($0.id, $0) })
        }
        return items
    }
}
