import Foundation
import Testing
@testable import KeyestroDomain

@Test func rankingHasDeterministicTieBreaks() {
    let action = ActionDescriptor(id: "open", title: "Open")
    let a = LauncherItem(
        id: ItemID(providerID: "apps", providerStableID: "a"),
        providerID: "apps",
        title: "Alpha",
        actions: [action],
        defaultActionID: action.id
    )
    let b = LauncherItem(
        id: ItemID(providerID: "apps", providerStableID: "b"),
        providerID: "apps",
        title: "Alpha",
        actions: [action],
        defaultActionID: action.id
    )
    let request = QueryRequest(generation: 1, rawText: "a", normalizedText: "a", mode: .all)
    #expect(Ranker().rank([b, a], for: request, now: Date(timeIntervalSince1970: 0)).map(\.id) == [a.id, b.id])
}

@Test func emptyQueryRecencyCanDisplaceAnHistoricallyFrequentApplication() throws {
    let action = ActionDescriptor(id: "open", title: "Open")
    let now = Date(timeIntervalSince1970: 10_000_000)
    let staleFrequent = LauncherItem(
        id: ItemID(providerID: "apps", providerStableID: "stale-frequent"),
        providerID: "apps",
        title: "Historically Frequent",
        actions: [action],
        defaultActionID: action.id,
        scoreFeatures: ScoreFeatures(
            lastUsedAt: now.addingTimeInterval(-91 * 86_400),
            executionCount90Days: 100
        )
    )
    let recentLowFrequency = LauncherItem(
        id: ItemID(providerID: "apps", providerStableID: "recent"),
        providerID: "apps",
        title: "Recently Used",
        actions: [action],
        defaultActionID: action.id,
        scoreFeatures: ScoreFeatures(lastUsedAt: now, executionCount90Days: 1)
    )
    let emptyQuery = QueryRequest(generation: 1, rawText: "", normalizedText: "", mode: .all)

    let ranked = Ranker().rank([staleFrequent, recentLowFrequency], for: emptyQuery, now: now)

    #expect(ranked.map(\.id) == [recentLowFrequency.id, staleFrequent.id])
    #expect(try #require(ranked.first).score > #require(ranked.last).score)
}

@Test func deduplicationMergesNonidenticalActions() throws {
    let open = ActionDescriptor(id: "open", title: "Open")
    let reveal = ActionDescriptor(id: "reveal", title: "Reveal")
    let canonical = CanonicalResource.url(try #require(URL(string: "https://example.com")))
    let first = LauncherItem(
        id: ItemID(providerID: "a", providerStableID: "1"), providerID: "a", title: "Example",
        canonicalResource: canonical, actions: [open], defaultActionID: open.id
    )
    let second = LauncherItem(
        id: ItemID(providerID: "b", providerStableID: "2"), providerID: "b", title: "Example",
        canonicalResource: canonical, actions: [reveal], defaultActionID: reveal.id
    )
    let merged = ItemDeduplicator.deduplicate([
        RankedItem(item: first, score: 1, matchTier: .exact),
        RankedItem(item: second, score: 0.9, matchTier: .exact),
    ])
    let mergedItem = try #require(merged.first?.item)
    #expect(merged.count == 1)
    #expect(mergedItem.actions.count == 2)
    #expect(mergedItem.actions.last?.route?.providerID == "b")
}

@Test func actionConfirmationTargetIsBackwardCompatibleBoundedAndPreservedByRouting() throws {
    let legacy = ActionDescriptor(id: "legacy", title: "Legacy", risk: .destructive)
    let decodedLegacy = try JSONDecoder().decode(
        ActionDescriptor.self,
        from: JSONEncoder().encode(legacy)
    )
    #expect(decodedLegacy.confirmationTarget == nil)

    let oversized = String(repeating: "x", count: DomainLimits.subtitleUnicodeScalars + 10)
    let action = ActionDescriptor(
        id: "delete",
        title: "Delete",
        risk: .destructive,
        confirmationTarget: oversized
    )
    #expect(action.confirmationTarget?.unicodeScalars.count == DomainLimits.subtitleUnicodeScalars)
    #expect(
        action.routed(
            from: "provider",
            itemID: ItemID(providerID: "provider", providerStableID: "item"),
            displayedID: "routed"
        ).confirmationTarget == action.confirmationTarget
    )
}
