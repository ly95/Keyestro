import Foundation
import KeyestroDomain

public protocol ExtensionSearchAuthorizing: Sendable {
    func globalSearchEnabled(extensionID: String) async -> Bool
    func setGlobalSearchEnabled(_ enabled: Bool, extensionID: String) async
}

public actor InMemoryExtensionSearchAuthorization: ExtensionSearchAuthorizing {
    private var enabledIDs: Set<String>

    public init(enabledIDs: Set<String> = []) {
        self.enabledIDs = enabledIDs
    }

    public func globalSearchEnabled(extensionID: String) -> Bool { enabledIDs.contains(extensionID) }

    public func setGlobalSearchEnabled(_ enabled: Bool, extensionID: String) {
        if enabled { enabledIDs.insert(extensionID) } else { enabledIDs.remove(extensionID) }
    }
}

/// Persists only the per-extension consent bit. Query text is never written to preferences.
public actor UserDefaultsExtensionSearchAuthorization: ExtensionSearchAuthorizing {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "extensions.globalSearch.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func globalSearchEnabled(extensionID: String) -> Bool {
        defaults.bool(forKey: keyPrefix + extensionID)
    }

    public func setGlobalSearchEnabled(_ enabled: Bool, extensionID: String) {
        defaults.set(enabled, forKey: keyPrefix + extensionID)
    }
}

public struct ExtensionProvider: LauncherProvider {
    public static let providerID = ProviderID("builtin.extensions")
    public let descriptor = ProviderDescriptor(
        id: providerID,
        displayName: "Extensions",
        supportedModes: [.all, .extensions],
        supportsEmptyQuery: true
    )

    private let store: any ExtensionStoring
    private let supervisor: ExtensionSupervisor
    private let authorization: any ExtensionSearchAuthorizing

    public init(
        store: any ExtensionStoring,
        supervisor: ExtensionSupervisor,
        authorization: any ExtensionSearchAuthorizing
    ) {
        self.store = store
        self.supervisor = supervisor
        self.authorization = authorization
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        let task = Task {
            do {
                let installed = try await store.allExtensions().filter(\.enabled)
                switch request.mode {
                case .extensions:
                    if let target = Self.explicitTarget(in: request.normalizedText, registrations: installed) {
                        let childRequest = QueryRequest(
                            id: request.id,
                            generation: request.generation,
                            rawText: target.query,
                            normalizedText: target.query,
                            mode: .extensions,
                            limit: request.limit,
                            context: request.context,
                            startedAt: request.startedAt
                        )
                        let child = await supervisor.search(
                            registration: target.registration,
                            request: childRequest,
                            commandID: target.commandID
                        )
                        do {
                            for try await event in child {
                                try Task.checkCancellation()
                                continuation.yield(event)
                            }
                        } catch let error as ExtensionSupervisorError {
                            continuation.yield(.status(.failed(error.descriptor)))
                            continuation.yield(.items([], isFinal: true))
                        }
                    } else {
                        continuation.yield(.items(Self.gatewayItems(installed, query: request.normalizedText), isFinal: true))
                    }
                case .all:
                    guard !request.normalizedText.isEmpty else {
                        // An extension may perform network work; empty global queries never leave the host.
                        continuation.yield(.items([], isFinal: true))
                        continuation.finish()
                        return
                    }
                    let eligible = await globalExtensions(from: installed)
                    guard !eligible.isEmpty else {
                        continuation.yield(.items([], isFinal: true))
                        continuation.finish()
                        return
                    }
                    await withTaskGroup(of: Void.self) { group in
                        for registration in eligible {
                            group.addTask {
                                let child = await supervisor.search(registration: registration, request: request)
                                do {
                                    for try await event in child {
                                        try Task.checkCancellation()
                                        if case let .items(items, _) = event, !items.isEmpty {
                                            continuation.yield(.items(items, isFinal: false))
                                        }
                                    }
                                } catch {
                                    // One extension is an isolated provider failure; the others continue.
                                }
                            }
                        }
                        await group.waitForAll()
                    }
                    continuation.yield(.items([], isFinal: true))
                default:
                    continuation.yield(.items([], isFinal: true))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        let stableID = request.itemID.providerStableID
        if stableID.hasPrefix("gateway\u{0}") {
            let parts = stableID.split(separator: "\u{0}", omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                return .failure(ErrorDescriptor(code: "extension.invalidGateway", message: "The extension command is unavailable."))
            }
            return .success(message: "@\(parts[1]):\(parts[2]) ")
        }
        let parts = stableID.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            let registration = try? await store.extensionRegistration(id: String(parts[0])),
            registration.enabled
        else {
            return .failure(ErrorDescriptor(code: "extension.missing", message: "The extension is no longer installed or enabled."))
        }
        return await supervisor.execute(
            registration: registration,
            itemStableID: String(parts[1]),
            actionID: request.actionID.rawValue,
            arguments: request.arguments
        )
    }

    private func globalExtensions(from registrations: [ExtensionRegistration]) async -> [ExtensionRegistration] {
        var output: [ExtensionRegistration] = []
        for registration in registrations where registration.manifest.searchPolicy == .global {
            if await authorization.globalSearchEnabled(extensionID: registration.id) {
                output.append(registration)
            }
        }
        return output
    }

    private struct ExplicitTarget {
        let registration: ExtensionRegistration
        let commandID: String?
        let query: String
    }

    private static func explicitTarget(
        in query: String,
        registrations: [ExtensionRegistration]
    ) -> ExplicitTarget? {
        let split = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let selector = split.first else { return nil }
        let selectorParts = selector.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let registration = registrations.first(where: { $0.id == String(selectorParts[0]) }) else { return nil }
        let commandID = selectorParts.count == 2 && !selectorParts[1].isEmpty ? String(selectorParts[1]) : nil
        if let commandID, !registration.manifest.commands.contains(where: { $0.id == commandID }) { return nil }
        return ExplicitTarget(
            registration: registration,
            commandID: commandID,
            query: split.count == 2 ? String(split[1]) : ""
        )
    }

    private static func gatewayItems(_ registrations: [ExtensionRegistration], query: String) -> [LauncherItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return registrations.flatMap { registration in
            registration.manifest.commands.map { command in (registration, command) }
        }
        .filter { registration, command in
            normalized.isEmpty
                || TextNormalizer.normalize(
                    ([registration.manifest.name, command.title] + command.keywords).joined(separator: " ")
                ).contains(normalized)
        }
        .prefix(DomainLimits.candidatesPerProvider)
        .map { registration, command in
            let stableID = "gateway\u{0}\(registration.id)\u{0}\(command.id)"
            let itemID = ItemID(providerID: providerID, providerStableID: stableID)
            let action = ActionDescriptor(
                id: "enter",
                title: "Open Extension Command",
                icon: .systemSymbol("arrow.right"),
                behavior: .replaceContent,
                risk: .safe
            )
            return LauncherItem(
                id: itemID,
                providerID: providerID,
                title: command.title,
                subtitle: "\(registration.manifest.name) · queries are shared only after opening this command",
                icon: .systemSymbol("puzzlepiece.extension"),
                canonicalResource: .command("extension-gateway:\(registration.id):\(command.id)"),
                keywords: [registration.manifest.name, registration.id] + command.keywords,
                actions: [action],
                defaultActionID: action.id,
                scoreFeatures: ScoreFeatures(providerPrior: 0.2)
            )
        }
    }
}
