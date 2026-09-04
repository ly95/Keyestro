import Foundation

/// A bounded reference to an icon rendered by the host.
public enum IconReference: Codable, Equatable, Sendable {
    case systemSymbol(String)
    case application(URL)
    case file(URL)
    case thumbnailPNG(Data)
    case extensionAsset(extensionID: String, path: String)
}

/// Supplemental, non-interactive metadata shown beside a launcher result.
public enum Accessory: Codable, Equatable, Sendable {
    case text(String)
    case keyboardShortcut(KeyEquivalent)
    case badge(String)
}

/// Controls whether a result preview may be shown or copied into diagnostics.
public enum ItemPrivacy: String, Codable, Sendable {
    case normal
    case sensitive
    case secret
}

/// Provider-supplied non-text ranking signals. Text matching is always computed by the host.
public struct ScoreFeatures: Codable, Equatable, Sendable {
    public let lastUsedAt: Date?
    public let executionCount90Days: Int
    public let context: Double
    public let providerPrior: Double
    public let isPinned: Bool

    public init(
        lastUsedAt: Date? = nil,
        executionCount90Days: Int = 0,
        context: Double = 0,
        providerPrior: Double = 0,
        isPinned: Bool = false
    ) {
        self.lastUsedAt = lastUsedAt
        self.executionCount90Days = max(0, executionCount90Days)
        self.context = context.clampedUnit
        self.providerPrior = providerPrior.clampedUnit
        self.isPinned = isPinned
    }
}

/// Uniform result model crossing every provider boundary.
public struct LauncherItem: Codable, Equatable, Identifiable, Sendable {
    public let id: ItemID
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String?
    public let icon: IconReference?
    public let canonicalResource: CanonicalResource?
    public let keywords: [String]
    /// Semantic aliases used instead of legacy subtitle/keyword matching when nonempty.
    public let searchAliases: [SearchAlias]
    public let accessories: [Accessory]
    public let actions: [ActionDescriptor]
    public let defaultActionID: ActionID
    public let scoreFeatures: ScoreFeatures
    public let privacy: ItemPrivacy

    public init(
        id: ItemID,
        providerID: ProviderID,
        title: String,
        subtitle: String? = nil,
        icon: IconReference? = nil,
        canonicalResource: CanonicalResource? = nil,
        keywords: [String] = [],
        searchAliases: [SearchAlias] = [],
        accessories: [Accessory] = [],
        actions: [ActionDescriptor],
        defaultActionID: ActionID,
        scoreFeatures: ScoreFeatures = ScoreFeatures(),
        privacy: ItemPrivacy = .normal
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.canonicalResource = canonicalResource
        self.keywords = keywords
        self.searchAliases = searchAliases
        self.accessories = accessories
        self.actions = actions
        self.defaultActionID = defaultActionID
        self.scoreFeatures = scoreFeatures
        self.privacy = privacy
    }

    /// Applies all host limits and drops malformed action lists.
    public func sanitized() -> Self? {
        let safeTitle = title.limitedToUnicodeScalars(DomainLimits.titleUnicodeScalars)
        guard !safeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var seenActions = Set<ActionID>()
        let safeActions = actions.prefix(DomainLimits.actionsPerItem).filter { action in
            !action.id.rawValue.isEmpty && seenActions.insert(action.id).inserted
        }
        guard !safeActions.isEmpty, safeActions.contains(where: { $0.id == defaultActionID }) else {
            return nil
        }

        let safeKeywords = keywords.prefix(DomainLimits.keywordCount).map {
            $0.limitedToUnicodeScalars(DomainLimits.keywordUnicodeScalars)
        }
        let safeSearchAliases: [SearchAlias] = searchAliases.prefix(DomainLimits.keywordCount).compactMap { alias -> SearchAlias? in
            let value = alias.value.limitedToUnicodeScalars(DomainLimits.keywordUnicodeScalars)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SearchAlias(value: value, role: alias.role, matchPolicy: alias.matchPolicy)
        }

        let safeIcon: IconReference?
        if case let .thumbnailPNG(data) = icon {
            safeIcon = data.count <= 256 * 1_024 ? icon : nil
        } else {
            safeIcon = icon
        }

        return Self(
            id: id,
            providerID: providerID,
            title: safeTitle,
            subtitle: subtitle?.limitedToUnicodeScalars(DomainLimits.subtitleUnicodeScalars),
            icon: safeIcon,
            canonicalResource: canonicalResource,
            keywords: safeKeywords,
            searchAliases: safeSearchAliases,
            accessories: accessories,
            actions: Array(safeActions),
            defaultActionID: defaultActionID,
            scoreFeatures: scoreFeatures,
            privacy: privacy
        )
    }

    public func replacingActions(_ actions: [ActionDescriptor]) -> Self {
        Self(
            id: id,
            providerID: providerID,
            title: title,
            subtitle: subtitle,
            icon: icon,
            canonicalResource: canonicalResource,
            keywords: keywords,
            searchAliases: searchAliases,
            accessories: accessories,
            actions: actions,
            defaultActionID: defaultActionID,
            scoreFeatures: scoreFeatures,
            privacy: privacy
        )
    }

    public func replacingScoreFeatures(_ scoreFeatures: ScoreFeatures) -> Self {
        Self(
            id: id,
            providerID: providerID,
            title: title,
            subtitle: subtitle,
            icon: icon,
            canonicalResource: canonicalResource,
            keywords: keywords,
            searchAliases: searchAliases,
            accessories: accessories,
            actions: actions,
            defaultActionID: defaultActionID,
            scoreFeatures: scoreFeatures,
            privacy: privacy
        )
    }
}

extension LauncherItem {
    private enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case title
        case subtitle
        case icon
        case canonicalResource
        case keywords
        case searchAliases
        case accessories
        case actions
        case defaultActionID
        case scoreFeatures
        case privacy
    }

    /// Decodes items written before semantic aliases existed with legacy keyword behavior intact.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(ItemID.self, forKey: .id),
            providerID: try container.decode(ProviderID.self, forKey: .providerID),
            title: try container.decode(String.self, forKey: .title),
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle),
            icon: try container.decodeIfPresent(IconReference.self, forKey: .icon),
            canonicalResource: try container.decodeIfPresent(CanonicalResource.self, forKey: .canonicalResource),
            keywords: try container.decode([String].self, forKey: .keywords),
            searchAliases: try container.decodeIfPresent([SearchAlias].self, forKey: .searchAliases) ?? [],
            accessories: try container.decode([Accessory].self, forKey: .accessories),
            actions: try container.decode([ActionDescriptor].self, forKey: .actions),
            defaultActionID: try container.decode(ActionID.self, forKey: .defaultActionID),
            scoreFeatures: try container.decode(ScoreFeatures.self, forKey: .scoreFeatures),
            privacy: try container.decode(ItemPrivacy.self, forKey: .privacy)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(canonicalResource, forKey: .canonicalResource)
        try container.encode(keywords, forKey: .keywords)
        if !searchAliases.isEmpty {
            try container.encode(searchAliases, forKey: .searchAliases)
        }
        try container.encode(accessories, forKey: .accessories)
        try container.encode(actions, forKey: .actions)
        try container.encode(defaultActionID, forKey: .defaultActionID)
        try container.encode(scoreFeatures, forKey: .scoreFeatures)
        try container.encode(privacy, forKey: .privacy)
    }
}

extension Double {
    fileprivate var clampedUnit: Double {
        guard isFinite else { return 0 }
        return min(1, max(0, self))
    }
}
