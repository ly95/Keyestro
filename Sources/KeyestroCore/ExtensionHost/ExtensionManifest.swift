import CryptoKit
import Foundation
import ImageIO
import KeyestroDomain
import MachO

/// Controls whether an extension receives only explicit command queries or separately authorized global queries.
public enum ExtensionSearchPolicy: String, Codable, Sendable {
    case explicit
    case global
}

/// A declarative search command advertised by an extension manifest.
public struct ExtensionCommandManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let mode: String
    public let keywords: [String]

    public init(id: String, title: String, mode: String, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.mode = mode
        self.keywords = keywords
    }
}

/// A host-rendered editor type supported by extension preference manifests.
public enum ExtensionPreferenceType: String, Codable, Sendable {
    case text
    case password
    case choice
    case file
    case directory
    case toggle
}

/// A declared extension preference and its validation constraints.
public struct ExtensionPreferenceManifest: Codable, Equatable, Sendable {
    public let name: String
    public let title: String
    public let type: ExtensionPreferenceType
    public let required: Bool
    public let choices: [String]

    private enum CodingKeys: String, CodingKey {
        case name, title, type, required, choices
    }

    public init(
        name: String,
        title: String,
        type: ExtensionPreferenceType,
        required: Bool,
        choices: [String] = []
    ) {
        self.name = name
        self.title = title
        self.type = type
        self.required = required
        self.choices = choices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decode(ExtensionPreferenceType.self, forKey: .type)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
    }
}

