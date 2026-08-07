import Foundation

/// Applies bounded compatibility normalization and locale-independent case folding to search text.
public enum TextNormalizer {
    /// NFKC-normalizes, locale-folds, trims, and collapses whitespace.
    public static func normalize(_ value: String, locale: Locale = .current) -> String {
        let compatibility = value.precomposedStringWithCompatibilityMapping
        let folded = compatibility.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        )
        return folded.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    /// Produces path and camel-case tokens without changing display text.
    public static func tokens(_ value: String, locale: Locale = .current) -> [String] {
        let separated = insertCamelCaseBoundaries(value)
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        return normalize(separated, locale: locale).split(separator: " ").map(String.init)
    }

    private static func insertCamelCaseBoundaries(_ value: String) -> String {
        var output = ""
        var previousWasLowercaseOrNumber = false
        for character in value {
            let isUppercase = character.isUppercase
            if isUppercase && previousWasLowercaseOrNumber {
                output.append(" ")
            }
            output.append(character)
            previousWasLowercaseOrNumber = character.isLowercase || character.isNumber
        }
        return output
    }
}

/// The strongest deterministic relationship found between a query and candidate text.
public enum MatchTier: Int, Codable, Comparable, Sendable {
    case exact = 0
    case titlePrefix = 1
    case tokenPrefix = 2
    case substring = 3
    case fuzzy = 4
    case metadata = 5
    case noQuery = 6
    case none = 7

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The tier and bounded numeric features produced by fuzzy matching.
public struct MatchEvaluation: Equatable, Sendable {
    public let tier: MatchTier
    public let textMatch: Double
    public let prefixBonus: Double

    public init(tier: MatchTier, textMatch: Double, prefixBonus: Double) {
        self.tier = tier
        self.textMatch = min(1, max(0, textMatch))
        self.prefixBonus = min(1, max(0, prefixBonus))
    }
}

/// Evaluates normalized query text against bounded titles, subtitles, and keywords.
public enum FuzzyMatcher {
    public static func evaluate(
        query: String,
        title: String,
        subtitle: String?,
        keywords: [String],
        locale: Locale = .current
    ) -> MatchEvaluation {
        let normalizedQuery = TextNormalizer.normalize(query, locale: locale)
        guard !normalizedQuery.isEmpty else {
            return MatchEvaluation(tier: .noQuery, textMatch: 1, prefixBonus: 0)
        }

        let normalizedTitle = TextNormalizer.normalize(title, locale: locale)
        if normalizedTitle == normalizedQuery {
            return MatchEvaluation(tier: .exact, textMatch: 1, prefixBonus: 1)
        }
        if normalizedTitle.hasPrefix(normalizedQuery) {
            let coverage = lengthCoverage(query: normalizedQuery, candidate: normalizedTitle)
            return MatchEvaluation(tier: .titlePrefix, textMatch: 0.9 + (0.1 * coverage), prefixBonus: 1)
        }

        let titleTokens = TextNormalizer.tokens(title, locale: locale)
        if titleTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return MatchEvaluation(tier: .tokenPrefix, textMatch: 0.86, prefixBonus: 0.8)
        }

        if normalizedTitle.range(of: normalizedQuery) != nil {
            let coverage = lengthCoverage(query: normalizedQuery, candidate: normalizedTitle)
            return MatchEvaluation(tier: .substring, textMatch: 0.72 + (0.18 * coverage), prefixBonus: 0.2)
        }

        if let fuzzy = subsequenceScore(query: normalizedQuery, candidate: normalizedTitle) {
            return MatchEvaluation(tier: .fuzzy, textMatch: fuzzy, prefixBonus: 0)
        }

        let metadata = ([subtitle].compactMap { $0 } + keywords)
            .map { TextNormalizer.normalize($0, locale: locale) }
        for value in metadata where !value.isEmpty {
            if value == normalizedQuery || value.hasPrefix(normalizedQuery) {
                return MatchEvaluation(tier: .metadata, textMatch: 0.62, prefixBonus: 0.35)
            }
            if value.contains(normalizedQuery) {
                return MatchEvaluation(tier: .metadata, textMatch: 0.52, prefixBonus: 0)
            }
            if let score = subsequenceScore(query: normalizedQuery, candidate: value) {
                return MatchEvaluation(tier: .metadata, textMatch: min(0.48, score * 0.72), prefixBonus: 0)
            }
        }

        return MatchEvaluation(tier: .none, textMatch: 0, prefixBonus: 0)
    }

    private static func lengthCoverage(query: String, candidate: String) -> Double {
        return min(1, Double(query.count) / Double(candidate.count))
    }

    private static func subsequenceScore(query: String, candidate: String) -> Double? {
        let queryCharacters = Array(query)
        let candidateCharacters = Array(candidate)
        guard !queryCharacters.isEmpty, queryCharacters.count <= candidateCharacters.count else { return nil }

        var queryIndex = 0
        var firstMatch: Int?
        var previousMatch: Int?
        var gaps = 0
        var consecutive = 0
        var longestRun = 0

        for (index, character) in candidateCharacters.enumerated() {
            guard queryIndex < queryCharacters.count, character == queryCharacters[queryIndex] else { continue }
            firstMatch = firstMatch ?? index
            if let previousMatch {
                let gap = index - previousMatch - 1
                gaps += max(0, gap)
                if gap == 0 {
                    consecutive += 1
                } else {
                    longestRun = max(longestRun, consecutive)
                    consecutive = 1
                }
            } else {
                consecutive = 1
            }
            previousMatch = index
            queryIndex += 1
        }

        guard queryIndex == queryCharacters.count else { return nil }
        longestRun = max(longestRun, consecutive)
        let coverage = Double(queryCharacters.count) / Double(candidateCharacters.count)
        let continuity = Double(longestRun) / Double(queryCharacters.count)
        let gapPenalty = min(0.35, Double(gaps) / Double(max(1, candidateCharacters.count)) * 0.7)
        let startBonus = firstMatch == 0 ? 0.1 : 0
        return min(0.72, max(0.2, 0.3 + (coverage * 0.22) + (continuity * 0.2) + startBonus - gapPenalty))
    }
}
