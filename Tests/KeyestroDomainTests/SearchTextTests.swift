import Foundation
import Testing
@testable import KeyestroDomain

@Test func normalizationUsesNFKCAndCollapsesWhitespace() {
    #expect(TextNormalizer.normalize("  Ｋéyestro\n\tAPP ", locale: Locale(identifier: "en_US")) == "keyestro app")
}

@Test func queryPrefixIsIgnoredDuringComposition() {
    #expect(QueryParser.parse("/文档", isComposing: true).mode == .all)
    #expect(QueryParser.parse("/文档", isComposing: false).mode == .files)
}

@Test func fuzzyMatchPrefersTitlePrefix() {
    let prefix = FuzzyMatcher.evaluate(query: "key", title: "Keyestro", subtitle: nil, keywords: [])
    let fuzzy = FuzzyMatcher.evaluate(query: "kys", title: "Keyestro", subtitle: nil, keywords: [])
    #expect(prefix.tier < fuzzy.tier)
    #expect(prefix.textMatch > fuzzy.textMatch)
}

@Test func semanticAliasesReturnTheStrongestMatchInsteadOfTheFirstMatch() {
    let evaluation = FuzzyMatcher.evaluate(
        query: "mail",
        title: "Thunderbird",
        aliases: [
            SearchAlias(value: "mailbox tools", role: .metadata),
            SearchAlias(value: "mail", role: .userAlias),
        ]
    )

    #expect(evaluation.tier == .exact)
    #expect(evaluation.textMatch == 1)
    #expect(evaluation.matchedAliasRole == .userAlias)
}

@Test func semanticAliasPoliciesKeepTechnicalIdentifiersLiteral() {
    let aliases = [SearchAlias(value: "com.google.Chrome", role: .technical)]

    #expect(
        FuzzyMatcher.evaluate(query: "cgc", title: "Unrelated", aliases: aliases).tier == .none
    )
    let literal = FuzzyMatcher.evaluate(
        query: "google.chrome",
        title: "Unrelated",
        aliases: aliases
    )
    #expect(literal.tier == .metadata)
    #expect(literal.matchedAliasRole == .technical)

    let exactOnly = [
        SearchAlias(value: "mailbox", role: .userAlias, matchPolicy: .exact)
    ]
    #expect(
        FuzzyMatcher.evaluate(query: "mail", title: "Unrelated", aliases: exactOnly).tier == .none
    )
}
