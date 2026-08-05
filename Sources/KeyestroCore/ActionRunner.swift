import Foundation
import KeyestroDomain

/// Executes one resolved stable action at most once and enforces host risk confirmation.
public actor ActionRunner {
    private let providers: [ProviderID: any LauncherProvider]
    private let rankingStore: (any RankingServicing)?
    private let rankingLearning: any RankingLearningServicing
    private let performance: any PerformanceRecording
    private let clock: any ClockServicing
    private var activeExecutionIDs = Set<UUID>()
    private var recentExecutionIDs: [UUID] = []
    private let recentLimit = 128

    public init(
        providers: [any LauncherProvider],
        rankingStore: (any RankingServicing)? = nil,
        rankingLearning: any RankingLearningServicing = RankingLearningPreferences(),
        performance: any PerformanceRecording = PerformanceRecorder.shared,
        clock: any ClockServicing = SystemClockService()
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
        self.rankingStore = rankingStore
        self.rankingLearning = rankingLearning
        self.performance = performance
        self.clock = clock
    }

    public func run(
        executionID: UUID,
        resolvedAction: ResolvedAction,
        arguments: [String: ArgumentValue],
        riskConfirmed: Bool
    ) async -> ActionRunOutcome {
        guard !activeExecutionIDs.contains(executionID), !recentExecutionIDs.contains(executionID) else {
            return .completed(
                .failure(
                    ErrorDescriptor(
                        code: "action.duplicateExecution",
                        message: "This action was already submitted."
                    )
                )
            )
        }

        if resolvedAction.descriptor.risk != .safe && !riskConfirmed {
            return .confirmationRequired(resolvedAction)
        }
        guard let provider = providers[resolvedAction.providerID] else {
            return .completed(
                .failure(
                    ErrorDescriptor(
                        code: "action.providerUnavailable",
                        message: "The action provider is not available.",
                        recoverySuggestion: "Refresh the search and try again."
                    )
                )
            )
        }

        activeExecutionIDs.insert(executionID)
        let startedAt = await clock.now()
        let result = await provider.execute(
            request: ProviderActionRequest(
                executionID: executionID,
                itemID: resolvedAction.itemID,
                actionID: resolvedAction.actionID,
                arguments: arguments
            )
        )
        await performance.record(.actionComplete, duration: startedAt.duration(to: await clock.now()))
        PerformanceSignposts.actionCompleted()
        activeExecutionIDs.remove(executionID)
        recentExecutionIDs.append(executionID)
        if recentExecutionIDs.count > recentLimit {
            recentExecutionIDs.removeFirst(recentExecutionIDs.count - recentLimit)
        }
        if case .success = result, rankingLearning.isEnabled() {
            try? await rankingStore?.record(
                itemID: resolvedAction.itemID,
                actionID: resolvedAction.actionID,
                at: await clock.wallTime()
            )
        }
        return .completed(result)
    }
}
