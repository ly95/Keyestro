import Combine
import Foundation

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsSection? = .general
    @Published var searchQuery = "" {
        didSet {
            reconcileSearchSelection(with: SettingsSearchCatalog.search(searchQuery))
        }
    }
    @Published private(set) var searchResultSelection: SettingsAnchor?
    @Published private(set) var pendingScrollRequest: SettingsScrollRequest?
    private var nextScrollRequestID: UInt64 = 0

    func navigate(to entry: SettingsSearchEntry) {
        searchResultSelection = entry.anchor
        selection = entry.section
        nextScrollRequestID &+= 1
        pendingScrollRequest = SettingsScrollRequest(
            id: nextScrollRequestID,
            anchor: entry.anchor
        )
    }

    func consumePendingScrollRequest(_ request: SettingsScrollRequest) {
        guard pendingScrollRequest == request else { return }
        pendingScrollRequest = nil
    }

    func moveSectionSelection(_ direction: SettingsNavigationDirection) {
        guard
            let next = adjacentValue(
                to: selection,
                in: SettingsSection.allCases,
                direction: direction
            )
        else { return }
        selection = next
    }

    func moveSearchSelection(
        _ direction: SettingsNavigationDirection,
        in results: [SettingsSearchEntry]
    ) {
        let anchors = results.map(\.anchor)
        guard
            let next = adjacentValue(
                to: searchResultSelection,
                in: anchors,
                direction: direction
            )
        else {
            searchResultSelection = nil
            return
        }
        searchResultSelection = next
    }

    func activateSearchSelection(in results: [SettingsSearchEntry]) {
        guard let entry = selectedSearchEntry(in: results) else { return }
        navigate(to: entry)
    }

    func selectedSearchEntry(in results: [SettingsSearchEntry]) -> SettingsSearchEntry? {
        guard !results.isEmpty else { return nil }
        return results.first { $0.anchor == searchResultSelection } ?? results.first
    }

    func reconcileSearchSelection(with results: [SettingsSearchEntry]) {
        guard !results.isEmpty else {
            searchResultSelection = nil
            return
        }
        if !results.contains(where: { $0.anchor == searchResultSelection }) {
            searchResultSelection = results[0].anchor
        }
    }

    private func adjacentValue<Value: Equatable>(
        to current: Value?,
        in values: [Value],
        direction: SettingsNavigationDirection
    ) -> Value? {
        guard !values.isEmpty else { return nil }
        guard let current, let currentIndex = values.firstIndex(of: current) else {
            return values[0]
        }

        switch direction {
        case .previous:
            return values[max(values.startIndex, currentIndex - 1)]
        case .next:
            return values[min(values.index(before: values.endIndex), currentIndex + 1)]
        }
    }
}

enum SettingsNavigationDirection: Sendable {
    case previous
    case next
}

struct SettingsScrollRequest: Equatable, Sendable {
    let id: UInt64
    let anchor: SettingsAnchor
}

/// Search targets and rendered scroll IDs share this type so adding a catalog
/// entry cannot silently introduce a misspelled string target.
enum SettingsAnchor: String, CaseIterable, Hashable, Sendable {
    case generalAppearance = "general.appearance"
    case generalDock = "general.dock"
    case generalLogin = "general.login"
    case shortcutsHotKeys = "shortcuts.hotkeys"
    case shortcutsNumbers = "shortcuts.numbers"
    case shortcutsPrefixes = "shortcuts.prefixes"
    case featuresFiles = "features.files"
    case featuresSleep = "features.sleep"
    case featuresClipboard = "features.clipboard"
    case featuresQuickPaste = "features.quick-paste"
    case featuresRetention = "features.retention"
    case featuresExclusions = "features.exclusions"
    case featuresOCR = "features.ocr"
    case featuresQuicklinks = "features.quicklinks"
    case featuresScripts = "features.scripts"
    case extensionsInstalled = "extensions.installed"
    case permissionsAccessibility = "permissions.accessibility"
    case permissionsScreenRecording = "permissions.screen-recording"
    case privacySummary = "privacy.summary"
    case privacyRanking = "privacy.ranking"
    case privacyClipboard = "privacy.clipboard"
    case privacyDelete = "privacy.delete"
    case updatesAutomatic = "updates.automatic"
    case updatesChannel = "updates.channel"
    case updatesCheck = "updates.check"
    case advancedPerformance = "advanced.performance"
    case advancedDiagnostics = "advanced.diagnostics"
    case advancedConfiguration = "advanced.configuration"
    case advancedCaches = "advanced.caches"
    case advancedDefaults = "advanced.defaults"
    case aboutVersion = "about.version"
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case shortcuts = "Shortcuts"
    case features = "Features"
    case extensions = "Extensions"
    case permissions = "Permissions"
    case privacy = "Privacy"
    case updates = "Updates"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    var title: String {
        let key =
            switch self {
            case .general: L10n.text("settings.section.general")
            case .shortcuts: L10n.text("settings.section.shortcuts")
            case .features: L10n.text("settings.section.features")
            case .extensions: L10n.text("settings.section.extensions")
            case .permissions: L10n.text("settings.section.permissions")
            case .privacy: L10n.text("settings.section.privacy")
            case .updates: L10n.text("settings.section.updates")
            case .advanced: L10n.text("settings.section.advanced")
            case .about: L10n.text("settings.section.about")
            }
        return key == "settings.section.\(rawValue.lowercased())" ? rawValue : key
    }