/// The versioned, validated trust-boundary manifest for a native extension package.
public struct ExtensionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String
    public let license: String
    public let executable: String
    public let minimumHostVersion: String
    public let capabilities: [String]
    public let searchPolicy: ExtensionSearchPolicy
    public let commands: [ExtensionCommandManifest]
    public let preferences: [ExtensionPreferenceManifest]
    public let executeTimeoutSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, description, author, license, executable
        case minimumHostVersion, capabilities, searchPolicy, commands, preferences
        case executeTimeoutSeconds
    }

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        description: String,
        author: String,
        license: String,
        executable: String,
        minimumHostVersion: String,
        capabilities: [String] = [],
        searchPolicy: ExtensionSearchPolicy = .explicit,
        commands: [ExtensionCommandManifest] = [],
        preferences: [ExtensionPreferenceManifest] = [],
        executeTimeoutSeconds: Int = 30
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.executable = executable
        self.minimumHostVersion = minimumHostVersion
        self.capabilities = capabilities
        self.searchPolicy = searchPolicy
        self.commands = commands
        self.preferences = preferences
        self.executeTimeoutSeconds = executeTimeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decode(String.self, forKey: .description)
        author = try container.decode(String.self, forKey: .author)
        license = try container.decode(String.self, forKey: .license)
        executable = try container.decode(String.self, forKey: .executable)
        minimumHostVersion = try container.decode(String.self, forKey: .minimumHostVersion)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        searchPolicy = try container.decodeIfPresent(ExtensionSearchPolicy.self, forKey: .searchPolicy) ?? .explicit
        commands = try container.decodeIfPresent([ExtensionCommandManifest].self, forKey: .commands) ?? []
        preferences = try container.decodeIfPresent([ExtensionPreferenceManifest].self, forKey: .preferences) ?? []
        executeTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .executeTimeoutSeconds) ?? 30
    }

    public func validate(root: URL) throws -> URL {
        try validateMetadata()
        let executableURL = try Self.resolveManagedPath(executable, root: root)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ExtensionValidationError.executableUnavailable
        }
        try Self.validateExecutable(executableURL)
        return executableURL
    }

    public func validateMetadata() throws {
        guard schemaVersion == 1,
            Self.validReverseDomainID(id),
            !name.isEmpty,
            !name.contains("\u{0}"),
            name.unicodeScalars.count <= 256,
            !description.contains("\u{0}"),
            description.unicodeScalars.count <= 2_048,
            !author.contains("\u{0}"),
            author.unicodeScalars.count <= 256,
            !license.contains("\u{0}"),
            license.unicodeScalars.count <= 128,
            Self.validSemVer(version),
            Self.validSemVer(minimumHostVersion),
            commands.count <= 100,
            preferences.count <= 100,
            capabilities.count <= 50,
            Set(capabilities).count == capabilities.count,
            capabilities.allSatisfy({ Self.validIdentifier($0, maximumLength: 128) }),
            (1...300).contains(executeTimeoutSeconds)
        else { throw ExtensionValidationError.invalidManifest }
        guard Set(commands.map(\.id)).count == commands.count,
            commands.allSatisfy({
                Self.validIdentifier($0.id, maximumLength: 128)
                    && !$0.title.isEmpty
                    && !$0.title.contains("\u{0}")
                    && $0.title.unicodeScalars.count <= 512
                    && $0.mode == "search"
                    && $0.keywords.count <= 50
                    && $0.keywords.allSatisfy {
                        !$0.isEmpty && !$0.contains("\u{0}") && $0.unicodeScalars.count <= 256
                    }
            }),
            Set(preferences.map(\.name)).count == preferences.count,
            preferences.allSatisfy(Self.validPreference)
        else { throw ExtensionValidationError.invalidManifest }
        guard !executable.isEmpty,
            executable.utf8.count <= 4_096,
            !executable.hasPrefix("/"),
            !executable.contains("..")
        else {
            throw ExtensionValidationError.pathEscape
        }
    }

    private static func validPreference(_ preference: ExtensionPreferenceManifest) -> Bool {
        guard validIdentifier(preference.name, maximumLength: 128),
            !preference.title.isEmpty,
            !preference.title.contains("\u{0}"),
            preference.title.unicodeScalars.count <= 256,
            preference.choices.count <= 50,
            Set(preference.choices).count == preference.choices.count,
            preference.choices.allSatisfy({
                !$0.isEmpty && !$0.contains("\u{0}") && $0.unicodeScalars.count <= 256
            })
        else { return false }
        return preference.type == .choice ? !preference.choices.isEmpty : preference.choices.isEmpty
    }

    private static func validIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
            let first = value.unicodeScalars.first,
            isASCIIAlpha(first) || first == "_"
        else { return false }
        return value.unicodeScalars.allSatisfy {
            isASCIIAlpha($0) || isASCIIDigit($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    public static func load(from root: URL) throws -> ExtensionManifest {
        let manifestURL = root.appendingPathComponent("extension.json", isDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1_024 else {
            throw ExtensionValidationError.manifestTooLarge
        }
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ExtensionValidationError.invalidManifest
        }
        _ = try manifest.validate(root: root)
        return manifest
    }

    public static func resolveManagedPath(_ relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\u{0}") else {
            throw ExtensionValidationError.pathEscape
        }
        let standardizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRoot.path + "/") else {
            throw ExtensionValidationError.pathEscape
        }
        return candidate
    }

    public static func validReverseDomainID(_ value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        return components.allSatisfy { component in
            let scalars = component.unicodeScalars
            guard let first = scalars.first, isASCIIAlpha(first) || isASCIIDigit(first) else { return false }
            return scalars.allSatisfy { isASCIIAlpha($0) || isASCIIDigit($0) || $0 == "-" }
        }
    }

    public static func validSemVer(_ value: String) -> Bool {
        value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validateExecutable(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 512) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw ExtensionValidationError.executableUnavailable
        }
        if prefix.starts(with: Data("#!".utf8)) {
            guard let firstLine = String(data: prefix, encoding: .utf8)?.split(separator: "\n", maxSplits: 1).first,
                firstLine.utf8.count <= 127
            else { throw ExtensionValidationError.invalidExecutableFormat }
            let command = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard command.hasPrefix("/"), !command.contains("\u{0}") else {
                throw ExtensionValidationError.invalidExecutableFormat
            }
            return
        }
        guard let architectures = CFBundleCopyExecutableArchitecturesForURL(url as CFURL) as? [NSNumber]
        else { throw ExtensionValidationError.invalidExecutableFormat }
        #if arch(arm64)
            let localCPUType = CPU_TYPE_ARM64
        #elseif arch(x86_64)
            let localCPUType = CPU_TYPE_X86_64
        #else
            let localCPUType: cpu_type_t = 0
        #endif
        guard architectures.contains(where: { $0.int32Value == localCPUType }) else {
            throw ExtensionValidationError.incompatibleArchitecture
        }
    }
}

/// Stable failures produced while validating an extension package or result payload.
public enum ExtensionValidationError: Error, Equatable, Sendable {
    case manifestTooLarge
    case invalidManifest
    case pathEscape
    case executableUnavailable
    case tooManyFiles
    case packageTooLarge
    case symbolicLinkNotAllowed
    case alreadyInstalled
    case invalidExecutableFormat
    case incompatibleArchitecture
    case manifestChangedDuringInstall
    case contentChangedDuringInstall

    public var descriptor: ErrorDescriptor {
        ErrorDescriptor(code: "extension.validation.\(String(describing: self))", message: "The extension package is invalid or unsafe.")
    }
}

/// An untrusted declarative action received from an extension process.
public struct ExtensionActionPayload: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let risk: ActionRisk
    public let behavior: ActionBehavior

    public init(id: String, title: String, risk: ActionRisk, behavior: ActionBehavior) {
        self.id = id
        self.title = title
        self.risk = risk
        self.behavior = behavior
    }
}

/// An untrusted launcher item received at the extension protocol boundary.
public struct ExtensionItemPayload: Codable, Equatable, Sendable {
    public struct Icon: Codable, Equatable, Sendable {
        public let type: String
        public let path: String?
        public let name: String?
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: Icon?
    public let keywords: [String]?
    public let actions: [ExtensionActionPayload]
    public let defaultActionId: String

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: Icon? = nil,
        keywords: [String]? = nil,
        actions: [ExtensionActionPayload],
        defaultActionId: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.actions = actions
        self.defaultActionId = defaultActionId
    }
}

