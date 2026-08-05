import Foundation
import KeyestroCore
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor
func clipboardMonitorUsesEnergyAwarePollingAndSuspendsForSystemState() async throws {
    let fixture = try ClipboardMonitorFixture()
    defer { fixture.remove() }
    let pasteboard = MonitorPasteboard()
    let clock = MonitorClock()
    let monitor = ClipboardMonitor(
        store: fixture.store,
        pasteboard: pasteboard,
        settings: fixture.settings,
        clock: clock,
        frontmostBundleIdentifier: { "com.example.editor" }
    )
    fixture.settings.clipboardEnabled = true
    monitor.start()
    defer { monitor.stop() }

    try await waitUntil { await fixture.store.currentState() == .ready(itemCount: 0) }
    try await clock.waitForSleepRequest(count: 1)
    pasteboard.content = .text("captured before sleep")
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil { await fixture.contains("captured before sleep") }

    monitor.systemWillSleep()
    #expect(!monitor.isPolling)
    let sleepRequestsBeforeWake = await clock.requestCount()
    pasteboard.content = .text("must not capture while asleep")
    pasteboard.changeCount += 1
    await clock.advance(by: .seconds(10))
    #expect(await !fixture.contains("must not capture while asleep"))

    monitor.systemDidWake()
    #expect(monitor.isPolling)
    try await clock.waitForSleepRequest(count: sleepRequestsBeforeWake + 1)
    pasteboard.content = .text("captured after wake")
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil { await fixture.contains("captured after wake") }
}

@Test @MainActor
func clipboardMonitorBacksOffAndHonorsExcludedApplications() async throws {
    let fixture = try ClipboardMonitorFixture()
    defer { fixture.remove() }
    let pasteboard = MonitorPasteboard()
    let clock = MonitorClock()
    let monitor = ClipboardMonitor(
        store: fixture.store,
        pasteboard: pasteboard,
        settings: fixture.settings,
        clock: clock,
        frontmostBundleIdentifier: { "com.example.password-manager" }
    )
    fixture.settings.clipboardExcludedApplications = "com.example.password-manager"
    fixture.settings.clipboardEnabled = true
    monitor.start()
    defer { monitor.stop() }

    try await waitUntil { await fixture.store.currentState() == .ready(itemCount: 0) }
    for request in 1...119 {
        try await clock.waitForSleepRequest(count: request)
        await clock.advance(by: .milliseconds(500))
    }
    try await clock.waitForSleepRequest(count: 120)
    #expect(await clock.lastRequestedDuration() == .seconds(2))

    pasteboard.content = .text("excluded secret")
    pasteboard.changeCount += 1
    await clock.advance(by: .seconds(2))
    try await clock.waitForSleepRequest(count: 121)
    #expect(await !fixture.contains("excluded secret"))
    #expect(await clock.lastRequestedDuration() == .milliseconds(500))
}

@Test @MainActor
func clipboardPauseStopsCaptureButKeepsExistingHistorySearchable() async throws {
    let fixture = try ClipboardMonitorFixture()
    defer { fixture.remove() }
    let pasteboard = MonitorPasteboard()
    let clock = MonitorClock()
    let monitor = ClipboardMonitor(
        store: fixture.store,
        pasteboard: pasteboard,
        settings: fixture.settings,
        clock: clock,
        frontmostBundleIdentifier: { "com.example.editor" }
    )
    fixture.settings.clipboardEnabled = true
    monitor.start()
    defer { monitor.stop() }

    try await waitUntil(or: .pauseInitialStateTimedOut) {
        await fixture.store.currentState() == .ready(itemCount: 0)
    }
    try await clock.waitForSleepRequest(count: 1, or: .pauseInitialPollTimedOut)
    pasteboard.content = .text("history remains available")
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil(or: .pauseInitialCaptureTimedOut) {
        await fixture.contains("history remains available")
    }

    fixture.settings.clipboardPaused = true
    #expect(!monitor.isPolling)
    try await waitUntil(or: .pauseStateTimedOut) {
        await fixture.store.currentState() == .ready(itemCount: 1)
    }
    #expect(await fixture.contains("history remains available"))

    pasteboard.content = .text("not captured while paused")
    pasteboard.changeCount += 1
    await clock.advance(by: .seconds(10))
    #expect(await !fixture.contains("not captured while paused"))

    let sleepRequestsBeforeUnpausing = await clock.requestCount()
    fixture.settings.clipboardPaused = false
    #expect(monitor.isPolling)
    try await clock.waitForSleepRequest(
        count: sleepRequestsBeforeUnpausing + 1,
        or: .pauseRestartPollTimedOut
    )
    pasteboard.content = .text("captured after unpausing")
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil(or: .pauseResumedCaptureTimedOut) {
        await fixture.contains("captured after unpausing")
    }
}

