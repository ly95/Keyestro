import Foundation
import SQLite3
import Testing
@testable import KeyestroCore

@Test func databaseCreatesMigrationBackupBeforeUpgradingLegacySchema() async throws {
    let (root, paths) = try databaseTestPaths("migration")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    #expect(
        sqlite3_exec(database, "CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES('preserve-me');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    try await launcherDatabase.prepare()
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("launcher-pre-v0-") }
    #expect(backups.count == 1)
    let backupBytes = try Data(contentsOf: try #require(backups.first))
    #expect(String(decoding: backupBytes, as: UTF8.self).contains("preserve-me"))
}

@Test func databaseRejectsNewerSchemaWithoutChangingIt() async throws {
    let (root, paths) = try databaseTestPaths("newer")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    #expect(sqlite3_exec(database, "PRAGMA user_version=99; CREATE TABLE future(value TEXT);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)
    let before = try Data(contentsOf: paths.database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    await #expect(throws: DatabaseError.newerSchema(found: 99, supported: LauncherDatabase.currentSchemaVersion)) {
        try await launcherDatabase.prepare()
    }
    #expect(try Data(contentsOf: paths.database) == before)
}

@Test func databaseMigratesVersionOneQuicklinksWithADefaultIcon() async throws {
    let (root, paths) = try databaseTestPaths("v1-icon")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    let oldSchema = """
        PRAGMA user_version=1;
        CREATE TABLE quicklinks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          url_template TEXT NOT NULL,
          arguments_json BLOB NOT NULL,
          keywords_json BLOB NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        """
    #expect(sqlite3_exec(database, oldSchema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    try await launcherDatabase.prepare()
    await launcherDatabase.close()
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
    #expect(backups.contains(where: { $0.lastPathComponent.hasPrefix("launcher-pre-v1-") }))

    var migrated: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &migrated, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    let migratedDatabase = try #require(migrated)
    defer { sqlite3_close_v2(migratedDatabase) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(migratedDatabase, "SELECT icon_name FROM quicklinks LIMIT 1;", -1, &statement, nil) == SQLITE_OK)
    sqlite3_finalize(statement)
}

@Test func databaseMigratesVersionTwoClipboardRowsForEncryptedThumbnails() async throws {
    let (root, paths) = try databaseTestPaths("v2-thumbnails")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    let oldSchema = """
        PRAGMA user_version=2;
        CREATE TABLE clipboard_items (
          id TEXT PRIMARY KEY,
          content_type TEXT NOT NULL,
          content_fingerprint TEXT NOT NULL,
          ciphertext BLOB,
          nonce BLOB,
          tag BLOB,
          encrypted_blob_path TEXT,
          inferred_source_bundle_id TEXT,
          byte_count INTEGER NOT NULL,
          is_sensitive INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          last_copied_at REAL NOT NULL
        );
        """
    #expect(sqlite3_exec(database, oldSchema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    try await launcherDatabase.prepare()
    await launcherDatabase.close()

    var migrated: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &migrated, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    let migratedDatabase = try #require(migrated)
    defer { sqlite3_close_v2(migratedDatabase) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(migratedDatabase, "PRAGMA table_info(clipboard_items);", -1, &statement, nil) == SQLITE_OK)
    let columns = try #require(statement)
    defer { sqlite3_finalize(columns) }
    var names = Set<String>()
    while sqlite3_step(columns) == SQLITE_ROW {
        if let text = sqlite3_column_text(columns, 1) { names.insert(String(cString: text)) }
    }
    #expect(names.contains("thumbnail_ciphertext"))
    #expect(names.contains("thumbnail_nonce"))
    #expect(names.contains("thumbnail_tag"))
}

@Test(arguments: [3, 4])
func databaseMigratesEveryLaterPublishedSchemaToVersionFive(version: Int) async throws {
    let (root, paths) = try databaseTestPaths("v\(version)-to-v5")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    let browserColumn = version >= 4 ? ", browser_bundle_id TEXT" : ""
    let schema = """
        PRAGMA user_version=\(version);
        CREATE TABLE quicklinks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          url_template TEXT NOT NULL,
          arguments_json BLOB NOT NULL,
          keywords_json BLOB NOT NULL,
          icon_name TEXT NOT NULL DEFAULT 'link'\(browserColumn),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        """
    #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    try await launcherDatabase.prepare()
    await launcherDatabase.close()

    var migrated: OpaquePointer?
    #expect(sqlite3_open_v2(paths.database.path, &migrated, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    let migratedDatabase = try #require(migrated)
    defer { sqlite3_close_v2(migratedDatabase) }
    #expect(try sqliteInteger(database: migratedDatabase, sql: "PRAGMA user_version;") == 5)
    #expect(try sqliteTableHasColumn(database: migratedDatabase, table: "quicklinks", column: "browser_bundle_id"))
    #expect(try sqliteTableExists(database: migratedDatabase, table: "configuration_transactions"))
    let backups = try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil)
    #expect(backups.contains(where: { $0.lastPathComponent.hasPrefix("launcher-pre-v\(version)-") }))
}

