import Foundation
import KeyestroDomain
import SQLite3

/// SQLite's opaque C handle is exclusively owned by `LauncherDatabase` and closes on wrapper deinit.
/// The wrapper never escapes that actor; unchecked sendability only bridges the imported C pointer type.
private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

public enum DatabaseError: Error, Equatable, Sendable {
    case openFailed(code: Int32)
    case statementFailed(code: Int32)
    case migrationFailed(code: Int32)
    case corruptData(table: String)
    case integrityCheckFailed
    case newerSchema(found: Int, supported: Int)
    case backupFailed(code: Int32)

    public var descriptor: ErrorDescriptor {
        switch self {
        case let .openFailed(code):
            ErrorDescriptor(code: "database.openFailed.\(code)", message: "The local database could not be opened.")
        case let .statementFailed(code):
            ErrorDescriptor(code: "database.statementFailed.\(code)", message: "The local database operation failed.")
        case let .migrationFailed(code):
            ErrorDescriptor(code: "database.migrationFailed.\(code)", message: "The local database could not be upgraded.")
        case .corruptData:
            ErrorDescriptor(code: "database.corruptData", message: "Stored local data is invalid.")
        case .integrityCheckFailed:
            ErrorDescriptor(
                code: "database.integrityCheckFailed",
                message: "The damaged local database could not be safely isolated.",
                recoverySuggestion: "Do not delete the database. Export diagnostics and restore a verified backup."
            )
        case let .newerSchema(found, supported):
            ErrorDescriptor(
                code: "database.newerSchema.\(found)",
                message: "This database was created by a newer Keyestro version.",
                recoverySuggestion: "Use a version that supports database schema \(found); this build supports \(supported)."
            )
        case let .backupFailed(code):
            ErrorDescriptor(code: "database.backupFailed.\(code)", message: "A migration backup could not be created.")
        }
    }
}

public struct DatabaseRecoveryReport: Codable, Equatable, Sendable {
    public let detectedAt: Date
    public let quarantineDirectory: URL
    public let recoveredRowCount: Int
    public let skippedRowCount: Int
    public let failedTables: [String]

    public init(
        detectedAt: Date,
        quarantineDirectory: URL,
        recoveredRowCount: Int,
        skippedRowCount: Int,
        failedTables: [String]
    ) {
        self.detectedAt = detectedAt
        self.quarantineDirectory = quarantineDirectory
        self.recoveredRowCount = recoveredRowCount
        self.skippedRowCount = skippedRowCount
        self.failedTables = failedTables
    }
}

