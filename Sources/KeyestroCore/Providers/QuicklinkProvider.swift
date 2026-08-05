import AppKit
import Foundation
import KeyestroDomain
import SQLite3

public struct QuicklinkDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let urlTemplate: String
    public let arguments: [ArgumentDefinition]
    public let keywords: [String]
    public let iconName: String
    public let browserBundleIdentifier: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        urlTemplate: String,
        arguments: [ArgumentDefinition],
        keywords: [String] = [],
        iconName: String = "link",
        browserBundleIdentifier: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard Self.validID(id), !title.isEmpty, title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
            urlTemplate.utf8.count <= 8_192,
            arguments.count <= 20,
            keywords.count <= DomainLimits.keywordCount,
            keywords.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= DomainLimits.keywordUnicodeScalars }),
            Self.validIconName(iconName),
            Self.validBrowserBundleIdentifier(browserBundleIdentifier),
            arguments.allSatisfy(Self.validArgument),
            Self.hasValidPlaceholderSyntax(urlTemplate),
            !Self.containsEmbeddedCredential(urlTemplate)
        else {
            throw ErrorDescriptor(code: "quicklinks.invalidDefinition", message: "The quick link definition is invalid.")
        }
        let argumentIDs = Set(arguments.map(\.id))
        guard argumentIDs.count == arguments.count,
            Self.placeholders(in: urlTemplate).isSubset(of: argumentIDs)
        else {
            throw ErrorDescriptor(
                code: "quicklinks.invalidPlaceholders",
                message: "Every URL placeholder must have one argument definition."
            )
        }
        self.id = id
        self.title = title
        self.urlTemplate = urlTemplate
        self.arguments = arguments
        self.keywords = keywords
        self.iconName = iconName
        self.browserBundleIdentifier = browserBundleIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func inferred(id: String = UUID().uuidString.lowercased(), title: String, urlTemplate: String) throws -> Self {
        let arguments = placeholders(in: urlTemplate).sorted().map {
            ArgumentDefinition(id: $0, title: $0.capitalized, kind: .text, required: true)
        }
        return try Self(id: id, title: title, urlTemplate: urlTemplate, arguments: arguments)
    }

    public static func placeholders(in template: String) -> Set<String> {
        var output = Set<String>()
        var remainder = template[...]
        while let opening = remainder.firstIndex(of: "{") {
            let afterOpening = remainder.index(after: opening)
            guard let closing = remainder[afterOpening...].firstIndex(of: "}") else { break }
            let name = String(remainder[afterOpening..<closing])
            if validArgumentID(name) { output.insert(name) }
            remainder = remainder[remainder.index(after: closing)...]
        }
        return output
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_")
            }
    }

    private static func validArgumentID(_ value: String) -> Bool {
        validID(value) && !value.contains(".")
    }

    private static func validIconName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
            }
    }

    private static func validBrowserBundleIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
            }
    }

    private static func validArgument(_ argument: ArgumentDefinition) -> Bool {
        guard validArgumentID(argument.id), !argument.title.isEmpty,
            argument.title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
            (argument.placeholder?.unicodeScalars.count ?? 0) <= 512
        else { return false }
        if case let .choice(options) = argument.kind {
            return !options.isEmpty && options.count <= 50
                && Set(options).count == options.count
                && options.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 256 }
        }
        return true
    }

    private static func hasValidPlaceholderSyntax(_ template: String) -> Bool {
        var remainder = template[...]
        while !remainder.isEmpty {
            guard let delimiter = remainder.firstIndex(where: { $0 == "{" || $0 == "}" }) else { return true }
            guard remainder[delimiter] == "{" else { return false }
            let afterOpening = remainder.index(after: delimiter)
            guard let closing = remainder[afterOpening...].firstIndex(of: "}") else { return false }
            let name = String(remainder[afterOpening..<closing])
            guard validArgumentID(name), !name.contains("{") else { return false }
            remainder = remainder[remainder.index(after: closing)...]
        }
        return true
    }

    private static func containsEmbeddedCredential(_ template: String) -> Bool {
        guard let components = URLComponents(string: template) else { return false }
        if components.user != nil || components.password != nil { return true }
        let sensitiveNames = Set([
            "accesskey", "accesstoken", "apikey", "auth", "authorization", "clientsecret", "key", "password",
            "passwd", "secret", "token",
        ])
        for item in components.queryItems ?? [] {
            let normalizedName = item.name.lowercased().filter(\.isLetter)
            guard sensitiveNames.contains(normalizedName), let value = item.value, !value.isEmpty else { continue }
            let placeholders = Self.placeholders(in: value)
            guard placeholders.count == 1, value == "{\(placeholders.first ?? "")}" else { return true }
        }
        return false
    }
}