@Test func databaseQuarantinesCorruptFileAttemptsReadOnlyRecoveryAndCreatesAHealthyDatabase() async throws {
    let (root, paths) = try databaseTestPaths("corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    let corrupt = Data("not-a-sqlite-database-preserve-this".utf8)
    try corrupt.write(to: paths.database)

    let launcherDatabase = LauncherDatabase(paths: paths)
    try await launcherDatabase.prepare()
    #expect(try await launcherDatabase.integrityCheck())

    let report = try #require(await launcherDatabase.latestRecoveryReport())
    #expect(report.quarantineDirectory.lastPathComponent.hasPrefix("Corrupt-"))
    #expect(report.recoveredRowCount == 0)
    let quarantinedDatabase = report.quarantineDirectory.appendingPathComponent("launcher.sqlite")
    #expect(try Data(contentsOf: quarantinedDatabase) == corrupt)
    #expect(FileManager.default.fileExists(atPath: report.quarantineDirectory.appendingPathComponent("recovery-report.json").path))
    #expect(try Data(contentsOf: paths.database) != corrupt)
}

@Test func databaseReadOnlyRecoverySalvagesHealthyRowsFromAPartiallyDamagedDatabase() async throws {
    let (root, paths) = try databaseTestPaths("partial-corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = LauncherDatabase(paths: paths)
    let quicklink = try QuicklinkDefinition(
        id: "recover-me",
        title: "Recovered Link",
        urlTemplate: "https://example.com",
        arguments: []
    )
    try await original.saveQuicklink(quicklink)
    await original.close()

    var raw: OpaquePointer?
    #expect(sqlite3_open(paths.database.path, &raw) == SQLITE_OK)
    let database = try #require(raw)
    #expect(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK)
    #expect(
        sqlite3_exec(database, "CREATE TABLE damage(value TEXT); INSERT INTO damage VALUES('broken page');", nil, nil, nil) == SQLITE_OK)
    let pageSize = try sqliteInteger(database: database, sql: "PRAGMA page_size;")
    let damagedRootPage = try sqliteInteger(
        database: database,
        sql: "SELECT rootpage FROM sqlite_schema WHERE name='damage';"
    )
    sqlite3_close_v2(database)

    let file = try FileHandle(forWritingTo: paths.database)
    try file.seek(toOffset: UInt64((damagedRootPage - 1) * pageSize))
    try file.write(contentsOf: Data([0]))
    try file.close()

    let recovered = LauncherDatabase(paths: paths)
    try await recovered.prepare()
    let report = try #require(await recovered.latestRecoveryReport())
    #expect(report.recoveredRowCount >= 1)
    let recoveredQuicklink = try #require(try await recovered.quicklink(id: quicklink.id))
    #expect(recoveredQuicklink.id == quicklink.id)
    #expect(recoveredQuicklink.title == quicklink.title)
    #expect(recoveredQuicklink.urlTemplate == quicklink.urlTemplate)
    #expect(recoveredQuicklink.arguments == quicklink.arguments)
    #expect(try await recovered.integrityCheck())
    #expect(FileManager.default.fileExists(atPath: report.quarantineDirectory.appendingPathComponent("launcher.sqlite").path))
}

@Test func databaseResumesInterruptedRecoveryBeforeAcceptingAPartialCandidate() async throws {
    let (root, paths) = try databaseTestPaths("interrupted-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let preserved = try QuicklinkDefinition(
        id: "preserved",
        title: "Preserved Link",
        urlTemplate: "https://example.com/preserved",
        arguments: []
    )
    let original = LauncherDatabase(paths: paths)
    try await original.saveQuicklink(preserved)
    await original.close()

    try paths.prepare()
    let quarantineName = "Corrupt-20240101-000000-\(UUID().uuidString.lowercased())"
    let quarantine = paths.backups.appendingPathComponent(quarantineName, isDirectory: true)
    try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
    try moveDatabaseFamilyForTest(from: paths.database, to: quarantine)

    // Simulate a crash after a structurally healthy but incomplete candidate was
    // installed at the authoritative path and before the recovery marker cleared.
    let partial = try QuicklinkDefinition(
        id: "partial",
        title: "Partial Link",
        urlTemplate: "https://example.com/partial",
        arguments: []
    )
    let partialDatabase = LauncherDatabase(paths: paths)
    try await partialDatabase.saveQuicklink(partial)
    await partialDatabase.close()
    let markerURL = paths.backups.appendingPathComponent("pending-database-recovery.json")
    try writePendingRecoveryMarkerForTest(named: quarantineName, to: markerURL)

    let resumed = LauncherDatabase(paths: paths)
    try await resumed.prepare()
    #expect(try await resumed.quicklink(id: preserved.id)?.title == preserved.title)
    #expect(try await resumed.quicklink(id: partial.id) == nil)
    #expect(try await resumed.integrityCheck())
    #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    let report = try #require(await resumed.latestRecoveryReport())
    #expect(report.quarantineDirectory == quarantine)
    #expect(report.recoveredRowCount >= 1)
    let quarantineContents = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
    #expect(quarantineContents.contains(where: { $0.lastPathComponent.hasPrefix("Interrupted-Recovery-") }))
}

@Test func databaseRecoveryMarkerRejectsASymlinkedQuarantineDirectory() async throws {
    let (root, paths) = try databaseTestPaths("recovery-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("preserve".utf8).write(to: sentinel)
    let quarantineName = "Corrupt-20240101-000000-\(UUID().uuidString.lowercased())"
    try FileManager.default.createSymbolicLink(
        at: paths.backups.appendingPathComponent(quarantineName),
        withDestinationURL: outside
    )
    let markerURL = paths.backups.appendingPathComponent("pending-database-recovery.json")
    try writePendingRecoveryMarkerForTest(named: quarantineName, to: markerURL)

    let database = LauncherDatabase(paths: paths)
    await #expect(throws: DatabaseError.integrityCheckFailed) {
        try await database.prepare()
    }
    #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
}

@Test func databasePersistsAndUpdatesLinkedScriptIdentity() async throws {
    let (root, paths) = try databaseTestPaths("linked-script")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = LauncherDatabase(paths: paths)
    // Use exactly representable fixture timestamps. The test is about database
    // persistence, not the sub-microsecond precision of the wall clock used by
    // Date() on the host running the suite.
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_001.25)
    let original = try ScriptDefinition(
        id: "linked",
        title: "Linked",
        executablePath: "/tmp/linked",
        contentHash: String(repeating: "a", count: 64),
        linkedFileIdentity: "1:2",
        createdAt: createdAt,
        updatedAt: updatedAt
    )
    try await database.saveScript(original)
    let loadedOriginal = try #require(try await database.script(id: original.id))
    expectSameScript(loadedOriginal, original)

    let updated = try ScriptDefinition(
        id: original.id,
        title: original.title,
        executablePath: original.executablePath,
        contentHash: String(repeating: "b", count: 64),
        linkedFileIdentity: "1:3",
        createdAt: original.createdAt,
        updatedAt: original.updatedAt.addingTimeInterval(2)
    )
    try await database.saveScript(updated)
    let loadedUpdated = try #require(try await database.script(id: original.id))
    expectSameScript(loadedUpdated, updated)
}

