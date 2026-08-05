import Darwin
import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test(arguments: [HostileExtensionMode.oversizedFrame, .invalidJSON, .duplicateIDs])
func hostileExtensionProtocolViolationsTerminateTheProcess(mode: HostileExtensionMode) async throws {
    let fixture = try HostileExtensionFixture(mode: mode)
    defer { fixture.remove() }
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        terminationGrace: .milliseconds(50)
    )

    let error = await searchError(supervisor: supervisor, registration: fixture.registration)
    try await waitUntil { await !supervisor.hasActiveProcess(extensionID: fixture.registration.id) }

    #expect(error == .protocolViolation)
}

@Test func infiniteExtensionLogsAreBoundedAndTerminateTheProcess() async throws {
    let fixture = try HostileExtensionFixture(mode: .infiniteLogs)
    defer { fixture.remove() }
    let host = RecordingExtensionHostHandler()
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        hostHandler: host,
        terminationGrace: .milliseconds(50)
    )

    let error = await searchError(supervisor: supervisor, registration: fixture.registration)
    let processIdentifier = try await fixture.waitForProcessIdentifier()
    let logSnapshot = await host.snapshot()

    #expect(error == .protocolViolation)
    #expect(logSnapshot.bytes <= 64 * 1_024)
    #expect(logSnapshot.messages <= 256)
    #expect(await processExits(processIdentifier))
}

@Test func threeExtensionCrashesOpenTheCircuitWithoutAutomaticRestart() async throws {
    let fixture = try HostileExtensionFixture(mode: .crash)
    defer { fixture.remove() }
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        terminationGrace: .milliseconds(20)
    )

    for _ in 0..<3 {
        let error = await searchError(supervisor: supervisor, registration: fixture.registration)
        #expect(error == .terminated)
        try await waitUntil { await !supervisor.hasActiveProcess(extensionID: fixture.registration.id) }
    }
    try await waitUntil { await supervisor.isCircuitOpen(extensionID: fixture.registration.id) }

    let error = await searchError(supervisor: supervisor, registration: fixture.registration)
    #expect(error == .circuitOpen)
}

@Test func ignoredExtensionShutdownMeetsDeadlineAndDoesNotCountAsACrash() async throws {
    let fixture = try HostileExtensionFixture(mode: .ignoreShutdown)
    defer { fixture.remove() }
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        shutdownTimeout: .milliseconds(100),
        terminationGrace: .milliseconds(50)
    )
    var priorProcessIdentifiers = Set<pid_t>()

    for _ in 0..<3 {
        try await completeSearch(supervisor: supervisor, registration: fixture.registration)
        let processIdentifier = try await fixture.waitForProcessIdentifier(excluding: priorProcessIdentifiers)
        priorProcessIdentifiers.insert(processIdentifier)
        let startedAt = ContinuousClock.now
        await supervisor.shutdown(extensionID: fixture.registration.id)

        #expect(startedAt.duration(to: .now) < .seconds(1))
        #expect(await processExits(processIdentifier))
    }
    #expect(await !supervisor.isCircuitOpen(extensionID: fixture.registration.id))
}

@Test func explicitHostileExtensionFailureIsPublishedAsARecoverableProviderStatus() async throws {
    let fixture = try HostileExtensionFixture(mode: .invalidJSON)
    defer { fixture.remove() }
    let store = InMemoryExtensionStore(registrations: [fixture.registration])
    let supervisor = ExtensionSupervisor(store: store, terminationGrace: .milliseconds(50))
    let provider = ExtensionProvider(
        store: store,
        supervisor: supervisor,
        authorization: InMemoryExtensionSearchAuthorization()
    )
    let query = "\(fixture.registration.id) hostile"
    let stream = provider.search(
        request: QueryRequest(generation: 1, rawText: query, normalizedText: query, mode: .extensions)
    )
    var failure: ErrorDescriptor?
    var completed = false
    for try await event in stream {
        switch event {
        case let .status(.failed(error)):
            failure = error
        case let .items(_, isFinal), let .replacement(_, isFinal):
            completed = completed || isFinal
        case .status:
            break
        }
    }

    #expect(failure?.code == "extension.protocolViolation")
    #expect(failure?.recoverySuggestion != nil)
    #expect(completed)
}

enum HostileExtensionMode: String, Sendable {
    case crash
    case oversizedFrame = "oversized-frame"
    case invalidJSON = "invalid-json"
    case duplicateIDs = "duplicate-ids"
    case infiniteLogs = "infinite-logs"
    case ignoreShutdown = "ignore-shutdown"
}

private struct HostileExtensionFixture: Sendable {
    let root: URL
    let processIdentifierFile: URL
    let registration: ExtensionRegistration

