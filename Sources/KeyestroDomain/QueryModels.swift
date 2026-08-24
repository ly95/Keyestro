import Foundation

/// Built-in query routing mode.
public enum QueryMode: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case files
    case commands
    case calculator
    case extensions
}

/// Non-sensitive context captured when a launcher query starts.
public struct QueryContext: Sendable, Equatable {
    public let frontmostBundleIdentifier: String?
    public let frontmostApplicationName: String?
    public let frontmostProcessIdentifier: Int32?
    public let frontmostWindowTitle: String?
    public let mouseScreenIdentifier: String?
    public let currentDirectoryURL: URL?

    public init(
        frontmostBundleIdentifier: String? = nil,
        frontmostApplicationName: String? = nil,
        frontmostProcessIdentifier: Int32? = nil,
        frontmostWindowTitle: String? = nil,
        mouseScreenIdentifier: String? = nil,
        currentDirectoryURL: URL? = nil
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.frontmostApplicationName = frontmostApplicationName?.limitedToUnicodeScalars(DomainLimits.titleUnicodeScalars)
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.frontmostWindowTitle = frontmostWindowTitle
        self.mouseScreenIdentifier = mouseScreenIdentifier
        self.currentDirectoryURL = currentDirectoryURL
    }
}

/// Immutable request passed to every provider for one search generation.
public struct QueryRequest: Sendable, Equatable {
    public let id: UUID
    public let generation: UInt64
    public let rawText: String
    public let normalizedText: String
    public let mode: QueryMode
    public let limit: Int
    public let context: QueryContext
    public let startedAt: ContinuousClock.Instant

    public init(
        id: UUID = UUID(),
        generation: UInt64,
        rawText: String,
        normalizedText: String,
        mode: QueryMode,
        limit: Int = DomainLimits.visibleItems,
        context: QueryContext = QueryContext(),
        startedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.id = id
        self.generation = generation
        self.rawText = rawText.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        self.normalizedText = normalizedText.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        self.mode = mode
        self.limit = min(max(1, limit), DomainLimits.visibleItems)
        self.context = context
        self.startedAt = startedAt
    }
}

/// Result of parsing an optional query prefix.
public struct ParsedQuery: Equatable, Sendable {
    public let mode: QueryMode
    public let searchText: String

    public init(mode: QueryMode, searchText: String) {
        self.mode = mode
        self.searchText = searchText
    }
}

/// Parses launcher prefixes without persisting or otherwise retaining raw query text.
public enum QueryParser {
    /// Parses a mode prefix only when input-method composition is inactive.
    public static func parse(_ rawText: String, isComposing: Bool, prefixesEnabled: Bool = true) -> ParsedQuery {
        guard prefixesEnabled, !isComposing, let first = rawText.first else {
            return ParsedQuery(mode: .all, searchText: rawText)
        }

        let mode: QueryMode
        switch first {
        case "/": mode = .files
        case ">": mode = .commands
        case "=": mode = .calculator
        case "@": mode = .extensions
        default: return ParsedQuery(mode: .all, searchText: rawText)
        }

        return ParsedQuery(mode: mode, searchText: String(rawText.dropFirst()))
    }
}
