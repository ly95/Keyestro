import Foundation

/// Tunable constants used by deterministic launcher ranking.
public struct RankingConfiguration: Equatable, Sendable {
    public let recencyHalfLifeDays: Double
    public let maximumFrequencyCount: Int
    public let minimumTextMatch: Double

    public init(
        recencyHalfLifeDays: Double = 14,
        maximumFrequencyCount: Int = 100,
        minimumTextMatch: Double = 0.2
    ) {
        self.recencyHalfLifeDays = max(0.01, recencyHalfLifeDays)
        self.maximumFrequencyCount = max(1, maximumFrequencyCount)
        self.minimumTextMatch = min(1, max(0, minimumTextMatch))
    }
}

/// Scores validated items from text match, recency, frequency, context, provider prior, and pin state.
public struct Ranker: Sendable {
    public let configuration: RankingConfiguration

    public init(configuration: RankingConfiguration = RankingConfiguration()) {
        self.configuration = configuration
    }

    public func rank(
        _ items: [LauncherItem],
        for request: QueryRequest,
        now: Date = Date(),
        locale: Locale = .current
    ) -> [RankedItem] {
        let ranked = items.compactMap { item -> RankedItem? in
            let match: MatchEvaluation
            if item.searchAliases.isEmpty {
                match = FuzzyMatcher.evaluate(
                    query: request.normalizedText,
                    title: item.title,
                    subtitle: item.subtitle,
                    keywords: item.keywords,
                    locale: locale
                )
            } else {
                match = FuzzyMatcher.evaluate(
                    query: request.normalizedText,
                    title: item.title,
                    aliases: item.searchAliases,
                    locale: locale
                )
            }
            guard match.tier != .none, request.normalizedText.isEmpty || match.textMatch >= configuration.minimumTextMatch else {
                return nil
            }

            let features = item.scoreFeatures
            let score =
                0.55 * match.textMatch
                + 0.15 * match.prefixBonus
                + 0.12 * recency(lastUsedAt: features.lastUsedAt, now: now)
                + 0.10 * frequency(count: features.executionCount90Days)
                + 0.05 * features.context
                + 0.03 * features.providerPrior
            return RankedItem(item: item, score: score, matchTier: match.tier)
        }

        return ranked.sorted(by: Self.isOrderedBefore)
    }

    private func recency(lastUsedAt: Date?, now: Date) -> Double {
        guard let lastUsedAt else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
        return pow(0.5, ageDays / configuration.recencyHalfLifeDays)
    }

    private func frequency(count: Int) -> Double {
        min(1, log1p(Double(max(0, count))) / log1p(Double(configuration.maximumFrequencyCount)))
    }

    /// A single lexicographic order keeps sorting transitive while preserving explicit intent.
    /// Pins are global user intent; among equally pinned results, exact matches form the
    /// firewall that bounded recency and frequency learning cannot cross.
    fileprivate static func isOrderedBefore(_ lhs: RankedItem, _ rhs: RankedItem) -> Bool {
        let lhsPinned = lhs.item.scoreFeatures.isPinned
        let rhsPinned = rhs.item.scoreFeatures.isPinned
        if lhsPinned != rhsPinned { return lhsPinned }

        let lhsExact = lhs.matchTier == .exact
        let rhsExact = rhs.matchTier == .exact
        if lhsExact != rhsExact { return lhsExact }

        // Ranker-produced scores are finite. Treat externally constructed NaNs as the
        // weakest score so this public comparison remains deterministic as well.
        let lhsScore = lhs.score.isNaN ? -Double.infinity : lhs.score
        let rhsScore = rhs.score.isNaN ? -Double.infinity : rhs.score
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        if lhs.matchTier != rhs.matchTier {
            return lhs.matchTier < rhs.matchTier
        }
        if lhs.item.providerID != rhs.item.providerID {
            return lhs.item.providerID < rhs.item.providerID
        }
        return lhs.item.id < rhs.item.id
    }
}

/// Merges compatible actions for items that identify the same canonical resource.
public enum ItemDeduplicator {
    public static func deduplicate(_ rankedItems: [RankedItem]) -> [RankedItem] {
        // Callers normally pass Ranker output, but sorting here also makes winner and
        // merged-action selection deterministic for independently constructed input.
        let orderedItems = rankedItems.sorted(by: Ranker.isOrderedBefore)
        var output: [RankedItem] = []
        var canonicalIndices: [CanonicalResource: Int] = [:]

        for candidate in orderedItems {
            guard let canonical = candidate.item.canonicalResource else {
                output.append(candidate)
                continue
            }

            guard let existingIndex = canonicalIndices[canonical] else {
                canonicalIndices[canonical] = output.count
                output.append(candidate)
                continue
            }

            output[existingIndex] = merge(winner: output[existingIndex], duplicate: candidate)
        }

        return output
    }

    private static func merge(winner: RankedItem, duplicate: RankedItem) -> RankedItem {
        var actions = winner.item.actions
        var actionIDs = Set(actions.map(\.id))

        for action in duplicate.item.actions {
            guard actions.count < DomainLimits.actionsPerItem else { break }

            let displayedID: ActionID
            if actionIDs.contains(action.id) {
                guard !actions.contains(where: { $0 == action }) else { continue }
                displayedID = uniqueRoutedActionID(
                    providerID: duplicate.item.providerID,
                    actionID: action.id,
                    occupiedIDs: actionIDs
                )
            } else {
                displayedID = action.id
            }
            actionIDs.insert(displayedID)
            actions.append(
                action.routed(
                    from: duplicate.item.providerID,
                    itemID: duplicate.item.id,
                    displayedID: displayedID
                )
            )
        }

        return RankedItem(
            item: winner.item.replacingActions(actions),
            score: winner.score,
            matchTier: winner.matchTier
        )
    }

    private static func uniqueRoutedActionID(
        providerID: ProviderID,
        actionID: ActionID,
        occupiedIDs: Set<ActionID>
    ) -> ActionID {
        let base = "\(providerID.rawValue).\(actionID.rawValue)"
        let first = ActionID(base)
        guard occupiedIDs.contains(first) else { return first }

        var suffix = 2
        while occupiedIDs.contains(ActionID("\(base).\(suffix)")) {
            suffix += 1
        }
        return ActionID("\(base).\(suffix)")
    }
}
