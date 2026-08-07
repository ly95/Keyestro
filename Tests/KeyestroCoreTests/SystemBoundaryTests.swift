import Foundation
import Testing
@testable import KeyestroCore

@Test func managedScriptInstallerUsesTheInjectedFileSystemBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-filesystem-boundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.filesystem-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let source = URL(fileURLWithPath: "/virtual/keyestro-script")
    let fileSystem = FakeFileSystemService()
    await fileSystem.addFile(at: source, data: Data("#!/bin/sh\nexit 0\n".utf8), executable: true)
    let store = InMemoryScriptStore()
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)

    let definition = try await installer.install(from: source, title: "Boundary Script")
    let installedURL = URL(fileURLWithPath: definition.executablePath)
    let metadata = await fileSystem.metadata(at: installedURL)
    #expect(metadata?.isRegularFile == true)
    #expect(metadata?.isExecutable == true)
    #expect(metadata?.posixPermissions == 0o700)
    #expect(try await fileSystem.sha256Digest(at: installedURL, maximumBytes: 1_024) == definition.contentHash)
    #expect(await store.script(id: definition.id) == definition)

    try await installer.remove(definition)
    #expect(await fileSystem.metadata(at: installedURL) == nil)
    #expect(await store.script(id: definition.id) == nil)
}

@Test func managedScriptRemovalRejectsAStoredPathBelongingToAnotherRegistration() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-script-removal-boundary-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.script-removal-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let fileSystem = FakeFileSystemService()
    let otherDirectory = paths.managedScripts.appendingPathComponent("other-registration", isDirectory: true)
    let executable = otherDirectory.appendingPathComponent("script", isDirectory: false)
    await fileSystem.addFile(at: executable, data: Data("preserve".utf8), executable: true)
    let definition = try ScriptDefinition(
        id: "requested-registration",
        title: "Mismatched",
        executablePath: executable.path,
        contentHash: String(repeating: "a", count: 64)
    )
    let store = InMemoryScriptStore(scripts: [definition])
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)

    await #expect(throws: ProcessServiceError.invalidExecutable) { try await installer.remove(definition) }
    #expect(await store.script(id: definition.id) == definition)
    #expect(await fileSystem.metadata(at: executable) != nil)
}

@Test func disabledNetworkBoundaryFailsClosedWithoutMakingARequest() async throws {
    let service = DisabledNetworkService()
    let url = try #require(URL(string: "https://example.invalid"))
    await #expect(throws: NetworkServiceError.disabled) {
        try await service.send(NetworkRequest(url: url))
    }
}

@Test func networkRequestBoundsTimeoutAndResponseSize() throws {
    let url = try #require(URL(string: "https://example.invalid"))
    let request = NetworkRequest(
        url: url,
        timeout: .seconds(600),
        maximumResponseBytes: Int.max
    )
    #expect(request.timeout == .seconds(60))
    #expect(request.maximumResponseBytes == 25 * 1_024 * 1_024)
}

@Test func fakeNetworkBoundaryRecordsOnlyExplicitRequests() async throws {
    let url = try #require(URL(string: "https://updates.example.invalid/feed"))
    let response = NetworkResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data("{}".utf8)
    )
    let network = FakeNetworkService(response: .success(response))
    let request = NetworkRequest(url: url)

    #expect(try await network.send(request) == response)
    #expect(await network.requests == [request])
}

@Test @MainActor func requiredUIBoundaryFakesDoNotTouchSystemState() async throws {
    let workspace = FakeWorkspaceService()
    let applicationURL = URL(fileURLWithPath: "/Applications/Fake.app")
    try await workspace.openApplication(at: applicationURL, bundleIdentifier: "com.example.fake")
    workspace.reveal(applicationURL)
    workspace.copyText("test")
    #expect(workspace.openedApplications.count == 1)
    #expect(workspace.revealedURLs == [applicationURL])
    #expect(workspace.copiedText == ["test"])

    let pasteboard = FakePasteboardService()
    #expect(pasteboard.write(.text("isolated")))
    #expect(pasteboard.readSupportedContent() == .text("isolated"))

    let updates = FakeUpdateService()
    updates.setChannel("beta")
    updates.checkForUpdates()
    #expect(updates.channel == "beta")
    #expect(updates.checkCount == 1)
}

@Test @MainActor func internalPasteboardBoundaryRegistersOnlyGenerationsItWrites() {
    let systemPasteboard = FakePasteboardService()
    let registry = ClipboardInternalWriteRegistry()
    let pasteboard = InternalWriteTrackingPasteboardService(
        pasteboard: systemPasteboard,
        internalWriteRegistry: registry
    )

    #expect(pasteboard.write(.text("internal")))
    #expect(registry.consume(changeCount: systemPasteboard.changeCount))
    #expect(!registry.consume(changeCount: systemPasteboard.changeCount))

    #expect(systemPasteboard.write(.text("external")))
    #expect(!registry.consume(changeCount: systemPasteboard.changeCount))
}

@Test func requiredAsyncBoundaryFakesAreControllable() async throws {
    let spotlight = FakeSpotlightService()
    #expect(try await spotlight.searchFiles(containing: "x", options: SpotlightSearchOptions(), limit: 10).isEmpty)

    let accessibility = FakeAccessibilityService(trusted: true)
    #expect(await accessibility.isTrusted())
    #expect(try await accessibility.windows().isEmpty)

    let capture = FakeCaptureService(permission: .notDeterminedOrDenied)
    #expect(await capture.permissionStatus() == .notDeterminedOrDenied)

    let process = FakeProcessService()
    let request = ProcessExecutionRequest(
        executableURL: URL(fileURLWithPath: "/virtual/process"),
        arguments: [],
        environment: [:]
    )
    #expect(try await process.run(request).termination == .exited(0))
    #expect(await process.requests == [request])
}
