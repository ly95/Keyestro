import Foundation
import KeyestroCore

struct PendingConfigurationImportSnapshot: Codable, Equatable {
    let scripts: [ExportedScriptRegistration]
    let extensions: [ExportedExtensionRegistration]
}

/// Keeps imported registrations inert until the user reconnects or reinstalls their code explicitly.
@MainActor
struct PendingConfigurationImportStore {
    static let scriptsKey = "imports.pendingScriptReconnections"
    static let extensionsKey = "imports.pendingExtensionReinstallations"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func scripts() throws -> [ExportedScriptRegistration] {
        try decode([ExportedScriptRegistration].self, defaultValue: [], forKey: Self.scriptsKey)
    }

    func extensions() throws -> [ExportedExtensionRegistration] {
        try decode([ExportedExtensionRegistration].self, defaultValue: [], forKey: Self.extensionsKey)
    }

    func snapshot() throws -> PendingConfigurationImportSnapshot {
        try PendingConfigurationImportSnapshot(scripts: scripts(), extensions: extensions())
    }

    func restore(_ snapshot: PendingConfigurationImportSnapshot) throws {
        try save(snapshot.scripts, forKey: Self.scriptsKey)
        try save(snapshot.extensions, forKey: Self.extensionsKey)
    }

    func merge(
        scripts: [ExportedScriptRegistration],
        extensions: [ExportedExtensionRegistration]
    ) throws {
        var mergedScripts: [String: ExportedScriptRegistration] = [:]
        for registration in try self.scripts() { mergedScripts[registration.id] = registration }
        for registration in scripts { mergedScripts[registration.id] = registration }
        var mergedExtensions: [String: ExportedExtensionRegistration] = [:]
        for registration in try self.extensions() { mergedExtensions[registration.manifest.id] = registration }
        for registration in extensions { mergedExtensions[registration.manifest.id] = registration }
        let scriptsData = try Self.encoder.encode(mergedScripts.values.sorted { $0.id < $1.id })
        let extensionsData = try Self.encoder.encode(
            mergedExtensions.values.sorted { $0.manifest.id < $1.manifest.id }
        )
        defaults.set(scriptsData, forKey: Self.scriptsKey)
        defaults.set(extensionsData, forKey: Self.extensionsKey)
    }

    func removeScript(_ registration: ExportedScriptRegistration) throws {
        try save(
            scripts().filter { $0.id != registration.id || $0.contentHash != registration.contentHash },
            forKey: Self.scriptsKey
        )
    }

    func removeExtension(_ registration: ExportedExtensionRegistration) throws {
        try save(
            extensions().filter {
                $0.manifest.id != registration.manifest.id
                    || $0.manifest.version != registration.manifest.version
                    || $0.contentHash != registration.contentHash
            },
            forKey: Self.extensionsKey
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        defaultValue: Value,
        forKey key: String
    ) throws -> Value {
        guard let data = defaults.data(forKey: key) else { return defaultValue }
        return try Self.decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, forKey key: String) throws {
        let data = try Self.encoder.encode(value)
        defaults.set(data, forKey: key)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