    var symbol: String {
        switch self {
        case .general: "gear"
        case .shortcuts: "keyboard"
        case .features: "square.grid.2x2"
        case .extensions: "puzzlepiece.extension"
        case .permissions: "hand.raised"
        case .privacy: "lock.shield"
        case .updates: "arrow.triangle.2.circlepath"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            L10n.text("Choose how Keyestro looks and behaves on this Mac.")
        case .shortcuts:
            L10n.text("Set the shortcuts and query gestures you use every day.")
        case .features:
            L10n.text("Configure local search, clipboard, capture, quick links, and scripts.")
        case .extensions:
            L10n.text("Review and manage the local extensions you trust.")
        case .permissions:
            L10n.text("See why access is needed and control it in macOS.")
        case .privacy:
            L10n.text("Keep local data, learning, and cleanup under your control.")
        case .updates:
            L10n.text("Choose how Keyestro checks for and installs new versions.")
        case .advanced:
            L10n.text("Diagnostics, backups, performance, and maintenance.")
        case .about:
            L10n.text("Version, license, and the local-first principles behind Keyestro.")
        }
    }
}

struct SettingsSearchEntry: Identifiable, Equatable {
    let anchor: SettingsAnchor
    let title: String
    let section: SettingsSection
    let keywords: [String]

    var id: String { anchor.rawValue }
    var localizedTitle: String {
        // These search-only labels do not otherwise appear as static SwiftUI
        // strings, so keep their localization keys visible to extraction.
        switch anchor {
        case .shortcutsHotKeys: L10n.text("Global shortcuts")
        case .privacySummary: L10n.text("Local data and query privacy")
        case .privacyClipboard: L10n.text("Clipboard privacy")
        case .aboutVersion: L10n.text("Keyestro version and license")
        default: L10n.text(title)
        }
    }
}

