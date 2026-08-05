import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func jsonRPCFramerHandlesFragmentationAndCoalescing() throws {
    let first = JSONRPCEnvelope(id: .integer(1), method: "initialize", params: .object(["version": .integer(1)]))
    let second = JSONRPCEnvelope(method: "initialized")
    let bytes = try JSONRPCFramer.frame(first) + JSONRPCFramer.frame(second)
    var framer = JSONRPCFramer()
    var frames: [Data] = []
    for chunk in stride(from: 0, to: bytes.count, by: 3) {
        frames += try framer.append(bytes.subdata(in: chunk..<min(bytes.count, chunk + 3)))
    }
    #expect(frames.count == 2)
    #expect(try JSONRPCFramer.decode(frames[0]) == first)
    #expect(try JSONRPCFramer.decode(frames[1]) == second)
}

@Test func extensionResultBoundaryRejectsOversizedKeywords() throws {
    let requestID = UUID()
    let manifest = ExtensionManifest(
        id: "com.example.boundary",
        name: "Boundary",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let payload = ExtensionPublishItems(
        requestId: requestID.uuidString.lowercased(),
        items: [
            ExtensionItemPayload(
                id: "item",
                title: "Item",
                keywords: [String(repeating: "x", count: DomainLimits.keywordUnicodeScalars + 1)],
                actions: [
                    ExtensionActionPayload(id: "open", title: "Open", risk: .safe, behavior: .closeLauncher)
                ],
                defaultActionId: "open"
            )
        ],
        isFinal: true
    )
    #expect(throws: ExtensionValidationError.invalidManifest) {
        try ExtensionResultValidator.validate(
            payload,
            expectedRequestID: requestID,
            manifest: manifest,
            extensionRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            providerID: "test.extensions"
        )
    }
}

@Test func extensionResultBoundaryRaisesRiskAndNeverAcceptsAnExtensionDowngrade() throws {
    let requestID = UUID()
    let manifest = ExtensionManifest(
        id: "com.example.risk-boundary",
        name: "Risk Boundary",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        capabilities: ["process.execute"]
    )
    let payload = ExtensionPublishItems(
        requestId: requestID.uuidString.lowercased(),
        items: [
            ExtensionItemPayload(
                id: "item",
                title: "Item",
                actions: [
                    ExtensionActionPayload(id: "claimed-safe", title: "Run", risk: .safe, behavior: .closeLauncher),
                    ExtensionActionPayload(
                        id: "destructive",
                        title: "Delete",
                        risk: .destructive,
                        behavior: .closeLauncher
                    ),
                ],
                defaultActionId: "claimed-safe"
            )
        ],
        isFinal: true
    )

    let validated = try ExtensionResultValidator.validate(
        payload,
        expectedRequestID: requestID,
        manifest: manifest,
        extensionRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
        providerID: "test.extensions"
    )
    let actions = try #require(validated.items.first?.actions)
    #expect(actions.first(where: { $0.id == "claimed-safe" })?.risk == .externalSideEffect)
    #expect(actions.first(where: { $0.id == "destructive" })?.risk == .destructive)
}

@Test func extensionBoundariesRejectEmbeddedNULIdentifiersAndManifestText() throws {
    let requestID = UUID()
    let manifest = ExtensionManifest(
        id: "com.example.boundary",
        name: "Boundary",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    let payload = ExtensionPublishItems(
        requestId: requestID.uuidString.lowercased(),
        items: [
            ExtensionItemPayload(
                id: "item\u{0}alias",
                title: "Item",
                actions: [
                    ExtensionActionPayload(id: "open", title: "Open", risk: .safe, behavior: .closeLauncher)
                ],
                defaultActionId: "open"
            )
        ],
        isFinal: true
    )
    #expect(throws: ExtensionValidationError.invalidManifest) {
        try ExtensionResultValidator.validate(
            payload,
            expectedRequestID: requestID,
            manifest: manifest,
            extensionRoot: URL(fileURLWithPath: "/tmp", isDirectory: true),
            providerID: "test.extensions"
        )
    }

    let invalidManifest = ExtensionManifest(
        id: "com.example.invalid-text",
        name: "Invalid\u{0}Name",
        version: "1.0.0",
        description: "test",
        author: "test",
        license: "MIT",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0"
    )
    #expect(throws: ExtensionValidationError.invalidManifest) { try invalidManifest.validateMetadata() }
}

@Test(arguments: [
    "Content-Length: -1\r\n\r\n{}",
    "Content-Length: 1\r\nContent-Length: 1\r\n\r\n{}",
    "Content-Length: 999999999\r\n\r\n{}",
    "Content-Length: nope\r\n\r\n{}",
])
func jsonRPCFramerRejectsInvalidLengths(input: String) {
    var framer = JSONRPCFramer()
    #expect(throws: ExtensionProtocolError.self) { try framer.append(Data(input.utf8)) }
}

@Test func extensionManifestRejectsPathEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-root", isDirectory: true)
    #expect(throws: ExtensionValidationError.pathEscape) {
        try ExtensionManifest.resolveManagedPath("../outside", root: root)
    }
    #expect(ExtensionManifest.validReverseDomainID("com.example.tools"))
    #expect(!ExtensionManifest.validReverseDomainID("not-an-id"))
    #expect(!ExtensionManifest.validReverseDomainID("com.example.工具"))
    #expect(ExtensionManifest.validSemVer("1.2.3-beta.1"))
}

@Test func extensionManifestDefaultsToExplicitSearch() throws {
    let json = """
        {
          "schemaVersion": 1,
          "id": "com.example.default-policy",
          "name": "Default Policy",
          "version": "1.0.0",
          "description": "test",
          "author": "test",
          "license": "MIT",
          "executable": "bin/extension",
          "minimumHostVersion": "0.1.0"
        }
        """
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    #expect(manifest.searchPolicy == .explicit)
    #expect(manifest.executeTimeoutSeconds == 30)
}

@Test func jsonRPCRejectsInvalidUTF8AndEnvelopeShape() {
    #expect(throws: ExtensionProtocolError.invalidUTF8) {
        try JSONRPCFramer.decode(Data([0xFF, 0xFE]))
    }
    let invalid = Data(#"{"jsonrpc":"2.0","method":"search","result":{}}"#.utf8)
    #expect(throws: ExtensionProtocolError.invalidEnvelope) {
        try JSONRPCFramer.decode(invalid)
    }
}

@Test func jsonRPCPreservesAnExplicitNullResult() throws {
    let response = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
    let decoded = try JSONRPCFramer.decode(response)
    #expect(decoded.id == .integer(7))
    #expect(decoded.result == .null)
    #expect(decoded.error == nil)

    let roundTrip = try JSONRPCFramer.decode(JSONEncoder().encode(decoded))
    #expect(roundTrip == decoded)
}
