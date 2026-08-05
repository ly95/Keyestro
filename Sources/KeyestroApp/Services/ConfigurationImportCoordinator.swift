import Foundation
import KeyestroCore

enum ConfigurationImportTransactionError: Error, Equatable {
    case applyFailed(backupURL: URL)
    case rollbackFailed(backupURL: URL)
    case completionFailed(backupURL: URL)
    case invalidJournal
}

private struct ConfigurationImportJournal: Codable {
    let schemaVersion: Int
    let transactionID: String
    let backupURL: URL
    let originalSettings: [String: JSONValue]
    let originalPending: PendingConfigurationImportSnapshot
    let importedSettings: [String: JSONValue]
    let importedScripts: [ExportedScriptRegistration]
    let importedExtensions: [ExportedExtensionRegistration]
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

/// Coordinates the SQLite merge and the two UserDefaults-backed stores as one compensating transaction.
/// The durable backup is created before the first mutation, and the SQLite merge is the final atomic commit.
@MainActor
final class ConfigurationImportCoordinator {
    private let service: ConfigurationService
    private let settings: SettingsStore
    private let pendingImports: PendingConfigurationImportStore
    private let removeJournal: @MainActor (URL) throws -> Void
    private let operationGate = ConfigurationImportOperationGate()

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
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let backupURL = try await applyExclusively(validated)
            await operationGate.release()
            return backupURL
        } catch {
            await operationGate.release()
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
            schemaVersion: 1,
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
            try applyImportedState(from: journal)
            try await service.merge(validated, transactionID: transactionID)
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
                    try? removeJournal(journalURL)
                    return backupURL
                } catch {
                    throw ConfigurationImportTransactionError.completionFailed(backupURL: backupURL)
                }
            }
            var rollbackSucceeded = true
            do { try settings.applyImportedConfiguration(originalSettings) } catch { rollbackSucceeded = false }
            do { try pendingImports.restore(originalPending) } catch { rollbackSucceeded = false }
            if rollbackSucceeded { try? removeJournal(journalURL) }
            guard rollbackSucceeded else {
                throw ConfigurationImportTransactionError.rollbackFailed(backupURL: backupURL)
            }
            throw ConfigurationImportTransactionError.applyFailed(backupURL: backupURL)
        }
    }

    @discardableResult
    func recoverIfNeeded() async throws -> Bool {
        await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let recovered = try await recoverIfNeededExclusively()
            await operationGate.release()
            return recovered
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func recoverIfNeededExclusively() async throws -> Bool {
        let journalURL = try await service.importJournalURL()
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        let journal = try readJournal(from: journalURL)
        if try await service.hasCommittedTransaction(journal.transactionID) {
            do {
                try applyImportedState(from: journal)
            } catch {
                throw ConfigurationImportTransactionError.completionFailed(backupURL: journal.backupURL)
            }
        } else {
            do {
                try settings.applyImportedConfiguration(journal.originalSettings)
                try pendingImports.restore(journal.originalPending)
            } catch {
                throw ConfigurationImportTransactionError.rollbackFailed(backupURL: journal.backupURL)
            }
        }
        try removeJournal(journalURL)
        return true
    }

    private func applyImportedState(from journal: ConfigurationImportJournal) throws {
        try settings.applyImportedConfiguration(journal.importedSettings)
        try pendingImports.merge(
            scripts: journal.importedScripts,
            extensions: journal.importedExtensions
        )
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
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
            (values.fileSize ?? Int.max) <= ConfigurationService.maximumDocumentBytes
        else { throw ConfigurationImportTransactionError.invalidJournal }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let journal = try? decoder.decode(ConfigurationImportJournal.self, from: data),
            journal.schemaVersion == 1,
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
}
