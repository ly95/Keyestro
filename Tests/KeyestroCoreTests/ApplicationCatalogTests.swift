import Foundation
import Testing
@testable import KeyestroCore

private struct ApplicationDiscoveryFake: ApplicationDiscovering {
    let urls: [URL]
    func discoverApplicationURLs(limit: Int) async throws -> [URL] { Array(urls.prefix(limit)) }
}

@Test func applicationCatalogMergesSpotlightApplicationsAndFiltersNestedHelpers() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-catalog-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("Custom.app", isDirectory: true)
    let helper = custom.appendingPathComponent("Contents/Library/LoginItems/Helper.app", isDirectory: true)
    try makeApplicationBundle(custom, identifier: "com.example.custom", backgroundOnly: false)
    try makeApplicationBundle(helper, identifier: "com.example.helper", backgroundOnly: false)

    let catalog = ApplicationCatalog(
        roots: [],
        cacheLifetime: 10,
        discovery: ApplicationDiscoveryFake(urls: [custom, helper])
    )
    let records = await catalog.records()
    #expect(records.map(\.bundleIdentifier) == ["com.example.custom"])
}

@Test func applicationCatalogIndexesAUserRenamedBundleAsAnAlias() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-alias-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let renamed = root.appendingPathComponent("My Browser.app", isDirectory: true)
    try makeApplicationBundle(
        renamed,
        identifier: "com.example.original-browser",
        backgroundOnly: false,
        bundleName: "Original Browser"
    )
    let catalog = ApplicationCatalog(roots: [], discovery: ApplicationDiscoveryFake(urls: [renamed]))
    let record = try #require(await catalog.records().first)
    #expect(record.displayName == "Original Browser")
    #expect(record.aliases.contains("My Browser"))
}

@Test func applicationCatalogAppliesLiveInstallAndRemovalWithoutRepeatingAFullDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("First.app", isDirectory: true)
    let second = root.appendingPathComponent("Second.app", isDirectory: true)
    try makeApplicationBundle(first, identifier: "com.example.first", backgroundOnly: false)
    try makeApplicationBundle(second, identifier: "com.example.second", backgroundOnly: false)

    let discovery = LiveApplicationDiscoveryFake(initial: [first])
    let catalog = ApplicationCatalog(roots: [], cacheLifetime: 3_600, discovery: discovery)
    #expect(await catalog.records().map(\.bundleIdentifier) == ["com.example.first"])
    await discovery.waitUntilSubscribed()

    await discovery.publish([first, second])
    try await waitForApplicationCatalog {
        await catalog.record(stableID: "com.example.second") != nil
    }
    #expect(await discovery.discoveryCount == 1)

    try FileManager.default.removeItem(at: first)
    await discovery.publish([second])
    try await waitForApplicationCatalog {
        await catalog.record(stableID: "com.example.first") == nil
    }
    #expect(await catalog.records().map(\.bundleIdentifier) == ["com.example.second"])
    #expect(await discovery.discoveryCount == 1)
}

@Test func applicationCatalogRevalidatesAnApplicationReplacedAtTheSamePath() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-replacement-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Replaced.app", isDirectory: true)
    try makeApplicationBundle(application, identifier: "com.example.before", backgroundOnly: false)
    let discovery = LiveApplicationDiscoveryFake(initial: [application])
    let catalog = ApplicationCatalog(roots: [], cacheLifetime: 3_600, discovery: discovery)
    #expect(await catalog.records().map(\.bundleIdentifier) == ["com.example.before"])
    await discovery.waitUntilSubscribed()

    try FileManager.default.removeItem(at: application)
    try makeApplicationBundle(application, identifier: "com.example.after", backgroundOnly: false)
    await discovery.publish([application])
    try await waitForApplicationCatalog {
        await catalog.record(stableID: "com.example.after") != nil
    }

    #expect(await catalog.record(stableID: "com.example.before") == nil)
    #expect(await catalog.records().map(\.bundleIdentifier) == ["com.example.after"])
    #expect(await discovery.discoveryCount == 1)
}

@Test func applicationActionResolutionRejectsAnUnobservedSamePathIdentityReplacement() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-action-replacement-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Target.app", isDirectory: true)
    try makeApplicationBundle(application, identifier: "com.example.expected", backgroundOnly: false)
    let catalog = ApplicationCatalog(
        roots: [],
        cacheLifetime: 3_600,
        discovery: ApplicationDiscoveryFake(urls: [application])
    )
    #expect(await catalog.records().map(\.stableID) == ["com.example.expected"])

    try FileManager.default.removeItem(at: application)
    try makeApplicationBundle(application, identifier: "com.example.substitute", backgroundOnly: false)

    #expect(await catalog.record(stableID: "com.example.expected") == nil)
    #expect(await catalog.record(stableID: "com.example.substitute")?.url == application)
}

