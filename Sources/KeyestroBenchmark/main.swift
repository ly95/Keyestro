import Darwin
import CryptoKit
import Foundation
import KeyestroCore
import KeyestroDomain
import SQLite3

private struct BenchmarkResult: Codable, Sendable {
    let id: String
    let requirementID: String
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let thresholdMilliseconds: Double
    let passed: Bool
}

private struct BenchmarkEnvironment: Codable, Sendable {
    let operatingSystem: String
    let architecture: String
    let hardwareModel: String
    let physicalMemoryBytes: UInt64
    let buildConfiguration: String
}

private struct BenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let iterations: Int
    let environment: BenchmarkEnvironment
    let executableSHA256: String
    let results: [BenchmarkResult]
}

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case invalidArguments(String)
    case operation(String)
    case threshold([String])

    var description: String {
        switch self {
        case let .invalidArguments(message), let .operation(message): message
        case let .threshold(ids): "Performance threshold failed: \(ids.joined(separator: ", "))"
        }
    }
}

private struct Options {
    var iterations = 30
    var output: URL?
    var requireThresholds = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--iterations":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]),
                    (1...100).contains(value)
                else { throw BenchmarkFailure.invalidArguments("--iterations must be between 1 and 100") }
                iterations = value
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkFailure.invalidArguments("--output requires a path")
                }
                output = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--require-thresholds":
                requireThresholds = true
            default:
                throw BenchmarkFailure.invalidArguments(
                    "usage: keyestro-benchmark [--iterations 30] [--output report.json] [--require-thresholds]"
                )
            }
            index += 1
        }
    }
}

private struct BenchmarkProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "benchmark",
        displayName: "Benchmark",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    let items: [LauncherItem]

    init(itemCount: Int) {
        let action = ActionDescriptor(id: "open", title: "Open")
        items = (0..<itemCount).map { index in
            LauncherItem(
                id: ItemID(providerID: "benchmark", providerStableID: "item-\(index)"),
                providerID: "benchmark",
                title: "Repository benchmark item \(index)",
                subtitle: "/benchmark/repository/\(index)",
                keywords: ["repository", "benchmark", "item"],
                actions: [action],
                defaultActionID: action.id
            )
        }
    }

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.items(items, isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult {
        .success()
    }
}

private struct NoopPerformanceRecorder: PerformanceRecording {
    func record(_ metric: PerformanceMetric, duration: Duration) async {}
}