/// Actor-owned SQLite connection configured with WAL, foreign keys, bounded waits, and transactional migrations.
public actor LauncherDatabase {
    public static let currentSchemaVersion = 5
    private static let pendingRecoveryFilename = "pending-database-recovery.json"
    private let paths: AppPaths
    private var connection: SQLiteConnection?
    private var recoveryReport: DatabaseRecoveryReport?

    private struct PendingDatabaseRecovery: Codable {
        let schemaVersion: Int
        let detectedAt: Date
        let quarantineDirectoryName: String
    }

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func prepare() throws {
        _ = try openIfNeeded()
    }

    public func integrityCheck() throws -> Bool {
        let database = try openIfNeeded()
        return try withStatement(database: database, sql: "PRAGMA integrity_check;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                let text = sqlite3_column_text(statement, 0)
            else { return false }
            return String(cString: text) == "ok"
        }
    }

    public func close() {
        connection = nil
    }

    public func latestRecoveryReport() -> DatabaseRecoveryReport? {
        recoveryReport
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection.pointer }
        try paths.prepare()
        try resumePendingRecoveryIfNeeded()
        let existingSize =
            (try? FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? NSNumber)?
            .int64Value ?? 0

        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            paths.database.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw DatabaseError.openFailed(code: status)
        }
        var ownedConnection: SQLiteConnection? = SQLiteConnection(pointer: database)

        do {
            if existingSize > 0 {
                let isHealthy = (try? quickCheck(database: database)) == true
                if !isHealthy {
                    ownedConnection = nil
                    try quarantineAndRecoverCorruptDatabase()
                    return try openIfNeeded()
                }
            }
            let schemaVersion = try userVersion(database: database)
            guard schemaVersion <= Self.currentSchemaVersion else {
                throw DatabaseError.newerSchema(found: schemaVersion, supported: Self.currentSchemaVersion)
            }
            if existingSize > 0, schemaVersion < Self.currentSchemaVersion {
                try createMigrationBackup(database: database, fromVersion: schemaVersion)
            }
            try execute(database: database, sql: "PRAGMA journal_mode=WAL;")
            try execute(database: database, sql: "PRAGMA foreign_keys=ON;")
            try execute(database: database, sql: "PRAGMA busy_timeout=5000;")
            try migrate(database: database)
            connection = ownedConnection
            return database
        } catch {
            ownedConnection = nil
            connection = nil
            throw error
        }
    }

    private func quarantineAndRecoverCorruptDatabase() throws {
        let detectedAt = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let pending = PendingDatabaseRecovery(
            schemaVersion: 1,
            detectedAt: detectedAt,
            quarantineDirectoryName: "Corrupt-\(formatter.string(from: detectedAt))-\(UUID().uuidString.lowercased())"
        )
        do {
            try persistPendingRecovery(pending)
            try performPendingRecovery(pending)
        } catch {
            throw DatabaseError.integrityCheckFailed
        }
    }

    private var pendingRecoveryURL: URL {
        paths.backups.appendingPathComponent(Self.pendingRecoveryFilename, isDirectory: false)
    }

    private func persistPendingRecovery(_ pending: PendingDatabaseRecovery) throws {
        let data = try JSONEncoder().encode(pending)
        try data.write(to: pendingRecoveryURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingRecoveryURL.path)
    }

    private func resumePendingRecoveryIfNeeded() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: pendingRecoveryURL.path) else { return }
        do {
            let data = try Data(contentsOf: pendingRecoveryURL, options: [.mappedIfSafe])
            guard data.count <= 64 * 1_024 else { throw DatabaseError.integrityCheckFailed }
            let pending = try JSONDecoder().decode(PendingDatabaseRecovery.self, from: data)
            try performPendingRecovery(pending)
        } catch {
            throw DatabaseError.integrityCheckFailed
        }
    }

    private func performPendingRecovery(_ pending: PendingDatabaseRecovery) throws {
        let manager = FileManager.default
        let quarantine = try validatedQuarantineURL(for: pending)
        try manager.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantine.path)

        let quarantinedDatabase = quarantine.appendingPathComponent(paths.database.lastPathComponent, isDirectory: false)
        if manager.fileExists(atPath: quarantinedDatabase.path) {
            if manager.fileExists(atPath: paths.database.path) {
                try preserveInterruptedDatabaseFamily(in: quarantine)
            } else {
                try finishMovingQuarantinedSidecars(to: quarantine)
            }
        } else if databaseFamilyExists(at: paths.database) {
            try moveDatabaseFamily(from: paths.database, to: quarantine, baseName: paths.database.lastPathComponent)
        }

        var candidateDirectory = quarantine.appendingPathComponent(
            "Recovery-Candidate-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try manager.createDirectory(
            at: candidateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var candidateDatabase = candidateDirectory.appendingPathComponent(paths.database.lastPathComponent, isDirectory: false)

        let outcome: RecoveryOutcome
        if manager.fileExists(atPath: quarantinedDatabase.path) {
            do {
                outcome = try attemptReadOnlyRecovery(from: quarantinedDatabase, to: candidateDatabase)
            } catch {
                let failedDirectory = quarantine.appendingPathComponent(
                    "Failed-Recovery-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try manager.moveItem(at: candidateDirectory, to: failedDirectory)
                candidateDirectory = quarantine.appendingPathComponent(
                    "Recovery-Candidate-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try manager.createDirectory(
                    at: candidateDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                candidateDatabase = candidateDirectory.appendingPathComponent(
                    paths.database.lastPathComponent,
                    isDirectory: false
                )
                try createEmptyRecoveryDatabase(at: candidateDatabase)
                outcome = RecoveryOutcome(recoveredRows: 0, skippedRows: 0, failedTables: ["database"])
            }
        } else {
            try createEmptyRecoveryDatabase(at: candidateDatabase)
            outcome = RecoveryOutcome(recoveredRows: 0, skippedRows: 0, failedTables: ["database"])
        }

        let report = DatabaseRecoveryReport(
            detectedAt: pending.detectedAt,
            quarantineDirectory: quarantine,
            recoveredRowCount: outcome.recoveredRows,
            skippedRowCount: outcome.skippedRows,
            failedTables: outcome.failedTables.sorted()
        )
        let reportData = try JSONEncoder().encode(report)
        let reportURL = quarantine.appendingPathComponent("recovery-report.json", isDirectory: false)
        try reportData.write(to: reportURL, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)

        if databaseFamilyExists(at: paths.database) {
            try preserveInterruptedDatabaseFamily(in: quarantine)
        }
        try moveDatabaseFamily(
            from: candidateDatabase,
            to: paths.database.deletingLastPathComponent(),
            baseName: paths.database.lastPathComponent
        )
        try manager.removeItem(at: pendingRecoveryURL)
        recoveryReport = report
    }

    private func validatedQuarantineURL(for pending: PendingDatabaseRecovery) throws -> URL {
        let name = pending.quarantineDirectoryName
        guard pending.schemaVersion == 1,
            name.hasPrefix("Corrupt-"),
            name.utf8.count <= 160,
            !name.contains("/"),
            !name.contains("\\"),
            !name.contains("\u{0}"),
            name != ".",
            name != ".."
        else { throw DatabaseError.integrityCheckFailed }
        let quarantine = paths.backups.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard quarantine.deletingLastPathComponent().standardizedFileURL == paths.backups.standardizedFileURL else {
            throw DatabaseError.integrityCheckFailed
        }
        let resolvedBackups = paths.backups.resolvingSymlinksInPath().standardizedFileURL
        let resolvedQuarantine = quarantine.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedQuarantine.deletingLastPathComponent() == resolvedBackups else {
            throw DatabaseError.integrityCheckFailed
        }
        return quarantine
    }

    private func databaseFamilyExists(at databaseURL: URL) -> Bool {
        let manager = FileManager.default
        return ["", "-wal", "-shm"].contains { suffix in
            manager.fileExists(atPath: databaseURL.path + suffix)
        }
    }

    private func preserveInterruptedDatabaseFamily(in quarantine: URL) throws {
        let manager = FileManager.default
        let interrupted = quarantine.appendingPathComponent(
            "Interrupted-Recovery-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try manager.createDirectory(
            at: interrupted,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try moveDatabaseFamily(from: paths.database, to: interrupted, baseName: paths.database.lastPathComponent)
    }

    private func finishMovingQuarantinedSidecars(to quarantine: URL) throws {
        let manager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: paths.database.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = quarantine.appendingPathComponent(paths.database.lastPathComponent + suffix, isDirectory: false)
            if manager.fileExists(atPath: destination.path) {
                let interrupted = quarantine.appendingPathComponent(
                    "Interrupted-Sidecar-\(UUID().uuidString.lowercased())\(suffix)",
                    isDirectory: false
                )
                try manager.moveItem(at: source, to: interrupted)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: interrupted.path)
            } else {
                try manager.moveItem(at: source, to: destination)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
    }

    private func moveDatabaseFamily(from databaseURL: URL, to directory: URL, baseName: String) throws {
        let manager = FileManager.default
        let members = [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
        var moved: [(source: URL, destination: URL)] = []
        do {
            for source in members where manager.fileExists(atPath: source.path) {
                let suffix = String(source.path.dropFirst(databaseURL.path.count))
                let destination = directory.appendingPathComponent(baseName + suffix, isDirectory: false)
                try manager.moveItem(at: source, to: destination)
                moved.append((source, destination))
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        } catch {
            for member in moved.reversed() where !manager.fileExists(atPath: member.source.path) {
                try? manager.moveItem(at: member.destination, to: member.source)
            }
            throw error
        }
    }

    private struct RecoveryTable {
        let name: String
        let columns: [String]
        let maximumRows: Int
    }

    private struct RecoveryOutcome {
        var recoveredRows: Int
        var skippedRows: Int
        var failedTables: [String]
    }

    private static let recoveryTables: [RecoveryTable] = [
        RecoveryTable(
            name: "usage_events",
            columns: ["item_key", "provider_id", "action_id", "occurred_at"],
            maximumRows: 1_000_000
        ),
        RecoveryTable(name: "pinned_items", columns: ["item_key", "provider_id", "pinned_at"], maximumRows: 100_000),
        RecoveryTable(
            name: "quicklinks",
            columns: [
                "id", "title", "url_template", "arguments_json", "keywords_json", "icon_name",
                "browser_bundle_id", "created_at", "updated_at",
            ],
            maximumRows: 1_000
        ),
        RecoveryTable(
            name: "scripts",
            columns: [
                "id", "title", "executable_bookmark", "executable_path", "arguments_json", "environment_json",
                "timeout_seconds", "content_hash", "enabled", "created_at", "updated_at",
            ],
            maximumRows: 1_000
        ),
        RecoveryTable(
            name: "clipboard_items",
            columns: [
                "id", "content_type", "content_fingerprint", "ciphertext", "nonce", "tag", "encrypted_blob_path",
                "thumbnail_ciphertext", "thumbnail_nonce", "thumbnail_tag", "inferred_source_bundle_id", "byte_count",
                "is_sensitive", "created_at", "last_copied_at",
            ],
            maximumRows: 10_000
        ),
        RecoveryTable(
            name: "extensions",
            columns: [
                "id", "version", "install_path", "manifest_json", "content_hash", "enabled", "last_error_code",
                "installed_at", "updated_at",
            ],
            maximumRows: 100
        ),
        RecoveryTable(
            name: "extension_preferences",
            columns: ["extension_id", "name", "value_json", "is_secret"],
            maximumRows: 10_000
        ),
        RecoveryTable(
            name: "configuration_transactions",
            columns: ["id", "committed_at"],
            maximumRows: 1_000
        ),
    ]

    private func attemptReadOnlyRecovery(from sourceURL: URL, to destinationURL: URL) throws -> RecoveryOutcome {
        var source: OpaquePointer?
        let sourceStatus = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceStatus == SQLITE_OK, let source else {
            if let source { sqlite3_close_v2(source) }
            throw DatabaseError.openFailed(code: sourceStatus)
        }
        defer { sqlite3_close_v2(source) }
        sqlite3_busy_timeout(source, 250)
        sqlite3_limit(source, SQLITE_LIMIT_LENGTH, 25 * 1_024 * 1_024)
        sqlite3_limit(source, SQLITE_LIMIT_COLUMN, 128)

        var destination: OpaquePointer?
        let destinationStatus = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationStatus == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw DatabaseError.openFailed(code: destinationStatus)
        }
        defer { sqlite3_close_v2(destination) }
        try execute(database: destination, sql: "PRAGMA journal_mode=DELETE;")
        try execute(database: destination, sql: "PRAGMA foreign_keys=ON;")
        try execute(database: destination, sql: "PRAGMA busy_timeout=250;")
        try migrate(database: destination)

        var outcome = RecoveryOutcome(recoveredRows: 0, skippedRows: 0, failedTables: [])
        for table in Self.recoveryTables {
            do {
                let sourceColumns = try tableColumns(database: source, table: table.name)
                let columns = table.columns.filter(sourceColumns.contains)
                guard !columns.isEmpty else { continue }
                let quotedColumns = columns.map(Self.quotedIdentifier).joined(separator: ",")
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
                let selectSQL = "SELECT \(quotedColumns) FROM \(Self.quotedIdentifier(table.name)) LIMIT \(table.maximumRows);"
                let insertSQL =
                    "INSERT OR IGNORE INTO \(Self.quotedIdentifier(table.name)) (\(quotedColumns)) VALUES (\(placeholders));"
                let counts = try recoverRows(
                    source: source,
                    destination: destination,
                    selectSQL: selectSQL,
                    insertSQL: insertSQL,
                    columnCount: columns.count
                )
                outcome.recoveredRows += counts.recovered
                outcome.skippedRows += counts.skipped
            } catch {
                outcome.failedTables.append(table.name)
            }
        }
        guard try quickCheck(database: destination) else { throw DatabaseError.integrityCheckFailed }
        return outcome
    }

    private func createEmptyRecoveryDatabase(at destinationURL: URL) throws {
        var destination: OpaquePointer?
        let status = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw DatabaseError.openFailed(code: status)
        }
        defer { sqlite3_close_v2(destination) }
        try execute(database: destination, sql: "PRAGMA journal_mode=DELETE;")
        try execute(database: destination, sql: "PRAGMA foreign_keys=ON;")
        try execute(database: destination, sql: "PRAGMA busy_timeout=250;")
        try migrate(database: destination)
        guard try quickCheck(database: destination) else { throw DatabaseError.integrityCheckFailed }
    }

    private func tableColumns(database: OpaquePointer, table: String) throws -> Set<String> {
        try withStatement(database: database, sql: "PRAGMA table_info(\(Self.quotedIdentifier(table)));") { statement in
            var columns = Set<String>()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return columns }
                guard status == SQLITE_ROW, let name = string(at: 1, in: statement) else {
                    throw DatabaseError.statementFailed(code: status)
                }
                columns.insert(name)
            }
        }
    }

    private func recoverRows(
        source: OpaquePointer,
        destination: OpaquePointer,
        selectSQL: String,
        insertSQL: String,
        columnCount: Int
    ) throws -> (recovered: Int, skipped: Int) {
        var selectStatement: OpaquePointer?
        let selectStatus = sqlite3_prepare_v2(source, selectSQL, -1, &selectStatement, nil)
        guard selectStatus == SQLITE_OK, let selectStatement else {
            throw DatabaseError.statementFailed(code: selectStatus)
        }
        defer { sqlite3_finalize(selectStatement) }
        var insertStatement: OpaquePointer?
        let insertStatus = sqlite3_prepare_v2(destination, insertSQL, -1, &insertStatement, nil)
        guard insertStatus == SQLITE_OK, let insertStatement else {
            throw DatabaseError.statementFailed(code: insertStatus)
        }
        defer { sqlite3_finalize(insertStatement) }

        var recovered = 0
        var skipped = 0
        while true {
            let status = sqlite3_step(selectStatement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw DatabaseError.statementFailed(code: status) }
            sqlite3_reset(insertStatement)
            sqlite3_clear_bindings(insertStatement)
            var bindingsSucceeded = true
            for index in 0..<columnCount {
                guard
                    sqlite3_bind_value(
                        insertStatement,
                        Int32(index + 1),
                        sqlite3_column_value(selectStatement, Int32(index))
                    ) == SQLITE_OK
                else {
                    bindingsSucceeded = false
                    break
                }
            }
            guard bindingsSucceeded, sqlite3_step(insertStatement) == SQLITE_DONE else {
                skipped += 1
                continue
            }
            if sqlite3_changes(destination) > 0 { recovered += 1 } else { skipped += 1 }
        }
        return (recovered, skipped)
    }

    private static func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func quickCheck(database: OpaquePointer) throws -> Bool {
        try withStatement(database: database, sql: "PRAGMA quick_check;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                let text = sqlite3_column_text(statement, 0)
            else { return false }
            return String(cString: text) == "ok"
        }
    }

    private func userVersion(database: OpaquePointer) throws -> Int {
        try withStatement(database: database, sql: "PRAGMA user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func createMigrationBackup(database: OpaquePointer, fromVersion: Int) throws {
        let filename = "launcher-pre-v\(fromVersion)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).sqlite"
        let destinationURL = paths.backups.appendingPathComponent(filename, isDirectory: false)
        var destination: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw DatabaseError.backupFailed(code: openStatus)
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw DatabaseError.backupFailed(code: sqlite3_errcode(destination))
        }
        let stepStatus = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw DatabaseError.backupFailed(code: stepStatus == SQLITE_DONE ? finishStatus : stepStatus)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        try pruneMigrationBackups()
    }

    private func pruneMigrationBackups() throws {
        let manager = FileManager.default
        let backups = try manager.contentsOfDirectory(
            at: paths.backups,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("launcher-pre-v") && $0.pathExtension == "sqlite" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for backup in backups.dropFirst(3) { try manager.removeItem(at: backup) }
    }

    private func migrate(database: OpaquePointer) throws {
        let schema = """
            CREATE TABLE IF NOT EXISTS schema_migrations (
              version INTEGER PRIMARY KEY,
              applied_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS usage_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_key TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              action_id TEXT NOT NULL,
              occurred_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS usage_events_item_time
              ON usage_events(item_key, occurred_at DESC);
            CREATE TABLE IF NOT EXISTS pinned_items (
              item_key TEXT PRIMARY KEY,
              provider_id TEXT NOT NULL,
              pinned_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS quicklinks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              url_template TEXT NOT NULL,
              arguments_json BLOB NOT NULL,
              keywords_json BLOB NOT NULL,
              icon_name TEXT NOT NULL DEFAULT 'link',
              browser_bundle_id TEXT,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS scripts (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              executable_bookmark BLOB,
              executable_path TEXT NOT NULL,
              arguments_json BLOB NOT NULL,
              environment_json BLOB NOT NULL,
              timeout_seconds INTEGER NOT NULL,
              content_hash TEXT NOT NULL,
              enabled INTEGER NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS clipboard_items (
              id TEXT PRIMARY KEY,
              content_type TEXT NOT NULL,
              content_fingerprint TEXT NOT NULL,
              ciphertext BLOB,
              nonce BLOB,
              tag BLOB,
              encrypted_blob_path TEXT,
              thumbnail_ciphertext BLOB,
              thumbnail_nonce BLOB,
              thumbnail_tag BLOB,
              inferred_source_bundle_id TEXT,
              byte_count INTEGER NOT NULL,
              is_sensitive INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL,
              last_copied_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS clipboard_items_recent
              ON clipboard_items(last_copied_at DESC);
            CREATE TABLE IF NOT EXISTS extensions (
              id TEXT PRIMARY KEY,
              version TEXT NOT NULL,
              install_path TEXT NOT NULL,
              manifest_json BLOB NOT NULL,
              content_hash TEXT NOT NULL,
              enabled INTEGER NOT NULL,
              last_error_code TEXT,
              installed_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS extension_preferences (
              extension_id TEXT NOT NULL,
              name TEXT NOT NULL,
              value_json BLOB,
              is_secret INTEGER NOT NULL,
              PRIMARY KEY(extension_id, name),
              FOREIGN KEY(extension_id) REFERENCES extensions(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS configuration_transactions (
              id TEXT PRIMARY KEY,
              committed_at REAL NOT NULL
            );
            """

        do {
            let startingVersion = try userVersion(database: database)
            try execute(database: database, sql: "BEGIN IMMEDIATE;")
            try execute(database: database, sql: schema)
            let hasQuicklinkIconColumn = try tableHasColumn(database: database, table: "quicklinks", column: "icon_name")
            if startingVersion < 2, !hasQuicklinkIconColumn {
                try execute(database: database, sql: "ALTER TABLE quicklinks ADD COLUMN icon_name TEXT NOT NULL DEFAULT 'link';")
            }
            if startingVersion < 3 {
                if try !tableHasColumn(database: database, table: "clipboard_items", column: "thumbnail_ciphertext") {
                    try execute(database: database, sql: "ALTER TABLE clipboard_items ADD COLUMN thumbnail_ciphertext BLOB;")
                }
                if try !tableHasColumn(database: database, table: "clipboard_items", column: "thumbnail_nonce") {
                    try execute(database: database, sql: "ALTER TABLE clipboard_items ADD COLUMN thumbnail_nonce BLOB;")
                }
                if try !tableHasColumn(database: database, table: "clipboard_items", column: "thumbnail_tag") {
                    try execute(database: database, sql: "ALTER TABLE clipboard_items ADD COLUMN thumbnail_tag BLOB;")
                }
            }
            if startingVersion < 4,
                try !tableHasColumn(database: database, table: "quicklinks", column: "browser_bundle_id")
            {
                try execute(database: database, sql: "ALTER TABLE quicklinks ADD COLUMN browser_bundle_id TEXT;")
            }
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (1, strftime('%s','now'));"
            )
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (2, strftime('%s','now'));"
            )
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (3, strftime('%s','now'));"
            )
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (4, strftime('%s','now'));"
            )
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (5, strftime('%s','now'));"
            )
            try execute(database: database, sql: "PRAGMA user_version=5;")
            try execute(database: database, sql: "COMMIT;")
        } catch let error as DatabaseError {
            try? execute(database: database, sql: "ROLLBACK;")
            switch error {
            case let .statementFailed(code): throw DatabaseError.migrationFailed(code: code)
            default: throw error
            }
        }
    }

    private func tableHasColumn(database: OpaquePointer, table: String, column: String) throws -> Bool {
        try withStatement(database: database, sql: "PRAGMA table_info(\(table));") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if string(at: 1, in: statement) == column { return true }
            }
            return false
        }
    }

    func databaseHandle() throws -> OpaquePointer {
        try openIfNeeded()
    }

    func withStatement<T>(
        database: OpaquePointer,
        sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed(code: status)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func execute(database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func requireDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw DatabaseError.statementFailed(code: status) }
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_int64(statement, index, value)
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
        }
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func bindNull(to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw DatabaseError.statementFailed(code: status) }
    }

    func string(at index: Int32, in statement: OpaquePointer) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    func data(at index: Int32, in statement: OpaquePointer) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
