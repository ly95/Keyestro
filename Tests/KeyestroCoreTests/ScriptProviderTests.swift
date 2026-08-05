import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func scriptProviderPassesAllFiveParameterKindsAsSingleArgvValues() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-script-provider-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("tool")
    try Data("test executable".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let definitions: [ArgumentDefinition] = [
        ArgumentDefinition(id: "text", title: "Text", kind: .text, required: true),
        ArgumentDefinition(id: "password", title: "Password", kind: .password, required: true),
        ArgumentDefinition(id: "choice", title: "Choice", kind: .choice(options: ["one", "two"]), required: true),
        ArgumentDefinition(id: "file", title: "File", kind: .file, required: true),
        ArgumentDefinition(id: "directory", title: "Directory", kind: .directory, required: true),
    ]
    let script = try ScriptDefinition(
        id: "parameter-test",
        title: "Parameter Test",
        executablePath: executable.path,
        arguments: definitions,
        contentHash: ManagedScriptInstaller.sha256(executable)
    )
    let process = RecordingProcessService()
    let provider = ScriptProvider(store: InMemoryScriptStore(scripts: [script]), processService: process)
    let file = root.appendingPathComponent("file with spaces.txt")
    let directory = root.appendingPathComponent("directory with spaces", isDirectory: true)
    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "scripts", providerStableID: script.id),
            actionID: "run",
            arguments: [
                "text": .text("spaces `quotes` $(not-a-shell)\nline"),
                "password": .text("never logged"),
                "choice": .text("two"),
                "file": .file(file),
                "directory": .file(directory),
            ]
        )
    )
    #expect(result == .success(message: "ok · \(formattedDuration(5, unit: .milliseconds))"))
    let request = try #require(await process.lastRequest)
    #expect(
        request.arguments == [
            "spaces `quotes` $(not-a-shell)\nline",
            "never logged",
            "two",
            file.path,
            directory.path,
        ]
    )
    #expect(request.timeout == .seconds(30))

    let rejectingProcess = RecordingProcessService()
    let rejectingProvider = ScriptProvider(
        store: InMemoryScriptStore(scripts: [script]),
        processService: rejectingProcess
    )
    let rejected = await rejectingProvider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "scripts", providerStableID: script.id),
            actionID: "run",
            arguments: [
                "text": .text("text"),
                "password": .text("secret"),
                "choice": .text("not-declared"),
                "file": .file(file),
                "directory": .file(directory),
            ]
        )
    )
    guard case let .failure(error) = rejected else {
        Issue.record("Expected an invalid choice failure")
        return
    }
    #expect(error.code == "scripts.invalidArgument")
    #expect(await rejectingProcess.lastRequest == nil)

    let nulRejected = await rejectingProvider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "scripts", providerStableID: script.id),
            actionID: "run",
            arguments: [
                "text": .text("before\u{0}after"),
                "password": .text("secret"),
                "choice": .text("two"),
                "file": .file(file),
                "directory": .file(directory),
            ]
        )
    )
    guard case let .failure(nulError) = nulRejected else {
        Issue.record("Expected an embedded-NUL failure")
        return
    }
    #expect(nulError.code == "scripts.invalidArgument")
    #expect(await rejectingProcess.lastRequest == nil)
}

@Test func scriptProviderMapsSignalDurationAndBothTruncationFlags() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-script-result-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("tool")
    try Data("test executable".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let script = try ScriptDefinition(
        id: "result-test",
        title: "Result Test",
        executablePath: executable.path,
        contentHash: ManagedScriptInstaller.sha256(executable)
    )
    let process = RecordingProcessService(
        result: ProcessExecutionResult(
            termination: .signalled(9),
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: true,
            standardErrorTruncated: true,
            duration: .milliseconds(1_250)
        )
    )
    let provider = ScriptProvider(store: InMemoryScriptStore(scripts: [script]), processService: process)
    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "scripts", providerStableID: script.id),
            actionID: "run",
            arguments: [:]
        )
    )
    #expect(
        result
            == .failure(
                ErrorDescriptor(
                    code: "scripts.signal.9",
                    message: "The script was terminated by signal 9.",
                    recoverySuggestion: "\(formattedDuration(1.25, unit: .seconds)) · stdout ≥ 1 MiB · stderr ≥ 1 MiB"
                )
            )
    )
}