@main
private enum KeyestroBenchmark {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let results = try await run(iterations: options.iterations)
            let report = BenchmarkReport(
                schemaVersion: 1,
                generatedAt: Date(),
                iterations: options.iterations,
                environment: environment(),
                executableSHA256: try executableSHA256(),
                results: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output = options.output {
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: output, options: .atomic)
                print(output.path)
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
            for result in results {
                print(
                    "\(result.requirementID) \(result.id): p50=\(format(result.p50Milliseconds))ms "
                        + "p95=\(format(result.p95Milliseconds))ms limit=\(format(result.thresholdMilliseconds))ms "
                        + (result.passed ? "PASS" : "FAIL")
                )
            }
            if options.requireThresholds {
                let failures = results.filter { !$0.passed }.map(\.requirementID)
                if !failures.isEmpty { throw BenchmarkFailure.threshold(failures) }
            }
        } catch {
            FileHandle.standardError.write(Data("keyestro-benchmark: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func run(iterations: Int) async throws -> [BenchmarkResult] {
        let query = try await benchmarkQuery(iterations: iterations)
        let spotlight = try await benchmarkSpotlight(iterations: iterations)
        let clipboard = try await benchmarkClipboard(iterations: iterations)
        let migration = try await benchmarkMigration(iterations: iterations)
        return [query, spotlight, clipboard, migration]
    }

    private static func benchmarkQuery(iterations: Int) async throws -> BenchmarkResult {
        let provider = BenchmarkProvider(itemCount: 500)
        let coordinator = QueryCoordinator(
            providers: [provider],
            performance: NoopPerformanceRecorder()
        )
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let startedAt = ContinuousClock.now
            let snapshots = await coordinator.search(rawText: "repository")
            var completed = false
            for await snapshot in snapshots where snapshot.isComplete {
                completed = true
            }
            guard completed else { throw BenchmarkFailure.operation("query benchmark did not complete") }
            samples.append(milliseconds(startedAt.duration(to: .now)))
        }
        return result(
            id: "aggregate-query-500",
            requirementID: "PERF-005",
            samples: samples,
            thresholdMilliseconds: 100
        )
    }

    private static func benchmarkClipboard(iterations: Int) async throws -> BenchmarkResult {
        let root = temporaryRoot(component: "clipboard")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.benchmark.clipboard",
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
        )
        let database = LauncherDatabase(paths: paths)
        let keys = InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.benchmark.clipboard"
        )
        let store = ClipboardStore(database: database, keyManager: keys)
        await store.initialize(enabled: true)
        for index in 0..<1_000 {
            let outcome = await store.capture(
                .text("benchmark needle-\(index) value \(String(repeating: "x", count: 32))"),
                sourceBundleIdentifier: "com.keyestro.benchmark",
                at: Date(timeIntervalSince1970: Double(index))
            )
            guard case .success = outcome else {
                throw BenchmarkFailure.operation("clipboard benchmark fixture could not be created")
            }
        }

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for index in 0..<iterations {
            let startedAt = ContinuousClock.now
            let outcome = await store.search("needle-\(index % 1_000)")
            guard case let .success(items) = outcome, !items.isEmpty else {
                throw BenchmarkFailure.operation("clipboard benchmark search returned no result")
            }
            samples.append(milliseconds(startedAt.duration(to: .now)))
        }
        await database.close()
        return result(
            id: "clipboard-search-1000",
            requirementID: "PERF-009",
            samples: samples,
            thresholdMilliseconds: 50
        )
    }

    private static func benchmarkSpotlight(iterations: Int) async throws -> BenchmarkResult {
        let spotlight = MDSpotlightService()
        let options = SpotlightSearchOptions()
        let probe = try await spotlightProbe(service: spotlight, options: options)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let startedAt = ContinuousClock.now
            let updates = await spotlight.searchFileUpdates(
                containing: probe,
                options: options,
                limit: DomainLimits.itemsPerBatch
            )
            var receivedInitialBatch = false
            for try await batch in updates where batch.phase == .initial {
                guard !batch.records.isEmpty else {
                    throw BenchmarkFailure.operation("Spotlight benchmark returned an empty initial batch")
                }
                samples.append(milliseconds(startedAt.duration(to: .now)))
                receivedInitialBatch = true
                break
            }
            guard receivedInitialBatch else {
                throw BenchmarkFailure.operation("Spotlight benchmark did not deliver an initial batch")
            }
        }
        return result(
            id: "spotlight-real-initial-batch",
            requirementID: "PERF-004",
            samples: samples,
            thresholdMilliseconds: 300
        )
    }

    private static func spotlightProbe(
        service: MDSpotlightService,
        options: SpotlightSearchOptions
    ) async throws -> String {
        for candidate in ["a", "e", "i", "o", "1", "."] {
            let records = try await service.searchFiles(containing: candidate, options: options, limit: 50)
            guard let first = records.first else { continue }
            let probe = first.displayName.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
            if !probe.isEmpty { return probe }
        }
        throw BenchmarkFailure.operation(
            "Spotlight benchmark needs at least one indexed file in Desktop, Documents, Downloads, Movies, Music, Pictures, or Public"
        )
    }

    private static func benchmarkMigration(iterations: Int) async throws -> BenchmarkResult {
        let root = temporaryRoot(component: "migration")
        defer { try? FileManager.default.removeItem(at: root) }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for iteration in 0..<iterations {
            let iterationRoot = root.appendingPathComponent("run-\(iteration)", isDirectory: true)
            let paths = try AppPaths(
                bundleIdentifier: "com.keyestro.benchmark.migration",
                applicationSupportRoot: iterationRoot.appendingPathComponent("support", isDirectory: true),
                cachesRoot: iterationRoot.appendingPathComponent("cache", isDirectory: true)
            )
            try paths.prepare()
            try createLegacyDatabase(at: paths.database)
            let database = LauncherDatabase(paths: paths)
            let startedAt = ContinuousClock.now
            try await database.prepare()
            samples.append(milliseconds(startedAt.duration(to: .now)))
            await database.close()
            try FileManager.default.removeItem(at: iterationRoot)
        }
        return result(
            id: "database-migration-10000",
            requirementID: "PERF-010",
            samples: samples,
            thresholdMilliseconds: 2_000
        )
    }

    private static func createLegacyDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw BenchmarkFailure.operation("legacy benchmark database could not be opened")
        }
        defer { sqlite3_close_v2(handle) }
        let sql = """
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
            BEGIN IMMEDIATE;
            WITH RECURSIVE sequence(value) AS (
              SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 10000
            )
            INSERT INTO quicklinks(id,title,url_template,arguments_json,keywords_json,created_at,updated_at)
            SELECT printf('id-%05d', value), printf('Title %05d', value),
                   'https://example.invalid/{query}', x'7B7D', x'5B5D', value, value
            FROM sequence;
            COMMIT;
            """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw BenchmarkFailure.operation("legacy benchmark database fixture failed")
        }
    }

    private static func result(
        id: String,
        requirementID: String,
        samples: [Double],
        thresholdMilliseconds: Double
    ) -> BenchmarkResult {
        let sorted = samples.sorted()
        let p50 = percentile(0.50, sorted: sorted)
        let p95 = percentile(0.95, sorted: sorted)
        return BenchmarkResult(
            id: id,
            requirementID: requirementID,
            sampleCount: sorted.count,
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            maximumMilliseconds: sorted.last ?? 0,
            thresholdMilliseconds: thresholdMilliseconds,
            passed: p95 <= thresholdMilliseconds
        )
    }

    private static func percentile(_ fraction: Double, sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func temporaryRoot(component: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyestroBenchmark-\(component)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func environment() -> BenchmarkEnvironment {
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        return BenchmarkEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName(),
            hardwareModel: systemControlString("hw.model") ?? "unknown",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            buildConfiguration: configuration
        )
    }

    private static func architectureName() -> String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static func systemControlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func executableSHA256() throws -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
