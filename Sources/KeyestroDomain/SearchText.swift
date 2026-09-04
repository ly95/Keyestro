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

/// Describes why alternate text identifies a launcher item.
///
/// Roles let the host keep user intent, human-readable names, descriptive metadata,
/// and machine identifiers from accidentally sharing the same matching behavior.
public enum SearchAliasRole: String, Codable, Sendable {
    /// A name explicitly chosen by the user. An exact match is treated like an exact title.
    case userAlias
    /// An official or alternate human-readable name. An exact match is treated like an exact title.
    case name
    /// A localized or translated name that should remain discoverable through fuzzy matching.
    case translation
    /// Descriptive text such as a category, subtitle, or legacy keyword.
    case metadata
    /// A machine-facing identifier or path that must not match by loose subsequence.
    case technical
}

/// Controls how loosely a query may match a semantic search alias.
public enum SearchMatchPolicy: String, Codable, Sendable {
    /// Only a complete normalized equality match is accepted.
    case exact
    /// Exact, prefix, and substring relationships are accepted, but fuzzy subsequences are not.
    case literal
    /// Exact, prefix, substring, token-prefix, and fuzzy subsequence relationships are accepted.
    case fuzzy
}

/// Alternate searchable text with an explicit semantic role and matching policy.
public struct SearchAlias: Codable, Equatable, Sendable {
    public let value: String
    public let role: SearchAliasRole
    public let matchPolicy: SearchMatchPolicy

    public init(
        value: String,
        role: SearchAliasRole,
        matchPolicy: SearchMatchPolicy? = nil
    ) {
        self.value = value
        self.role = role
        self.matchPolicy = matchPolicy ?? (role == .technical ? .literal : .fuzzy)
    }
}

/// The tier and bounded numeric features produced by fuzzy matching.
public struct MatchEvaluation: Equatable, Sendable {
    public let tier: MatchTier
    public let textMatch: Double
    public let prefixBonus: Double
    public let matchedAliasRole: SearchAliasRole?

    public init(
        tier: MatchTier,
        textMatch: Double,
        prefixBonus: Double,
        matchedAliasRole: SearchAliasRole? = nil
    ) {
        self.tier = tier
        self.textMatch = min(1, max(0, textMatch))
        self.prefixBonus = min(1, max(0, prefixBonus))
        self.matchedAliasRole = matchedAliasRole
    }
}

/// Evaluates normalized query text against bounded titles, subtitles, and keywords.
public enum FuzzyMatcher {
    /// Backward-compatible matching for providers that have not assigned semantic alias roles yet.
    public static func evaluate(
        query: String,
        title: String,
        subtitle: String?,
        keywords: [String],
        locale: Locale = .current
    ) -> MatchEvaluation {
        var aliases = keywords.map {
            SearchAlias(value: $0, role: .metadata)
        }
        if let subtitle {
            aliases.insert(SearchAlias(value: subtitle, role: .metadata), at: 0)
        }
        return evaluate(query: query, title: title, aliases: aliases, locale: locale)
    }

    /// Evaluates a title and every semantic alias, returning the strongest relationship found.
    public static func evaluate(
        query: String,
        title: String,
        aliases: [SearchAlias],
        locale: Locale = .current
    ) -> MatchEvaluation {
        let normalizedQuery = TextNormalizer.normalize(query, locale: locale)
        guard !normalizedQuery.isEmpty else {
            return MatchEvaluation(tier: .noQuery, textMatch: 1, prefixBonus: 0)
        }

        let normalizedTitle = TextNormalizer.normalize(title, locale: locale)
        var strongest = primaryEvaluation(
            query: normalizedQuery,
            candidate: normalizedTitle,
            tokens: TextNormalizer.tokens(title, locale: locale),
            policy: .fuzzy
        )

        for alias in aliases {
            let normalizedAlias = TextNormalizer.normalize(alias.value, locale: locale)
            guard !normalizedAlias.isEmpty else { continue }
            let primary = primaryEvaluation(
                query: normalizedQuery,
                candidate: normalizedAlias,
                tokens: TextNormalizer.tokens(alias.value, locale: locale),
                policy: alias.matchPolicy
            )
            let candidate = aliasEvaluation(primary, role: alias.role)
            if isStronger(candidate, than: strongest) {
                strongest = candidate
            }
        }

        return strongest
    }

