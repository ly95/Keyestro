import Foundation
import KeyestroDomain

public protocol SystemCommandConfirmationServicing: Sendable {
    @MainActor func shouldConfirmSleep() -> Bool
    @MainActor func markSleepExplanationShown()
}

public struct AlwaysConfirmSystemCommands: SystemCommandConfirmationServicing {
    public init() {}

    @MainActor public func shouldConfirmSleep() -> Bool { true }
    @MainActor public func markSleepExplanationShown() {}
}

public struct SystemCommandProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "system",
        displayName: "System Commands",
        supportedModes: [.all, .commands],
        supportsEmptyQuery: true
    )
    private let service: any SystemCommandServicing
    private let confirmation: any SystemCommandConfirmationServicing

    public init(
        service: any SystemCommandServicing = MacSystemCommandService(),
        confirmation: any SystemCommandConfirmationServicing = AlwaysConfirmSystemCommands()
    ) {
        self.service = service
        self.confirmation = confirmation
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let task = Task {
            let shouldConfirmSleep = await confirmation.shouldConfirmSleep()
            let items = Self.commands.compactMap { command -> LauncherItem? in
                let match = FuzzyMatcher.evaluate(
                    query: request.normalizedText,
                    title: command.title,
                    subtitle: command.subtitle,
                    keywords: command.keywords
                )
                guard match.tier != .none else { return nil }
                let itemID = ItemID(providerID: descriptor.id, providerStableID: command.id.rawValue)
                let action = ActionDescriptor(
                    id: "execute",
                    title: command.title,
                    icon: .systemSymbol(command.symbol),
                    behavior: .closeLauncher,
                    risk: command.id == .sleepSystem && shouldConfirmSleep ? .externalSideEffect : .safe,
                    confirmationTarget: command.id == .sleepSystem ? "This Mac" : nil
                )
                return LauncherItem(
                    id: itemID,
                    providerID: descriptor.id,
                    title: command.title,
                    subtitle: command.subtitle,
                    icon: .systemSymbol(command.symbol),
                    canonicalResource: .command("system:\(command.id.rawValue)"),
                    keywords: command.keywords,
                    actions: [action],
                    defaultActionID: action.id,
                    scoreFeatures: ScoreFeatures(providerPrior: 0.6)
                )
            }
            continuation.yield(.items(items, isFinal: true))
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id,
            request.actionID == "execute",
            let command = SystemCommandID(rawValue: request.itemID.providerStableID)
        else {
            return .failure(ErrorDescriptor(code: "system.invalidCommand", message: "The system command is invalid."))
        }
        if command == .sleepSystem { await confirmation.markSleepExplanationShown() }
        switch await service.execute(command) {
        case .success:
            return .success()
        case let .failure(error): return .failure(error)
        }
    }

    private struct Command: Sendable {
        let id: SystemCommandID
        let title: String
        let subtitle: String
        let symbol: String
        let keywords: [String]
    }

    private static let commands: [Command] = [
        Command(
            id: .sleepSystem, title: "Sleep Mac", subtitle: "Put this Mac to sleep", symbol: "moon.zzz", keywords: ["sleep", "system"]),
        Command(
            id: .openSystemSettings, title: "Open System Settings", subtitle: "Open macOS settings", symbol: "gear",
            keywords: ["preferences", "settings"]),
        Command(
            id: .openAccessibilitySettings, title: "Open Accessibility Privacy Settings", subtitle: "Manage window-control permission",
            symbol: "hand.raised", keywords: ["permission", "privacy", "accessibility"]),
        Command(
            id: .openScreenRecordingSettings, title: "Open Screen Recording Privacy Settings", subtitle: "Manage capture permission",
            symbol: "rectangle.dashed.badge.record", keywords: ["permission", "privacy", "screenshot"]),
        Command(
            id: .openApplicationsFolder, title: "Open Applications Folder", subtitle: "/Applications", symbol: "folder",
            keywords: ["apps", "finder"]),
        Command(
            id: .openDownloadsFolder, title: "Open Downloads Folder", subtitle: "Downloads", symbol: "arrow.down.circle",
            keywords: ["downloads", "finder"]),
        Command(id: .openHomeFolder, title: "Open Home Folder", subtitle: "Home", symbol: "house", keywords: ["home", "finder"]),
    ]
}
