import Foundation
import KeyestroDomain

/// Resolved provider action. Providers never receive a stale array index.
public struct ProviderActionRequest: Sendable, Equatable {
    public let executionID: UUID
    public let itemID: ItemID
    public let actionID: ActionID
    public let arguments: [String: ArgumentValue]

    public init(
        executionID: UUID,
        itemID: ItemID,
        actionID: ActionID,
        arguments: [String: ArgumentValue]
    ) {
        self.executionID = executionID
        self.itemID = itemID
        self.actionID = actionID
        self.arguments = arguments
    }
}

/// Search provider that can also execute actions against its own stable resources.
public protocol LauncherProvider: SearchProvider {
    func execute(request: ProviderActionRequest) async -> ActionResult
}

/// Optional provider lifecycle hook for work that should happen when the app starts,
/// rather than on the first visible launcher query.
public protocol LauncherProviderPrewarming: Sendable {
    func prewarm() async
}

public struct ResolvedAction: Sendable, Equatable {
    public let providerID: ProviderID
    public let itemID: ItemID
    public let actionID: ActionID
    public let descriptor: ActionDescriptor
    public let displayedTitle: String
    public let displayedSubtitle: String?
    public let privacy: ItemPrivacy

    public init(
        providerID: ProviderID,
        itemID: ItemID,
        actionID: ActionID,
        descriptor: ActionDescriptor,
        displayedTitle: String,
        displayedSubtitle: String?,
        privacy: ItemPrivacy
    ) {
        self.providerID = providerID
        self.itemID = itemID
        self.actionID = actionID
        self.descriptor = descriptor
        self.displayedTitle = displayedTitle
        self.displayedSubtitle = displayedSubtitle
        self.privacy = privacy
    }
}

public enum ActionRunOutcome: Sendable, Equatable {
    case confirmationRequired(ResolvedAction)
    case completed(ActionResult)
}
