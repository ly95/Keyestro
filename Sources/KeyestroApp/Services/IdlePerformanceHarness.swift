import AppKit
import Foundation
import KeyestroCore

private struct IdlePerformanceOptions {
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
                    (1...3_700).contains(value)
                else { throw IdlePerformanceHarnessError.invalidArguments }
                durationSeconds = value
            case "--ready-file":
                index += 1
                guard index < arguments.count else {
                    throw IdlePerformanceHarnessError.invalidArguments
                }
                readyFile = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                throw IdlePerformanceHarnessError.invalidArguments
            }
            index += 1
        }
        guard let durationSeconds, let readyFile else {
            throw IdlePerformanceHarnessError.invalidArguments
        }
        duration = .seconds(durationSeconds)
        self.readyFile = readyFile
    }
}

private struct IdlePerformanceReadyMarker: Codable {
    let schemaVersion: Int
    let processIdentifier: Int32
    let clipboardEnabled: Bool
    let clipboardStoreState: String
}

private enum IdlePerformanceHarnessError: Error {
    case invalidArguments
    case clipboardInitializationFailed(String)
}

/// Runs the actual packaged clipboard monitor against isolated persistence so an
/// external process can measure idle CPU and RSS without touching user data.
@MainActor
enum IdlePerformanceHarness {
    static func run(arguments: [String]) async throws {
        let options = try IdlePerformanceOptions(arguments: arguments)
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("keyestro-idle-performance-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "com.keyestro.launcher.idle-performance.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw IdlePerformanceHarnessError.clipboardInitializationFailed("isolated defaults unavailable")
        }
        defaults.removePersistentDomain(forName: defaultsName)

        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.launcher.idle-performance",
            applicationSupportRoot: workspace.appendingPathComponent("ApplicationSupport", isDirectory: true),
            cachesRoot: workspace.appendingPathComponent("Caches", isDirectory: true)
        )
        let database = LauncherDatabase(paths: paths)
        try await database.prepare()
        let keyManager = InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.launcher.idle-performance"
        )
        let store = ClipboardStore(database: database, keyManager: keyManager)
        let settings = SettingsStore(defaults: defaults)
        settings.clipboardEnabled = true
        settings.clipboardPaused = false
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: MacPasteboardService(),
            settings: settings
        )

        defer {
            monitor.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? manager.removeItem(at: workspace)
        }
        monitor.start()
        try await waitUntilReady(store: store)
        try writeReadyMarker(to: options.readyFile)
        try await Task.sleep(for: options.duration)
        monitor.stop()
        await store.initialize(enabled: false)
        await database.close()
    }

    private static func waitUntilReady(store: ClipboardStore) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            switch await store.currentState() {
            case .ready:
                return
            case let .failed(error):
                throw IdlePerformanceHarnessError.clipboardInitializationFailed(error.code)
            case let .keyMissing(count):
                throw IdlePerformanceHarnessError.clipboardInitializationFailed("key missing for \(count) items")
            case .disabled, .loading:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw IdlePerformanceHarnessError.clipboardInitializationFailed("initialization timed out")
    }

    private static func writeReadyMarker(to destination: URL) throws {
        let marker = IdlePerformanceReadyMarker(
            schemaVersion: 1,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            clipboardEnabled: true,
            clipboardStoreState: "ready"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }
}
