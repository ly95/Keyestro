import Foundation
import Testing
@testable import KeyestroDomain

@Test func identifierDescriptionsAndOrderingCoverBothIdentityDimensions() {
    let providerA: ProviderID = "a"
    let providerB = ProviderID(rawValue: "b")
    #expect(providerA.description == "a")
    #expect(providerA < providerB)

    let first = ItemID(providerID: providerA, providerStableID: "first")
    let second = ItemID(providerID: providerA, providerStableID: "second")
    let otherProvider = ItemID(providerID: providerB, providerStableID: "first")
    #expect(first.description == "a:first")
    #expect(first < second)
    #expect(first < otherProvider)

    let open: ActionID = "open"
    let reveal = ActionID(rawValue: "reveal")
    #expect(open.description == "open")
    #expect(open < reveal)
}

@Test func launcherItemSanitizationCoversEveryRejectedAndBoundedShape() throws {
    let open = ActionDescriptor(id: "open", title: "Open")
    let baseID = ItemID(providerID: "coverage", providerStableID: "item")

    let blank = LauncherItem(
        id: baseID,
        providerID: "coverage",
        title: " \n ",
        actions: [open],
        defaultActionID: open.id
    )
    #expect(blank.sanitized() == nil)

    let missingDefault = LauncherItem(
        id: baseID,
        providerID: "coverage",
        title: "Missing default",
        actions: [ActionDescriptor(id: "other", title: "Other")],
        defaultActionID: open.id
    )
    #expect(missingDefault.sanitized() == nil)

    let duplicateOnly = LauncherItem(
        id: baseID,
        providerID: "coverage",
        title: "Duplicate",
        actions: [
            ActionDescriptor(id: "", title: "Empty"),
            open,
            ActionDescriptor(id: "open", title: "Duplicate"),
        ],
        defaultActionID: open.id
    )
    #expect(try #require(duplicateOnly.sanitized()).actions == [open])

    let oversizedThumbnail = LauncherItem(
        id: baseID,
        providerID: "coverage",
        title: "Thumbnail",
        icon: .thumbnailPNG(Data(repeating: 0, count: 256 * 1_024 + 1)),
        actions: [open],
        defaultActionID: open.id,
        scoreFeatures: ScoreFeatures(context: .infinity, providerPrior: -.infinity)
    )
    let sanitized = try #require(oversizedThumbnail.sanitized())
    #expect(sanitized.icon == nil)
    #expect(sanitized.scoreFeatures.context == 0)
    #expect(sanitized.scoreFeatures.providerPrior == 0)
}

@Test func fuzzyMatchingCoversCamelCaseAndEveryMetadataRelationship() {
    #expect(TextNormalizer.tokens("fooBar/baz-qux_value.txt") == ["foo", "bar", "baz", "qux", "value", "txt"])

    let contains = FuzzyMatcher.evaluate(
        query: "needle",
        title: "unrelated",
        subtitle: "prefix needle suffix",
        keywords: []
    )
    #expect(contains.tier == .metadata)
    #expect(contains.textMatch == 0.52)

    let fuzzyMetadata = FuzzyMatcher.evaluate(
        query: "ace",
        title: "unrelated",
        subtitle: nil,
        keywords: ["abcdef"]
    )
    #expect(fuzzyMetadata.tier == .metadata)
    #expect(fuzzyMetadata.textMatch <= 0.48)

    #expect(FuzzyMatcher.evaluate(query: "longer", title: "tiny", subtitle: nil, keywords: []).tier == .none)
    #expect(FuzzyMatcher.evaluate(query: "zzz", title: "abcdef", subtitle: nil, keywords: []).tier == .none)
}

