import Foundation
import KeyestroCore
import Testing

@Test func diagnosticsArchiveIsBoundedAndExcludesUserPayloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.diagnostics-tests",
        applicationSupportRoot: root.appendingPathComponent("Support"),
        cachesRoot: root.appendingPathComponent("Caches")
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try paths.prepare()
    let process = FoundationProcessService()
    let service = DiagnosticsService(
        paths: paths,
        extensions: InMemoryExtensionStore(),
        database: nil,
        processService: process,
        bundleURL: URL(fileURLWithPath: "/bin/ls"),
        appVersion: "1.0.0",
        buildVersion: "1"
    )
    let snapshot = await service.snapshot(
        settings: ["feature.enabled": .bool(true)],
        permissions: ["screenRecording": "notAllowed"],
        recentErrorCodes: ["capture.permissionDenied"]
    )
    let archive = root.appendingPathComponent("diagnostics.zip")
    try await service.exportZIP(snapshot, to: archive)
    let size = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(size > 0)
    #expect(size < 20 * 1_024 * 1_024)

    let extracted = root.appendingPathComponent("Extracted", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    let extraction = try await process.run(
        ProcessExecutionRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, extracted.path],
            environment: [:],
            timeout: .seconds(10)
        )
    )
    #expect(extraction.termination == .exited(0))
    let json =
        extracted
        .appendingPathComponent("Keyestro Diagnostics", isDirectory: true)
        .appendingPathComponent("diagnostics.json")
    let text = try String(contentsOf: json, encoding: .utf8)
    #expect(text.contains("capture.permissionDenied"))
    #expect(!text.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    #expect(!text.contains("clipboard"))
}
