import Foundation

/// Stable identifier for a search provider.
public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Stable identifier for an item within one provider.
public struct ItemID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let providerID: ProviderID
    public let providerStableID: String

    public init(providerID: ProviderID, providerStableID: String) {
        self.providerID = providerID
        self.providerStableID = providerStableID
    }

    public var description: String {
        "\(providerID.rawValue):\(providerStableID)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.providerID != rhs.providerID {
            return lhs.providerID < rhs.providerID
        }
        return lhs.providerStableID < rhs.providerStableID
    }
}

/// Identifier for an action within an item.
public struct ActionID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Canonical identity used to deduplicate resources returned by different providers.
public enum CanonicalResource: Codable, Hashable, Sendable {
    case application(bundleIdentifier: String)
    case file(URL)
    case url(URL)
    case command(String)
}
