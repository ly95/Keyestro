import AppKit
import Foundation
import KeyestroCore

private struct PackagedSoakOptions {
    let duration: Duration
    let readyFile: URL

    init(arguments: [String]) throws {
        var durationSeconds: Int?
        var readyFile: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]),
                    (1...30_000).contains(value)
                else { throw PackagedSoakError.invalidArguments }
                durationSeconds = value
            case "--ready-file":
                index += 1
                guard index < arguments.count else { throw PackagedSoakError.invalidArguments }
                readyFile = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                throw PackagedSoakError.invalidArguments
            }
            index += 1
        }
        guard let durationSeconds, let readyFile else { throw PackagedSoakError.invalidArguments }
        duration = .seconds(durationSeconds)
        self.readyFile = readyFile
    }
}

private struct PackagedSoakReadyMarker: Codable {
    let schemaVersion: Int
    let processIdentifier: Int32
    let clipboardEnabled: Bool
    let clipboardItemCount: Int
    let queryIntervalSeconds: Int
}

private enum PackagedSoakError: Error {
    case invalidArguments
    case defaultsUnavailable
    case clipboardInitializationFailed
    case clipboardFixtureFailed
    case queryFailed
}

/// Exercises the encrypted clipboard store, real pasteboard monitor, and query
/// coordinator continuously. RSS growth is sampled by an external process.
@MainActor
enum PackagedSoakHarness {
    static func run(arguments: [String]) async throws {
        let options = try PackagedSoakOptions(arguments: arguments)
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("keyestro-packaged-soak-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "com.keyestro.launcher.packaged-soak.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw PackagedSoakError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsName)
        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.launcher.packaged-soak",
            applicationSupportRoot: workspace.appendingPathComponent("ApplicationSupport", isDirectory: true),
            cachesRoot: workspace.appendingPathComponent("Caches", isDirectory: true)
        )
        let database = LauncherDatabase(paths: paths)
        try await database.prepare()
        let store = ClipboardStore(
            database: database,
            keyManager: InstallationKeyManager(
                keychain: InMemoryKeychainService(),
                service: "com.keyestro.launcher.packaged-soak"
            )
        )
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardEnabled = true
        settings.clipboardPaused = false
        let pasteboard = MacPasteboardService()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, settings: settings)
        monitor.start()

        defer {
            monitor.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? manager.removeItem(at: workspace)
        }
        try await waitForClipboard(store)
        try await populate(store)
        let provider = ClipboardProvider(store: store, pasteboard: pasteboard)
        let coordinator = QueryCoordinator(providers: [provider])
        for index in 0..<10 {
            try await runQuery(index: index, coordinator: coordinator)
        }
        try writeReadyMarker(to: options.readyFile)

        let deadline = ContinuousClock.now.advanced(by: options.duration)
        var iteration = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if iteration.isMultiple(of: 10) {
                let captured = await store.capture(
                    .text("soak rolling item \(iteration)"),
                    sourceBundleIdentifier: "com.keyestro.launcher.packaged-soak"
                )
                guard case .success = captured else { throw PackagedSoakError.clipboardFixtureFailed }
            }
            try await runQuery(index: iteration, coordinator: coordinator)
            iteration += 1
            try await Task.sleep(for: .seconds(1))
        }
        await coordinator.cancelCurrentSearch()
        monitor.stop()
        await store.initialize(enabled: false)
        await database.close()
    }

    private static func waitForClipboard(_ store: ClipboardStore) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            switch await store.currentState() {
            case .ready:
                return
            case .failed, .keyMissing:
                throw PackagedSoakError.clipboardInitializationFailed
            case .disabled, .loading:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw PackagedSoakError.clipboardInitializationFailed
    }

    private static func populate(_ store: ClipboardStore) async throws {
        let base = Date().addingTimeInterval(-1_000)
        for index in 0..<1_000 {
            let result = await store.capture(
                .text("soak fixture item \(index) \(String(repeating: "x", count: 32))"),
                sourceBundleIdentifier: "com.keyestro.launcher.packaged-soak",
                at: base.addingTimeInterval(Double(index))
            )
            guard case .success = result else { throw PackagedSoakError.clipboardFixtureFailed }
        }
    }

    private static func runQuery(index: Int, coordinator: QueryCoordinator) async throws {
        let stream = await coordinator.search(rawText: "soak fixture item \(index % 1_000)")
        var completed = false
        for await snapshot in stream where snapshot.isComplete {
            completed = true
            break
        }
        guard completed else { throw PackagedSoakError.queryFailed }
    }

    private static func writeReadyMarker(to destination: URL) throws {
        let marker = PackagedSoakReadyMarker(
            schemaVersion: 1,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            clipboardEnabled: true,
            clipboardItemCount: 1_000,
            queryIntervalSeconds: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(marker).write(to: destination, options: .atomic)
    }
}
