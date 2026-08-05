import Foundation
import Testing
@testable import KeyestroCore

private actor SecurityInspectionProcessFake: ProcessServicing {
    private(set) var requests: [ProcessExecutionRequest] = []

    func run(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        requests.append(request)
        let executable = request.executableURL.path
        let output: String
        let termination: ProcessTermination
        if executable == "/usr/bin/codesign", request.arguments.first == "--verify" {
            output = ""
            termination = .exited(0)
        } else if executable == "/usr/bin/codesign" {
            output = "Identifier=com.example.extension\nTeamIdentifier=ABCDE12345\n"
            termination = .exited(0)
        } else if executable == "/usr/sbin/spctl" {
            output = "accepted\nsource=Notarized Developer ID\n"
            termination = .exited(0)
        } else {
            output = "0081;example;Safari;"
            termination = .exited(0)
        }
        return ProcessExecutionResult(
            termination: termination,
            standardOutput: Data(output.utf8),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            duration: .zero
        )
    }
}

@Test func extensionSecurityInspectionUsesOnlyFixedReadOnlyTools() async throws {
    let fake = SecurityInspectionProcessFake()
    let inspector = ExtensionSecurityInspector(processService: fake)
    let manifest = ExtensionManifest(
        id: "com.example.extension",
        name: "Example",
        version: "1.0.0",
        description: "Example",
        author: "Example",
        license: "MIT",
        executable: "bin/example",
        minimumHostVersion: "0.1.0"
    )
    let registration = ExtensionRegistration(
        manifest: manifest,
        installPath: "/tmp/example.extension",
        manifestJSON: Data(),
        contentHash: String(repeating: "a", count: 64),
        enabled: false
    )
    let report = await inspector.inspect(registration: registration)
    #expect(report.codeSignature == .developerID(teamIdentifier: "ABCDE12345"))
    #expect(report.gatekeeper == .accepted)
    #expect(report.notarized)
    #expect(report.quarantinePresent)

    let requests = await fake.requests
    #expect(Set(requests.map(\.executableURL.path)) == ["/usr/bin/codesign", "/usr/sbin/spctl", "/usr/bin/xattr"])
    #expect(requests.allSatisfy { $0.arguments.last == "/tmp/example.extension/bin/example" || $0.executableURL.path == "/usr/bin/xattr" })
}