@Test func rankingAndDeduplicationCoverEveryDeterministicTieBreaker() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let open = ActionDescriptor(id: "open", title: "Open")
    func item(
        provider: ProviderID,
        stableID: String,
        title: String = "Same",
        pinned: Bool = false,
        canonical: CanonicalResource? = nil,
        actions: [ActionDescriptor] = [open]
    ) -> LauncherItem {
        LauncherItem(
            id: ItemID(providerID: provider, providerStableID: stableID),
            providerID: provider,
            title: title,
            canonicalResource: canonical,
            actions: actions,
            defaultActionID: actions[0].id,
            scoreFeatures: ScoreFeatures(lastUsedAt: now, executionCount90Days: 1, isPinned: pinned)
        )
    }

    let pinned = item(provider: "same", stableID: "pinned", pinned: true)
    let unpinned = item(provider: "same", stableID: "plain")
    let rankedPinned = Ranker().rank(
        [unpinned, pinned],
        for: QueryRequest(generation: 1, rawText: "same", normalizedText: "same", mode: .all),
        now: now
    )
    #expect(rankedPinned.first?.id == pinned.id)

    let exact = item(provider: "same", stableID: "exact", title: "same")
    let token = item(provider: "same", stableID: "token", title: "prefix same")
    let tierTie = Ranker(
        configuration: RankingConfiguration(minimumTextMatch: 0)
    ).rank(
        [token, exact],
        for: QueryRequest(generation: 2, rawText: "same", normalizedText: "same", mode: .all),
        now: now
    )
    #expect(tierTie.first?.id == exact.id)

    let providerA = item(provider: "a", stableID: "same")
    let providerB = item(provider: "b", stableID: "same")
    let providerTie = Ranker().rank(
        [providerB, providerA],
        for: QueryRequest(generation: 3, rawText: "same", normalizedText: "same", mode: .all),
        now: now
    )
    #expect(providerTie.first?.item.providerID == "a")

    let exactTie = LauncherItem(
        id: ItemID(providerID: "same", providerStableID: "exact-tier"),
        providerID: "same",
        title: "same",
        actions: [open],
        defaultActionID: open.id,
        scoreFeatures: ScoreFeatures(context: 0.26)
    )
    let tokenTie = LauncherItem(
        id: ItemID(providerID: "same", providerStableID: "token-tier"),
        providerID: "same",
        title: "prefix same",
        actions: [open],
        defaultActionID: open.id,
        scoreFeatures: ScoreFeatures(lastUsedAt: now)
    )
    let matchTierTie = Ranker().rank(
        [tokenTie, exactTie],
        for: QueryRequest(generation: 4, rawText: "same", normalizedText: "same", mode: .all),
        now: now
    )
    #expect(matchTierTie.first?.id == exactTie.id)

    let canonical = CanonicalResource.command("coverage")
    let weaker = RankedItem(item: item(provider: "weak", stableID: "1", canonical: canonical), score: 0.2, matchTier: .fuzzy)
    let stronger = RankedItem(item: item(provider: "strong", stableID: "2", canonical: canonical), score: 0.9, matchTier: .exact)
    #expect(ItemDeduplicator.deduplicate([weaker, stronger]).first?.item.providerID == "strong")

    let existingReroute = ActionDescriptor(id: "duplicate.open", title: "Existing")
    let duplicateOpen = ActionDescriptor(id: "open", title: "Different")
    let winner = RankedItem(
        item: item(
            provider: "winner",
            stableID: "winner",
            canonical: canonical,
            actions: [open, existingReroute]
        ),
        score: 1,
        matchTier: .exact
    )
    let duplicate = RankedItem(
        item: item(
            provider: "duplicate",
            stableID: "duplicate",
            canonical: canonical,
            actions: [duplicateOpen]
        ),
        score: 0,
        matchTier: .fuzzy
    )
    let collisionMerged = try #require(ItemDeduplicator.deduplicate([winner, duplicate]).first)
    #expect(collisionMerged.item.actions.count == 3)
    #expect(collisionMerged.item.actions.last?.id == "duplicate.open.2")
    #expect(collisionMerged.item.actions.last?.route?.providerID == "duplicate")

    let identical = RankedItem(
        item: item(provider: "duplicate", stableID: "identical", canonical: canonical),
        score: 0,
        matchTier: .fuzzy
    )
    #expect(ItemDeduplicator.deduplicate([winner, identical]).first?.item.actions.count == 2)

    let exactSort = RankedItem(item: item(provider: "same", stableID: "sort-exact"), score: 0.5, matchTier: .exact)
    let fuzzySort = RankedItem(item: item(provider: "same", stableID: "sort-fuzzy"), score: 0.5, matchTier: .fuzzy)
    #expect(ItemDeduplicator.deduplicate([fuzzySort, exactSort]).first?.matchTier == .exact)
}