    private static func primaryEvaluation(
        query: String,
        candidate: String,
        tokens: [String],
        policy: SearchMatchPolicy
    ) -> MatchEvaluation {
        guard !candidate.isEmpty else {
            return MatchEvaluation(tier: .none, textMatch: 0, prefixBonus: 0)
        }
        if candidate == query {
            return MatchEvaluation(tier: .exact, textMatch: 1, prefixBonus: 1)
        }
        guard policy != .exact else {
            return MatchEvaluation(tier: .none, textMatch: 0, prefixBonus: 0)
        }
        if candidate.hasPrefix(query) {
            let coverage = lengthCoverage(query: query, candidate: candidate)
            return MatchEvaluation(tier: .titlePrefix, textMatch: 0.9 + (0.1 * coverage), prefixBonus: 1)
        }
        if policy == .fuzzy, tokens.contains(where: { $0.hasPrefix(query) }) {
            return MatchEvaluation(tier: .tokenPrefix, textMatch: 0.86, prefixBonus: 0.8)
        }
        if candidate.range(of: query) != nil {
            let coverage = lengthCoverage(query: query, candidate: candidate)
            return MatchEvaluation(tier: .substring, textMatch: 0.72 + (0.18 * coverage), prefixBonus: 0.2)
        }
        if policy == .fuzzy, let fuzzy = subsequenceScore(query: query, candidate: candidate) {
            return MatchEvaluation(tier: .fuzzy, textMatch: fuzzy, prefixBonus: 0)
        }
        return MatchEvaluation(tier: .none, textMatch: 0, prefixBonus: 0)
    }

    private static func aliasEvaluation(
        _ evaluation: MatchEvaluation,
        role: SearchAliasRole
    ) -> MatchEvaluation {
        guard evaluation.tier != .none else { return evaluation }

        if role == .userAlias || role == .name {
            return MatchEvaluation(
                tier: evaluation.tier,
                textMatch: evaluation.textMatch,
                prefixBonus: evaluation.prefixBonus,
                matchedAliasRole: role
            )
        }

        let textMatch: Double
        let prefixBonus: Double
        switch evaluation.tier {
        case .exact, .titlePrefix:
            textMatch = 0.62
            prefixBonus = 0.35
        case .tokenPrefix:
            if role == .metadata {
                // Preserve legacy subtitle/keyword substring scoring when the token is internal.
                textMatch = 0.52
                prefixBonus = 0
            } else {
                textMatch = 0.6
                prefixBonus = 0.25
            }
        case .substring:
            textMatch = 0.52
            prefixBonus = 0
        case .fuzzy:
            textMatch = min(0.48, evaluation.textMatch * 0.72)
            prefixBonus = 0
        case .metadata, .noQuery, .none:
            textMatch = evaluation.textMatch
            prefixBonus = evaluation.prefixBonus
        }
        return MatchEvaluation(
            tier: .metadata,
            textMatch: textMatch,
            prefixBonus: prefixBonus,
            matchedAliasRole: role
        )
    }

    private static func isStronger(_ candidate: MatchEvaluation, than current: MatchEvaluation) -> Bool {
        if candidate.tier != current.tier { return candidate.tier < current.tier }
        if abs(candidate.textMatch - current.textMatch) > 0.000_000_1 {
            return candidate.textMatch > current.textMatch
        }
        if abs(candidate.prefixBonus - current.prefixBonus) > 0.000_000_1 {
            return candidate.prefixBonus > current.prefixBonus
        }
        return rolePriority(candidate.matchedAliasRole) < rolePriority(current.matchedAliasRole)
    }

    private static func rolePriority(_ role: SearchAliasRole?) -> Int {
        switch role {
        case nil: 0
        case .userAlias: 1
        case .name: 2
        case .translation: 3
        case .metadata: 4
        case .technical: 5
        }
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