@Test @MainActor
func clipboardMonitorSurfacesRejectedContentWithoutStoppingLaterCapture() async throws {
    let fixture = try ClipboardMonitorFixture()
    defer { fixture.remove() }
    let pasteboard = MonitorPasteboard()
    let clock = MonitorClock()
    var issue: ErrorDescriptor?
    let monitor = ClipboardMonitor(
        store: fixture.store,
        pasteboard: pasteboard,
        settings: fixture.settings,
        clock: clock,
        frontmostBundleIdentifier: { "com.example.editor" },
        onCaptureIssue: { issue = $0 }
    )
    fixture.settings.clipboardEnabled = true
    monitor.start()
    defer { monitor.stop() }

    try await waitUntil { await fixture.store.currentState() == .ready(itemCount: 0) }
    try await clock.waitForSleepRequest(count: 1)
    pasteboard.content = .text(String(repeating: "x", count: 2 * 1_024 * 1_024 + 1))
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil { issue != nil }
    #expect(issue?.code == "clipboard.textTooLarge")
    #expect(await fixture.store.currentState() == .ready(itemCount: 0))

    try await clock.waitForSleepRequest(count: 2)
    pasteboard.content = .text("capture continues after rejection")
    pasteboard.changeCount += 1
    await clock.advance(by: .milliseconds(500))
    try await waitUntil { await fixture.contains("capture continues after rejection") }
}

@MainActor
private final class MonitorPasteboard: PasteboardServicing {
    var changeCount = 0
    var content: ClipboardContent?

    func readSupportedContent() -> ClipboardContent? { content }
    func write(_ content: ClipboardContent) -> Bool {
        self.content = content
        changeCount += 1
        return true
    }
}

private actor MonitorClock: ClockServicing {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var instant = ContinuousClock.now
    private var wall = Date(timeIntervalSince1970: 1_700_000_000)
    private var sleepers: [UUID: Sleeper] = [:]
    private var requested: [Duration] = []

    func now() -> ContinuousClock.Instant { instant }
    func wallTime() -> Date { wall }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        requested.append(duration)
        let token = UUID()
        let deadline = instant.advanced(by: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[token] = Sleeper(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        let components = duration.components
        wall = wall.addingTimeInterval(
            Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
        let ready = sleepers.filter { $0.value.deadline <= instant }
        for (token, sleeper) in ready {
            sleepers[token] = nil
            sleeper.continuation.resume()
        }
    }

    func lastRequestedDuration() -> Duration? { requested.last }
    func requestCount() -> Int { requested.count }

    func waitForSleepRequest(
        count: Int,
        or failure: ClipboardMonitorTestError = .conditionTimedOut
    ) async throws {
        for _ in 0..<10_000 {
            if requested.count >= count { return }
            await Task.yield()
        }
        throw failure
    }

    private func cancel(_ token: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: token) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private struct ClipboardMonitorFixture {
    let root: URL
    let database: LauncherDatabase
    let store: ClipboardStore
    let defaultsName: String
    let settings: SettingsStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.tests.clipboard-monitor",
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
        )
        database = LauncherDatabase(paths: paths)
        store = ClipboardStore(
            database: database,
            keyManager: InstallationKeyManager(
                keychain: InMemoryKeychainService(),
                service: "com.keyestro.tests.clipboard-monitor"
            )
        )
        defaultsName = "com.keyestro.tests.clipboard-monitor.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw ClipboardMonitorTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsName)
        settings = SettingsStore(defaults: defaults)
    }

    func contains(_ query: String) async -> Bool {
        guard case let .success(items) = await store.search(query) else { return false }
        return !items.isEmpty
    }

    func remove() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ClipboardMonitorTestError: Error {
    case conditionTimedOut
    case defaultsUnavailable
    case pauseInitialStateTimedOut
    case pauseInitialPollTimedOut
    case pauseInitialCaptureTimedOut
    case pauseStateTimedOut
    case pauseRestartPollTimedOut
    case pauseResumedCaptureTimedOut
}

@MainActor
private func waitUntil(
    or failure: ClipboardMonitorTestError = .conditionTimedOut,
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw failure
}
