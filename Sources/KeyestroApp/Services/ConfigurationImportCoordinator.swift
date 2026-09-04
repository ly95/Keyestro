import Foundation
import KeyestroCore

enum ConfigurationImportTransactionError: Error, Equatable {
    case applyFailed(backupURL: URL)
    case rollbackFailed(backupURL: URL)
    case completionFailed(backupURL: URL)
    case invalidJournal
}

private struct ConfigurationImportJournal: Codable {
    enum State: String, Codable {
        case prepared
        case completed
    }

    let schemaVersion: Int
    let state: State?
    let transactionID: String
    let backupURL: URL
    let originalSettings: [String: JSONValue]
    let originalPending: PendingConfigurationImportSnapshot
    let importedSettings: [String: JSONValue]
    let importedScripts: [ExportedScriptRegistration]
    let importedExtensions: [ExportedExtensionRegistration]

    func markingCompleted() -> Self {
        Self(
            schemaVersion: schemaVersion,
            state: .completed,
            transactionID: transactionID,
            backupURL: backupURL,
            originalSettings: originalSettings,
            originalPending: originalPending,
            importedSettings: importedSettings,
            importedScripts: importedScripts,
            importedExtensions: importedExtensions
        )
    }
}

private actor ConfigurationImportOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Coordinates the SQLite merge and the two UserDefaults-backed stores as one recoverable transaction.
/// The durable backup and journal are written first. UserDefaults are published only after SQLite commits,
/// so observers cannot perform irreversible work for an import that never reached its commit point.
@MainActor
final class ConfigurationImportCoordinator {
    private let service: ConfigurationService
    private let settings: SettingsStore
    private let pendingImports: PendingConfigurationImportStore
    private let removeJournal: @MainActor (URL) throws -> Void
    /// Configuration UI models and startup recovery can briefly coexist. A process-wide
    /// gate prevents two coordinator instances from operating on the single journal.
    private static let operationGate = ConfigurationImportOperationGate()