@Test func concurrentApplicationCatalogRefreshesShareOneDiscovery() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-refresh-order-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let newer = root.appendingPathComponent("Newer.app", isDirectory: true)
    try makeApplicationBundle(newer, identifier: "com.example.newer", backgroundOnly: false)
    let discovery = ControlledApplicationDiscoveryFake()
    let catalog = ApplicationCatalog(roots: [], cacheLifetime: 3_600, discovery: discovery)

    let first = Task { await catalog.records(forceRefresh: true) }
    await discovery.waitForRequest(1)
    let second = Task { await catalog.records(forceRefresh: true) }
    for _ in 0..<100 { await Task.yield() }

    #expect(await discovery.requestsStarted() == 1)
    await discovery.completeRequest(1, with: [newer])
    #expect(await second.value.map(\.stableID) == ["com.example.newer"])
    #expect(await first.value.map(\.stableID) == ["com.example.newer"])
    #expect(await catalog.records().map(\.stableID) == ["com.example.newer"])
}

@Test func cancellingAColdApplicationCatalogWaiterReturnsWithoutCancellingSharedRefresh() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-app-cancelled-refresh-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("Later.app", isDirectory: true)
    try makeApplicationBundle(application, identifier: "com.example.later", backgroundOnly: false)
    let discovery = ControlledApplicationDiscoveryFake()
    let catalog = ApplicationCatalog(roots: [], cacheLifetime: 3_600, discovery: discovery)

    let cancelled = Task { await catalog.records(forceRefresh: true) }
    await discovery.waitForRequest(1)
    cancelled.cancel()
    #expect((await cancelled.value).isEmpty)

    let surviving = Task { await catalog.records(forceRefresh: true) }
    for _ in 0..<100 { await Task.yield() }
    #expect(await discovery.requestsStarted() == 1)
    await discovery.completeRequest(1, with: [application])
    #expect(await surviving.value.map(\.stableID) == ["com.example.later"])
}

private actor LiveApplicationDiscoveryFake: ApplicationDiscovering {
    private let initial: [URL]
    private var continuation: AsyncThrowingStream<[URL], any Error>.Continuation?
    private(set) var discoveryCount = 0

    init(initial: [URL]) {
        self.initial = initial
    }

    func discoverApplicationURLs(limit: Int) -> [URL] {
        discoveryCount += 1
        return Array(initial.prefix(limit))
    }

    func applicationURLUpdates(limit: Int) -> AsyncThrowingStream<[URL], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[URL], any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        self.continuation = continuation
        return stream
    }

    func publish(_ urls: [URL]) {
        continuation?.yield(urls)
    }

    func waitUntilSubscribed() async {
        while continuation == nil { await Task.yield() }
    }
}

private actor ControlledApplicationDiscoveryFake: ApplicationDiscovering {
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<[URL], any Error>] = [:]

    func discoverApplicationURLs(limit: Int) async throws -> [URL] {
        requestCount += 1
        let request = requestCount
        return try await withCheckedThrowingContinuation { continuations[request] = $0 }
    }

    func waitForRequest(_ request: Int) async {
        while continuations[request] == nil { await Task.yield() }
    }

    func requestsStarted() -> Int { requestCount }

    func completeRequest(_ request: Int, with urls: [URL]) {
        continuations.removeValue(forKey: request)?.resume(returning: urls)
    }
}

private enum ApplicationCatalogTestError: Error {
    case conditionTimedOut
}

private func waitForApplicationCatalog(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw ApplicationCatalogTestError.conditionTimedOut
}

private func makeApplicationBundle(
    _ root: URL,
    identifier: String,
    backgroundOnly: Bool,
    bundleName: String? = nil
) throws {
    let executableDirectory = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    let executable = executableDirectory.appendingPathComponent("Example")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let info: [String: Any] = [
        "CFBundleIdentifier": identifier,
        "CFBundleName": bundleName ?? root.deletingPathExtension().lastPathComponent,
        "CFBundleDisplayName": bundleName ?? root.deletingPathExtension().lastPathComponent,
        "CFBundleExecutable": "Example",
        "CFBundlePackageType": "APPL",
        "LSBackgroundOnly": backgroundOnly,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
}
