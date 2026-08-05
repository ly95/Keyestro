import Foundation

/// Stable, localizable error information crossing a domain boundary.
public struct ErrorDescriptor: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverySuggestion: String?

    public init(code: String, message: String, recoverySuggestion: String? = nil) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

/// Shared validation limits required at every provider boundary.
public enum DomainLimits {
    public static let queryUnicodeScalars = 512
    public static let titleUnicodeScalars = 512
    public static let subtitleUnicodeScalars = 2_048
    public static let keywordCount = 50
    public static let keywordUnicodeScalars = 256
    public static let actionsPerItem = 50
    public static let itemsPerBatch = 50
    public static let visibleItems = 50
    public static let candidatesPerProvider = 200
    public static let aggregateCandidates = 1_000
}

extension String {
    /// Returns a scalar-bounded string without splitting a Unicode scalar.
    public func limitedToUnicodeScalars(_ maximum: Int) -> String {
        guard maximum >= 0, unicodeScalars.count > maximum else { return self }
        return String(String.UnicodeScalarView(unicodeScalars.prefix(maximum)))
    }
}