    init(
        service: ConfigurationService,
        settings: SettingsStore,
        defaults: UserDefaults = .standard,
        removeJournal: @escaping @MainActor (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.service = service
        self.settings = settings
        pendingImports = PendingConfigurationImportStore(defaults: defaults)
        self.removeJournal = removeJournal
    }

    @discardableResult
    func apply(_ validated: ValidatedConfigurationImport) async throws -> URL {
        await Self.operationGate.acquire()
        do {
            try Task.checkCancellation()
            let backupURL = try await applyExclusively(validated)
            await Self.operationGate.release()
            return backupURL
        } catch {
            await Self.operationGate.release()
            throw error
        }
    }

    private func applyExclusively(_ validated: ValidatedConfigurationImport) async throws -> URL {
        _ = try await recoverIfNeededExclusively()
        let originalSettings = settings.exportedConfiguration()
        let originalPending = try pendingImports.snapshot()
        let backupURL = try await service.createBackup(currentSettings: originalSettings)
        let transactionID = UUID().uuidString.lowercased()
        let journal = ConfigurationImportJournal(
            schemaVersion: 2,
            state: .prepared,
            transactionID: transactionID,
            backupURL: backupURL,
            originalSettings: originalSettings,
            originalPending: originalPending,
            importedSettings: validated.document.payload.settings,
            importedScripts: validated.document.payload.scripts,
            importedExtensions: validated.document.payload.extensions
        )
        let journalURL = try await service.importJournalURL()
        try write(journal, to: journalURL)

        do {
            try await service.merge(validated, transactionID: transactionID)
            try applyImportedState(from: journal)
            try write(journal.markingCompleted(), to: journalURL)
            try? removeJournal(journalURL)
            return backupURL
        } catch {
            let committed: Bool
            do {
                committed = try await service.hasCommittedTransaction(transactionID)
            } catch {
                throw ConfigurationImportTransactionError.rollbackFailed(backupURL: backupURL)
            }
            if committed {
                do {
                    try applyImportedState(from: journal)
                    try write(journal.markingCompleted(), to: journalURL)
                    try? removeJournal(journalURL)
                    return backupURL
                } catch {
                    throw ConfigurationImportTransactionError.completionFailed(backupURL: backupURL)
                }
            }
            // Schema-v2 imports do not touch UserDefaults until the SQLite commit
            // succeeds. In particular, do not restore a snapshot here: the user may
            // have changed a local capability while the merge was awaiting I/O.
            try? removeJournal(journalURL)
            throw ConfigurationImportTransactionError.applyFailed(backupURL: backupURL)
        }
    }

    @discardableResult
    func recoverIfNeeded() async throws -> Bool {
        await Self.operationGate.acquire()
        do {
            try Task.checkCancellation()
            let recovered = try await recoverIfNeededExclusively()
            await Self.operationGate.release()
            return recovered
        } catch {
            await Self.operationGate.release()
            throw error
        }
    }

    private func recoverIfNeededExclusively() async throws -> Bool {
        let journalURL = try await service.importJournalURL()
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        let journal: ConfigurationImportJournal
        do {
            journal = try readJournal(from: journalURL)
        } catch {
            quarantineInvalidJournal(at: journalURL)
            throw ConfigurationImportTransactionError.invalidJournal
        }
        if journal.state == .completed {
            try? removeJournal(journalURL)
            return true
        }
        let committed = try await service.hasCommittedTransaction(journal.transactionID)
        if committed {
            do {
                if journal.schemaVersion == 1 {
                    // Version 1 could import capability grants before committing the
                    // database. Restore the same-installation grants captured by that
                    // journal before applying its portable settings under v2 rules.
                    try restoreLegacyLocalSettings(from: journal)
                }
                try applyImportedState(from: journal)
            } catch {
                throw ConfigurationImportTransactionError.completionFailed(backupURL: journal.backupURL)
            }
        } else if journal.schemaVersion == 1 {
            // Version 1 applied settings before the database commit. Restore its
            // same-installation capability snapshot, then its portable settings and
            // pending registrations. Version 2 never needs this compensating path.
            do {
                try restoreLegacyLocalSettings(from: journal)
                try settings.applyImportedConfiguration(journal.originalSettings)
                try pendingImports.restore(journal.originalPending)
            } catch {
                throw ConfigurationImportTransactionError.rollbackFailed(backupURL: journal.backupURL)
            }
        }
        do {
            try write(journal.markingCompleted(), to: journalURL)
        } catch {
            if committed {
                throw ConfigurationImportTransactionError.completionFailed(backupURL: journal.backupURL)
            }
            throw ConfigurationImportTransactionError.rollbackFailed(backupURL: journal.backupURL)
        }
        try? removeJournal(journalURL)
        return true
    }

    private func applyImportedState(from journal: ConfigurationImportJournal) throws {
        try settings.applyImportedConfiguration(journal.importedSettings)
        try pendingImports.merge(
            scripts: journal.importedScripts,
            extensions: journal.importedExtensions
        )
    }

    private func restoreLegacyLocalSettings(from journal: ConfigurationImportJournal) throws {
        let originalLocalSettings = journal.originalSettings.filter {
            ConfigurationService.locallyAuthorizedSettingKeys.contains($0.key)
        }
        try settings.restoreLocalConfigurationSnapshot(originalLocalSettings)
    }

    private func write(_ journal: ConfigurationImportJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= ConfigurationService.maximumDocumentBytes else {
            throw ConfigurationImportTransactionError.invalidJournal
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readJournal(from url: URL) throws -> ConfigurationImportJournal {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= ConfigurationService.maximumDocumentBytes
        else { throw ConfigurationImportTransactionError.invalidJournal }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let journal = try? decoder.decode(ConfigurationImportJournal.self, from: data),
            [1, 2].contains(journal.schemaVersion),
            (journal.schemaVersion == 1 || journal.state != nil),
            UUID(uuidString: journal.transactionID) != nil,
            journal.backupURL.isFileURL,
            journal.backupURL.deletingLastPathComponent().standardizedFileURL
                == url.deletingLastPathComponent().standardizedFileURL,
            journal.originalSettings.count <= 100,
            journal.importedSettings.count <= 100,
            journal.originalPending.scripts.count <= 1_000,
            journal.originalPending.extensions.count <= 100,
            journal.importedScripts.count <= 1_000,
            journal.importedExtensions.count <= 100
        else { throw ConfigurationImportTransactionError.invalidJournal }
        try journal.originalPending.scripts.forEach { try $0.validate() }
        try journal.originalPending.extensions.forEach { try $0.validate() }
        try journal.importedScripts.forEach { try $0.validate() }
        try journal.importedExtensions.forEach { try $0.validate() }
        return journal
    }

    /// Preserve a malformed journal for diagnostics when possible, but never leave it
    /// at the live transaction path where it would block every future import.
    private func quarantineInvalidJournal(at url: URL) {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let quarantinedURL = url.deletingLastPathComponent().appendingPathComponent(
            "ConfigurationImportTransaction.invalid-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        do {
            try FileManager.default.moveItem(at: url, to: quarantinedURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quarantinedURL.path)
        } catch {
            // The journal has already failed strict validation and cannot safely be
            // replayed. Removing it is safer than permanently blocking recovery.
            try? FileManager.default.removeItem(at: url)
        }
    }
}