private func expectSameScript(_ actual: ScriptDefinition, _ expected: ScriptDefinition) {
    #expect(actual.id == expected.id)
    #expect(actual.title == expected.title)
    #expect(actual.executablePath == expected.executablePath)
    #expect(actual.arguments == expected.arguments)
    #expect(actual.environment == expected.environment)
    #expect(actual.timeoutSeconds == expected.timeoutSeconds)
    #expect(actual.contentHash == expected.contentHash)
    #expect(actual.linkedFileIdentity == expected.linkedFileIdentity)
    #expect(actual.enabled == expected.enabled)
    #expect(actual.createdAt == expected.createdAt)
    #expect(actual.updatedAt == expected.updatedAt)
}

@Test func configurationTransactionMarkerCommitsAtomicallyWithQuicklinksAndSurvivesReopen() async throws {
    let (root, paths) = try databaseTestPaths("configuration-transaction")
    defer { try? FileManager.default.removeItem(at: root) }
    let transactionID = UUID().uuidString.lowercased()
    let link = try QuicklinkDefinition.inferred(
        id: "transaction-link",
        title: "Transaction Link",
        urlTemplate: "https://example.com"
    )
    let database = LauncherDatabase(paths: paths)
    try await database.mergeQuicklinksAtomically([link], transactionID: transactionID)
    #expect(try await database.hasCommittedConfigurationTransaction(transactionID))
    #expect(try await database.quicklink(id: link.id)?.title == link.title)
    await database.close()
    #expect(try configurationTransactionIDs(at: paths.database).contains(transactionID))

    let reopened = LauncherDatabase(paths: paths)
    #expect(try await reopened.hasCommittedConfigurationTransaction(transactionID))
    #expect(try await reopened.quicklink(id: link.id)?.title == link.title)
}