/// A bounded batch of extension results associated with one host request identifier.
public struct ExtensionPublishItems: Codable, Equatable, Sendable {
    public let requestId: String
    public let items: [ExtensionItemPayload]
    public let isFinal: Bool

    public init(requestId: String, items: [ExtensionItemPayload], isFinal: Bool) {
        self.requestId = requestId
        self.items = items
        self.isFinal = isFinal
    }
}

/// Host-domain items produced only after an extension batch passes boundary validation.
public struct ValidatedExtensionItems: Sendable {
    public let items: [LauncherItem]
    public let isFinal: Bool
}

/// Validates untrusted extension result batches and raises action risk where capabilities require it.
public enum ExtensionResultValidator {
    public static func validate(
        _ payload: ExtensionPublishItems,
        expectedRequestID: UUID,
        manifest: ExtensionManifest,
        extensionRoot: URL,
        providerID: ProviderID
    ) throws -> ValidatedExtensionItems {
        guard payload.requestId == expectedRequestID.uuidString.lowercased(),
            payload.items.count <= DomainLimits.itemsPerBatch,
            Set(payload.items.map(\.id)).count == payload.items.count
        else { throw ExtensionValidationError.invalidManifest }
        let minimumRisk: ActionRisk =
            manifest.capabilities.contains(where: {
                $0 == "process.execute" || $0 == "filesystem.write" || $0 == "network"
            }) ? .externalSideEffect : .safe

        let items = try payload.items.map { item -> LauncherItem in
            guard !item.id.isEmpty,
                item.id.utf8.count <= 256,
                !item.id.contains("\u{0}"),
                !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !item.title.contains("\u{0}"),
                item.title.unicodeScalars.count <= DomainLimits.titleUnicodeScalars,
                (item.subtitle?.unicodeScalars.count ?? 0) <= DomainLimits.subtitleUnicodeScalars,
                item.subtitle.map({ !$0.contains("\u{0}") }) ?? true,
                (item.keywords?.count ?? 0) <= DomainLimits.keywordCount,
                item.keywords?.allSatisfy({
                    !$0.isEmpty && !$0.contains("\u{0}")
                        && $0.unicodeScalars.count <= DomainLimits.keywordUnicodeScalars
                })
                    != false,
                item.actions.count <= DomainLimits.actionsPerItem,
                Set(item.actions.map(\.id)).count == item.actions.count,
                item.actions.allSatisfy({
                    !$0.id.isEmpty && $0.id.utf8.count <= 128 && !$0.id.contains("\u{0}")
                        && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.title.contains("\u{0}")
                        && $0.title.unicodeScalars.count <= 256
                }),
                item.actions.contains(where: { $0.id == item.defaultActionId })
            else { throw ExtensionValidationError.invalidManifest }
            let icon: IconReference?
            if let iconPayload = item.icon {
                if iconPayload.type == "asset", let path = iconPayload.path {
                    let iconURL = try ExtensionManifest.resolveManagedPath(path, root: extensionRoot)
                    try validateImage(iconURL)
                    icon = .extensionAsset(extensionID: manifest.id, path: path)
                } else if iconPayload.type == "symbol",
                    let name = iconPayload.name,
                    !name.isEmpty,
                    name.utf8.count <= 128
                {
                    icon = .systemSymbol(name)
                } else {
                    throw ExtensionValidationError.invalidManifest
                }
            } else {
                icon = .systemSymbol("puzzlepiece.extension")
            }
            let itemID = ItemID(
                providerID: providerID,
                providerStableID: "\(manifest.id)\u{0}\(item.id)"
            )
            let actions = item.actions.map { action in
                ActionDescriptor(
                    id: ActionID(action.id),
                    title: action.title,
                    behavior: action.behavior,
                    risk: max(action.risk, minimumRisk),
                    confirmationTarget: "\(manifest.name) — \(item.title) [\(item.id)]"
                )
            }
            return LauncherItem(
                id: itemID,
                providerID: providerID,
                title: item.title,
                subtitle: item.subtitle,
                icon: icon,
                canonicalResource: .command("extension:\(manifest.id):\(item.id)"),
                keywords: item.keywords ?? [],
                actions: actions,
                defaultActionID: ActionID(item.defaultActionId),
                scoreFeatures: ScoreFeatures(providerPrior: 0.3)
            )
        }
        return ValidatedExtensionItems(items: items, isFinal: payload.isFinal)
    }

    private static func validateImage(_ url: URL) throws {
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
            let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            fileSize <= 10 * 1_024 * 1_024,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.intValue > 0,
            height.intValue > 0,
            width.int64Value <= 16_000_000 / height.int64Value
        else { throw ExtensionValidationError.invalidManifest }
    }
}
