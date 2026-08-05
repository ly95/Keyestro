import CryptoKit
import Foundation
import KeyestroDomain
import SQLite3

public struct ScriptDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let executablePath: String
    public let arguments: [ArgumentDefinition]
    public let environment: [String: String]
    public let timeoutSeconds: Int
    public let contentHash: String
    /// Non-nil only for advanced linked-original registrations.
    public let linkedFileIdentity: String?
    public let enabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        executablePath: String,
        arguments: [ArgumentDefinition] = [],
        environment: [String: String] = [:],
        timeoutSeconds: Int = 30,
        contentHash: String,
        linkedFileIdentity: String? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
            id.unicodeScalars.allSatisfy({
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".")
            }),
            !title.isEmpty,
            !title.contains("\u{0}"),
            title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
            URL(fileURLWithPath: executablePath).isFileURL,
            executablePath.hasPrefix("/"),
            !executablePath.contains("\u{0}"),
            executablePath.utf8.count <= 4_096,
            arguments.count <= 50,
            Set(arguments.map(\.id)).count == arguments.count,
            arguments.allSatisfy(Self.validArgument),
            environment.isEmpty,
            (1...300).contains(timeoutSeconds),
            contentHash.count == 64,
            contentHash.unicodeScalars.allSatisfy({
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }),
            linkedFileIdentity.map(Self.validFileIdentity) ?? true
        else {
            throw ErrorDescriptor(code: "scripts.invalidDefinition", message: "The script definition is invalid.")
        }
        self.id = id
        self.title = title
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.contentHash = contentHash
        self.linkedFileIdentity = linkedFileIdentity
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isLinkedOriginal: Bool { linkedFileIdentity != nil }

    private static func validFileIdentity(_ identity: String) -> Bool {
        !identity.isEmpty && identity.utf8.count <= 256 && !identity.contains("\u{0}")
    }

    private static func validArgument(_ argument: ArgumentDefinition) -> Bool {
        guard !argument.id.isEmpty,
            argument.id.utf8.count <= 128,
            argument.id.unicodeScalars.allSatisfy({
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }),
            !argument.title.isEmpty,
            !argument.title.contains("\u{0}"),
            argument.title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
            (argument.placeholder?.unicodeScalars.count ?? 0) <= 512,
            argument.placeholder.map({ !$0.contains("\u{0}") }) ?? true
        else { return false }
        if case let .choice(options) = argument.kind {
            return !options.isEmpty && options.count <= 50 && Set(options).count == options.count
                && options.allSatisfy {
                    !$0.isEmpty && !$0.contains("\u{0}") && $0.unicodeScalars.count <= 256
                }
        }
        return true
    }
}

public protocol ScriptStoring: Sendable {
    func allScripts() async throws -> [ScriptDefinition]
    func script(id: String) async throws -> ScriptDefinition?
    func saveScript(_ definition: ScriptDefinition) async throws
    func deleteScript(id: String) async throws
    /// Atomically rejects a stale settings snapshot instead of deleting a
    /// newer registration that reuses the same stable identifier.
    func deleteScript(ifUnchanged definition: ScriptDefinition) async throws -> Bool
}

