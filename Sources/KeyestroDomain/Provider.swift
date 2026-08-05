import Foundation

/// Declares a provider's identity, supported query modes, and empty-query behavior.
public struct ProviderDescriptor: Codable, Equatable, Sendable {
    public let id: ProviderID
    public let displayName: String
    public let supportedModes: Set<QueryMode>
    public let supportsEmptyQuery: Bool
    public let isNetworkProvider: Bool

    public init(
        id: ProviderID,
        displayName: String,
        supportedModes: Set<QueryMode>,
        supportsEmptyQuery: Bool,
        isNetworkProvider: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedModes = supportedModes
        self.supportsEmptyQuery = supportsEmptyQuery
        self.isNetworkProvider = isNetworkProvider
    }
}

/// A provider's current user-visible availability or failure state.
public enum ProviderStatus: Equatable, Sendable {
    case loading
    case ready
    case empty
    case slow
    case permissionDenied(ErrorDescriptor)
    case unavailable(ErrorDescriptor)
    case failed(ErrorDescriptor)
}

/// A bounded streaming update emitted by a search provider.
public enum ProviderEvent: Sendable {
    case items([LauncherItem], isFinal: Bool)
    /// Replaces the provider's entire current result set, including removal of stale live results.
    case replacement([LauncherItem], isFinal: Bool)
    case status(ProviderStatus)
}

/// A cancellable, streaming source of launcher candidates.
public protocol SearchProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error>
}

/// A validated launcher item paired with its deterministic aggregate score.
public struct RankedItem: Identifiable, Equatable, Sendable {
    public let item: LauncherItem
    public let score: Double
    public let matchTier: MatchTier

    public init(item: LauncherItem, score: Double, matchTier: MatchTier) {
        self.item = item
        self.score = score
        self.matchTier = matchTier
    }

    public var id: ItemID { item.id }
}

/// An immutable, generation-bound view of aggregate query results and provider states.
public struct QuerySnapshot: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let items: [RankedItem]
    public let statuses: [ProviderID: ProviderStatus]
    public let isComplete: Bool

    public init(
        requestID: UUID,
        generation: UInt64,
        items: [RankedItem],
        statuses: [ProviderID: ProviderStatus],
        isComplete: Bool
    ) {
        self.requestID = requestID
        self.generation = generation
        self.items = items
        self.statuses = statuses
        self.isComplete = isComplete
    }
}
