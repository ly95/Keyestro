import Foundation
import KeyestroCore

enum ApplicationCredentialStorage: String, Sendable {
    case keychain
    case ephemeral
}

struct ApplicationStorageConfiguration: Sendable {
    static let infoDictionaryKey = "KeyestroRuntimeStorageMode"
    static let productionBundleIdentifier = "com.keyestro.launcher"
    static let localBundleIdentifier = "com.keyestro.launcher.local"

    let bundleIdentifier: String
    let credentialStorage: ApplicationCredentialStorage

    private let applicationSupportRoot: URL?
    private let cachesRoot: URL?
    private let ephemeralRunsRoot: URL?
    private let ephemeralRunRoot: URL?

    var isEphemeral: Bool {
        credentialStorage == .ephemeral
    }

    static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        runIdentifier: UUID = UUID()
    ) -> ApplicationStorageConfiguration {
        resolve(
            infoDictionary: bundle.infoDictionary ?? [:],
            temporaryDirectory: fileManager.temporaryDirectory,
            runIdentifier: runIdentifier
        )
    }

    static func resolve(
        infoDictionary: [String: Any],
        temporaryDirectory: URL,
        runIdentifier: UUID = UUID()
    ) -> ApplicationStorageConfiguration {
        let requestedBundleIdentifier = infoDictionary["CFBundleIdentifier"] as? String
        let bundleIdentifier =
            requestedBundleIdentifier.flatMap {
                isValidBundleIdentifier($0) ? $0 : nil
            } ?? localBundleIdentifier
        let requestedStorage = (infoDictionary[infoDictionaryKey] as? String)
            .flatMap(ApplicationCredentialStorage.init(rawValue:))

        guard requestedStorage == .keychain, requestedBundleIdentifier == bundleIdentifier else {
            let runsRoot = temporaryDirectory
                .standardizedFileURL
                .appendingPathComponent("KeyestroLocalRuns", isDirectory: true)
            let runRoot = runsRoot.appendingPathComponent(runIdentifier.uuidString, isDirectory: true)
            return ApplicationStorageConfiguration(
                bundleIdentifier: bundleIdentifier,
                credentialStorage: .ephemeral,
                applicationSupportRoot: runRoot.appendingPathComponent("ApplicationSupport", isDirectory: true),
                cachesRoot: runRoot.appendingPathComponent("Caches", isDirectory: true),
                ephemeralRunsRoot: runsRoot,
                ephemeralRunRoot: runRoot
            )
        }

        return ApplicationStorageConfiguration(
            bundleIdentifier: bundleIdentifier,
            credentialStorage: .keychain,
            applicationSupportRoot: nil,
            cachesRoot: nil,
            ephemeralRunsRoot: nil,
            ephemeralRunRoot: nil
        )
    }

    func makePaths() throws -> AppPaths {
        try AppPaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot
        )
    }

    func makeCredentialStore() -> any KeychainServicing {
        switch credentialStorage {
        case .keychain:
            MacKeychainService()
        case .ephemeral:
            InMemoryKeychainService()
        }
    }

    func removeEphemeralData(fileManager: FileManager = .default) throws {
        guard credentialStorage == .ephemeral,
            let ephemeralRunsRoot,
            let ephemeralRunRoot,
            ephemeralRunRoot.deletingLastPathComponent().standardizedFileURL
                == ephemeralRunsRoot.standardizedFileURL,
            UUID(uuidString: ephemeralRunRoot.lastPathComponent) != nil
        else {
            return
        }
        guard fileManager.fileExists(atPath: ephemeralRunRoot.path) else { return }
        try fileManager.removeItem(at: ephemeralRunRoot)
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value.count <= 255, value.contains("."), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }
}
