import Foundation

/// The code-signing state disclosed before native extension installation.
public enum ExtensionCodeSignatureStatus: Equatable, Sendable {
    case developerID(teamIdentifier: String)
    case valid
    case adHoc
    case unsigned
    case invalid
    case unavailable
}

/// Gatekeeper's assessment of an extension executable without bypassing quarantine.
public enum ExtensionGatekeeperStatus: Equatable, Sendable {
    case accepted
    case rejected
    case unavailable
}

/// A read-only signature, notarization, Gatekeeper, and quarantine inspection report.
public struct ExtensionSecurityReport: Equatable, Sendable {
    public let codeSignature: ExtensionCodeSignatureStatus
    public let gatekeeper: ExtensionGatekeeperStatus
    public let notarized: Bool
    public let quarantinePresent: Bool

    public init(
        codeSignature: ExtensionCodeSignatureStatus,
        gatekeeper: ExtensionGatekeeperStatus,
        notarized: Bool,
        quarantinePresent: Bool
    ) {
        self.codeSignature = codeSignature
        self.gatekeeper = gatekeeper
        self.notarized = notarized
        self.quarantinePresent = quarantinePresent
    }
}

/// Performs read-only local security inspection without changing quarantine or Gatekeeper policy.
public actor ExtensionSecurityInspector {
    private let processService: any ProcessServicing

    public init(processService: any ProcessServicing = FoundationProcessService()) {
        self.processService = processService
    }

    public func inspect(registration: ExtensionRegistration) async -> ExtensionSecurityReport {
        let root = URL(fileURLWithPath: registration.installPath, isDirectory: true).standardizedFileURL
        guard let executable = try? ExtensionManifest.resolveManagedPath(registration.manifest.executable, root: root) else {
            return ExtensionSecurityReport(
                codeSignature: .unavailable,
                gatekeeper: .unavailable,
                notarized: false,
                quarantinePresent: false
            )
        }

        async let signature = inspectCodeSignature(executable)
        async let gatekeeper = inspectGatekeeper(executable)
        async let quarantine = hasQuarantineAttribute(root)
        let signatureResult = await signature
        let gatekeeperResult = await gatekeeper
        return ExtensionSecurityReport(
            codeSignature: signatureResult,
            gatekeeper: gatekeeperResult.status,
            notarized: gatekeeperResult.notarized,
            quarantinePresent: await quarantine
        )
    }

    private func inspectCodeSignature(_ executable: URL) async -> ExtensionCodeSignatureStatus {
        let verify = await run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--verbose=2", executable.path]
        )
        guard let verify else { return .unavailable }
        guard verify.termination == .exited(0) else {
            let output = Self.output(verify).lowercased()
            return output.contains("not signed") ? .unsigned : .invalid
        }

        guard
            let details = await run(
                executable: "/usr/bin/codesign",
                arguments: ["--display", "--verbose=4", executable.path]
            )
        else { return .valid }
        let output = Self.output(details)
        if output.localizedCaseInsensitiveContains("Signature=adhoc") { return .adHoc }
        if let teamIdentifier = Self.value(after: "TeamIdentifier=", in: output),
            teamIdentifier != "not set",
            !teamIdentifier.isEmpty
        {
            return .developerID(teamIdentifier: teamIdentifier)
        }
        return .valid
    }

    private func inspectGatekeeper(_ executable: URL) async -> (status: ExtensionGatekeeperStatus, notarized: Bool) {
        guard
            let result = await run(
                executable: "/usr/sbin/spctl",
                arguments: ["--assess", "--type", "execute", "--verbose=2", executable.path]
            )
        else { return (.unavailable, false) }
        let output = Self.output(result)
        let notarized =
            output.localizedCaseInsensitiveContains("notarized developer id")
            || output.localizedCaseInsensitiveContains("source=notarized")
        return (result.termination == .exited(0) ? .accepted : .rejected, notarized)
    }

    private func hasQuarantineAttribute(_ root: URL) async -> Bool {
        guard
            let result = await run(
                executable: "/usr/bin/xattr",
                arguments: ["-p", "com.apple.quarantine", root.path]
            )
        else { return false }
        return result.termination == .exited(0) && !result.standardOutput.isEmpty
    }

    private func run(executable: String, arguments: [String]) async -> ProcessExecutionResult? {
        try? await processService.run(
            ProcessExecutionRequest(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: [:],
                timeout: .seconds(5),
                maximumOutputBytes: 64 * 1_024
            )
        )
    }

    private static func output(_ result: ProcessExecutionResult) -> String {
        String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
    }

    private static func value(after prefix: String, in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
