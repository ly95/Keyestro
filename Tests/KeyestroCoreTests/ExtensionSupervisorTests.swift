import Darwin
import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func hangingExtensionSearchTimesOutAndTerminatesItsProcessGroup() async throws {
    let fixture = try HangingExtensionFixture()
    defer { fixture.remove() }
    let clock = ManualClockService()
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        initializationTimeout: .seconds(10),
        searchTimeout: .milliseconds(250),
        cancellationGrace: .milliseconds(100),
        terminationGrace: .milliseconds(100),
        clock: clock
    )

    let consumer = Task { () -> ExtensionSupervisorError? in
        let stream = await supervisor.search(
            registration: fixture.registration,
            request: QueryRequest(generation: 1, rawText: "hang", normalizedText: "hang", mode: .extensions)
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

    let processIDs = try await fixture.waitForProcessIDs()
    try await fixture.waitForSearchStart()
    await waitForSleepRequests(clock, atLeast: 3)
    await clock.advance(by: .milliseconds(250))
    await waitForSleepRequests(clock, atLeast: 4)
    await clock.advance(by: .milliseconds(100))

    #expect(await consumer.value == .timedOut("search"))
    #expect(await processesExit(processIDs))
}

@Test func cancellingExtensionSearchTerminatesAnUnresponsiveProcessGroup() async throws {
    let fixture = try HangingExtensionFixture()
    defer { fixture.remove() }
    let clock = ManualClockService()
    let supervisor = ExtensionSupervisor(
        store: InMemoryExtensionStore(registrations: [fixture.registration]),
        initializationTimeout: .seconds(10),
        searchTimeout: .seconds(2),
        cancellationGrace: .milliseconds(100),
        terminationGrace: .milliseconds(100),
        clock: clock
    )
    let consumer = Task {
        let stream = await supervisor.search(
            registration: fixture.registration,
            request: QueryRequest(generation: 1, rawText: "hang", normalizedText: "hang", mode: .extensions)
        )
        do {
            for try await _ in stream {}
        } catch {}
    }

    let processIDs = try await fixture.waitForProcessIDs()
    try await fixture.waitForSearchStart()
    consumer.cancel()
    await waitForSleepRequests(clock, atLeast: 4)
    await clock.advance(by: .milliseconds(100))
    await waitForSleepRequests(clock, atLeast: 5)
    await clock.advance(by: .milliseconds(100))
    await consumer.value

    #expect(await processesExit(processIDs))
}

private struct HangingExtensionFixture: Sendable {
    let root: URL
    let pidFile: URL
    let searchFile: URL
    let registration: ExtensionRegistration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-extension-supervisor-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("bin/extension", isDirectory: false)
        pidFile = root.appendingPathComponent("processes", isDirectory: false)
        searchFile = root.appendingPathComponent("search-started", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let program = #"""
            #!/usr/bin/python3
            import json
            import os
            import subprocess
            import sys
            import time

            child = subprocess.Popen(["/bin/sleep", "60"])
            root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
            with open(os.path.join(root, "processes"), "w", encoding="ascii") as output:
                output.write(f"{os.getpid()} {child.pid}")
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

            def respond(request, result):
                body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}, separators=(",", ":")).encode("utf-8")
                sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
                sys.stdout.buffer.flush()

            while True:
                request = read_message()
                if request is None:
                    break
                method = request.get("method")
                if method == "initialize":
                    respond(request, {"protocolVersion": {"major": 1, "minor": 0}})
                elif method == "search":
                    with open(os.path.join(root, "search-started"), "w", encoding="ascii") as output:
                        output.write("started")
                    while True:
                        time.sleep(1)
            """#
        try Data(program.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let manifest = ExtensionManifest(
            id: "com.keyestro.tests.hanging-\(UUID().uuidString.lowercased())",
            name: "Hanging Test Extension",
            version: "1.0.0",
            description: "Exercises process-group timeout handling.",
            author: "Keyestro Tests",
            license: "Apache-2.0",
            executable: "bin/extension",
            minimumHostVersion: "0.1.0"
        )
        registration = ExtensionRegistration(
            manifest: manifest,
            installPath: root.path,
            manifestJSON: try JSONEncoder().encode(manifest),
            contentHash: String(repeating: "a", count: 64),
            enabled: true
        )
    }

    func waitForProcessIDs() async throws -> [pid_t] {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: pidFile, encoding: .ascii) {
                let processIDs = value.split(separator: " ").compactMap { pid_t($0) }
                if processIDs.count == 2 { return processIDs }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ExtensionSupervisorTestError.processesDidNotStart
    }

    func waitForSearchStart() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: searchFile.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ExtensionSupervisorTestError.searchDidNotStart
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ExtensionSupervisorTestError: Error {
    case processesDidNotStart
    case searchDidNotStart
}

private func processesExit(_ processIDs: [pid_t]) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if processIDs.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