@Test func linkedOriginalRequiresStableIdentityAndHashBeforeEveryExecution() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-linked-script-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.linked-script-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let source = URL(fileURLWithPath: "/virtual/linked-script")
    let fileSystem = FakeFileSystemService()
    await fileSystem.addFile(at: source, data: Data("version one".utf8), executable: true)
    let store = InMemoryScriptStore()
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)
    let definition = try await installer.linkOriginal(from: source, title: "Linked Script")
    #expect(definition.isLinkedOriginal)
    #expect(definition.executablePath == source.path)

    let process = RecordingProcessService()
    let provider = ScriptProvider(store: store, processService: process, fileSystem: fileSystem)
    let request = ProviderActionRequest(
        executionID: UUID(),
        itemID: ItemID(providerID: "scripts", providerStableID: definition.id),
        actionID: "run",
        arguments: [:]
    )
    #expect(await provider.execute(request: request) == .success(message: "ok · \(formattedDuration(5, unit: .milliseconds))"))
    #expect(await process.requestCount == 1)

    // Replacing a file with byte-identical content still changes its filesystem identity.
    await fileSystem.addFile(at: source, data: Data("version one".utf8), executable: true)
    guard case let .failure(identityError) = await provider.execute(request: request) else {
        Issue.record("Expected an identity-change failure")
        return
    }
    #expect(identityError.code == "scripts.contentChanged")
    #expect(await process.requestCount == 1)

    let reconfirmedIdentity = try await installer.reconfirmLinkedOriginal(definition)
    #expect(await provider.execute(request: request).isSuccess)
    #expect(await process.requestCount == 2)

    await fileSystem.addFile(at: source, data: Data("version two".utf8), executable: true)
    guard case let .failure(contentError) = await provider.execute(request: request) else {
        Issue.record("Expected a content-change failure")
        return
    }
    #expect(contentError.code == "scripts.contentChanged")
    #expect(await process.requestCount == 2)

    let reconfirmedContent = try await installer.reconfirmLinkedOriginal(reconfirmedIdentity)
    #expect(reconfirmedContent.contentHash != reconfirmedIdentity.contentHash)
    #expect(await provider.execute(request: request).isSuccess)
    #expect(await process.requestCount == 3)

    try await installer.remove(reconfirmedContent)
    #expect(await store.script(id: definition.id) == nil)
    #expect(await fileSystem.metadata(at: source)?.isRegularFile == true)
}

@Test func importedScriptReconnectsOnlyWhenTheSelectedBytesMatch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-reconnected-script-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.reconnected-script-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let matchingSource = URL(fileURLWithPath: "/virtual/exported-script")
    let wrongSource = URL(fileURLWithPath: "/virtual/wrong-script")
    let fileSystem = FakeFileSystemService()
    let matchingData = Data("exported bytes".utf8)
    await fileSystem.addFile(at: matchingSource, data: matchingData, executable: true)
    await fileSystem.addFile(at: wrongSource, data: Data("different bytes".utf8), executable: true)
    let argument = ArgumentDefinition(id: "name", title: "Name", kind: .text, required: true)
    let exportedDefinition = try ScriptDefinition(
        id: "exported-script",
        title: "Exported Script",
        executablePath: "/private/not-exported/exported-script",
        arguments: [argument],
        timeoutSeconds: 17,
        contentHash: try await fileSystem.sha256Digest(
            at: matchingSource,
            maximumBytes: ManagedScriptInstaller.maximumScriptBytes
        )
    )
    let registration = ExportedScriptRegistration(exportedDefinition)
    let store = InMemoryScriptStore()
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)

    await #expect(throws: (any Error).self) {
        try await installer.reconnect(registration, from: wrongSource)
    }
    #expect(await store.allScripts().isEmpty)

    let restored = try await installer.reconnect(registration, from: matchingSource)
    #expect(restored.id == registration.id)
    #expect(restored.title == registration.title)
    #expect(restored.arguments == registration.arguments)
    #expect(restored.timeoutSeconds == registration.timeoutSeconds)
    #expect(restored.contentHash == registration.contentHash)
    #expect(!restored.isLinkedOriginal)
    #expect(restored.executablePath != matchingSource.path)
    #expect(await fileSystem.metadata(at: matchingSource)?.isRegularFile == true)
}

