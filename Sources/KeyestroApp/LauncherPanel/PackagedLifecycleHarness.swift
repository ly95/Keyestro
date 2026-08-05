import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain

private struct PackagedLifecycleOptions {
    let iterations: Int
    let output: URL

    init(arguments: [String]) throws {
        var iterations: Int?
        var output: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--iterations":
                index += 1
                guard index < arguments.count,
                    let value = Int(arguments[index]),
                    (1...10_000).contains(value)
                else { throw PackagedLifecycleError.invalidArguments }
                iterations = value
            case "--output":
                index += 1
                guard index < arguments.count else { throw PackagedLifecycleError.invalidArguments }
                output = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            default:
                throw PackagedLifecycleError.invalidArguments
            }
            index += 1
        }
        guard let iterations, let output else { throw PackagedLifecycleError.invalidArguments }
        self.iterations = iterations
        self.output = output
    }
}

private struct PackagedLifecycleReport: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let iterations: Int
    let elapsedSeconds: Double
    let initialWindowCount: Int
    let baselineWindowCount: Int
    let maximumWindowCount: Int
    let finalWindowCount: Int
    let baselineVisibleWindowCount: Int
    let maximumVisibleWindowCount: Int
    let finalVisibleWindowCount: Int
    let baselineLauncherPanelCount: Int
    let maximumLauncherPanelCount: Int
    let finalLauncherPanelCount: Int
    let baselineWindowInventory: [String: Int]
    let maximumWindowInventory: [String: Int]
    let finalWindowInventory: [String: Int]
    let panelVisibleAfterCompletion: Bool
    let releaseEligible: Bool
    let passed: Bool
}

private enum PackagedLifecycleError: Error {
    case invalidArguments
    case panelDidNotShow(Int)
    case panelDidNotDismiss(Int)
    case outputCreationFailed
}

