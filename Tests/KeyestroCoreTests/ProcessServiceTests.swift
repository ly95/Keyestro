import Darwin
import Foundation
import Testing
@testable import KeyestroCore

@Test func processArgumentsAreNotInterpretedByAShell() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("argv.sh")
    let sentinel = directory.appendingPathComponent("should-not-exist")
    try Data("#!/bin/sh\nprintf '<%s>\\n' \"$@\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let dangerous = "$(touch \(sentinel.path)) `echo injected` ; newline\nvalue"
    let result = try await FoundationProcessService().run(
        ProcessExecutionRequest(
            executableURL: script,
            arguments: [dangerous],
            environment: [:],
            timeout: .seconds(3)
        )
    )
    #expect(result.termination == .exited(0))
    #expect(String(decoding: result.standardOutput, as: UTF8.self).contains(dangerous))
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test func processOutputIsDrainedAndBounded() async throws {
    let request = ProcessExecutionRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: ["x"],
        environment: [:],
        timeout: .milliseconds(150),
        maximumOutputBytes: 4_096
    )
    let result = try await FoundationProcessService().run(request)
    #expect(result.termination == .timedOut)
    #expect(result.standardOutput.count == 4_096)
    #expect(result.standardOutputTruncated)
}

@Test func minimumProcessEnvironmentDoesNotInheritSecrets() {
    let environment = FoundationProcessService.minimumEnvironment(
        overrides: ["API_TOKEN": "must-not-pass", "KEYESTRO_INVOCATION_ID": "test-id"]
    )
    #expect(environment["PATH"] != nil)
    #expect(environment["HOME"] != nil)
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    #expect(environment["API_TOKEN"] == nil)
    #expect(environment["KEYESTRO_INVOCATION_ID"] == "test-id")
}

@Test func processTimeoutTerminatesTheWholeDescendantGroup() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-process-group-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("descendant.sh")
    try Data("#!/bin/sh\nsleep 30 &\nprintf '%s\\n' \"$!\"\nwait\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let result = try await FoundationProcessService().run(
        ProcessExecutionRequest(
            executableURL: script,
            arguments: [],
            environment: [:],
            timeout: .milliseconds(150)
        )
    )

    #expect(result.termination == .timedOut)
    let childText = String(decoding: result.standardOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let childPID = try #require(pid_t(childText))
    #expect(Darwin.kill(childPID, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func processBoundaryRejectsEmbeddedNULAndClampsResourceLimits() async throws {
    let request = ProcessExecutionRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: ["before\u{0}after"],
        environment: [:],
        timeout: .seconds(3_600),
        maximumOutputBytes: Int.max
    )
    #expect(request.timeout == .seconds(300))
    #expect(request.maximumOutputBytes == 1_024 * 1_024)
    await #expect(throws: ProcessServiceError.invalidRequest) {
        try await FoundationProcessService().run(request)
    }

    await #expect(throws: ProcessServiceError.invalidRequest) {
        try await FoundationProcessService().run(
            ProcessExecutionRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ["KEYESTRO_INVOCATION_ID": "before\u{0}after"]
            )
        )
    }
}
