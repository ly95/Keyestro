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
            let match = FuzzyMatcher.evaluate(
                query: request.normalizedText,
                title: item.title,
                subtitle: item.subtitle,
                keywords: item.keywords,
                locale: locale
            )
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

        return ranked.sorted(by: isOrderedBefore)
    }

    private func recency(lastUsedAt: Date?, now: Date) -> Double {
        guard let lastUsedAt else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(lastUsedAt) / 86_400)
        return pow(0.5, ageDays / configuration.recencyHalfLifeDays)
    }

    private func frequency(count: Int) -> Double {
        min(1, log1p(Double(max(0, count))) / log1p(Double(configuration.maximumFrequencyCount)))
    }

    private func isOrderedBefore(_ lhs: RankedItem, _ rhs: RankedItem) -> Bool {
        if lhs.item.providerID == rhs.item.providerID,
            lhs.item.scoreFeatures.isPinned != rhs.item.scoreFeatures.isPinned
        {
            return lhs.item.scoreFeatures.isPinned
        }
        if abs(lhs.score - rhs.score) > 0.000_000_1 {
            return lhs.score > rhs.score
        }
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
        var output: [RankedItem] = []
        var canonicalIndices: [CanonicalResource: Int] = [:]

        for candidate in rankedItems {
            guard let canonical = candidate.item.canonicalResource else {
                output.append(candidate)
                continue
            }

            guard let existingIndex = canonicalIndices[canonical] else {
                canonicalIndices[canonical] = output.count
                output.append(candidate)
                continue
            }

            let existing = output[existingIndex]
            if candidate.score > existing.score {
                output[existingIndex] = merge(winner: candidate, duplicate: existing)
            } else {
                output[existingIndex] = merge(winner: existing, duplicate: candidate)
            }
        }

        return output.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.000_000_1 { return lhs.score > rhs.score }
            if lhs.matchTier != rhs.matchTier { return lhs.matchTier < rhs.matchTier }
            if lhs.item.providerID != rhs.item.providerID { return lhs.item.providerID < rhs.item.providerID }
            return lhs.id < rhs.id
        }
    }

    private static func merge(winner: RankedItem, duplicate: RankedItem) -> RankedItem {
        var actions = winner.item.actions
        var actionIDs = Set(actions.map(\.id))

        for action in duplicate.item.actions {
            var displayedID = action.id
            if actionIDs.contains(displayedID) {
                guard !actions.contains(where: { $0 == action }) else { continue }
                displayedID = ActionID("\(duplicate.item.providerID.rawValue).\(action.id.rawValue)")
            }
            guard actionIDs.insert(displayedID).inserted else { continue }
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
}