public actor InMemoryScriptStore: ScriptStoring {
    private var scripts: [String: ScriptDefinition] = [:]

    public init(scripts: [ScriptDefinition] = []) {
        self.scripts = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
    }

    public func allScripts() -> [ScriptDefinition] {
        scripts.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func script(id: String) -> ScriptDefinition? { scripts[id] }
    public func saveScript(_ definition: ScriptDefinition) { scripts[definition.id] = definition }
    public func deleteScript(id: String) { scripts[id] = nil }
    public func deleteScript(ifUnchanged definition: ScriptDefinition) -> Bool {
        guard scripts[definition.id] == definition else { return false }
        scripts[definition.id] = nil
        return true
    }
}

extension LauncherDatabase: ScriptStoring {
    public func allScripts() throws -> [ScriptDefinition] {
        let database = try databaseHandle()
        let decoder = JSONDecoder()
        return try withStatement(
            database: database,
            sql: """
                SELECT id,title,executable_path,arguments_json,environment_json,timeout_seconds,
                       executable_bookmark,content_hash,enabled,created_at,updated_at
                FROM scripts ORDER BY title COLLATE NOCASE,id;
                """
        ) { statement in
            var output: [ScriptDefinition] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW,
                    let id = string(at: 0, in: statement),
                    let title = string(at: 1, in: statement),
                    let path = string(at: 2, in: statement),
                    let argumentsData = data(at: 3, in: statement),
                    let environmentData = data(at: 4, in: statement),
                    let contentHash = string(at: 7, in: statement)
                else { throw DatabaseError.corruptData(table: "scripts") }
                let linkedIdentity: String?
                if let identityData = data(at: 6, in: statement) {
                    guard let decoded = String(data: identityData, encoding: .utf8) else {
                        throw DatabaseError.corruptData(table: "scripts")
                    }
                    linkedIdentity = decoded
                } else {
                    linkedIdentity = nil
                }
                output.append(
                    try ScriptDefinition(
                        id: id,
                        title: title,
                        executablePath: path,
                        arguments: try decoder.decode([ArgumentDefinition].self, from: argumentsData),
                        environment: try decoder.decode([String: String].self, from: environmentData),
                        timeoutSeconds: Int(sqlite3_column_int64(statement, 5)),
                        contentHash: contentHash,
                        linkedFileIdentity: linkedIdentity,
                        enabled: sqlite3_column_int64(statement, 8) != 0,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
                    )
                )
            }
            return output
        }
    }

    public func script(id: String) throws -> ScriptDefinition? {
        try allScripts().first(where: { $0.id == id })
    }

    public func saveScript(_ definition: ScriptDefinition) throws {
        let database = try databaseHandle()
        let encoder = JSONEncoder()
        try withStatement(
            database: database,
            sql: """
                INSERT INTO scripts(
                  id,title,executable_bookmark,executable_path,arguments_json,environment_json,
                  timeout_seconds,content_hash,enabled,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title,executable_bookmark=excluded.executable_bookmark,
                  executable_path=excluded.executable_path,
                  arguments_json=excluded.arguments_json,environment_json=excluded.environment_json,
                  timeout_seconds=excluded.timeout_seconds,content_hash=excluded.content_hash,
                  enabled=excluded.enabled,updated_at=excluded.updated_at;
                """
        ) { statement in
            try bind(definition.id, to: 1, in: statement)
            try bind(definition.title, to: 2, in: statement)
            if let identity = definition.linkedFileIdentity {
                try bind(Data(identity.utf8), to: 3, in: statement)
            } else {
                try bindNull(to: 3, in: statement)
            }
            try bind(definition.executablePath, to: 4, in: statement)
            try bind(try encoder.encode(definition.arguments), to: 5, in: statement)
            try bind(try encoder.encode(definition.environment), to: 6, in: statement)
            try bind(Int64(definition.timeoutSeconds), to: 7, in: statement)
            try bind(definition.contentHash, to: 8, in: statement)
            try bind(Int64(definition.enabled ? 1 : 0), to: 9, in: statement)
            try bind(definition.createdAt.timeIntervalSince1970, to: 10, in: statement)
            try bind(definition.updatedAt.timeIntervalSince1970, to: 11, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteScript(id: String) throws {
        let database = try databaseHandle()
        try withStatement(database: database, sql: "DELETE FROM scripts WHERE id=?;") { statement in
            try bind(id, to: 1, in: statement)
            try requireDone(statement)
        }
    }

    public func deleteScript(ifUnchanged definition: ScriptDefinition) throws -> Bool {
        guard try script(id: definition.id) == definition else { return false }
        try deleteScript(id: definition.id)
        return true
    }
}

public actor ManagedScriptInstaller {
    public static let maximumScriptBytes = 100 * 1_024 * 1_024

    private let paths: AppPaths
    private let store: any ScriptStoring
    private let fileSystem: any FileSystemServicing
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        paths: AppPaths,
        store: any ScriptStoring,
        fileSystem: any FileSystemServicing = LocalFileSystemService()
    ) {
        self.paths = paths
        self.store = store
        self.fileSystem = fileSystem
    }

    public func install(from source: URL, title: String? = nil) async throws -> ScriptDefinition {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let (canonicalSource, _) = try await validatedSource(source)
        return try await installManagedCopy(
            from: canonicalSource,
            sourceName: source.lastPathComponent,
            id: UUID().uuidString.lowercased(),
            title: title ?? source.deletingPathExtension().lastPathComponent,
            arguments: [],
            timeoutSeconds: 30,
            expectedHash: nil
        )
    }

    /// Restores exported registration metadata only after the user reconnects the exact script bytes.
    public func reconnect(
        _ registration: ExportedScriptRegistration,
        from source: URL
    ) async throws -> ScriptDefinition {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        try registration.validate()
        let (canonicalSource, _) = try await validatedSource(source)
        let id =
            try await store.script(id: registration.id) == nil
            ? registration.id
            : UUID().uuidString.lowercased()
        return try await installManagedCopy(
            from: canonicalSource,
            sourceName: source.lastPathComponent,
            id: id,
            title: registration.title,
            arguments: registration.arguments,
            timeoutSeconds: registration.timeoutSeconds,
            expectedHash: registration.contentHash
        )
    }

    private func installManagedCopy(
        from canonicalSource: URL,
        sourceName: String,
        id: String,
        title: String,
        arguments: [ArgumentDefinition],
        timeoutSeconds: Int,
        expectedHash: String?
    ) async throws -> ScriptDefinition {
        try paths.prepare()
        let scriptDirectory = paths.managedScripts.appendingPathComponent(id, isDirectory: true)
        try await fileSystem.createDirectory(at: scriptDirectory, permissions: 0o700)
        let safeName = sourceName.replacingOccurrences(of: "/", with: "-")
        let destination = scriptDirectory.appendingPathComponent(safeName, isDirectory: false)
        do {
            try await fileSystem.copyItem(at: canonicalSource, to: destination)
            try await fileSystem.setPermissions(0o700, at: destination)
            let hash = try await fileSystem.sha256Digest(at: destination, maximumBytes: Self.maximumScriptBytes)
            guard expectedHash.map({ $0 == hash }) ?? true else {
                throw ErrorDescriptor(
                    code: "scripts.reconnectionHashMismatch",
                    message: "The selected script does not match the exported registration.",
                    recoverySuggestion: "Choose the original script, or install this file as a new script."
                )
            }
            let definition = try ScriptDefinition(
                id: id,
                title: title,
                executablePath: destination.path,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                contentHash: hash
            )
            try await store.saveScript(definition)
            return definition
        } catch {
            try? await fileSystem.removeItem(at: scriptDirectory)
            throw error
        }
    }

    /// Registers a script in place. The caller must obtain explicit user confirmation first.
    public func linkOriginal(from source: URL, title: String? = nil) async throws -> ScriptDefinition {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        let (canonicalSource, metadata) = try await validatedSource(source)
        guard let identity = metadata.fileIdentity else { throw ProcessServiceError.invalidExecutable }
        let definition = try ScriptDefinition(
            id: UUID().uuidString.lowercased(),
            title: title ?? source.deletingPathExtension().lastPathComponent,
            executablePath: canonicalSource.path,
            contentHash: try await fileSystem.sha256Digest(
                at: canonicalSource,
                maximumBytes: Self.maximumScriptBytes
            ),
            linkedFileIdentity: identity
        )
        try await store.saveScript(definition)
        return definition
    }

    /// Explicitly trusts the current identity and contents of an already-linked script.
    public func reconfirmLinkedOriginal(_ definition: ScriptDefinition) async throws -> ScriptDefinition {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        guard definition.isLinkedOriginal else { throw ProcessServiceError.invalidExecutable }
        let source = URL(fileURLWithPath: definition.executablePath)
        let (canonicalSource, metadata) = try await validatedSource(source)
        guard let identity = metadata.fileIdentity else { throw ProcessServiceError.invalidExecutable }
        let updated = try ScriptDefinition(
            id: definition.id,
            title: definition.title,
            executablePath: canonicalSource.path,
            arguments: definition.arguments,
            environment: definition.environment,
            timeoutSeconds: definition.timeoutSeconds,
            contentHash: try await fileSystem.sha256Digest(
                at: canonicalSource,
                maximumBytes: Self.maximumScriptBytes
            ),
            linkedFileIdentity: identity,
            enabled: definition.enabled,
            createdAt: definition.createdAt,
            updatedAt: Date()
        )
        try await store.saveScript(updated)
        return updated
    }

    private func validatedSource(_ source: URL) async throws -> (URL, FileSystemItemMetadata) {
        let canonicalSource = try await fileSystem.canonicalURL(for: source)
        let metadata = try await fileSystem.metadata(at: canonicalSource)
        guard source.isFileURL,
            canonicalSource.isFileURL,
            let metadata,
            metadata.isRegularFile,
            !metadata.isSymbolicLink,
            metadata.isExecutable,
            metadata.byteCount <= Self.maximumScriptBytes
        else { throw ProcessServiceError.invalidExecutable }
        return (canonicalSource, metadata)
    }

    public func remove(_ definition: ScriptDefinition) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()

        var managedDirectory: URL?
        if !definition.isLinkedOriginal {
            let executable = URL(fileURLWithPath: definition.executablePath).standardizedFileURL
            let managedRoot = paths.managedScripts.standardizedFileURL
            let expectedDirectory = managedRoot.appendingPathComponent(definition.id, isDirectory: true).standardizedFileURL
            guard expectedDirectory.deletingLastPathComponent() == managedRoot,
                executable.deletingLastPathComponent() == expectedDirectory
            else { throw ProcessServiceError.invalidExecutable }
            if try await fileSystem.metadata(at: expectedDirectory) != nil {
                managedDirectory = expectedDirectory
            }
        }
        guard try await store.deleteScript(ifUnchanged: definition) else {
            throw ErrorDescriptor(
                code: "scripts.staleRegistration",
                message: "The script changed after the removal confirmation.",
                recoverySuggestion: "Review the current script and confirm removal again."
            )
        }
        if let managedDirectory {
            do {
                try await fileSystem.removeItem(at: managedDirectory)
            } catch {
                throw ErrorDescriptor(
                    code: "scripts.removalCleanupFailed",
                    message: "The script was unregistered, but its managed files could not be deleted.",
                    recoverySuggestion: "Use Delete All Local Data to remove remaining managed files."
                )
            }
        }
    }

    private func acquireOperation() async {
        guard operationInProgress else {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ScriptProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "scripts",
        displayName: "Scripts",
        supportedModes: [.all, .commands],
        supportsEmptyQuery: true
    )
    private let store: any ScriptStoring
    private let processService: any ProcessServicing
    private let fileSystem: any FileSystemServicing

    public init(
        store: any ScriptStoring,
        processService: any ProcessServicing,
        fileSystem: any FileSystemServicing = LocalFileSystemService()
    ) {
        self.store = store
        self.processService = processService
        self.fileSystem = fileSystem
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let task = Task {
            do {
                let scripts = try await store.allScripts().filter(\.enabled)
                let items = scripts.compactMap { script -> LauncherItem? in
                    let match = FuzzyMatcher.evaluate(
                        query: request.normalizedText,
                        title: script.title,
                        subtitle: "Script command",
                        keywords: ["script", "command"]
                    )
                    guard match.tier != .none else { return nil }
                    let itemID = ItemID(providerID: descriptor.id, providerStableID: script.id)
                    let run = ActionDescriptor(
                        id: "run",
                        title: "Run Script",
                        icon: .systemSymbol("terminal"),
                        behavior: .keepLauncherOpen,
                        risk: .externalSideEffect,
                        confirmationTarget: "\(script.title) — \(script.executablePath) — SHA-256 \(script.contentHash.prefix(12))",
                        arguments: script.arguments
                    )
                    return LauncherItem(
                        id: itemID,
                        providerID: descriptor.id,
                        title: script.title,
                        subtitle: "Trusted local script",
                        icon: .systemSymbol("terminal"),
                        canonicalResource: .command("script:\(script.id)"),
                        keywords: ["script", "command"],
                        actions: [run],
                        defaultActionID: run.id,
                        scoreFeatures: ScoreFeatures(providerPrior: 0.5)
                    )
                }
                continuation.yield(.items(items, isFinal: true))
            } catch {
                continuation.yield(.status(.failed(ErrorDescriptor(code: "scripts.loadFailed", message: "Scripts could not be loaded."))))
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id, request.actionID == "run" else {
            return .failure(ErrorDescriptor(code: "scripts.invalidAction", message: "The script action is invalid."))
        }
        do {
            guard let script = try await store.script(id: request.itemID.providerStableID), script.enabled else {
                return .failure(ErrorDescriptor(code: "scripts.notFound", message: "The script is unavailable."))
            }
            let registeredExecutable = URL(fileURLWithPath: script.executablePath).standardizedFileURL
            let executable = try await fileSystem.canonicalURL(for: registeredExecutable)
            let executableValues = try await fileSystem.metadata(at: executable)
            guard executableValues?.isRegularFile == true,
                executableValues?.isSymbolicLink != true,
                executableValues?.isExecutable == true,
                script.linkedFileIdentity.map({ $0 == executableValues?.fileIdentity }) ?? true,
                try await fileSystem.sha256Digest(
                    at: executable,
                    maximumBytes: ManagedScriptInstaller.maximumScriptBytes
                ) == script.contentHash
            else {
                return .failure(
                    ErrorDescriptor(
                        code: "scripts.contentChanged",
                        message: "The script changed after installation.",
                        recoverySuggestion: "Review and reinstall the script before running it."
                    )
                )
            }
            let argv = try script.arguments.map { definition -> String in
                guard let value = request.arguments[definition.id] else {
                    if definition.required {
                        throw ErrorDescriptor(code: "scripts.missingArgument", message: "A required script argument is missing.")
                    }
                    return ""
                }
                switch (definition.kind, value) {
                case let (.text, .text(text)), let (.password, .text(text)):
                    guard !text.contains("\u{0}"), text.unicodeScalars.count <= 8_192 else {
                        throw ErrorDescriptor(code: "scripts.invalidArgument", message: "A script argument is too long.")
                    }
                    return text
                case let (.choice(options), .text(choice)):
                    guard options.contains(choice) else {
                        throw ErrorDescriptor(code: "scripts.invalidArgument", message: "A script choice is invalid.")
                    }
                    return choice
                case let (.file, .file(url)), let (.directory, .file(url)):
                    let standardized = url.standardizedFileURL
                    guard standardized.isFileURL,
                        standardized.path.hasPrefix("/"),
                        !standardized.path.contains("\u{0}"),
                        standardized.path.utf8.count <= 4_096
                    else {
                        throw ErrorDescriptor(code: "scripts.invalidArgument", message: "A script path is invalid.")
                    }
                    return standardized.path
                default:
                    throw ErrorDescriptor(code: "scripts.invalidArgument", message: "A script argument has the wrong type.")
                }
            }
            let result = try await processService.run(
                ProcessExecutionRequest(
                    executableURL: executable,
                    arguments: argv,
                    environment: script.environment,
                    workingDirectoryURL: executable.deletingLastPathComponent(),
                    timeout: .seconds(script.timeoutSeconds)
                )
            )
            return Self.actionResult(result)
        } catch let descriptor as ErrorDescriptor {
            return .failure(descriptor)
        } catch let error as ProcessServiceError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "scripts.executionFailed", message: "The script could not be executed."))
        }
    }

    private static func actionResult(_ result: ProcessExecutionResult) -> ActionResult {
        let output = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .limitedToUnicodeScalars(240)
        let metadata = executionMetadata(result)
        switch result.termination {
        case .exited(0):
            return .success(message: output.isEmpty ? metadata : "\(output) · \(metadata)")
        case let .exited(code):
            return .failure(
                ErrorDescriptor(
                    code: "scripts.exit.\(code)",
                    message: "The script exited with code \(code).",
                    recoverySuggestion: metadata
                )
            )
        case let .signalled(signal):
            return .failure(
                ErrorDescriptor(
                    code: "scripts.signal.\(signal)",
                    message: "The script was terminated by signal \(signal).",
                    recoverySuggestion: metadata
                )
            )
        case .timedOut:
            return .failure(
                ErrorDescriptor(
                    code: "scripts.timeout",
                    message: "The script exceeded its timeout.",
                    recoverySuggestion: metadata
                )
            )
        }
    }

    private static func executionMetadata(_ result: ProcessExecutionResult) -> String {
        let components = result.duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        let measurement: Measurement<UnitDuration> =
            milliseconds < 1_000
            ? Measurement(value: milliseconds.rounded(), unit: .milliseconds)
            : Measurement(value: milliseconds / 1_000, unit: .seconds)
        let duration = formatter.string(from: measurement)
        var fields = [duration]
        if result.standardOutputTruncated { fields.append("stdout ≥ 1 MiB") }
        if result.standardErrorTruncated { fields.append("stderr ≥ 1 MiB") }
        return fields.joined(separator: " · ")
    }
}
