import Foundation
import KeyestroCore
import KeyestroDomain

private let usage = """
    usage:
      launcher-extension-test validate <extension>
      launcher-extension-test run <extension> [--query <text>]
      launcher-extension-test fuzz-framing <extension>
    """

@main
private enum ExtensionTestCommand {
    static func main() async {
        do {
            try await run()
        } catch let error as ExtensionSupervisorError {
            writeError("error: \(error.descriptor.message) [\(error.descriptor.code)]")
            exit(1)
        } catch let error as ExtensionValidationError {
            writeError("error: \(error.descriptor.message) [\(error.descriptor.code)]")
            exit(1)
        } catch {
            writeError("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            writeError(usage)
            exit(64)
        }
        let command = arguments[0]
        let source = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        let inspected = try await inspect(source)
        switch command {
        case "validate":
            printValidation(inspected)
        case "run":
            let query = value(after: "--query", in: arguments) ?? ""
            try await runExtension(inspected, query: query)
        case "fuzz-framing":
            try fuzzFraming()
            printValidation(inspected)
            print("framing: 1,000 fragmented/coalesced cases passed")
        default:
            writeError(usage)
            exit(64)
        }
    }

    private static func inspect(_ source: URL) async throws -> ExtensionRegistration {
        let bundleID = "com.keyestro.extension-test.\(UUID().uuidString.lowercased())"
        let paths = try AppPaths(bundleIdentifier: bundleID)
        let installer = ExtensionInstaller(paths: paths, store: InMemoryExtensionStore())
        return try await installer.inspect(sourceRoot: source)
    }

    private static func printValidation(_ registration: ExtensionRegistration) {
        print("valid: \(registration.manifest.id) \(registration.manifest.version)")
        print("sha256: \(registration.contentHash)")
        print("executable: \(registration.manifest.executable)")
        print("capabilities: \(registration.manifest.capabilities.sorted().joined(separator: ", "))")
        print("warning: native extensions run with your user permissions; process isolation is not a security sandbox")
    }

    private static func runExtension(_ inspected: ExtensionRegistration, query: String) async throws {
        let registration = ExtensionRegistration(
            manifest: inspected.manifest,
            installPath: inspected.installPath,
            manifestJSON: inspected.manifestJSON,
            contentHash: inspected.contentHash,
            enabled: true
        )
        let store = InMemoryExtensionStore(registrations: [registration])
        let supervisor = ExtensionSupervisor(store: store)
        let request = QueryRequest(
            generation: 1,
            rawText: query,
            normalizedText: TextNormalizer.normalize(query),
            mode: .extensions
        )
        let stream = await supervisor.search(registration: registration, request: request)
        var itemCount = 0
        var firstAction: (itemID: String, actionID: String)?
        do {
            for try await event in stream {
                switch event {
                case let .items(items, isFinal), let .replacement(items, isFinal):
                    for item in items {
                        itemCount += 1
                        print("item: \(item.title) [\(item.id.providerStableID)]")
                        if firstAction == nil,
                            let action = item.actions.first,
                            let separator = item.id.providerStableID.firstIndex(of: "\u{0}")
                        {
                            firstAction = (
                                String(item.id.providerStableID[item.id.providerStableID.index(after: separator)...]),
                                action.id.rawValue
                            )
                        }
                    }
                    if isFinal { print("search: final") }
                case let .status(status):
                    print("status: \(String(describing: status))")
                }
            }
            guard let firstAction else { throw ExtensionContractError.noExecutableAction }
            let actionResult = await supervisor.execute(
                registration: registration,
                itemStableID: firstAction.itemID,
                actionID: firstAction.actionID,
                arguments: [:]
            )
            guard case .success = actionResult else { throw ExtensionContractError.actionFailed(actionResult) }
            print("execute: passed")
            await supervisor.shutdownAll()
            print("run: handshake/search/execute/shutdown passed (\(itemCount) items)")
        } catch {
            await supervisor.shutdownAll()
            throw error
        }
    }

    private static func fuzzFraming() throws {
        let envelopes = (0..<20).map { index in
            JSONRPCEnvelope(
                id: .integer(Int64(index + 1)),
                method: "search",
                params: .object([
                    "query": .string("line one\nline two \(index) 🎹"),
                    "requestId": .string(UUID().uuidString.lowercased()),
                ])
            )
        }
        let framed = try envelopes.reduce(into: Data()) { output, envelope in
            output.append(try JSONRPCFramer.frame(envelope))
        }
        for seed in 0..<1_000 {
            var generator = SplitMix64(seed: UInt64(seed))
            var framer = JSONRPCFramer()
            var decoded: [JSONRPCEnvelope] = []
            var offset = 0
            while offset < framed.count {
                let remaining = framed.count - offset
                let size = min(remaining, Int(generator.next() % 257) + 1)
                let chunk = framed.subdata(in: offset..<(offset + size))
                for body in try framer.append(chunk) {
                    decoded.append(try JSONRPCFramer.decode(body))
                }
                offset += size
            }
            guard decoded == envelopes else { throw ExtensionProtocolError.invalidJSON }
        }
        let invalid = [
            "Content-Length: -1\r\n\r\n{}",
            "Content-Length: 1\r\nContent-Length: 1\r\n\r\n{}",
            "Content-Length: 1048577\r\n\r\n{}",
            "Content-Length: nope\r\n\r\n{}",
        ]
        for bytes in invalid {
            var framer = JSONRPCFramer()
            do {
                _ = try framer.append(Data(bytes.utf8))
                throw ExtensionProtocolError.invalidContentLength
            } catch is ExtensionProtocolError {
                continue
            }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

private enum ExtensionContractError: LocalizedError {
    case noExecutableAction
    case actionFailed(ActionResult)

    var errorDescription: String? {
        switch self {
        case .noExecutableAction:
            "The extension did not publish an executable action."
        case let .actionFailed(result):
            "The first published action failed: \(String(describing: result))"
        }
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