enum SettingsSearchCatalog {
    static let entries: [SettingsSearchEntry] = [
        entry(.generalAppearance, "Launcher appearance", .general, "theme", "light", "dark", "auto"),
        entry(.generalDock, "Show Keyestro in the Dock", .general, "dock icon", "menu bar"),
        entry(.generalLogin, "Launch at Login", .general, "startup", "login item", "open at startup"),

        entry(
            .shortcutsHotKeys,
            "Global shortcuts",
            .shortcuts,
            "hotkey",
            "launcher",
            "clipboard history",
            "quick paste"
        ),
        entry(
            .shortcutsNumbers,
            "Command-number opens visible results",
            .shortcuts,
            "command 1",
            "number row",
            "result slot"
        ),
        entry(
            .shortcutsPrefixes,
            "Enable /, >, =, and @ query prefixes",
            .shortcuts,
            "slash",
            "greater than",
            "equals",
            "at",
            "provider mode"
        ),

        entry(.featuresFiles, "File Search", .features, "spotlight", "content", "hidden files", "system locations", "trash"),
        entry(
            .featuresSleep,
            "Always confirm before putting this Mac to sleep",
            .features,
            "confirm",
            "system action",
            "power"
        ),
        entry(.featuresClipboard, "Clipboard history", .features, "monitoring", "pause", "local", "encrypted"),
        entry(
            .featuresQuickPaste,
            "Quick Paste",
            .features,
            "paste latest",
            "clipboard",
            "accessibility",
            "sensitive text"
        ),
        entry(.featuresRetention, "Clipboard retention", .features, "history", "quota", "days", "unlimited"),
        entry(
            .featuresExclusions,
            "Excluded application Bundle IDs (one per line)",
            .features,
            "bundle id",
            "privacy",
            "ignore app"
        ),
        entry(.featuresOCR, "OCR recognition languages", .features, "vision", "recognition", "english", "chinese", "japanese"),
        entry(.featuresQuicklinks, "Quick Links", .features, "url", "web search", "template"),
        entry(.featuresScripts, "Scripts", .features, "command", "executable", "managed script"),

        entry(.extensionsInstalled, "Installed Extensions", .extensions, "plugin", "package", "global search", "preferences"),

        entry(.permissionsAccessibility, "Accessibility", .permissions, "paste", "keyboard", "window management"),
        entry(.permissionsScreenRecording, "Screen Recording", .permissions, "screenshot", "capture", "ocr"),

        entry(
            .privacySummary,
            "Local data and query privacy",
            .privacy,
            "local first",
            "raw query",
            "diagnostics"
        ),
        entry(.privacyRanking, "Learn from successful actions", .privacy, "ranking", "usage history", "frecency"),
        entry(
            .privacyClipboard,
            "Clipboard privacy",
            .privacy,
            "clear history",
            "encrypted",
            "sensitive"
        ),
        entry(.privacyDelete, "Delete All Local Data and Quit…", .privacy, "erase", "reset", "quit"),

        entry(.updatesAutomatic, "Automatically check for updates", .updates, "check", "download"),
        entry(.updatesChannel, "Update channel", .updates, "stable", "beta"),
        entry(.updatesCheck, "Check Now", .updates, "version", "sparkle"),

        entry(.advancedPerformance, "Local Performance Diagnostics", .advanced, "timing", "p50", "p95", "report"),
        entry(.advancedDiagnostics, "Diagnostics", .advanced, "logs", "support", "export"),
        entry(.advancedConfiguration, "Configuration", .advanced, "backup", "import", "export", "settings", "json"),
        entry(.advancedCaches, "Clear Caches", .advanced, "reset cache", "cleanup"),
        entry(.advancedDefaults, "Restore default settings", .advanced, "reset preferences", "factory defaults"),

        entry(.aboutVersion, "Keyestro version and license", .about, "build", "open source", "apache"),
    ]

    static func search(_ query: String) -> [SettingsSearchEntry] {
        let tokens = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        return entries.compactMap { entry -> (SettingsSearchEntry, Int)? in
            let title = normalized(entry.localizedTitle)
            let fallbackTitle = normalized(entry.title)
            let section = normalized(entry.section.title)
            let keywords = entry.keywords.map(normalized)
            var total = 0

            for token in tokens {
                let scores =
                    [
                        matchScore(token, in: title, title: true),
                        matchScore(token, in: fallbackTitle, title: true),
                        matchScore(token, in: section, title: false),
                    ] + keywords.map { matchScore(token, in: $0, title: false) }
                guard let best = scores.min(), best < noMatchScore else { return nil }
                total += best
            }
            return (entry, total)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let lhsSection = SettingsSection.allCases.firstIndex(of: lhs.0.section) ?? .max
            let rhsSection = SettingsSection.allCases.firstIndex(of: rhs.0.section) ?? .max
            if lhsSection != rhsSection { return lhsSection < rhsSection }
            return lhs.0.localizedTitle.localizedStandardCompare(rhs.0.localizedTitle) == .orderedAscending
        }
        .map(\.0)
    }

    private static func entry(
        _ anchor: SettingsAnchor,
        _ title: String,
        _ section: SettingsSection,
        _ keywords: String...
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(anchor: anchor, title: title, section: section, keywords: keywords)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private static func matchScore(_ token: String, in value: String, title: Bool) -> Int {
        if value == token { return title ? 0 : 3 }
        if value.hasPrefix(token) { return title ? 1 : 4 }
        if value.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix(token) }) {
            return title ? 2 : 5
        }
        if value.contains(token) { return title ? 3 : 6 }
        return noMatchScore
    }

    private static let noMatchScore = Int.max / 16
}