public protocol QuicklinkStoring: Sendable {
    func allQuicklinks() async throws -> [QuicklinkDefinition]
    func quicklink(id: String) async throws -> QuicklinkDefinition?
    func saveQuicklink(_ definition: QuicklinkDefinition) async throws
    func deleteQuicklink(id: String) async throws
    /// Deletes only if the complete user-visible definition is still the one
    /// that was reviewed. The comparison and deletion are one isolated operation.
    func deleteQuicklink(ifUnchanged definition: QuicklinkDefinition) async throws -> Bool
}

public protocol QuicklinkBatchStoring: QuicklinkStoring {
    func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) async throws
    func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition], transactionID: String) async throws
    func hasCommittedConfigurationTransaction(_ transactionID: String) async throws -> Bool
}

public actor InMemoryQuicklinkStore: QuicklinkBatchStoring {
    private var definitions: [String: QuicklinkDefinition]
    private var committedConfigurationTransactions = Set<String>()

    public init(definitions: [QuicklinkDefinition] = []) {
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }

    public func allQuicklinks() -> [QuicklinkDefinition] {
        definitions.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func quicklink(id: String) -> QuicklinkDefinition? {
        definitions[id]
    }

    public func saveQuicklink(_ definition: QuicklinkDefinition) {
        definitions[definition.id] = definition
    }

    public func deleteQuicklink(id: String) {
        definitions[id] = nil
    }

    public func deleteQuicklink(ifUnchanged definition: QuicklinkDefinition) -> Bool {
        guard definitions[definition.id] == definition else { return false }
        definitions[definition.id] = nil
        return true
    }

    public func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) {
        var merged = self.definitions
        for definition in definitions { merged[definition.id] = definition }
        self.definitions = merged
    }

    public func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition], transactionID: String) {
        mergeQuicklinksAtomically(definitions)
        committedConfigurationTransactions.insert(transactionID)
    }

    public func hasCommittedConfigurationTransaction(_ transactionID: String) -> Bool {
        committedConfigurationTransactions.contains(transactionID)
    }
}

