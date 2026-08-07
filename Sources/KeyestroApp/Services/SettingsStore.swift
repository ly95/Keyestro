import AppKit
import Combine
import Foundation
import KeyestroCore

enum SettingsImportError: Error, Equatable {
    case persistenceFailed
    case rollbackFailed
}

enum LauncherAppearancePreference: String, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let showDockIcon = "general.showDockIcon"
        static let launcherAppearance = "appearance.launcher"
        static let prefixesEnabled = "search.prefixesEnabled"
        static let rankingLearningEnabled = "ranking.learningEnabled"
        static let numberShortcutsEnabled = "shortcuts.numberShortcutsEnabled"
        static let launcherKeyCode = "shortcuts.launcher.keyCode"
        static let launcherModifiers = "shortcuts.launcher.modifiers"
        static let launcherShortcut = "shortcuts.launcher.combined"
        static let clipboardHistoryKeyCode = "shortcuts.clipboardHistory.keyCode"
        static let clipboardHistoryModifiers = "shortcuts.clipboardHistory.modifiers"
        static let clipboardHistoryShortcut = "shortcuts.clipboardHistory.combined"
        static let quickPasteShortcut = "shortcuts.quickPaste.combined"
        static let quickPasteEnabled = "clipboard.quickPaste.enabled"
        static let quickPasteAllowsSensitiveContent = "clipboard.quickPaste.allowsSensitiveContent"
        static let clipboardEnabled = "clipboard.enabled"
        static let clipboardPaused = "clipboard.paused"
        static let clipboardRetentionPreset = "clipboard.retentionPreset"
        static let clipboardExcludedApplications = "clipboard.excludedApplications"
        static let ocrLanguagePreset = "capture.ocrLanguagePreset"
        static let fileContentSearchEnabled = "files.contentSearchEnabled"
        static let fileHiddenFilesEnabled = "files.hiddenFilesEnabled"
        static let fileSystemLocationsEnabled = "files.systemLocationsEnabled"
        static let fileTrashEnabled = "files.trashEnabled"
        static let confirmSleepEveryTime = "system.confirmSleepEveryTime"
        static let sleepExplanationShown = "system.sleepExplanationShown"
        static let onboardingCompleted = "lifecycle.onboardingCompleted"
    }

    private let persistence: any SettingsPersisting
    private var isRollingBackSetting = false
    private var isApplyingShortcuts = false
    private var fileSearchPreferencesGeneration: UInt64 = 0
    let fileSearchPreferences: FileSearchPreferences
    let rankingLearningPreferences: RankingLearningPreferences
    @Published private(set) var persistenceError: String?

    @Published var showDockIcon: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(showDockIcon, forKey: Key.showDockIcon) else {
                rollbackSetting { showDockIcon = oldValue }
                return
            }
            applyActivationPolicy()
        }
    }

    @Published var launcherAppearance: LauncherAppearancePreference {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(launcherAppearance.rawValue, forKey: Key.launcherAppearance) {
                rollbackSetting { launcherAppearance = oldValue }
            }
        }
    }

    @Published var prefixesEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(prefixesEnabled, forKey: Key.prefixesEnabled) {
                rollbackSetting { prefixesEnabled = oldValue }
            }
        }
    }

    @Published var rankingLearningEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(rankingLearningEnabled, forKey: Key.rankingLearningEnabled) else {
                rollbackSetting { rankingLearningEnabled = oldValue }
                return
            }
            rankingLearningPreferences.setEnabled(rankingLearningEnabled)
        }
    }

    @Published var numberShortcutsEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(numberShortcutsEnabled, forKey: Key.numberShortcutsEnabled) {
                rollbackSetting { numberShortcutsEnabled = oldValue }
            }
        }
    }

    @Published var launcherShortcut: HotKeyShortcut {
        didSet {
            guard !isRollingBackSetting else { return }
            guard
                isApplyingShortcuts
                    || (launcherShortcut != clipboardHistoryShortcut && launcherShortcut != quickPasteShortcut)
            else {
                shortcutValidationError = "Keyestro shortcuts must be different."
                rollbackSetting { launcherShortcut = oldValue }
                return
            }
            let value = "\(launcherShortcut.keyCode):\(launcherShortcut.modifiers)"
            if !persist(value, forKey: Key.launcherShortcut) {
                rollbackSetting { launcherShortcut = oldValue }
            } else {
                shortcutValidationError = nil
            }
        }
    }

    @Published var clipboardHistoryShortcut: HotKeyShortcut {
        didSet {
            guard !isRollingBackSetting else { return }
            guard
                isApplyingShortcuts
                    || (clipboardHistoryShortcut != launcherShortcut && clipboardHistoryShortcut != quickPasteShortcut)
            else {
                shortcutValidationError = "Keyestro shortcuts must be different."
                rollbackSetting { clipboardHistoryShortcut = oldValue }
                return
            }
            let value = "\(clipboardHistoryShortcut.keyCode):\(clipboardHistoryShortcut.modifiers)"
            if !persist(value, forKey: Key.clipboardHistoryShortcut) {
                rollbackSetting { clipboardHistoryShortcut = oldValue }
            } else {
                shortcutValidationError = nil
            }
        }
    }

    @Published var quickPasteShortcut: HotKeyShortcut? {
        didSet {
            guard !isRollingBackSetting else { return }
            guard
                isApplyingShortcuts
                    || quickPasteShortcut == nil
                    || (quickPasteShortcut != launcherShortcut && quickPasteShortcut != clipboardHistoryShortcut)
            else {
                shortcutValidationError = "Keyestro shortcuts must be different."
                rollbackSetting { quickPasteShortcut = oldValue }
                return
            }
            let value = quickPasteShortcut.map { "\($0.keyCode):\($0.modifiers)" } ?? ""
            if !persist(value, forKey: Key.quickPasteShortcut) {
                rollbackSetting { quickPasteShortcut = oldValue }
            } else {
                shortcutValidationError = nil
            }
        }
    }

    @Published private(set) var shortcutValidationError: String?
    @Published private(set) var hotKeyRegistrationError: String?
    @Published private(set) var clipboardHistoryHotKeyRegistrationError: String?
    @Published private(set) var quickPasteHotKeyRegistrationError: String?

    @Published var quickPasteEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(quickPasteEnabled, forKey: Key.quickPasteEnabled) {
                rollbackSetting { quickPasteEnabled = oldValue }
            }
        }
    }

    @Published var quickPasteAllowsSensitiveContent: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(quickPasteAllowsSensitiveContent, forKey: Key.quickPasteAllowsSensitiveContent) {
                rollbackSetting { quickPasteAllowsSensitiveContent = oldValue }
            }
        }
    }

    @Published var clipboardEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(clipboardEnabled, forKey: Key.clipboardEnabled) {
                rollbackSetting { clipboardEnabled = oldValue }
            }
        }
    }

    @Published var clipboardPaused: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(clipboardPaused, forKey: Key.clipboardPaused) {
                rollbackSetting { clipboardPaused = oldValue }
            }
        }
    }

    @Published var clipboardRetentionPreset: String {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(clipboardRetentionPreset, forKey: Key.clipboardRetentionPreset) {
                rollbackSetting { clipboardRetentionPreset = oldValue }
            }
        }
    }

    @Published var clipboardExcludedApplications: String {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(clipboardExcludedApplications, forKey: Key.clipboardExcludedApplications) {
                rollbackSetting { clipboardExcludedApplications = oldValue }
            }
        }
    }

    @Published var ocrLanguagePreset: String {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(ocrLanguagePreset, forKey: Key.ocrLanguagePreset) {
                rollbackSetting { ocrLanguagePreset = oldValue }
            }
        }
    }

    @Published var fileContentSearchEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(fileContentSearchEnabled, forKey: Key.fileContentSearchEnabled) else {
                rollbackSetting { fileContentSearchEnabled = oldValue }
                return
            }
            syncFileSearchPreferences()
        }
    }

    @Published var fileHiddenFilesEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(fileHiddenFilesEnabled, forKey: Key.fileHiddenFilesEnabled) else {
                rollbackSetting { fileHiddenFilesEnabled = oldValue }
                return
            }
            syncFileSearchPreferences()
        }
    }

    @Published var fileSystemLocationsEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(fileSystemLocationsEnabled, forKey: Key.fileSystemLocationsEnabled) else {
                rollbackSetting { fileSystemLocationsEnabled = oldValue }
                return
            }
            syncFileSearchPreferences()
        }
    }

    @Published var fileTrashEnabled: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            guard persist(fileTrashEnabled, forKey: Key.fileTrashEnabled) else {
                rollbackSetting { fileTrashEnabled = oldValue }
                return
            }
            syncFileSearchPreferences()
        }
    }

    @Published var confirmSleepEveryTime: Bool {
        didSet {
            guard !isRollingBackSetting else { return }
            if !persist(confirmSleepEveryTime, forKey: Key.confirmSleepEveryTime) {
                rollbackSetting { confirmSleepEveryTime = oldValue }
            }
        }
    }

    @Published private(set) var onboardingCompleted: Bool

    var ocrRecognitionLanguages: [String] {
        switch ocrLanguagePreset {
        case "en-US": ["en-US"]
        case "zh-Hans": ["zh-Hans"]
        case "ja-JP": ["ja-JP"]
        case "en-zh": ["en-US", "zh-Hans"]
        default: []
        }
    }

    var clipboardRetentionPolicy: ClipboardRetentionPolicy {
        Self.clipboardRetentionPolicy(for: clipboardRetentionPreset)
    }

    static func clipboardRetentionPolicy(for preset: String) -> ClipboardRetentionPolicy {
        switch preset {
        case "1-day": ClipboardRetentionPolicy(maximumAge: 86_400, maximumItemCount: 1_000)
        case "7-days": ClipboardRetentionPolicy(maximumAge: 7 * 86_400, maximumItemCount: 1_000)
        case "90-days": ClipboardRetentionPolicy(maximumAge: 90 * 86_400, maximumItemCount: 1_000)
        case "unlimited": ClipboardRetentionPolicy(maximumAge: nil, maximumItemCount: nil)
        default: ClipboardRetentionPolicy(maximumAge: 30 * 86_400, maximumItemCount: 1_000)
        }
    }

    var excludedClipboardBundleIdentifiers: Set<String> {
        Self.excludedClipboardBundleIdentifiers(from: clipboardExcludedApplications)
    }

    static func excludedClipboardBundleIdentifiers(from value: String) -> Set<String> {
        Set(
            value
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 255 && !$0.contains(where: \.isWhitespace) }
        )
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(persistence: UserDefaultsSettingsPersistence(defaults: defaults))
    }

    init(persistence: any SettingsPersisting) {
        self.persistence = persistence
        persistenceError = nil
        let contentSearch = persistence.object(forKey: Key.fileContentSearchEnabled) as? Bool ?? false
        let hiddenFiles = persistence.object(forKey: Key.fileHiddenFilesEnabled) as? Bool ?? false
        let systemLocations = persistence.object(forKey: Key.fileSystemLocationsEnabled) as? Bool ?? false
        let trash = persistence.object(forKey: Key.fileTrashEnabled) as? Bool ?? false
        fileSearchPreferences = FileSearchPreferences(
            SpotlightSearchOptions(
                searchContents: contentSearch,
                includeHiddenFiles: hiddenFiles,
                includeSystemLocations: systemLocations,
                includeTrash: trash
            )
        )
        let learningEnabled = persistence.object(forKey: Key.rankingLearningEnabled) as? Bool ?? true
        rankingLearningPreferences = RankingLearningPreferences(enabled: learningEnabled)
        showDockIcon = persistence.object(forKey: Key.showDockIcon) as? Bool ?? false
        launcherAppearance =
            LauncherAppearancePreference(
                rawValue: persistence.string(forKey: Key.launcherAppearance) ?? ""
            ) ?? .automatic
        prefixesEnabled = persistence.object(forKey: Key.prefixesEnabled) as? Bool ?? true
        rankingLearningEnabled = learningEnabled
        numberShortcutsEnabled = persistence.object(forKey: Key.numberShortcutsEnabled) as? Bool ?? true
        let storedShortcut = Self.loadShortcut(
            from: persistence,
            combinedKey: Key.launcherShortcut,
            keyCodeKey: Key.launcherKeyCode,
            modifiersKey: Key.launcherModifiers,
            defaultShortcut: .optionSpace
        )
        launcherShortcut = storedShortcut
        let storedClipboardShortcut = Self.loadShortcut(
            from: persistence,
            combinedKey: Key.clipboardHistoryShortcut,
            keyCodeKey: Key.clipboardHistoryKeyCode,
            modifiersKey: Key.clipboardHistoryModifiers,
            defaultShortcut: .optionShiftV
        )
        let resolvedClipboardShortcut: HotKeyShortcut =
            if storedClipboardShortcut != storedShortcut {
                storedClipboardShortcut
            } else if storedShortcut != .optionShiftV {
                .optionShiftV
            } else {
                .optionSpace
            }
        clipboardHistoryShortcut = resolvedClipboardShortcut
        let storedQuickPasteShortcut = Self.loadOptionalShortcut(
            from: persistence,
            combinedKey: Key.quickPasteShortcut
        )
        quickPasteShortcut =
            if storedQuickPasteShortcut != storedShortcut
                && storedQuickPasteShortcut != resolvedClipboardShortcut
            {
                storedQuickPasteShortcut
            } else {
                nil
            }
        shortcutValidationError = nil
        hotKeyRegistrationError = nil
        clipboardHistoryHotKeyRegistrationError = nil
        quickPasteHotKeyRegistrationError = nil
        quickPasteEnabled = persistence.object(forKey: Key.quickPasteEnabled) as? Bool ?? false
        quickPasteAllowsSensitiveContent =
            persistence.object(forKey: Key.quickPasteAllowsSensitiveContent) as? Bool ?? true
        clipboardEnabled = persistence.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        clipboardPaused = persistence.object(forKey: Key.clipboardPaused) as? Bool ?? false
        clipboardRetentionPreset = persistence.string(forKey: Key.clipboardRetentionPreset) ?? "30-days"
        clipboardExcludedApplications = persistence.string(forKey: Key.clipboardExcludedApplications) ?? ""
        ocrLanguagePreset = persistence.string(forKey: Key.ocrLanguagePreset) ?? "en-zh"
        fileContentSearchEnabled = contentSearch
        fileHiddenFilesEnabled = hiddenFiles
        fileSystemLocationsEnabled = systemLocations
        fileTrashEnabled = trash
        confirmSleepEveryTime = persistence.object(forKey: Key.confirmSleepEveryTime) as? Bool ?? true
        onboardingCompleted = persistence.bool(forKey: Key.onboardingCompleted)
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    func restoreDefaults() throws {
        do {
            try applyImportedConfiguration(Self.defaultConfiguration)
        } catch SettingsImportError.rollbackFailed {
            persistenceError =
                "Default settings could not be restored, and automatic rollback was incomplete. Restore a configuration backup."
            throw SettingsImportError.rollbackFailed
        } catch {
            persistenceError = "Default settings could not be restored. Previous values were kept."
            throw SettingsImportError.persistenceFailed
        }
    }

    func exportedConfiguration() -> [String: JSONValue] {
        [
            Key.showDockIcon: .bool(showDockIcon),
            Key.launcherAppearance: .string(launcherAppearance.rawValue),
            Key.prefixesEnabled: .bool(prefixesEnabled),
            Key.rankingLearningEnabled: .bool(rankingLearningEnabled),
            Key.numberShortcutsEnabled: .bool(numberShortcutsEnabled),
            Key.launcherKeyCode: .integer(Int64(launcherShortcut.keyCode)),
            Key.launcherModifiers: .integer(Int64(launcherShortcut.modifiers)),
            Key.clipboardHistoryKeyCode: .integer(Int64(clipboardHistoryShortcut.keyCode)),
            Key.clipboardHistoryModifiers: .integer(Int64(clipboardHistoryShortcut.modifiers)),
            Key.quickPasteShortcut: .string(
                quickPasteShortcut.map { "\($0.keyCode):\($0.modifiers)" } ?? ""
            ),
            Key.quickPasteEnabled: .bool(quickPasteEnabled),
            Key.quickPasteAllowsSensitiveContent: .bool(quickPasteAllowsSensitiveContent),
            Key.clipboardEnabled: .bool(clipboardEnabled),
            Key.clipboardPaused: .bool(clipboardPaused),
            Key.clipboardRetentionPreset: .string(clipboardRetentionPreset),
            Key.clipboardExcludedApplications: .string(clipboardExcludedApplications),
            Key.ocrLanguagePreset: .string(ocrLanguagePreset),
            Key.fileContentSearchEnabled: .bool(fileContentSearchEnabled),
            Key.fileHiddenFilesEnabled: .bool(fileHiddenFilesEnabled),
            Key.fileSystemLocationsEnabled: .bool(fileSystemLocationsEnabled),
            Key.fileTrashEnabled: .bool(fileTrashEnabled),
            Key.confirmSleepEveryTime: .bool(confirmSleepEveryTime),
        ]
    }

    func applyImportedConfiguration(_ values: [String: JSONValue]) throws {
        let original = exportedConfiguration()
        do {
            try applyImportedValues(values)
        } catch {
            do {
                try applyImportedValues(original)
            } catch {
                persistenceError = "The imported settings could not be rolled back. Restore the pre-import configuration backup."
                throw SettingsImportError.rollbackFailed
            }
            persistenceError = "The imported settings could not be saved. The previous values were restored."
            throw SettingsImportError.persistenceFailed
        }
    }

    private func applyImportedValues(_ values: [String: JSONValue]) throws {
        let importedLauncherShortcut = Self.importedShortcut(
            from: values,
            keyCodeKey: Key.launcherKeyCode,
            modifiersKey: Key.launcherModifiers,
            fallback: launcherShortcut
        )
        let importedClipboardShortcut = Self.importedShortcut(
            from: values,
            keyCodeKey: Key.clipboardHistoryKeyCode,
            modifiersKey: Key.clipboardHistoryModifiers,
            fallback: clipboardHistoryShortcut
        )
        let importedQuickPasteShortcut = Self.importedOptionalShortcut(
            from: values,
            combinedKey: Key.quickPasteShortcut,
            fallback: quickPasteShortcut
        )
        guard
            Self.shortcutsAreUnique(
                launcher: importedLauncherShortcut,
                clipboardHistory: importedClipboardShortcut,
                quickPaste: importedQuickPasteShortcut
            )
        else {
            shortcutValidationError = "Keyestro shortcuts must be different."
            throw SettingsImportError.persistenceFailed
        }

        if case let .bool(value) = values[Key.showDockIcon], value != showDockIcon {
            showDockIcon = value
            guard showDockIcon == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .string(value) = values[Key.launcherAppearance],
            let appearance = LauncherAppearancePreference(rawValue: value),
            appearance != launcherAppearance
        {
            launcherAppearance = appearance
            guard launcherAppearance == appearance else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.prefixesEnabled], value != prefixesEnabled {
            prefixesEnabled = value
            guard prefixesEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.rankingLearningEnabled], value != rankingLearningEnabled {
            rankingLearningEnabled = value
            guard rankingLearningEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        try applyShortcuts(
            launcher: importedLauncherShortcut,
            clipboardHistory: importedClipboardShortcut,
            quickPaste: importedQuickPasteShortcut
        )
        if case let .bool(value) = values[Key.numberShortcutsEnabled], value != numberShortcutsEnabled {
            numberShortcutsEnabled = value
            guard numberShortcutsEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.quickPasteEnabled], value != quickPasteEnabled {
            quickPasteEnabled = value
            guard quickPasteEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.quickPasteAllowsSensitiveContent],
            value != quickPasteAllowsSensitiveContent
        {
            quickPasteAllowsSensitiveContent = value
            guard quickPasteAllowsSensitiveContent == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.clipboardEnabled], value != clipboardEnabled {
            clipboardEnabled = value
            guard clipboardEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.clipboardPaused], value != clipboardPaused {
            clipboardPaused = value
            guard clipboardPaused == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .string(value) = values[Key.clipboardRetentionPreset],
            ["1-day", "7-days", "30-days", "90-days", "unlimited"].contains(value),
            value != clipboardRetentionPreset
        {
            clipboardRetentionPreset = value
            guard clipboardRetentionPreset == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .string(value) = values[Key.clipboardExcludedApplications], value.utf8.count <= 16_384,
            value != clipboardExcludedApplications
        {
            clipboardExcludedApplications = value
            guard clipboardExcludedApplications == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .string(value) = values[Key.ocrLanguagePreset],
            ["automatic", "en-zh", "en-US", "zh-Hans", "ja-JP"].contains(value),
            value != ocrLanguagePreset
        {
            ocrLanguagePreset = value
            guard ocrLanguagePreset == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.fileContentSearchEnabled], value != fileContentSearchEnabled {
            fileContentSearchEnabled = value
            guard fileContentSearchEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.fileHiddenFilesEnabled], value != fileHiddenFilesEnabled {
            fileHiddenFilesEnabled = value
            guard fileHiddenFilesEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.fileSystemLocationsEnabled], value != fileSystemLocationsEnabled {
            fileSystemLocationsEnabled = value
            guard fileSystemLocationsEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.fileTrashEnabled], value != fileTrashEnabled {
            fileTrashEnabled = value
            guard fileTrashEnabled == value else { throw SettingsImportError.persistenceFailed }
        }
        if case let .bool(value) = values[Key.confirmSleepEveryTime], value != confirmSleepEveryTime {
            confirmSleepEveryTime = value
            guard confirmSleepEveryTime == value else { throw SettingsImportError.persistenceFailed }
        }
    }

    @discardableResult
    func setShortcut(_ shortcut: HotKeyShortcut, for action: HotKeyAction) -> Bool {
        switch action {
        case .launcher:
            launcherShortcut = shortcut
            return launcherShortcut == shortcut
        case .clipboardHistory:
            clipboardHistoryShortcut = shortcut
            return clipboardHistoryShortcut == shortcut
        case .quickPaste:
            quickPasteShortcut = shortcut
            return quickPasteShortcut == shortcut
        }
    }

    func shortcut(for action: HotKeyAction) -> HotKeyShortcut? {
        switch action {
        case .launcher: launcherShortcut
        case .clipboardHistory: clipboardHistoryShortcut
        case .quickPaste: quickPasteShortcut
        }
    }

    func hotKeyRegistrationError(for action: HotKeyAction) -> String? {
        switch action {
        case .launcher: hotKeyRegistrationError
        case .clipboardHistory: clipboardHistoryHotKeyRegistrationError
        case .quickPaste: quickPasteHotKeyRegistrationError
        }
    }

    func setHotKeyRegistrationError(_ value: String?, for action: HotKeyAction = .launcher) {
        switch action {
        case .launcher: hotKeyRegistrationError = value
        case .clipboardHistory: clipboardHistoryHotKeyRegistrationError = value
        case .quickPaste: quickPasteHotKeyRegistrationError = value
        }
    }

    @discardableResult
    func completeOnboarding() -> Bool {
        guard persist(true, forKey: Key.onboardingCompleted) else { return false }
        onboardingCompleted = true
        return true
    }

    private func syncFileSearchPreferences() {
        fileSearchPreferencesGeneration &+= 1
        let generation = fileSearchPreferencesGeneration
        let options = SpotlightSearchOptions(
            searchContents: fileContentSearchEnabled,
            includeHiddenFiles: fileHiddenFilesEnabled,
            includeSystemLocations: fileSystemLocationsEnabled,
            includeTrash: fileTrashEnabled
        )
        Task { [weak self] in
            guard let self, generation == fileSearchPreferencesGeneration else { return }
            await fileSearchPreferences.update(options)
        }
    }

    private func persist(_ value: Bool, forKey key: String) -> Bool {
        persist { try persistence.set(value, forKey: key) }
    }

    private func persist(_ value: String, forKey key: String) -> Bool {
        persist { try persistence.set(value, forKey: key) }
    }

    private func persist(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            persistenceError = nil
            return true
        } catch {
            persistenceError = "The setting could not be saved. The previous value was restored."
            return false
        }
    }

    private func rollbackSetting(_ operation: () -> Void) {
        isRollingBackSetting = true
        defer { isRollingBackSetting = false }
        operation()
    }

    private func applyShortcuts(
        launcher: HotKeyShortcut,
        clipboardHistory: HotKeyShortcut,
        quickPaste: HotKeyShortcut?
    ) throws {
        guard
            Self.shortcutsAreUnique(
                launcher: launcher,
                clipboardHistory: clipboardHistory,
                quickPaste: quickPaste
            )
        else {
            shortcutValidationError = "Keyestro shortcuts must be different."
            throw SettingsImportError.persistenceFailed
        }
        isApplyingShortcuts = true
        defer { isApplyingShortcuts = false }
        if launcher != launcherShortcut {
            launcherShortcut = launcher
            guard launcherShortcut == launcher else { throw SettingsImportError.persistenceFailed }
        }
        if clipboardHistory != clipboardHistoryShortcut {
            clipboardHistoryShortcut = clipboardHistory
            guard clipboardHistoryShortcut == clipboardHistory else { throw SettingsImportError.persistenceFailed }
        }
        if quickPaste != quickPasteShortcut {
            quickPasteShortcut = quickPaste
            guard quickPasteShortcut == quickPaste else { throw SettingsImportError.persistenceFailed }
        }
        shortcutValidationError = nil
    }

    private static func shortcutsAreUnique(
        launcher: HotKeyShortcut,
        clipboardHistory: HotKeyShortcut,
        quickPaste: HotKeyShortcut?
    ) -> Bool {
        guard launcher != clipboardHistory else { return false }
        guard let quickPaste else { return true }
        return quickPaste != launcher && quickPaste != clipboardHistory
    }

    private static func importedShortcut(
        from values: [String: JSONValue],
        keyCodeKey: String,
        modifiersKey: String,
        fallback: HotKeyShortcut
    ) -> HotKeyShortcut {
        guard case let .integer(keyCode) = values[keyCodeKey],
            case let .integer(modifiers) = values[modifiersKey],
            keyCode >= 0,
            modifiers >= 0,
            let keyCode = UInt32(exactly: keyCode),
            let modifiers = UInt32(exactly: modifiers)
        else { return fallback }
        let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.isValid ? shortcut : fallback
    }

    private static func loadShortcut(
        from persistence: any SettingsPersisting,
        combinedKey: String,
        keyCodeKey: String,
        modifiersKey: String,
        defaultShortcut: HotKeyShortcut
    ) -> HotKeyShortcut {
        if let combined = persistence.string(forKey: combinedKey) {
            let components = combined.split(separator: ":", omittingEmptySubsequences: false)
            if components.count == 2,
                let keyCode = UInt32(components[0]),
                let modifiers = UInt32(components[1])
            {
                let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)
                if shortcut.isValid { return shortcut }
            }
        }
        let legacy = HotKeyShortcut(
            keyCode: UInt32(clamping: persistence.integer(forKey: keyCodeKey)),
            modifiers: UInt32(clamping: persistence.integer(forKey: modifiersKey))
        )
        return legacy.isValid ? legacy : defaultShortcut
    }

    private static func importedOptionalShortcut(
        from values: [String: JSONValue],
        combinedKey: String,
        fallback: HotKeyShortcut?
    ) -> HotKeyShortcut? {
        guard case let .string(value) = values[combinedKey] else { return fallback }
        guard !value.isEmpty else { return nil }
        return parseOptionalShortcut(value) ?? fallback
    }

    private static func loadOptionalShortcut(
        from persistence: any SettingsPersisting,
        combinedKey: String
    ) -> HotKeyShortcut? {
        guard let value = persistence.string(forKey: combinedKey) else { return nil }
        return parseOptionalShortcut(value)
    }

    private static func parseOptionalShortcut(_ value: String) -> HotKeyShortcut? {
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
            let keyCode = UInt32(components[0]),
            let modifiers = UInt32(components[1])
        else { return nil }
        let shortcut = HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.isValid ? shortcut : nil
    }

    private static let defaultConfiguration: [String: JSONValue] = [
        Key.showDockIcon: .bool(false),
        Key.launcherAppearance: .string(LauncherAppearancePreference.automatic.rawValue),
        Key.prefixesEnabled: .bool(true),
        Key.rankingLearningEnabled: .bool(true),
        Key.numberShortcutsEnabled: .bool(true),
        Key.launcherKeyCode: .integer(Int64(HotKeyShortcut.optionSpace.keyCode)),
        Key.launcherModifiers: .integer(Int64(HotKeyShortcut.optionSpace.modifiers)),
        Key.clipboardHistoryKeyCode: .integer(Int64(HotKeyShortcut.optionShiftV.keyCode)),
        Key.clipboardHistoryModifiers: .integer(Int64(HotKeyShortcut.optionShiftV.modifiers)),
        Key.quickPasteShortcut: .string(""),
        Key.quickPasteEnabled: .bool(false),
        Key.quickPasteAllowsSensitiveContent: .bool(true),
        Key.clipboardEnabled: .bool(false),
        Key.clipboardPaused: .bool(false),
        Key.clipboardRetentionPreset: .string("30-days"),
        Key.clipboardExcludedApplications: .string(""),
        Key.ocrLanguagePreset: .string("en-zh"),
        Key.fileContentSearchEnabled: .bool(false),
        Key.fileHiddenFilesEnabled: .bool(false),
        Key.fileSystemLocationsEnabled: .bool(false),
        Key.fileTrashEnabled: .bool(false),
        Key.confirmSleepEveryTime: .bool(true),
    ]
}

extension SettingsStore: SystemCommandConfirmationServicing {
    func shouldConfirmSleep() -> Bool {
        confirmSleepEveryTime || !persistence.bool(forKey: Key.sleepExplanationShown)
    }

    func markSleepExplanationShown() {
        _ = persist(true, forKey: Key.sleepExplanationShown)
    }
}