@MainActor
enum PackagedLifecycleHarness {
    static func run(arguments: [String]) async throws {
        let options = try PackagedLifecycleOptions(arguments: arguments)
        let suiteName = "com.keyestro.launcher.lifecycle.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PackagedLifecycleError.outputCreationFailed
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = LifecycleProvider()
        let coordinator = QueryCoordinator(providers: [provider])
        let settings = SettingsStore(defaults: defaults)
        let model = LauncherViewModel(
            coordinator: coordinator,
            actionRunner: ActionRunner(providers: [provider]),
            settings: settings
        )
        let controller = LauncherPanelController(viewModel: model, restoresPreviousApplication: false)
        // Establish AppKit/SwiftUI's one-time helper windows before checking for sustained growth.
        // A yield-only warm-up can dismiss the panel before SwiftUI services the first display pass,
        // which makes a legitimate helper window appear after the baseline and look like a leak.
        var baselineWindowCount = NSApplication.shared.windows.count
        var baselineVisibleWindowCount = visibleWindowCount()
        var baselineLauncherPanelCount = LauncherPanelController.launcherPanelWindowCount()
        var baselineWindowInventory = windowInventory()
        // Exercise the full presentation/query/dismiss path for roughly six seconds.
        // AppKit can lazily create an invisible SPRoundedWindow several seconds after
        // the first presentation; it belongs in the baseline, not in the measured loop.
        for _ in 0..<40 {
            controller.show()
            try await Task.sleep(for: .milliseconds(100))
            if NSApplication.shared.windows.count >= baselineWindowCount {
                baselineWindowCount = NSApplication.shared.windows.count
                baselineWindowInventory = windowInventory()
            }
            baselineVisibleWindowCount = max(baselineVisibleWindowCount, visibleWindowCount())
            baselineLauncherPanelCount = max(
                baselineLauncherPanelCount,
                LauncherPanelController.launcherPanelWindowCount()
            )
            controller.dismiss()
            await coordinator.cancelCurrentSearch()
            try await Task.sleep(for: .milliseconds(50))
            if NSApplication.shared.windows.count >= baselineWindowCount {
                baselineWindowCount = NSApplication.shared.windows.count
                baselineWindowInventory = windowInventory()
            }
            baselineVisibleWindowCount = max(baselineVisibleWindowCount, visibleWindowCount())
            baselineLauncherPanelCount = max(
                baselineLauncherPanelCount,
                LauncherPanelController.launcherPanelWindowCount()
            )
        }
        controller.dismiss()
        await coordinator.cancelCurrentSearch()
        try await waitForStableWindowCount()
        let initialWindowCount = NSApplication.shared.windows.count
        if initialWindowCount >= baselineWindowCount {
            baselineWindowCount = initialWindowCount
            baselineWindowInventory = windowInventory()
        }
        var maximumWindowCount = baselineWindowCount
        var maximumVisibleWindowCount = baselineVisibleWindowCount
        var maximumLauncherPanelCount = baselineLauncherPanelCount
        var maximumWindowInventory = baselineWindowInventory
        let startedAt = ContinuousClock.now

        for iteration in 0..<options.iterations {
            let priorFirstFrameGeneration = controller.firstFrameGeneration
            controller.show()
            guard controller.isVisible else { throw PackagedLifecycleError.panelDidNotShow(iteration) }
            try await waitForFirstFrame(
                controller,
                after: priorFirstFrameGeneration,
                iteration: iteration
            )
            if NSApplication.shared.windows.count > maximumWindowCount {
                maximumWindowCount = NSApplication.shared.windows.count
                maximumWindowInventory = windowInventory()
            }
            maximumVisibleWindowCount = max(maximumVisibleWindowCount, visibleWindowCount())
            maximumLauncherPanelCount = max(
                maximumLauncherPanelCount,
                LauncherPanelController.launcherPanelWindowCount()
            )
            controller.dismiss()
            guard !controller.isVisible else { throw PackagedLifecycleError.panelDidNotDismiss(iteration) }
            // Drain the just-dismissed generation instead of accumulating thousands of
            // unstructured cancellation tasks behind the presentation pipeline.
            await coordinator.cancelCurrentSearch()
            if NSApplication.shared.windows.count > maximumWindowCount {
                maximumWindowCount = NSApplication.shared.windows.count
                maximumWindowInventory = windowInventory()
            }
            maximumVisibleWindowCount = max(maximumVisibleWindowCount, visibleWindowCount())
            maximumLauncherPanelCount = max(
                maximumLauncherPanelCount,
                LauncherPanelController.launcherPanelWindowCount()
            )
            if iteration.isMultiple(of: 100) {
                await Task.yield()
            }
        }
        await coordinator.cancelCurrentSearch()
        for _ in 0..<10 { await Task.yield() }
        if NSApplication.shared.windows.count > maximumWindowCount {
            maximumWindowCount = NSApplication.shared.windows.count
            maximumWindowInventory = windowInventory()
        }
        let finalWindowCount = NSApplication.shared.windows.count
        let finalVisibleWindowCount = visibleWindowCount()
        let finalLauncherPanelCount = LauncherPanelController.launcherPanelWindowCount()
        let finalWindowInventory = windowInventory()
        let elapsedSeconds = seconds(startedAt.duration(to: .now))
        let passed = Self.windowCountsPass(
            panelVisibleAfterCompletion: controller.isVisible,
            baselineWindowCount: baselineWindowCount,
            maximumWindowCount: maximumWindowCount,
            finalWindowCount: finalWindowCount,
            baselineVisibleWindowCount: baselineVisibleWindowCount,
            maximumVisibleWindowCount: maximumVisibleWindowCount,
            finalVisibleWindowCount: finalVisibleWindowCount,
            baselineLauncherPanelCount: baselineLauncherPanelCount,
            maximumLauncherPanelCount: maximumLauncherPanelCount,
            finalLauncherPanelCount: finalLauncherPanelCount
        )
        let report = PackagedLifecycleReport(
            schemaVersion: 1,
            generatedAt: Date(),
            iterations: options.iterations,
            elapsedSeconds: elapsedSeconds,
            initialWindowCount: initialWindowCount,
            baselineWindowCount: baselineWindowCount,
            maximumWindowCount: maximumWindowCount,
            finalWindowCount: finalWindowCount,
            baselineVisibleWindowCount: baselineVisibleWindowCount,
            maximumVisibleWindowCount: maximumVisibleWindowCount,
            finalVisibleWindowCount: finalVisibleWindowCount,
            baselineLauncherPanelCount: baselineLauncherPanelCount,
            maximumLauncherPanelCount: maximumLauncherPanelCount,
            finalLauncherPanelCount: finalLauncherPanelCount,
            baselineWindowInventory: baselineWindowInventory,
            maximumWindowInventory: maximumWindowInventory,
            finalWindowInventory: finalWindowInventory,
            panelVisibleAfterCompletion: controller.isVisible,
            releaseEligible: options.iterations == 10_000,
            passed: passed
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
        if !passed { throw PackagedLifecycleError.outputCreationFailed }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func windowInventory() -> [String: Int] {
        var inventory: [String: Int] = [:]
        for window in NSApplication.shared.windows {
            let key = "\(String(describing: type(of: window)))|level=\(window.level.rawValue)|visible=\(window.isVisible)"
            inventory[key, default: 0] += 1
        }
        return inventory
    }

    private static func visibleWindowCount() -> Int {
        NSApplication.shared.windows.count(where: \.isVisible)
    }

    static func windowCountsPass(
        panelVisibleAfterCompletion: Bool,
        baselineWindowCount: Int,
        maximumWindowCount: Int,
        finalWindowCount: Int,
        baselineVisibleWindowCount: Int,
        maximumVisibleWindowCount: Int,
        finalVisibleWindowCount: Int,
        baselineLauncherPanelCount: Int,
        maximumLauncherPanelCount: Int,
        finalLauncherPanelCount: Int
    ) -> Bool {
        let transientInvisibleSystemWindowAllowance = 1
        return !panelVisibleAfterCompletion
            && maximumWindowCount <= baselineWindowCount + transientInvisibleSystemWindowAllowance
            && finalWindowCount <= baselineWindowCount
            && maximumVisibleWindowCount <= baselineVisibleWindowCount
            && finalVisibleWindowCount == 0
            && maximumLauncherPanelCount <= baselineLauncherPanelCount
            && finalLauncherPanelCount <= baselineLauncherPanelCount
    }

    private static func waitForStableWindowCount() async throws {
        var previousCount = -1
        var consecutiveStableSamples = 0
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(25))
            let currentCount = NSApplication.shared.windows.count
            if currentCount == previousCount {
                consecutiveStableSamples += 1
                if consecutiveStableSamples >= 12 { return }
            } else {
                previousCount = currentCount
                consecutiveStableSamples = 0
            }
        }
        throw PackagedLifecycleError.outputCreationFailed
    }

    private static func waitForFirstFrame(
        _ controller: LauncherPanelController,
        after generation: UInt64,
        iteration: Int
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if controller.firstFrameGeneration > generation { return }
            // Sleeping briefly lets AppKit service the staged DispatchQueue.main
            // presentation blocks. Repeated Task.yield() calls can unfairly resume
            // this MainActor task and starve those blocks under a long soak.
            try await Task.sleep(for: .milliseconds(1))
        }
        throw PackagedLifecycleError.panelDidNotShow(iteration)
    }
}

private struct LifecycleProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "packaged-lifecycle",
        displayName: "Packaged Lifecycle",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.items([], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult { .success() }
}