extension LauncherDatabase: QuicklinkStoring {
    public func allQuicklinks() throws -> [QuicklinkDefinition] {
        let database = try databaseHandle()
        let decoder = JSONDecoder()
        return try withStatement(
            database: database,
            sql:
                "SELECT id,title,url_template,arguments_json,keywords_json,icon_name,browser_bundle_id,created_at,updated_at FROM quicklinks ORDER BY title COLLATE NOCASE,id;"
        ) { statement in
            var links: [QuicklinkDefinition] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                    let id = string(at: 0, in: statement),
                    let title = string(at: 1, in: statement),
                    let template = string(at: 2, in: statement),
                    let argumentsData = data(at: 3, in: statement),
                    let keywordsData = data(at: 4, in: statement),
                    let iconName = string(at: 5, in: statement)
                else { throw DatabaseError.corruptData(table: "quicklinks") }
                let arguments = try decoder.decode([ArgumentDefinition].self, from: argumentsData)
                let keywords = try decoder.decode([String].self, from: keywordsData)
                links.append(
                    try QuicklinkDefinition(
                        id: id,
                        title: title,
                        urlTemplate: template,
                        arguments: arguments,
                        keywords: keywords,
                        iconName: iconName,
                        browserBundleIdentifier: string(at: 6, in: statement),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
                    )
                )
            }
            return links
        }
    }

    public func quicklink(id: String) throws -> QuicklinkDefinition? {
        try allQuicklinks().first(where: { $0.id == id })
    }

    public func saveQuicklink(_ definition: QuicklinkDefinition) throws {
        let database = try databaseHandle()
        let encoder = JSONEncoder()
        let arguments = try encoder.encode(definition.arguments)
        let keywords = try encoder.encode(definition.keywords)
        try withStatement(
            database: database,
            sql: """
                INSERT INTO quicklinks(id,title,url_template,arguments_json,keywords_json,icon_name,browser_bundle_id,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title,
                  url_template=excluded.url_template,
                  arguments_json=excluded.arguments_json,
                  keywords_json=excluded.keywords_json,
                  icon_name=excluded.icon_name,
                  browser_bundle_id=excluded.browser_bundle_id,
                  updated_at=excluded.updated_at;
                """
        ) { statement in
            try bind(definition.id, to: 1, in: statement)
            try bind(definition.title, to: 2, in: statement)
            try bind(definition.urlTemplate, to: 3, in: statement)
            try bind(arguments, to: 4, in: statement)
            try bind(keywords, to: 5, in: statement)
            try bind(definition.iconName, to: 6, in: statement)
            if let browserBundleIdentifier = definition.browserBundleIdentifier {
                try bind(browserBundleIdentifier, to: 7, in: statement)
            } else {
                try bindNull(to: 7, in: statement)
            }
            try bind(definition.createdAt.timeIntervalSince1970, to: 8, in: statement)
            try bind(definition.updatedAt.timeIntervalSince1970, to: 9, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteQuicklink(id: String) throws {
        let database = try databaseHandle()
        try withStatement(database: database, sql: "DELETE FROM quicklinks WHERE id=?;") { statement in
            try bind(id, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteQuicklink(ifUnchanged definition: QuicklinkDefinition) throws -> Bool {
        guard try quicklink(id: definition.id) == definition else { return false }
        try deleteQuicklink(id: definition.id)
        return true
    }
}

extension LauncherDatabase: QuicklinkBatchStoring {
    public func mergeQuicklinksAtomically(_ definitions: [QuicklinkDefinition]) throws {
        try performQuicklinkMerge(definitions, transactionID: nil)
    }

    public func mergeQuicklinksAtomically(
        _ definitions: [QuicklinkDefinition],
        transactionID: String
    ) throws {
        guard UUID(uuidString: transactionID) != nil else {
            throw DatabaseError.corruptData(table: "configuration_transactions")
        }
        try performQuicklinkMerge(definitions, transactionID: transactionID)
    }

    public func hasCommittedConfigurationTransaction(_ transactionID: String) throws -> Bool {
        guard UUID(uuidString: transactionID) != nil else { return false }
        let database = try databaseHandle()
        return try withStatement(
            database: database,
            sql: "SELECT 1 FROM configuration_transactions WHERE id=? LIMIT 1;"
        ) { statement in
            try bind(transactionID.lowercased(), to: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func performQuicklinkMerge(
        _ definitions: [QuicklinkDefinition],
        transactionID: String?
    ) throws {
        let database = try databaseHandle()
        let encoder = JSONEncoder()
        do {
            try execute(database: database, sql: "BEGIN IMMEDIATE;")
            for definition in definitions {
                try withStatement(
                    database: database,
                    sql: """
                        INSERT INTO quicklinks(id,title,url_template,arguments_json,keywords_json,icon_name,browser_bundle_id,created_at,updated_at)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                          title=excluded.title,url_template=excluded.url_template,
                          arguments_json=excluded.arguments_json,keywords_json=excluded.keywords_json,
                          icon_name=excluded.icon_name,
                          browser_bundle_id=excluded.browser_bundle_id,
                          updated_at=excluded.updated_at;
                        """
                ) { statement in
                    try bind(definition.id, to: 1, in: statement)
                    try bind(definition.title, to: 2, in: statement)
                    try bind(definition.urlTemplate, to: 3, in: statement)
                    try bind(try encoder.encode(definition.arguments), to: 4, in: statement)
                    try bind(try encoder.encode(definition.keywords), to: 5, in: statement)
                    try bind(definition.iconName, to: 6, in: statement)
                    if let browserBundleIdentifier = definition.browserBundleIdentifier {
                        try bind(browserBundleIdentifier, to: 7, in: statement)
                    } else {
                        try bindNull(to: 7, in: statement)
                    }
                    try bind(definition.createdAt.timeIntervalSince1970, to: 8, in: statement)
                    try bind(definition.updatedAt.timeIntervalSince1970, to: 9, in: statement)
                    try requireDone(statement)
                }
            }
            if let transactionID {
                try withStatement(
                    database: database,
                    sql: "INSERT OR IGNORE INTO configuration_transactions(id,committed_at) VALUES(?,?);"
                ) { statement in
                    try bind(transactionID.lowercased(), to: 1, in: statement)
                    try bind(Date().timeIntervalSince1970, to: 2, in: statement)
                    try requireDone(statement)
                }
                try execute(
                    database: database,
                    sql: """
                        DELETE FROM configuration_transactions
                        WHERE id NOT IN (
                          SELECT id FROM configuration_transactions ORDER BY committed_at DESC,id DESC LIMIT 100
                        );
                        """
                )
            }
            try execute(database: database, sql: "COMMIT;")
        } catch {
            try? execute(database: database, sql: "ROLLBACK;")
            throw error
        }
    }
}

public protocol URLOpening: Sendable {
    @MainActor
    func open(_ url: URL, browserBundleIdentifier: String?) async -> Bool
}

public struct MacURLOpener: URLOpening, Sendable {
    public init() {}

    @MainActor
    public func open(_ url: URL, browserBundleIdentifier: String?) async -> Bool {
        guard let browserBundleIdentifier else { return NSWorkspace.shared.open(url) }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

public protocol URLSchemeAuthorizing: Sendable {
    func isApproved(_ scheme: String) async -> Bool
    func approve(_ scheme: String) async
}

public actor InMemoryURLSchemeAuthorization: URLSchemeAuthorizing {
    private var approvedSchemes: Set<String>

    public init(approvedSchemes: Set<String> = []) {
        self.approvedSchemes = Set(approvedSchemes.map { $0.lowercased() })
    }

    public func isApproved(_ scheme: String) -> Bool {
        Self.isImplicitlyApproved(scheme) || approvedSchemes.contains(scheme.lowercased())
    }

    public func approve(_ scheme: String) {
        approvedSchemes.insert(scheme.lowercased())
    }

    fileprivate static func isImplicitlyApproved(_ scheme: String) -> Bool {
        ["http", "https"].contains(scheme.lowercased())
    }
}

/// Persists only a normalized URL scheme after the user confirms and the host
/// successfully opens it. URLs and quick-link arguments are never stored here.
public actor UserDefaultsURLSchemeAuthorization: URLSchemeAuthorizing {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "quicklinks.approvedSchemes") {
        self.defaults = defaults
        self.key = key
    }

    public func isApproved(_ scheme: String) -> Bool {
        InMemoryURLSchemeAuthorization.isImplicitlyApproved(scheme)
            || Set(defaults.stringArray(forKey: key) ?? []).contains(scheme.lowercased())
    }

    public func approve(_ scheme: String) {
        guard !InMemoryURLSchemeAuthorization.isImplicitlyApproved(scheme) else { return }
        var approved = Set(defaults.stringArray(forKey: key) ?? [])
        approved.insert(scheme.lowercased())
        defaults.set(approved.sorted(), forKey: key)
    }
}

public struct QuicklinkProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "quicklinks",
        displayName: "Quick Links",
        supportedModes: [.all, .commands],
        supportsEmptyQuery: true
    )
    private let store: any QuicklinkStoring
    private let urlOpener: any URLOpening
    private let schemeAuthorization: any URLSchemeAuthorizing

    public init(
        store: any QuicklinkStoring,
        urlOpener: any URLOpening = MacURLOpener(),
        schemeAuthorization: any URLSchemeAuthorizing = InMemoryURLSchemeAuthorization()
    ) {
        self.store = store
        self.urlOpener = urlOpener
        self.schemeAuthorization = schemeAuthorization
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task {
            do {
                let links = try await store.allQuicklinks()
                try Task.checkCancellation()
                var items: [LauncherItem] = []
                for definition in links {
                    let match = FuzzyMatcher.evaluate(
                        query: request.normalizedText,
                        title: definition.title,
                        subtitle: definition.urlTemplate,
                        keywords: definition.keywords
                    )
                    guard match.tier != .none else { continue }
                    let itemID = ItemID(providerID: descriptor.id, providerStableID: definition.id)
                    let scheme = Self.scheme(for: definition.urlTemplate)
                    let approved =
                        if let scheme {
                            await schemeAuthorization.isApproved(scheme)
                        } else {
                            false
                        }
                    let action = ActionDescriptor(
                        id: "open",
                        title: "Open Link",
                        icon: .systemSymbol("safari"),
                        behavior: .closeLauncher,
                        risk: approved ? .safe : .externalSideEffect,
                        confirmationTarget: scheme.map { _ in definition.urlTemplate },
                        arguments: definition.arguments
                    )
                    items.append(
                        LauncherItem(
                            id: itemID,
                            providerID: descriptor.id,
                            title: definition.title,
                            subtitle: definition.urlTemplate,
                            icon: .systemSymbol(definition.iconName),
                            canonicalResource: .command("quicklink:\(definition.id)"),
                            keywords: definition.keywords,
                            actions: [action],
                            defaultActionID: action.id,
                            scoreFeatures: ScoreFeatures(providerPrior: 0.55)
                        )
                    )
                }
                continuation.yield(.items(items, isFinal: true))
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
                return
            } catch {
                continuation.yield(
                    .status(
                        .failed(
                            ErrorDescriptor(code: "quicklinks.loadFailed", message: "Quick links could not be loaded.")
                        )
                    )
                )
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id, request.actionID == "open" else {
            return .failure(ErrorDescriptor(code: "quicklinks.invalidAction", message: "The quick link action is invalid."))
        }
        do {
            guard let definition = try await store.quicklink(id: request.itemID.providerStableID) else {
                return .failure(ErrorDescriptor(code: "quicklinks.notFound", message: "The quick link was removed."))
            }
            let url = try Self.render(definition: definition, values: request.arguments)
            guard let scheme = url.scheme?.lowercased() else {
                return .failure(ErrorDescriptor(code: "quicklinks.invalidURL", message: "The rendered URL is invalid."))
            }
            guard await urlOpener.open(url, browserBundleIdentifier: definition.browserBundleIdentifier) else {
                return .failure(
                    ErrorDescriptor(
                        code: "quicklinks.openFailed",
                        message: definition.browserBundleIdentifier == nil
                            ? "The URL could not be opened." : "The selected browser is unavailable."
                    )
                )
            }
            await schemeAuthorization.approve(scheme)
            return .success()
        } catch let error as ErrorDescriptor {
            return .failure(error)
        } catch {
            return .failure(ErrorDescriptor(code: "quicklinks.executionFailed", message: "The quick link could not be opened."))
        }
    }

    public static func render(
        definition: QuicklinkDefinition,
        values: [String: ArgumentValue]
    ) throws -> URL {
        var rendered = definition.urlTemplate
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for argument in definition.arguments {
            guard let value = values[argument.id] else {
                if argument.required {
                    throw ErrorDescriptor(
                        code: "quicklinks.missingArgument",
                        message: "A required link argument is missing."
                    )
                }
                continue
            }
            let rawValue: String
            switch value {
            case let .text(text): rawValue = text
            case let .file(url): rawValue = url.path
            }
            guard !rawValue.contains("\u{0}"), rawValue.utf8.count <= 8_192 else {
                throw ErrorDescriptor(code: "quicklinks.invalidArgument", message: "A link argument is invalid or too long.")
            }
            guard let encoded = rawValue.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ErrorDescriptor(code: "quicklinks.encodingFailed", message: "A link argument could not be encoded.")
            }
            rendered = rendered.replacingOccurrences(of: "{\(argument.id)}", with: encoded)
        }
        guard rendered.utf8.count <= 32_768,
            !rendered.contains("{"), !rendered.contains("}"),
            let url = URL(string: rendered),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            throw ErrorDescriptor(code: "quicklinks.invalidURL", message: "The rendered URL is invalid.")
        }
        return url
    }

    private static func scheme(for template: String) -> String? {
        URL(string: template)?.scheme?.lowercased()
    }
}
