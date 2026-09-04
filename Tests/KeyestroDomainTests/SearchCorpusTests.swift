import Foundation
import Testing
@testable import KeyestroDomain

private struct SearchCorpusCase {
    let query: String
    let expectedItemID: ItemID
    let maximumRank: Int
}

private func corpusItem(
    _ stableID: String,
    title: String,
    aliases: [SearchAlias] = [],
    scoreFeatures: ScoreFeatures = ScoreFeatures()
) -> LauncherItem {
    let action = ActionDescriptor(id: "open", title: "Open")
    return LauncherItem(
        id: ItemID(providerID: "corpus", providerStableID: stableID),
        providerID: "corpus",
        title: title,
        searchAliases: aliases,
        actions: [action],
        defaultActionID: action.id,
        scoreFeatures: scoreFeatures
    )
}

@Test func syntheticSearchCorpusMaintainsTopOneAndTopFiveReachability() throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let heavilyLearned = ScoreFeatures(
        lastUsedAt: now,
        executionCount90Days: 100,
        context: 1,
        providerPrior: 1
    )
    let items = [
        corpusItem("calendar", title: "Calendar"),
        corpusItem("calendar-helper", title: "Calendar Helper", scoreFeatures: heavilyLearned),
        corpusItem(
            "thunderbird",
            title: "Thunderbird",
            aliases: [SearchAlias(value: "mail", role: .userAlias)]
        ),
        corpusItem("mailroom", title: "Mailroom Automation", scoreFeatures: heavilyLearned),
        corpusItem("visual-studio-code", title: "Visual Studio Code"),
        corpusItem("vscodium", title: "VSCodium", scoreFeatures: heavilyLearned),
        corpusItem("vsc-tools", title: "VSC Tools"),
        corpusItem("voice-screen-capture", title: "Voice Screen Capture"),
        corpusItem("observer", title: "Observer"),
        corpusItem("obsidian", title: "Obsidian"),
    ]
    let cases = [
        SearchCorpusCase(
            query: "calendar",
            expectedItemID: ItemID(providerID: "corpus", providerStableID: "calendar"),
            maximumRank: 1
        ),
        SearchCorpusCase(
            query: "mail",
            expectedItemID: ItemID(providerID: "corpus", providerStableID: "thunderbird"),
            maximumRank: 1
        ),
        SearchCorpusCase(
            query: "vsc",
            expectedItemID: ItemID(providerID: "corpus", providerStableID: "visual-studio-code"),
            maximumRank: 5
        ),
        SearchCorpusCase(
            query: "obs",
            expectedItemID: ItemID(providerID: "corpus", providerStableID: "obsidian"),
            maximumRank: 5
        ),
    ]

    for testCase in cases {
        let request = QueryRequest(
            generation: 1,
            rawText: testCase.query,
            normalizedText: TextNormalizer.normalize(testCase.query),
            mode: .all
        )
        let ranked = Ranker().rank(items, for: request, now: now)
        let index = try #require(ranked.firstIndex(where: { $0.id == testCase.expectedItemID }))
        #expect(index < testCase.maximumRank, "\(testCase.query) exceeded its corpus rank budget")
    }
}

@Test func exactNameAndUserAliasCannotBeOvertakenByFrecency() throws {
    let now = Date(timeIntervalSince1970: 10_000_000)
    let learnedPrefix = corpusItem(
        "mailroom",
        title: "Mailroom Automation",
        scoreFeatures: ScoreFeatures(
            lastUsedAt: now,
            executionCount90Days: 100,
            context: 1,
            providerPrior: 1
        )
    )
    let exactUserAlias = corpusItem(
        "thunderbird",
        title: "Thunderbird",
        aliases: [SearchAlias(value: "mail", role: .userAlias)]
    )
    let exactOfficialName = corpusItem(
        "mail-suite",
        title: "Communication Suite",
        aliases: [SearchAlias(value: "mail", role: .name)]
    )
    let request = QueryRequest(
        generation: 1,
        rawText: "mail",
        normalizedText: "mail",
        mode: .all
    )

    let ranked = Ranker().rank(
        [learnedPrefix, exactUserAlias, exactOfficialName],
        for: request,
        now: now
    )

    #expect(ranked.prefix(2).allSatisfy { $0.matchTier == .exact })
    #expect(ranked.last?.id == learnedPrefix.id)
    #expect(try #require(ranked.last).score > #require(ranked.first).score)
}

@Test func frequencyLearningIsScoreMonotonicWithoutRetainingQueryText() throws {
    let request = QueryRequest(
        generation: 1,
        rawText: "vsc",
        normalizedText: "vsc",
        mode: .all
    )
    let counts = [0, 1, 10, 100]
    let scores = try counts.map { count in
        let item = corpusItem(
            "visual-studio-code",
            title: "Visual Studio Code",
            scoreFeatures: ScoreFeatures(executionCount90Days: count)
        )
        return try #require(Ranker().rank([item], for: request).first).score
    }

    #expect(zip(scores, scores.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
}

@Test func manualPinRemainsAboveTheExactIntentFirewallWithinAProvider() {
    let exact = corpusItem(
        "exact",
        title: "Communication Suite",
        aliases: [SearchAlias(value: "mail", role: .userAlias)]
    )
    let pinnedPrefix = corpusItem(
        "pinned",
        title: "Mailroom",
        scoreFeatures: ScoreFeatures(isPinned: true)
    )
    let request = QueryRequest(
        generation: 1,
        rawText: "mail",
        normalizedText: "mail",
        mode: .all
    )

    let ranked = Ranker().rank([exact, pinnedPrefix], for: request)

    #expect(ranked.first?.id == pinnedPrefix.id)
    #expect(ranked.last?.matchTier == .exact)
}

@Test func launcherItemCodablePreservesSemanticAliasesAndAcceptsLegacyPayloads() throws {
    let item = corpusItem(
        "codable",
        title: "Codable",
        aliases: [
            SearchAlias(value: "com.example.codable", role: .technical, matchPolicy: .exact)
        ]
    )
    let encoded = try JSONEncoder().encode(item)
    let roundTrip = try JSONDecoder().decode(LauncherItem.self, from: encoded)
    #expect(roundTrip == item)
    #expect(roundTrip.searchAliases.first?.role == .technical)
    #expect(roundTrip.searchAliases.first?.matchPolicy == .exact)

    var legacyObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "searchAliases")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let decodedLegacy = try JSONDecoder().decode(LauncherItem.self, from: legacyData)

    #expect(decodedLegacy.searchAliases.isEmpty)
    #expect(decodedLegacy.id == item.id)
    #expect(decodedLegacy.title == item.title)
}