    init(mode: HostileExtensionMode) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-hostile-extension-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("bin/extension", isDirectory: false)
        processIdentifierFile = root.appendingPathComponent("process-id", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(Self.program(mode: mode).utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let manifest = ExtensionManifest(
            id: "com.keyestro.tests.hostile-\(UUID().uuidString.lowercased())",
            name: "Hostile Test Extension",
            version: "1.0.0",
            description: "Exercises hostile extension isolation.",
            author: "Keyestro Tests",
            license: "Apache-2.0",
            executable: "bin/extension",
            minimumHostVersion: "0.1.0"
        )
        registration = ExtensionRegistration(
            manifest: manifest,
            installPath: root.path,
            manifestJSON: try JSONEncoder().encode(manifest),
            contentHash: String(repeating: "b", count: 64),
            enabled: true
        )
    }

    func waitForProcessIdentifier(excluding prior: Set<pid_t> = []) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: processIdentifierFile, encoding: .ascii),
                let processIdentifier = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                !prior.contains(processIdentifier)
            {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HostileExtensionTestError.processDidNotStart
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func program(mode: HostileExtensionMode) -> String {
        #"""
        #!/usr/bin/python3
        import json
        import os
        import sys
        import time

        MODE = "\#(mode.rawValue)"
        ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
        with open(os.path.join(ROOT, "process-id"), "w", encoding="ascii") as output:
            output.write(str(os.getpid()))
            output.flush()

        def read_message():
            length = None
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line == b"\r\n":
                    break
                name, value = line.decode("ascii").split(":", 1)
                if name.lower() == "content-length":
                    length = int(value.strip())
            return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))

        def send(payload):
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
            sys.stdout.buffer.write(header + body)
            sys.stdout.buffer.flush()

        def result_item():
            return {
                "id": "duplicate",
                "title": "Duplicate",
                "actions": [{"id": "open", "title": "Open", "risk": "safe", "behavior": "closeLauncher"}],
                "defaultActionId": "open"
            }

        while True:
            request = read_message()
            if request is None:
                break
            method = request.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": {"major": 1, "minor": 0}}})
            elif method == "search":
                if MODE == "crash":
                    os._exit(17)
                elif MODE == "oversized-frame":
                    sys.stdout.buffer.write(b"Content-Length: 1048577\r\n\r\n")
                    sys.stdout.buffer.flush()
                    while True:
                        time.sleep(1)
                elif MODE == "invalid-json":
                    for _ in range(3):
                        sys.stdout.buffer.write(b"Content-Length: 1\r\n\r\n{")
                    sys.stdout.buffer.flush()
                    while True:
                        time.sleep(1)
                elif MODE == "duplicate-ids":
                    request_id = request["params"]["requestId"]
                    send({
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "result": {"requestId": request_id, "items": [result_item(), result_item()], "isFinal": True}
                    })
                elif MODE == "infinite-logs":
                    while True:
                        sys.stderr.buffer.write(b"x" * 4096)
                        sys.stderr.buffer.flush()
                else:
                    request_id = request["params"]["requestId"]
                    send({
                        "jsonrpc": "2.0",
                        "id": request["id"],
                        "result": {"requestId": request_id, "items": [], "isFinal": True}
                    })
            elif method == "shutdown":
                if MODE == "ignore-shutdown":
                    while True:
                        time.sleep(1)
                send({"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}})
            elif method == "exit":
                break
        """#
    }
}

private actor RecordingExtensionHostHandler: ExtensionHostRequestHandling {
    private var bytes = 0
    private var messages = 0

    func showHUD(extensionID: String, message: String) async {}
    func openURL(extensionID: String, url: URL) async -> Bool { false }
    func readPreference(extensionID: String, name: String) async -> JSONValue? { nil }

    func log(extensionID: String, level: String, message: String) async {
        bytes += message.utf8.count
        messages += 1
    }

    func snapshot() -> (bytes: Int, messages: Int) {
        (bytes, messages)
    }
}

private enum HostileExtensionTestError: Error {
    case processDidNotStart
    case searchDidNotComplete
}

private func searchError(
    supervisor: ExtensionSupervisor,
    registration: ExtensionRegistration
) async -> ExtensionSupervisorError? {
    let stream = await supervisor.search(
        registration: registration,
        request: QueryRequest(generation: 1, rawText: "hostile", normalizedText: "hostile", mode: .extensions)
    )
    do {
        for try await _ in stream {}
        return nil
    } catch let error as ExtensionSupervisorError {
        return error
    } catch {
        return nil
    }
}

private func completeSearch(
    supervisor: ExtensionSupervisor,
    registration: ExtensionRegistration
) async throws {
    let stream = await supervisor.search(
        registration: registration,
        request: QueryRequest(generation: 1, rawText: "healthy", normalizedText: "healthy", mode: .extensions)
    )
    var completed = false
    for try await event in stream {
        switch event {
        case let .items(_, isFinal), let .replacement(_, isFinal):
            completed = completed || isFinal
        case .status:
            break
        }
    }
    if !completed { throw HostileExtensionTestError.searchDidNotComplete }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw HostileExtensionTestError.processDidNotStart
}

private func processExits(_ processIdentifier: pid_t) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if kill(processIdentifier, 0) == -1, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