@Test func concurrentScriptReconnectionsNeverShareOrDeleteTheSameManagedDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-concurrent-script-reconnect-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.concurrent-script-reconnect-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let source = URL(fileURLWithPath: "/virtual/concurrent-exported-script")
    let fileSystem = FakeFileSystemService()
    let sourceData = Data("concurrent exported bytes".utf8)
    await fileSystem.addFile(at: source, data: sourceData, executable: true)
    let exported = try ScriptDefinition(
        id: "concurrent-exported-script",
        title: "Concurrent Exported Script",
        executablePath: "/private/not-exported/concurrent-exported-script",
        contentHash: try await fileSystem.sha256Digest(
            at: source,
            maximumBytes: ManagedScriptInstaller.maximumScriptBytes
        )
    )
    let registration = ExportedScriptRegistration(exported)
    let store = InMemoryScriptStore()
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)

    async let first = installer.reconnect(registration, from: source)
    async let second = installer.reconnect(registration, from: source)
    let restored = try await [first, second]

    #expect(Set(restored.map(\.id)).count == 2)
    #expect(restored.contains { $0.id == registration.id })
    #expect(await store.allScripts().count == 2)
    for definition in restored {
        #expect(await fileSystem.metadata(at: URL(fileURLWithPath: definition.executablePath))?.isRegularFile == true)
    }
}

@Test func scriptRemovalRejectsAStaleSettingsSnapshotAndPreservesTheCurrentManagedCopy() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-stale-script-removal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.stale-script-removal-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let source = URL(fileURLWithPath: "/virtual/stale-script")
    let fileSystem = FakeFileSystemService()
    await fileSystem.addFile(at: source, data: Data("managed bytes".utf8), executable: true)
    let store = InMemoryScriptStore()
    let installer = ManagedScriptInstaller(paths: paths, store: store, fileSystem: fileSystem)
    let reviewed = try await installer.install(from: source, title: "Reviewed Title")
    let current = try ScriptDefinition(
        id: reviewed.id,
        title: "Changed Title",
        executablePath: reviewed.executablePath,
        arguments: reviewed.arguments,
        environment: reviewed.environment,
        timeoutSeconds: reviewed.timeoutSeconds,
        contentHash: reviewed.contentHash,
        linkedFileIdentity: reviewed.linkedFileIdentity,
        enabled: reviewed.enabled,
        createdAt: reviewed.createdAt,
        updatedAt: reviewed.updatedAt.addingTimeInterval(1)
    )
    await store.saveScript(current)

    do {
        try await installer.remove(reviewed)
        Issue.record("Expected a stale script snapshot to be rejected")
    } catch let descriptor as ErrorDescriptor {
        #expect(descriptor.code == "scripts.staleRegistration")
    }
    #expect(await store.script(id: reviewed.id) == current)
    #expect(await fileSystem.metadata(at: URL(fileURLWithPath: reviewed.executablePath))?.isRegularFile == true)
}

private actor RecordingProcessService: ProcessServicing {
    private(set) var lastRequest: ProcessExecutionRequest?
    private(set) var requestCount = 0
    private let result: ProcessExecutionResult

    init(
        result: ProcessExecutionResult = ProcessExecutionResult(
            termination: .exited(0),
            standardOutput: Data("ok".utf8),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            duration: .milliseconds(5)
        )
    ) {
        self.result = result
    }

    func run(_ request: ProcessExecutionRequest) -> ProcessExecutionResult {
        lastRequest = request
        requestCount += 1
        return result
    }
}

private extension ActionResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func formattedDuration(_ value: Double, unit: UnitDuration) -> String {
    let formatter = MeasurementFormatter()
    formatter.locale = .current
    formatter.unitOptions = .providedUnit
    formatter.unitStyle = .short
    return formatter.string(from: Measurement(value: value, unit: unit))
}
