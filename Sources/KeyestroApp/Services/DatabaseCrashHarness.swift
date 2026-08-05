import Foundation
import KeyestroCore

private struct DatabaseCrashWriterOptions {
    let root: URL
    let readyFile: URL

    init(arguments: [String]) throws {
        let values = try DatabaseCrashArguments(arguments: arguments)
        guard let readyFile = values.readyFile, values.output == nil, values.minimumCount == nil else {
            throw DatabaseCrashHarnessError.invalidArguments
        }
        root = values.root
        self.readyFile = readyFile
    }
}

private struct DatabaseCrashReadbackOptions {
    let root: URL
    let output: URL
    let minimumCount: Int

    init(arguments: [String]) throws {
        let values = try DatabaseCrashArguments(arguments: arguments)
        guard let output = values.output,
            let minimumCount = values.minimumCount,
            values.readyFile == nil,
            (1...10_000).contains(minimumCount)
        else { throw DatabaseCrashHarnessError.invalidArguments }
        root = values.root
        self.output = output
        self.minimumCount = minimumCount
    }
}

private struct DatabaseCrashArguments {
    let root: URL
    let readyFile: URL?
    let output: URL?
    let minimumCount: Int?

    init(arguments: [String]) throws {
        var root: URL?
        var readyFile: URL?
        var output: URL?
        var minimumCount: Int?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            guard index < arguments.count else { throw DatabaseCrashHarnessError.invalidArguments }
            let value = arguments[index]
            switch option {
            case "--root": root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
            case "--ready-file": readyFile = URL(fileURLWithPath: value).standardizedFileURL
            case "--output": output = URL(fileURLWithPath: value).standardizedFileURL
            case "--minimum-count": minimumCount = Int(value)
            default: throw DatabaseCrashHarnessError.invalidArguments
            }
            index += 1
        }
        guard let root, root.path != "/" else { throw DatabaseCrashHarnessError.invalidArguments }
        self.root = root
        self.readyFile = readyFile
        self.output = output
        self.minimumCount = minimumCount
    }
}

private struct DatabaseCrashReadyMarker: Codable {
    let schemaVersion: Int
    let processIdentifier: Int32
    let committedItemCount: Int
}

private struct DatabaseCrashReadbackReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let integrityCheckPassed: Bool
    let committedItemCount: Int
    let minimumExpectedItemCount: Int
    let passed: Bool
}

private enum DatabaseCrashHarnessError: Error {
    case invalidArguments
    case fixtureWriteFailed
    case integrityCheckFailed
}

enum DatabaseCrashHarness {
    static func writeUntilKilled(arguments: [String]) async throws -> Never {
        let options = try DatabaseCrashWriterOptions(arguments: arguments)
        let (database, store) = try await makeStore(root: options.root)
        let base = Date().addingTimeInterval(-1_000)
        for index in 0..<1_000 {
            let result = await store.capture(
                .text("committed crash fixture \(index)"),
                sourceBundleIdentifier: "com.keyestro.launcher.database-crash",
                at: base.addingTimeInterval(Double(index))
            )
            guard case .success = result else { throw DatabaseCrashHarnessError.fixtureWriteFailed }
        }
        let marker = DatabaseCrashReadyMarker(
            schemaVersion: 1,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            committedItemCount: 1_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: options.readyFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(marker).write(to: options.readyFile, options: .atomic)

        var index = 0
        while true {
            let result = await store.capture(
                .text("rolling crash fixture \(index)"),
                sourceBundleIdentifier: "com.keyestro.launcher.database-crash"
            )
            guard case .success = result else {
                await database.close()
                throw DatabaseCrashHarnessError.fixtureWriteFailed
            }
            index += 1
            if index.isMultiple(of: 10) { await Task.yield() }
        }
    }

    static func readBack(arguments: [String]) async throws {
        let options = try DatabaseCrashReadbackOptions(arguments: arguments)
        let paths = try paths(root: options.root)
        let database = LauncherDatabase(paths: paths)
        try await database.prepare()
        let integrity = try await database.integrityCheck()
        let count = try await database.clipboardItemCount()
        await database.close()
        let passed = integrity && count >= options.minimumCount
        let report = DatabaseCrashReadbackReport(
            schemaVersion: 1,
            generatedAt: Date(),
            integrityCheckPassed: integrity,
            committedItemCount: count,
            minimumExpectedItemCount: options.minimumCount,
            passed: passed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: options.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: options.output, options: .atomic)
        if !passed { throw DatabaseCrashHarnessError.integrityCheckFailed }
    }

    private static func makeStore(root: URL) async throws -> (LauncherDatabase, ClipboardStore) {
        let database = LauncherDatabase(paths: try paths(root: root))
        try await database.prepare()
        let store = ClipboardStore(
            database: database,
            keyManager: InstallationKeyManager(
                keychain: InMemoryKeychainService(),
                service: "com.keyestro.launcher.database-crash"
            ),
            policy: ClipboardRetentionPolicy(maximumAge: nil, maximumItemCount: nil)
        )
        await store.initialize(enabled: true)
        guard case .ready = await store.currentState() else {
            throw DatabaseCrashHarnessError.fixtureWriteFailed
        }
        return (database, store)
    }

    private static func paths(root: URL) throws -> AppPaths {
        try AppPaths(
            bundleIdentifier: "com.keyestro.launcher.database-crash",
            applicationSupportRoot: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
            cachesRoot: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }
}
