import Foundation

/// The minimum user-safety classification the host must enforce before executing an action.
public enum ActionRisk: String, Codable, CaseIterable, Sendable, Comparable {
    case safe
    case externalSideEffect
    case destructive

    private var severity: Int {
        switch self {
        case .safe: 0
        case .externalSideEffect: 1
        case .destructive: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// Describes how the launcher UI changes after an action completes.
public enum ActionBehavior: String, Codable, Sendable {
    case closeLauncher
    case keepLauncherOpen
    case replaceContent
}

/// A portable keyboard shortcut made from a key and modifier set.
public struct KeyEquivalent: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// A modifier supported by launcher action shortcuts.
public enum KeyModifier: String, Codable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
}

/// The declarative editor and validation rules for an action argument.
public enum ArgumentKind: Codable, Equatable, Sendable {
    case text
    case password
    case choice(options: [String])
    case file
    case directory
}

/// A bounded, declarative argument requested before an action runs.
public struct ArgumentDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: ArgumentKind
    public let required: Bool
    public let placeholder: String?

    public init(
        id: String,
        title: String,
        kind: ArgumentKind,
        required: Bool,
        placeholder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.required = required
        self.placeholder = placeholder
    }
}

/// A validated value supplied for an action argument.
public enum ArgumentValue: Codable, Equatable, Sendable {
    case text(String)
    case file(URL)
}

/// Host-owned route added when actions from a duplicate item are merged.
public struct ActionRoute: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let itemID: ItemID
    public let actionID: ActionID

    public init(providerID: ProviderID, itemID: ItemID, actionID: ActionID) {
        self.providerID = providerID
        self.itemID = itemID
        self.actionID = actionID
    }
}

/// User-visible action metadata, including risk, behavior, arguments, and an optional provider route.
public struct ActionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: ActionID
    public let title: String
    public let icon: IconReference?
    public let shortcut: KeyEquivalent?
    public let behavior: ActionBehavior
    public let risk: ActionRisk
    /// A non-secret, action-specific description of the object affected by a
    /// confirmed action. The host owns the confirmation UI and never treats
    /// this value as an execution route.
    public let confirmationTarget: String?
    public let arguments: [ArgumentDefinition]
    public let route: ActionRoute?

    public init(
        id: ActionID,
        title: String,
        icon: IconReference? = nil,
        shortcut: KeyEquivalent? = nil,
        behavior: ActionBehavior = .closeLauncher,
        risk: ActionRisk = .safe,
        confirmationTarget: String? = nil,
        arguments: [ArgumentDefinition] = [],
        route: ActionRoute? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.behavior = behavior
        self.risk = risk
        let boundedTarget = confirmationTarget?.limitedToUnicodeScalars(DomainLimits.subtitleUnicodeScalars)
        self.confirmationTarget =
            boundedTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? boundedTarget : nil
        self.arguments = arguments
        self.route = route
    }

    public func routed(from providerID: ProviderID, itemID: ItemID, displayedID: ActionID) -> Self {
        Self(
            id: displayedID,
            title: title,
            icon: icon,
            shortcut: shortcut,
            behavior: behavior,
            risk: risk,
            confirmationTarget: confirmationTarget,
            arguments: arguments,
            route: ActionRoute(providerID: providerID, itemID: itemID, actionID: id)
        )
    }
}

/// A generation-bound request to execute a stable item and action pair.
public struct ActionExecutionRequest: Sendable, Equatable {
    public let executionID: UUID
    public let generation: UInt64
    public let itemID: ItemID
    public let actionID: ActionID
    public let arguments: [String: ArgumentValue]

    public init(
        executionID: UUID = UUID(),
        generation: UInt64,
        itemID: ItemID,
        actionID: ActionID,
        arguments: [String: ArgumentValue] = [:]
    ) {
        self.executionID = executionID
        self.generation = generation
        self.itemID = itemID
        self.actionID = actionID
        self.arguments = arguments
    }
}

/// The structured completion state returned by an action provider.
public enum ActionResult: Equatable, Sendable {
    case success(message: String? = nil)
    case cancelled
    case failure(ErrorDescriptor)
}
