import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain

private struct PackagedUIPerformanceOptions {
    let iterations: Int
    let output: URL

    init(arguments: [String]) throws {
        var iterations = 1
        var output: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--iterations":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]),
                    (1...100).contains(value)
                else { throw PackagedUIPerformanceError.invalidArguments }
                iterations = value
            case "--output":
                index += 1
                guard index < arguments.count else { throw PackagedUIPerformanceError.invalidArguments }
                output = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                throw PackagedUIPerformanceError.invalidArguments
            }
            index += 1
        }
        guard let output else { throw PackagedUIPerformanceError.invalidArguments }
        self.iterations = iterations
        self.output = output
    }
}

private struct PackagedUIPerformanceEnvironment: Codable, Sendable {
    let operatingSystem: String
    let architecture: String
    let physicalMemoryBytes: UInt64
    let buildConfiguration: String
}

private struct PackagedUIPerformanceSamples: Codable, Sendable {
    let coldStartMilliseconds: [Double]
    let hotInvocationMilliseconds: [Double]
    let cachedFirstBatchMilliseconds: [Double]
    let inputToRenderedUIMilliseconds: [Double]
    let mainThreadSegmentMilliseconds: [Double]
}

private struct PackagedUIPerformanceReport: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let environment: PackagedUIPerformanceEnvironment
    let samples: PackagedUIPerformanceSamples
}

private enum PackagedUIPerformanceError: Error {
    case invalidArguments
    case conditionTimedOut(String)
    case outputCreationFailed
}

@MainActor
enum PackagedUIPerformanceHarness {
    static func run(arguments: [String], processStartedAt: ContinuousClock.Instant) async throws {
        let options = try PackagedUIPerformanceOptions(arguments: arguments)
        let suiteName = "com.keyestro.launcher.packaged-ui-performance.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PackagedUIPerformanceError.outputCreationFailed
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = UIPerformanceProvider()
        let coordinator = QueryCoordinator(providers: [provider])
        let settings = SettingsStore(defaults: defaults)
        let model = LauncherViewModel(
            coordinator: coordinator,
            actionRunner: ActionRunner(providers: [provider]),
            settings: settings
        )
        let controller = LauncherPanelController(viewModel: model, restoresPreviousApplication: false)
        var mainThreadSegments: [Double] = []

        let coldFrame = try await showAndWaitForFirstFrame(controller)
        mainThreadSegments.append(contentsOf: coldFrame.mainThreadSegments.map(milliseconds))
        try await wait("cold cached result") {
            model.results.first?.item.id.providerStableID == "empty" && !model.isSearching
        }
        let coldStart = coldStartMilliseconds(processStartedAt: processStartedAt)

        var hotInvocations: [Double] = []
        var cachedFirstBatches: [Double] = []
        var inputToRenderedUI: [Double] = []
        for iteration in 0..<options.iterations {
            controller.dismiss()
            await Task.yield()

            let frame = try await showAndWaitForFirstFrame(controller)
            let invocation = milliseconds(frame.invokeToFirstFrame)
            hotInvocations.append(invocation)
            cachedFirstBatches.append(invocation)
            mainThreadSegments.append(contentsOf: frame.mainThreadSegments.map(milliseconds))

            let token = "perf-\(iteration)-\(UUID().uuidString.lowercased())"
            let queryStartedAt = ContinuousClock.now
            let queryMutationStartedAt = ContinuousClock.now
            model.queryDidChange(token, isComposing: false)
            mainThreadSegments.append(milliseconds(queryMutationStartedAt.duration(to: .now)))
            try await wait("rendered query result") {
                model.results.first?.item.id.providerStableID == token && !model.isSearching
            }
            let displayStartedAt = ContinuousClock.now
            controller.displayIfNeeded()
            mainThreadSegments.append(milliseconds(displayStartedAt.duration(to: .now)))
            inputToRenderedUI.append(milliseconds(queryStartedAt.duration(to: .now)))
        }
        controller.dismiss()

        let report = PackagedUIPerformanceReport(
            schemaVersion: 1,
            generatedAt: Date(),
            environment: environment(),
            samples: PackagedUIPerformanceSamples(
                coldStartMilliseconds: [coldStart],
                hotInvocationMilliseconds: hotInvocations,
                cachedFirstBatchMilliseconds: cachedFirstBatches,
                inputToRenderedUIMilliseconds: inputToRenderedUI,
                mainThreadSegmentMilliseconds: mainThreadSegments
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try FileManager.default.createDirectory(
            at: options.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: options.output, options: .atomic)
    }

    private static func wait(
        _ name: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        throw PackagedUIPerformanceError.conditionTimedOut(name)
    }

    private static func showAndWaitForFirstFrame(
        _ controller: LauncherPanelController
    ) async throws -> (
        invokeToFirstFrame: Duration,
        mainThreadSegments: [Duration]
    ) {
        let priorGeneration = controller.firstFrameGeneration
        controller.show()
        try await wait("first frame") {
            controller.firstFrameGeneration > priorGeneration
        }
        guard
            let invokeToFirstFrame = controller.lastInvokeToFirstFrameDuration,
            controller.lastFirstFrameMainThreadSegment != nil,
            !controller.lastPresentationMainThreadSegments.isEmpty
        else { throw PackagedUIPerformanceError.conditionTimedOut("first frame metrics") }
        return (invokeToFirstFrame, controller.lastPresentationMainThreadSegments)
    }

    private static func coldStartMilliseconds(processStartedAt: ContinuousClock.Instant) -> Double {
        if let rawValue = ProcessInfo.processInfo.environment["KEYESTRO_BENCHMARK_LAUNCHED_AT"],
            let launchedAt = Double(rawValue),
            launchedAt.isFinite
        {
            let elapsed = (ProcessInfo.processInfo.systemUptime - launchedAt) * 1_000
            if (0...60_000).contains(elapsed) { return elapsed }
        }
        return milliseconds(processStartedAt.duration(to: .now))
    }

    private static func environment() -> PackagedUIPerformanceEnvironment {
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        #if arch(arm64)
            let architecture = "arm64"
        #elseif arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "unknown"
        #endif
        return PackagedUIPerformanceEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            buildConfiguration: configuration
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private struct UIPerformanceProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "packaged-ui-performance",
        displayName: "Packaged UI Performance",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let stableID = request.normalizedText.isEmpty ? "empty" : request.normalizedText
        let action = ActionDescriptor(id: "open", title: "Open")
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: stableID),
            providerID: descriptor.id,
            title: stableID == "empty" ? "Cached Application" : "Result \(stableID)",
            actions: [action],
            defaultActionID: action.id
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }
}
