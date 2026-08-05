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