@Test func conditionalConfigurationMergeRejectsAChangedQuicklinkAtomically() async throws {
    let (root, paths) = try databaseTestPaths("configuration-conflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "Original",
        urlTemplate: "https://original.example"
    )
    let edited = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "User Edit",
        urlTemplate: "https://edited.example"
    )
    let imported = try QuicklinkDefinition.inferred(
        id: "shared",
        title: "Imported",
        urlTemplate: "https://imported.example"
    )
    let database = LauncherDatabase(paths: paths)
    try await database.saveQuicklink(original)
    try await database.saveQuicklink(edited)
    let transactionID = UUID().uuidString.lowercased()

    await #expect(throws: ConfigurationError.conflictingChanges) {
        try await database.mergeQuicklinksAtomically(
            [imported],
            transactionID: transactionID,
            expecting: [QuicklinkMergeExpectation(id: original.id, existingDefinition: original)]
        )
    }
    let preserved = try #require(try await database.quicklink(id: edited.id))
    #expect(preserved.title == edited.title)
    #expect(preserved.urlTemplate == edited.urlTemplate)
    #expect(try await database.hasCommittedConfigurationTransaction(transactionID) == false)
}

private func configurationTransactionIDs(at url: URL) throws -> [String] {
    var raw: OpaquePointer?
    guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let raw else { return [] }
    defer { sqlite3_close_v2(raw) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(raw, "SELECT id FROM configuration_transactions ORDER BY id;", -1, &statement, nil) == SQLITE_OK,
        let statement
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
    }
    return values
}

private func databaseTestPaths(_ name: String) throws -> (URL, AppPaths) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-database-\(name)-\(UUID().uuidString)", isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.database-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    return (root, paths)
}

private func moveDatabaseFamilyForTest(from database: URL, to directory: URL) throws {
    let manager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let source = URL(fileURLWithPath: database.path + suffix)
        guard manager.fileExists(atPath: source.path) else { continue }
        try manager.moveItem(
            at: source,
            to: directory.appendingPathComponent(database.lastPathComponent + suffix)
        )
    }
}

private func writePendingRecoveryMarkerForTest(named quarantineName: String, to url: URL) throws {
    let marker: [String: Any] = [
        "schemaVersion": 1,
        "detectedAt": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
        "quarantineDirectoryName": quarantineName,
    ]
    try JSONSerialization.data(withJSONObject: marker).write(to: url, options: [.atomic])
}

private func sqliteInteger(database: OpaquePointer, sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func sqliteTableHasColumn(database: OpaquePointer, table: String, column: String) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
        let statement
    else { throw DatabaseError.statementFailed(code: sqlite3_errcode(database)) }
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 1), String(cString: text) == column { return true }
    }
    return false
}

private func sqliteTableExists(database: OpaquePointer, table: String) throws -> Bool {
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name=? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement
    else { throw DatabaseError.statementFailed(code: sqlite3_errcode(database)) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
        throw DatabaseError.statementFailed(code: sqlite3_errcode(database))
    }
    return sqlite3_step(statement) == SQLITE_ROW
}
