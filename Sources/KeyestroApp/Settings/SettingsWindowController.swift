import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import KeyestroCore
import KeyestroDomain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation: SettingsNavigationModel

    init(
        settings: SettingsStore,
        quicklinks: any QuicklinkStoring,
        clipboardStore: ClipboardStore?,
        pasteboard: any PasteboardServicing = MacPasteboardService(),
        scripts: any ScriptStoring,
        scriptInstaller: ManagedScriptInstaller?,
        extensions: any ExtensionStoring,
        extensionInstaller: ExtensionInstaller?,
        extensionSupervisor: ExtensionSupervisor,
        extensionAuthorization: any ExtensionSearchAuthorizing,
        extensionPreferences: ExtensionPreferenceService,
        updateService: SparkleUpdateService,
        configurationService: ConfigurationService?,
        diagnosticsService: DiagnosticsService?,
        clearCaches: @escaping @MainActor () async -> String,
        beginHotKeyRecording: @escaping () -> Void,
        endHotKeyRecording: @escaping () -> Void,
        deleteAllLocalData: @escaping () -> Void,
        rankingStore: (any RankingServicing)?
    ) {
        let navigation = SettingsNavigationModel()
        self.navigation = navigation
        let root = SettingsView(
            navigation: navigation,
            settings: settings,
            quicklinks: quicklinks,
            clipboardStore: clipboardStore,
            pasteboard: pasteboard,
            scripts: scripts,
            scriptInstaller: scriptInstaller,
            extensions: extensions,
            extensionInstaller: extensionInstaller,
            extensionSupervisor: extensionSupervisor,
            extensionAuthorization: extensionAuthorization,
            extensionPreferences: extensionPreferences,
            updateService: updateService,
            configurationService: configurationService,
            diagnosticsService: diagnosticsService,
            clearCaches: clearCaches,
            beginHotKeyRecording: beginHotKeyRecording,
            endHotKeyRecording: endHotKeyRecording,
            deleteAllLocalData: deleteAllLocalData,
            rankingStore: rankingStore
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("settings.title")
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(section: SettingsSection? = nil) {
        if let section { navigation.selection = section }
        showWindow(nil)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsSection? = .general
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
}

enum AboutVersionLabel {
    static var current: String {
        text(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func text(
        marketingVersion: String?,
        buildNumber: String?,
        localizedFormat: String? = nil
    ) -> String {
        let version = marketingVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "0.1.0"
        let build = buildNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "1"
        return String(
            format: localizedFormat ?? L10n.text("about.version.format"),
            locale: Locale.current,
            arguments: [version, build]
        )
    }
}

private struct SettingsView: View {
    private enum DestructiveSettingsAction: String, Identifiable {
        case clearRankingHistory
        case restoreDefaults

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clearRankingHistory:
                "Clear all learned ranking history?"
            case .restoreDefaults:
                "Restore all default settings?"
            }
        }

        var buttonTitle: String {
            switch self {
            case .clearRankingHistory:
                "Clear Ranking History"
            case .restoreDefaults:
                "Restore Default Settings"
            }
        }

        var message: String {
            switch self {
            case .clearRankingHistory:
                "This permanently deletes all learned usage events from Keyestro's local database. Manual pins are kept."
            case .restoreDefaults:
                "This resets all non-secret Keyestro settings, including all shortcuts and privacy choices. Quicklinks, scripts, extensions, and their saved data are kept."
            }
        }
    }

    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var settings: SettingsStore
    let quicklinks: any QuicklinkStoring
    let clipboardStore: ClipboardStore?
    let pasteboard: any PasteboardServicing
    let scripts: any ScriptStoring
    let scriptInstaller: ManagedScriptInstaller?
    let extensions: any ExtensionStoring
    let extensionInstaller: ExtensionInstaller?
    let extensionSupervisor: ExtensionSupervisor
    let extensionAuthorization: any ExtensionSearchAuthorizing
    let extensionPreferences: ExtensionPreferenceService
    @ObservedObject var updateService: SparkleUpdateService
    let configurationService: ConfigurationService?
    let diagnosticsService: DiagnosticsService?
    let clearCaches: @MainActor () async -> String
    let beginHotKeyRecording: () -> Void
    let endHotKeyRecording: () -> Void
    let deleteAllLocalData: () -> Void
    let rankingStore: (any RankingServicing)?
    @State private var confirmsDeleteAllData = false
    @State private var cacheMessage: String?
    @State private var isClearingCaches = false
    @State private var rankingMessage: String?
    @State private var isClearingRanking = false
    @State private var defaultSettingsMessage: String?
    @State private var destructiveSettingsAction: DestructiveSettingsAction?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(navigation.selection?.title ?? L10n.text("settings.title")).font(.largeTitle.bold())
                    if let error = settings.persistenceError {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityElement(children: .combine)
                    }
                    detail(for: navigation.selection ?? .general)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog(
            "Delete all local Keyestro data and quit?",
            isPresented: $confirmsDeleteAllData,
            titleVisibility: .visible
        ) {
            Button("Delete All Local Data and Quit", role: .destructive, action: deleteAllLocalData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the database, caches, clipboard history, managed scripts and extensions, Keychain keys, login item, and preferences. This cannot be undone."
            )
        }
        .confirmationDialog(
            L10n.text(destructiveSettingsAction?.title ?? "Confirm settings change"),
            isPresented: Binding(
                get: { destructiveSettingsAction != nil },
                set: { if !$0 { destructiveSettingsAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = destructiveSettingsAction {
                Button(L10n.text(action.buttonTitle), role: .destructive) {
                    perform(action)
                    destructiveSettingsAction = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(L10n.text(destructiveSettingsAction?.message ?? ""))
        }
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Launcher appearance", selection: $settings.launcherAppearance) {
                        ForEach(LauncherAppearancePreference.allCases) { appearance in
                            Text(L10n.text(appearance.title)).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Auto follows the macOS appearance. A Light or Dark override is saved on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Show Keyestro in the Dock", isOn: $settings.showDockIcon)
            Text("Keyestro remains available from the menu bar when the Dock icon is hidden.")
                .foregroundStyle(.secondary)
            LoginItemSettingsView()
        case .shortcuts:
            ShortcutRecorder(
                settings: settings,
                beginRecording: beginHotKeyRecording,
                endRecording: endHotKeyRecording
            )
            Toggle("Command-number opens visible results", isOn: $settings.numberShortcutsEnabled)
            Toggle("Enable /, >, =, and @ query prefixes", isOn: $settings.prefixesEnabled)
        case .features:
            GroupBox("File Search") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable file search", isOn: $settings.fileSearchEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Search indexed file contents", isOn: $settings.fileContentSearchEnabled)
                        Toggle("Include hidden files", isOn: $settings.fileHiddenFilesEnabled)
                        Toggle("Include system locations", isOn: $settings.fileSystemLocationsEnabled)
                        Toggle("Include the Trash", isOn: $settings.fileTrashEnabled)
                    }
                    .disabled(!settings.fileSearchEnabled)
                    Text(
                        "Off by default. Keyestro does not inspect Desktop, Documents, Downloads, or other file-search folders until you enable this setting. macOS may ask for folder access on your first file search."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Always confirm before putting this Mac to sleep", isOn: $settings.confirmSleepEveryTime)
            Text("The first sleep action always explains its effect. You can keep confirmation enabled for every use.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Clipboard history", isOn: $settings.clipboardEnabled)
            Toggle("Pause clipboard monitoring", isOn: $settings.clipboardPaused)
                .disabled(!settings.clipboardEnabled)
            Text("Clipboard history is off by default and will be encrypted before persistence.")
                .foregroundStyle(.secondary)
            QuickPasteSettingsView(
                settings: settings,
                openPermissions: { navigation.selection = .permissions }
            )
            Picker("Clipboard retention", selection: $settings.clipboardRetentionPreset) {
                Text("1 day").tag("1-day")
                Text("7 days").tag("7-days")
                Text("30 days or 1,000 items").tag("30-days")
                Text("90 days").tag("90-days")
                Text("Unlimited items (500 MiB quota)").tag("unlimited")
            }
            Text("Excluded application Bundle IDs (one per line)").font(.callout.weight(.medium))
            TextEditor(text: $settings.clipboardExcludedApplications)
                .font(.body.monospaced())
                .frame(minHeight: 64, maxHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text(
                "The source application is inferred best-effort when the clipboard changes; exclusions are a privacy convenience, not a security boundary."
            )
            .font(.caption).foregroundStyle(.secondary)
            Picker("OCR recognition languages", selection: $settings.ocrLanguagePreset) {
                Text("Automatic").tag("automatic")
                Text("English + 简体中文").tag("en-zh")
                Text("English").tag("en-US")
                Text("简体中文").tag("zh-Hans")
                Text("日本語").tag("ja-JP")
            }
            Text("Screenshot OCR uses Vision accurate mode on this Mac and never sends images to a network service.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            QuicklinkSettingsView(store: quicklinks)
            Divider()
            ScriptSettingsView(store: scripts, installer: scriptInstaller)
        case .extensions:
            ExtensionSettingsView(
                store: extensions,
                installer: extensionInstaller,
                supervisor: extensionSupervisor,
                authorization: extensionAuthorization,
                preferences: extensionPreferences
            )
        case .permissions:
            PermissionsView()
        case .privacy:
            Text("Raw queries are never persisted. Clipboard, screenshots, and diagnostics remain local unless you explicitly export them.")
            Toggle("Learn from successful actions", isOn: $settings.rankingLearningEnabled)
            Text("When disabled, saved usage history is neither applied nor updated. Manual pins still affect ranking.")
                .font(.caption).foregroundStyle(.secondary)
            ClipboardPrivacyView(store: clipboardStore)
            HStack {
                Button("Clear ranking history…", role: .destructive) {
                    destructiveSettingsAction = .clearRankingHistory
                }
                .disabled(rankingStore == nil || isClearingRanking)
            }
            if let rankingMessage {
                Text(L10n.text(rankingMessage)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Button("Delete All Local Data and Quit…", role: .destructive) {
                confirmsDeleteAllData = true
            }
        case .updates:
            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { updateService.automaticallyChecksForUpdates },
                    set: { updateService.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .disabled(!updateService.isConfigured)
            Toggle(
                "Automatically download updates",
                isOn: Binding(
                    get: { updateService.automaticallyDownloadsUpdates },
                    set: { updateService.setAutomaticallyDownloadsUpdates($0) }
                )
            )
            .disabled(!updateService.isConfigured)
            Picker(
                "Update channel",
                selection: Binding(
                    get: { updateService.channel },
                    set: { updateService.setChannel($0) }
                )
            ) {
                Text("Stable").tag("stable")
                Text("Beta").tag("beta")
            }
            .disabled(!updateService.isConfigured)
            Button("Check Now") { updateService.checkForUpdates() }
                .disabled(!updateService.canCheckForUpdates)
            if let error = updateService.lastErrorMessage {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.secondary)
            }
        case .advanced:
            PerformanceSettingsView(pasteboard: pasteboard)
            DiagnosticsSettingsView(service: diagnosticsService, settings: settings)
            ConfigurationSettingsView(
                service: configurationService,
                settings: settings,
                navigation: navigation
            )
            Divider()
            Button("Clear Caches") {
                isClearingCaches = true
                cacheMessage = nil
                Task {
                    cacheMessage = await clearCaches()
                    isClearingCaches = false
                }
            }
            .disabled(isClearingCaches)
            if let cacheMessage {
                Text(L10n.text(cacheMessage)).font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore default settings…", role: .destructive) {
                destructiveSettingsAction = .restoreDefaults
            }
            if let defaultSettingsMessage {
                Text(L10n.text(defaultSettingsMessage)).font(.caption).foregroundStyle(.secondary)
            }
        case .about:
            Label {
                Text(verbatim: AboutVersionLabel.current)
            } icon: {
                Image(systemName: "command")
            }
            .font(.title2.bold())
            Text("Native, open source, and local-first. Apache-2.0 licensed.")
                .foregroundStyle(.secondary)
        }
    }

    private func perform(_ action: DestructiveSettingsAction) {
        switch action {
        case .clearRankingHistory:
            guard let rankingStore else { return }
            isClearingRanking = true
            rankingMessage = nil
            Task {
                do {
                    try await rankingStore.clearLearning()
                    rankingMessage = "Ranking history cleared."
                } catch {
                    rankingMessage = "Ranking history could not be cleared."
                }
                isClearingRanking = false
            }
        case .restoreDefaults:
            do {
                try settings.restoreDefaults()
                defaultSettingsMessage = "Default settings restored."
            } catch {
                defaultSettingsMessage = "Default settings could not be restored. Previous values were kept."
            }
        }
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var settings: SettingsStore
    let beginRecording: () -> Void
    let endRecording: () -> Void
    @State private var recordingAction: HotKeyAction?
    @State private var eventMonitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow(for: .launcher)
            shortcutRow(for: .clipboardHistory)
            shortcutRow(for: .quickPaste)
            Text("Use Command, Option, or Control with another key. Conflicts remain visible and the menu bar stays available.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = validationMessage ?? settings.shortcutValidationError ?? settings.persistenceError {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.red)
            }
            if let message = settings.hotKeyRegistrationError(for: .launcher) {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.red)
            }
            if let message = settings.hotKeyRegistrationError(for: .clipboardHistory) {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.red)
            }
            if let message = settings.hotKeyRegistrationError(for: .quickPaste) {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func shortcutRow(for action: HotKeyAction) -> some View {
        LabeledContent(L10n.text(label(for: action))) {
            Button(
                recordingAction == action
                    ? L10n.text("Press a shortcut…")
                    : settings.shortcut(for: action)?.displayName ?? L10n.text("Record Shortcut…")
            ) {
                if recordingAction == action {
                    stopRecording()
                } else {
                    startRecording(action)
                }
            }
            .font(.body.monospaced())
            .accessibilityLabel(L10n.text(accessibilityLabel(for: action)))
        }
    }

    private func startRecording(_ action: HotKeyAction) {
        stopRecording()
        validationMessage = nil
        recordingAction = action
        beginRecording()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard let shortcut = HotKeyShortcut(event: event) else {
                validationMessage = "Include Command, Option, or Control; Escape and Tab are reserved."
                return nil
            }
            if settings.setShortcut(shortcut, for: action) {
                stopRecording()
            } else {
                validationMessage = settings.shortcutValidationError ?? settings.persistenceError
            }
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        guard recordingAction != nil else { return }
        recordingAction = nil
        endRecording()
    }

    private func label(for action: HotKeyAction) -> String {
        switch action {
        case .launcher: "Open Keyestro"
        case .clipboardHistory: "Open Clipboard History"
        case .quickPaste: "Quick Paste Latest Text"
        }
    }

    private func accessibilityLabel(for action: HotKeyAction) -> String {
        switch action {
        case .launcher: "Open Keyestro shortcut"
        case .clipboardHistory: "Open Clipboard History shortcut"
        case .quickPaste: "Quick Paste latest text shortcut"
        }
    }
}

private struct QuickPasteSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let openPermissions: () -> Void
    @State private var confirmsEnable = false

    var body: some View {
        GroupBox("Quick Paste") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Enable Quick Paste for the latest text or URL",
                    isOn: Binding(
                        get: { settings.quickPasteEnabled },
                        set: { value in
                            if value {
                                confirmsEnable = true
                            } else {
                                settings.quickPasteEnabled = false
                            }
                        }
                    )
                )
                Toggle(
                    "Allow sensitive-looking text",
                    isOn: $settings.quickPasteAllowsSensitiveContent
                )
                .disabled(!settings.quickPasteEnabled)
                if settings.quickPasteShortcut == nil {
                    Label(
                        "Record a unique Quick Paste shortcut in Shortcuts before it can run.",
                        systemImage: "keyboard.badge.ellipsis"
                    )
                    .font(.caption)
                    .foregroundStyle(settings.quickPasteEnabled ? .orange : .secondary)
                }
                Text(
                    "The shortcut writes the newest history item to the clipboard and sends Command-V only if the same destination app remains frontmost. Images, files, and blocked sensitive items open Clipboard History instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Review Accessibility Permission", action: openPermissions)
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Enable Quick Paste?", isPresented: $confirmsEnable) {
            Button("Enable") { settings.quickPasteEnabled = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Quick Paste requires Accessibility permission to send Command-V to the frontmost app. It may paste sensitive clipboard text unless you turn off “Allow sensitive-looking text.”"
            )
        }
    }
}

private struct LoginItemSettingsView: View {
    private let service = MacLoginItemService()
    @State private var status: LoginItemStatus = .disabled
    @State private var error: String?

    var body: some View {
        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { status == .enabled },
                set: { enabled in update(enabled) }
            )
        )
        .onAppear { status = service.status() }
        if status == .requiresApproval {
            Text("macOS requires approval in System Settings → General → Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(L10n.text(error)).font(.caption).foregroundStyle(.red) }
    }

    private func update(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            status = service.status()
            error = nil
        } catch {
            status = service.status()
            self.error = "The login item setting could not be changed."
        }
    }
}

@MainActor
final class ExtensionSettingsModel: ObservableObject {
    @Published var registrations: [ExtensionRegistration] = []
    @Published var pendingImports: [ExportedExtensionRegistration] = []
    @Published var globalSearchEnabled: [String: Bool] = [:]
    @Published var preferenceStates: [String: ExtensionPreferenceState] = [:]
    @Published var preferenceText: [String: String] = [:]
    @Published var preferenceToggles: [String: Bool] = [:]
    @Published var inspected: ExtensionRegistration?
    @Published var reinstallTarget: ExportedExtensionRegistration?
    @Published var securityReport: ExtensionSecurityReport?
    @Published var error: String?
    @Published var isWorking = false

    private let store: any ExtensionStoring
    private let installer: ExtensionInstaller?
    private let supervisor: ExtensionSupervisor
    private let authorization: any ExtensionSearchAuthorizing
    private let preferences: ExtensionPreferenceService
    private let securityInspector = ExtensionSecurityInspector()
    private let pendingImportStore: PendingConfigurationImportStore

    init(
        store: any ExtensionStoring,
        installer: ExtensionInstaller?,
        supervisor: ExtensionSupervisor,
        authorization: any ExtensionSearchAuthorizing,
        preferences: ExtensionPreferenceService,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.installer = installer
        self.supervisor = supervisor
        self.authorization = authorization
        self.preferences = preferences
        pendingImportStore = PendingConfigurationImportStore(defaults: defaults)
        reload()
        reloadPendingImports()
    }

    func reload() {
        Task {
            do {
                let values = try await store.allExtensions()
                var consent: [String: Bool] = [:]
                for value in values {
                    consent[value.id] = await authorization.globalSearchEnabled(extensionID: value.id)
                }
                var states: [String: ExtensionPreferenceState] = [:]
                var textValues: [String: String] = [:]
                var toggleValues: [String: Bool] = [:]
                for registration in values {
                    let extensionStates = try await preferences.states(extensionID: registration.id)
                    for declaration in registration.manifest.preferences {
                        let key = Self.preferenceKey(extensionID: registration.id, name: declaration.name)
                        if let state = extensionStates[declaration.name] {
                            states[key] = state
                            if case let .string(value)? = state.value { textValues[key] = value }
                            if case let .bool(value)? = state.value { toggleValues[key] = value }
                        }
                    }
                }
                registrations = values
                globalSearchEnabled = consent
                preferenceStates = states
                preferenceText = textValues
                preferenceToggles = toggleValues
                error = nil
            } catch {
                self.error = "Extensions could not be loaded."
            }
        }
    }

    func reloadPendingImports() {
        do {
            pendingImports = try pendingImportStore.extensions()
        } catch {
            pendingImports = []
            self.error = "Pending extension reinstallations could not be read."
        }
    }

    func choosePackage() {
        choosePackage(reinstalling: nil)
    }

    func choosePackage(for registration: ExportedExtensionRegistration) {
        choosePackage(reinstalling: registration)
    }

    private func choosePackage(reinstalling target: ExportedExtensionRegistration?) {
        guard let installer else {
            error = "Managed extension storage is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect Extension"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.isWorking = true
                defer { self.isWorking = false }
                do {
                    let inspected = try await installer.inspect(sourceRoot: url)
                    if let target {
                        guard inspected.id == target.manifest.id,
                            inspected.manifest.version == target.manifest.version,
                            inspected.contentHash == target.contentHash
                        else {
                            self.error = "The selected package does not match the imported extension registration."
                            return
                        }
                    }
                    self.inspected = inspected
                    self.reinstallTarget = target
                    self.securityReport = await self.securityInspector.inspect(registration: inspected)
                    self.error = nil
                } catch let validation as ExtensionValidationError {
                    self.error = validation.descriptor.message
                } catch {
                    self.error = "The selected directory is not a valid extension package."
                }
            }
        }
    }

    func installInspected() {
        guard let installer, let inspected else { return }
        let target = reinstallTarget
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await installer.install(
                    sourceRoot: URL(fileURLWithPath: inspected.installPath, isDirectory: true),
                    enable: true
                )
                self.inspected = nil
                self.securityReport = nil
                self.reinstallTarget = nil
                if let target {
                    try pendingImportStore.removeExtension(target)
                    reloadPendingImports()
                }
                reload()
            } catch ExtensionValidationError.alreadyInstalled {
                self.error = "That extension version is already installed."
            } catch {
                self.error = "The extension could not be installed."
            }
        }
    }

    func setEnabled(_ enabled: Bool, registration: ExtensionRegistration) {
        Task {
            do {
                if !enabled { await supervisor.disable(extensionID: registration.id) }
                try await store.saveExtension(registration.replacing(enabled: enabled))
                reload()
            } catch {
                self.error = "The extension setting could not be saved."
            }
        }
    }

    func setGlobalSearch(_ enabled: Bool, registration: ExtensionRegistration) {
        Task {
            await authorization.setGlobalSearchEnabled(enabled, extensionID: registration.id)
            reload()
        }
    }

    func retry(_ registration: ExtensionRegistration) {
        Task {
            await supervisor.retry(extensionID: registration.id)
            error = "The extension may start again on its next query."
        }
    }

    func text(extensionID: String, name: String) -> String {
        preferenceText[Self.preferenceKey(extensionID: extensionID, name: name)] ?? ""
    }

    func setText(_ value: String, extensionID: String, name: String) {
        preferenceText[Self.preferenceKey(extensionID: extensionID, name: name)] = value
    }

    func toggle(extensionID: String, name: String) -> Bool {
        preferenceToggles[Self.preferenceKey(extensionID: extensionID, name: name)] ?? false
    }

    func setToggle(_ value: Bool, extensionID: String, name: String) {
        preferenceToggles[Self.preferenceKey(extensionID: extensionID, name: name)] = value
    }

    func isPreferenceSet(extensionID: String, name: String) -> Bool {
        preferenceStates[Self.preferenceKey(extensionID: extensionID, name: name)]?.isSet == true
    }

    func savePreference(_ declaration: ExtensionPreferenceManifest, registration: ExtensionRegistration) {
        let key = Self.preferenceKey(extensionID: registration.id, name: declaration.name)
        let value: JSONValue
        if declaration.type == .toggle {
            value = .bool(preferenceToggles[key] ?? false)
        } else {
            let text = preferenceText[key] ?? (declaration.type == .choice ? declaration.choices.first ?? "" : "")
            value = .string(text)
        }
        Task {
            do {
                try await preferences.set(value, extensionID: registration.id, name: declaration.name)
                if declaration.type != .password {
                    await supervisor.preferencesChanged(extensionID: registration.id, values: [declaration.name: value])
                }
                if declaration.type == .password { preferenceText[key] = "" }
                reload()
            } catch let preferenceError as ExtensionPreferenceError {
                error = preferenceError.descriptor.message
            } catch {
                self.error = "The extension preference could not be saved."
            }
        }
    }

    func clearPreference(_ declaration: ExtensionPreferenceManifest, registration: ExtensionRegistration) {
        Task {
            do {
                try await preferences.remove(ifCurrentMatches: registration, name: declaration.name)
                if declaration.type != .password {
                    await supervisor.preferencesChanged(extensionID: registration.id, values: [declaration.name: .null])
                }
                reload()
            } catch let preferenceError as ExtensionPreferenceError {
                error = preferenceError.descriptor.message
            } catch {
                self.error = "The extension preference could not be cleared."
            }
        }
    }

    func choosePath(_ declaration: ExtensionPreferenceManifest, registration: ExtensionRegistration) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = declaration.type == .file
        panel.canChooseDirectories = declaration.type == .directory
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.setText(url.standardizedFileURL.path, extensionID: registration.id, name: declaration.name)
            }
        }
    }

    func remove(_ registration: ExtensionRegistration) {
        guard let installer else { return }
        Task {
            do {
                await supervisor.disable(extensionID: registration.id)
                try await preferences.removeAll(
                    extensionID: registration.id,
                    whilePerforming: { try await installer.remove(registration) }
                )
                await authorization.setGlobalSearchEnabled(false, extensionID: registration.id)
                reload()
            } catch let descriptor as ErrorDescriptor {
                self.error = descriptor.message
            } catch {
                self.error = "The extension could not be removed."
            }
        }
    }

    private static func preferenceKey(extensionID: String, name: String) -> String {
        "\(extensionID)\u{1F}\(name)"
    }
}

private struct ExtensionSettingsView: View {
    private struct PreferenceRemoval: Identifiable {
        let registration: ExtensionRegistration
        let declaration: ExtensionPreferenceManifest

        var id: String { "\(registration.id)\u{1F}\(declaration.name)" }
    }

    @StateObject private var model: ExtensionSettingsModel
    @State private var removal: ExtensionRegistration?
    @State private var preferenceRemoval: PreferenceRemoval?

    init(
        store: any ExtensionStoring,
        installer: ExtensionInstaller?,
        supervisor: ExtensionSupervisor,
        authorization: any ExtensionSearchAuthorizing,
        preferences: ExtensionPreferenceService
    ) {
        _model = StateObject(
            wrappedValue: ExtensionSettingsModel(
                store: store,
                installer: installer,
                supervisor: supervisor,
                authorization: authorization,
                preferences: preferences
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Installed Extensions").font(.headline)
                Spacer()
                Button("Install Local Extension…") { model.choosePackage() }
                    .disabled(model.isWorking)
            }
            Label(
                "Native extensions run with your user permissions. Process isolation protects Keyestro from crashes, but it is not a security sandbox. Install only code you trust.",
                systemImage: "exclamationmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.orange)

            if !model.pendingImports.isEmpty {
                GroupBox("Imported Extensions Requiring Reinstallation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select and review the exact exported package. Its identifier, version, and SHA-256 must all match.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.pendingImports, id: \.manifest.id) { registration in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(registration.manifest.name)
                                    Text("\(registration.manifest.id) · \(registration.manifest.version)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Select Package…") { model.choosePackage(for: registration) }
                                    .disabled(model.isWorking)
                            }
                        }
                    }
                }
            }

            if let inspected = model.inspected {
                GroupBox("Review Before Installing") {
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent("Name", value: "\(inspected.manifest.name) \(inspected.manifest.version)")
                        LabeledContent("Source", value: inspected.installPath)
                        LabeledContent("Executable", value: inspected.manifest.executable)
                        LabeledContent("SHA-256", value: inspected.contentHash)
                        if let report = model.securityReport {
                            LabeledContent("Code signature", value: signatureLabel(report.codeSignature))
                            LabeledContent("Gatekeeper", value: gatekeeperLabel(report.gatekeeper))
                            LabeledContent("Notarization", value: report.notarized ? "Detected" : "Not detected")
                            LabeledContent("Quarantine", value: report.quarantinePresent ? "Present" : "Not present")
                        } else {
                            LabeledContent("Security inspection", value: "Checking…")
                        }
                        LabeledContent(
                            "Capabilities",
                            value: inspected.manifest.capabilities.isEmpty
                                ? "None declared"
                                : inspected.manifest.capabilities.sorted().joined(separator: ", ")
                        )
                        Text("Gatekeeper and quarantine remain enforced. Keyestro never removes quarantine or bypasses system security.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") {
                                model.inspected = nil
                                model.securityReport = nil
                                model.reinstallTarget = nil
                            }
                            Spacer()
                            Button("Install and Enable") { model.installInspected() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .textSelection(.enabled)
                }
            }

            if model.registrations.isEmpty, model.inspected == nil {
                ContentUnavailableView(
                    "No extensions installed",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Choose a local .extension directory to inspect it before installation.")
                )
            }
            ForEach(model.registrations) { registration in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                            VStack(alignment: .leading) {
                                Text(registration.manifest.name).font(.headline)
                                Text("\(registration.id) · \(registration.manifest.version)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { registration.enabled },
                                    set: { model.setEnabled($0, registration: registration) }
                                )
                            )
                            .labelsHidden()
                        }
                        Text(registration.manifest.description).foregroundStyle(.secondary)
                        if registration.manifest.searchPolicy == .global {
                            Toggle(
                                "Share global query text with this extension",
                                isOn: Binding(
                                    get: { model.globalSearchEnabled[registration.id] == true },
                                    set: { model.setGlobalSearch($0, registration: registration) }
                                )
                            )
                            Text("Off by default. When enabled, this extension receives queries outside @ mode.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Explicit search: query text is shared only after you open one of this extension’s commands in @ mode.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !registration.manifest.preferences.isEmpty {
                            Divider()
                            Text("Preferences").font(.callout.weight(.semibold))
                            ForEach(registration.manifest.preferences, id: \.name) { declaration in
                                preferenceEditor(declaration, registration: registration)
                            }
                        }
                        HStack {
                            Text("SHA-256 \(registration.contentHash)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Retry") { model.retry(registration) }
                            Button("Remove…", role: .destructive) { removal = registration }
                        }
                    }
                }
            }
            if let error = model.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.red) }
        }
        .onAppear {
            model.reload()
            model.reloadPendingImports()
        }
        .confirmationDialog(
            "Remove \(removal?.manifest.name ?? "extension")?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible
        ) {
            if let removal {
                Button("Remove Extension and Managed Files", role: .destructive) {
                    model.remove(removal)
                    self.removal = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops its entire process group and deletes all managed versions. External source files are not changed.")
        }
        .confirmationDialog(
            L10n.format(
                "extension.preference.clear.confirmation",
                preferenceRemoval?.declaration.title ?? L10n.text("extension preference"),
                preferenceRemoval?.registration.manifest.name ?? L10n.text("extension")
            ),
            isPresented: Binding(
                get: { preferenceRemoval != nil },
                set: { if !$0 { preferenceRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let candidate = preferenceRemoval {
                Button("Clear Preference", role: .destructive) {
                    model.clearPreference(candidate.declaration, registration: candidate.registration)
                    preferenceRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if preferenceRemoval?.declaration.type == .password {
                Text(
                    "This permanently removes this extension's saved secret from the Keychain. The secret value is never shown in this confirmation."
                )
            } else {
                Text("This removes the saved value and notifies the extension that this exact preference is now unset.")
            }
        }
    }

    private func signatureLabel(_ status: ExtensionCodeSignatureStatus) -> String {
        switch status {
        case let .developerID(teamIdentifier): "Developer ID · \(teamIdentifier)"
        case .valid: "Valid signature"
        case .adHoc: "Ad-hoc signature"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid"
        case .unavailable: "Unknown"
        }
    }

    private func gatekeeperLabel(_ status: ExtensionGatekeeperStatus) -> String {
        switch status {
        case .accepted: "Accepted"
        case .rejected: "Not accepted"
        case .unavailable: "Unknown"
        }
    }

    @ViewBuilder
    private func preferenceEditor(
        _ declaration: ExtensionPreferenceManifest,
        registration: ExtensionRegistration
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(declaration.title)
                if declaration.required {
                    Text("Required").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.isPreferenceSet(extensionID: registration.id, name: declaration.name) ? "Set" : "Not set")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                switch declaration.type {
                case .password:
                    SecureField("Enter a new secret", text: preferenceTextBinding(declaration, registration: registration))
                case .choice:
                    ViewportConstrainedChoicePicker(
                        title: declaration.title,
                        options: declaration.choices,
                        selection: preferenceChoiceBinding(declaration, registration: registration)
                    )
                case .file, .directory:
                    TextField("Absolute path", text: preferenceTextBinding(declaration, registration: registration))
                    Button("Choose…") { model.choosePath(declaration, registration: registration) }
                case .toggle:
                    Toggle(
                        declaration.title,
                        isOn: Binding(
                            get: { model.toggle(extensionID: registration.id, name: declaration.name) },
                            set: { model.setToggle($0, extensionID: registration.id, name: declaration.name) }
                        )
                    )
                    .labelsHidden()
                case .text:
                    TextField("Value", text: preferenceTextBinding(declaration, registration: registration))
                }
                Button("Save") { model.savePreference(declaration, registration: registration) }
                    .disabled(
                        declaration.type == .password
                            && model.text(extensionID: registration.id, name: declaration.name).isEmpty
                    )
                if model.isPreferenceSet(extensionID: registration.id, name: declaration.name) {
                    Button("Clear…", role: .destructive) {
                        preferenceRemoval = PreferenceRemoval(
                            registration: registration,
                            declaration: declaration
                        )
                    }
                }
            }
            if declaration.type == .password {
                Text(
                    "Stored in Keychain. When requested, the secret itself is delivered to this trusted extension process; it is never sent in preferencesChanged notifications."
                )
                .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    private func preferenceTextBinding(
        _ declaration: ExtensionPreferenceManifest,
        registration: ExtensionRegistration
    ) -> Binding<String> {
        Binding(
            get: { model.text(extensionID: registration.id, name: declaration.name) },
            set: { model.setText($0, extensionID: registration.id, name: declaration.name) }
        )
    }

    private func preferenceChoiceBinding(
        _ declaration: ExtensionPreferenceManifest,
        registration: ExtensionRegistration
    ) -> Binding<String> {
        Binding(
            get: {
                let value = model.text(extensionID: registration.id, name: declaration.name)
                return declaration.choices.contains(value) ? value : declaration.choices.first ?? ""
            },
            set: { model.setText($0, extensionID: registration.id, name: declaration.name) }
        )
    }
}

@MainActor
final class PerformanceSettingsModel: ObservableObject {
    @Published var report: PerformanceReport?
    @Published var message: String?
    @Published var isWorking = false
    private let pasteboard: any PasteboardServicing

    init(pasteboard: any PasteboardServicing = MacPasteboardService()) {
        self.pasteboard = pasteboard
    }

    func run() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            report = await PerformanceRecorder.shared.report()
            isWorking = false
            message =
                report?.summaries.isEmpty == false
                ? "Local performance report updated."
                : "No timing samples yet. Open and use the launcher, then run the diagnostic again."
        }
    }

    func copy() {
        guard let report,
            let data = try? JSONEncoder.performanceReportEncoder.encode(report),
            let text = String(data: data, encoding: .utf8)
        else { return }
        _ = pasteboard.write(.text(text))
        message = "Performance report copied without query or result content."
    }

    func reset() {
        Task {
            await PerformanceRecorder.shared.reset()
            report = nil
            message = "Local performance samples cleared."
        }
    }
}

private extension JSONEncoder {
    static var performanceReportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct PerformanceSettingsView: View {
    @StateObject private var model: PerformanceSettingsModel

    init(pasteboard: any PasteboardServicing) {
        _model = StateObject(wrappedValue: PerformanceSettingsModel(pasteboard: pasteboard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Performance Diagnostics").font(.headline)
            Text(
                "Keyestro keeps only bounded timing samples in memory. Queries, result titles, clipboard content, and file paths are never recorded."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Run Local Performance Diagnostics") { model.run() }
                    .disabled(model.isWorking)
                Button("Copy Performance Report") { model.copy() }
                    .disabled(model.report?.summaries.isEmpty != false)
                Button("Clear Performance Samples") { model.reset() }
            }
            if let report = model.report, !report.summaries.isEmpty {
                GroupBox("Recent p50 / p95") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.summaries, id: \.metric) { summary in
                            LabeledContent(summary.metric.rawValue) {
                                Text(
                                    "p50 \(summary.p50Milliseconds, format: .number.precision(.fractionLength(1))) ms · p95 \(summary.p95Milliseconds, format: .number.precision(.fractionLength(1))) ms · n=\(summary.sampleCount)"
                                )
                                .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
            }
            if let message = model.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
            }
        }
        Divider()
    }
}

@MainActor
final class DiagnosticsSettingsModel: ObservableObject {
    @Published var preview: DiagnosticsPreview?
    @Published var message: String?
    @Published var isWorking = false
    private let service: DiagnosticsService?
    private let settings: SettingsStore

    init(service: DiagnosticsService?, settings: SettingsStore) {
        self.service = service
        self.settings = settings
    }

    func preparePreview() {
        guard let service else {
            message = "Diagnostics are unavailable in this session."
            return
        }
        preview = service.preview()
        message = nil
    }

    func export() {
        guard let service, preview != nil else {
            message = "Review the export preview first."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Keyestro Diagnostics.zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.isWorking = true
                defer { self.isWorking = false }
                let permissions = [
                    "accessibility": AXIsProcessTrusted() ? "allowed" : "notAllowed",
                    "screenRecording": CGPreflightScreenCaptureAccess() ? "allowed" : "notAllowed",
                ]
                let snapshot = await service.snapshot(
                    settings: self.settings.exportedConfiguration(),
                    permissions: permissions
                )
                do {
                    try await service.exportZIP(snapshot, to: url)
                    self.message = "Diagnostics exported. Review diagnostics.json before sharing."
                } catch {
                    self.message = "The diagnostics archive could not be created."
                }
            }
        }
    }
}

private struct DiagnosticsSettingsView: View {
    @StateObject private var model: DiagnosticsSettingsModel

    init(service: DiagnosticsService?, settings: SettingsStore) {
        _model = StateObject(wrappedValue: DiagnosticsSettingsModel(service: service, settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.headline)
            HStack {
                Button("Prepare Export Preview") { model.preparePreview() }
                Button("Export Diagnostics ZIP…") { model.export() }
                    .disabled(model.preview == nil || model.isWorking)
            }
            if let preview = model.preview {
                GroupBox("Export Preview") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Files: \(preview.files.joined(separator: ", "))")
                        ForEach(preview.fields, id: \.self) { Label($0, systemImage: "checkmark") }
                        Divider()
                        ForEach(preview.excluded, id: \.self) { Label($0, systemImage: "lock") }
                    }
                    .font(.caption)
                }
            }
            if let message = model.message { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
        }
        Divider()
    }
}

@MainActor
final class ConfigurationSettingsModel: ObservableObject {
    @Published var pendingImport: ValidatedConfigurationImport?
    @Published var pendingScriptCount = 0
    @Published var pendingExtensionCount = 0
    @Published var message: String?
    @Published var isWorking = false

    private let service: ConfigurationService?
    private let settings: SettingsStore
    private let pendingImports: PendingConfigurationImportStore
    private let importCoordinator: ConfigurationImportCoordinator?

    init(service: ConfigurationService?, settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.service = service
        self.settings = settings
        pendingImports = PendingConfigurationImportStore(defaults: defaults)
        importCoordinator = service.map { ConfigurationImportCoordinator(service: $0, settings: settings, defaults: defaults) }
        reloadPendingImports()
        Task { [weak self] in await self?.recoverInterruptedImport() }
    }

    func reloadPendingImports() {
        do {
            pendingScriptCount = try pendingImports.scripts().count
            pendingExtensionCount = try pendingImports.extensions().count
        } catch {
            pendingScriptCount = 0
            pendingExtensionCount = 0
            message = "Pending imported registrations could not be read."
        }
    }

    private func recoverInterruptedImport() async {
        guard let importCoordinator else { return }
        do {
            guard try await importCoordinator.recoverIfNeeded() else { return }
            reloadPendingImports()
            message = "An interrupted configuration import was recovered."
        } catch {
            message = "An interrupted import could not be recovered automatically. Restore its pre-import backup."
        }
    }

    func exportConfiguration() {
        guard let service else {
            message = "Configuration storage is unavailable."
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let data = try await service.export(settings: settings.exportedConfiguration())
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Keyestro Configuration.json"
                let response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                guard response == .OK, let url = panel.url else { return }
                try await Task.detached(priority: .utility) {
                    try data.write(to: url, options: [.atomic])
                }.value
                message = "Configuration exported. Secrets, clipboard content, and script bodies were excluded."
            } catch {
                message = "Configuration could not be exported."
            }
        }
    }

    func chooseImport() {
        guard let service else {
            message = "Configuration storage is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.isWorking = true
                defer { self.isWorking = false }
                do {
                    let data = try await Task.detached(priority: .utility) {
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard values.isRegularFile == true,
                            (values.fileSize ?? Int.max) <= ConfigurationService.maximumDocumentBytes
                        else { throw ConfigurationError.tooLarge }
                        return try Data(contentsOf: url, options: .mappedIfSafe)
                    }.value
                    self.pendingImport = try await service.inspectImport(data)
                    self.message = nil
                } catch ConfigurationError.invalidChecksum {
                    self.message = "The configuration checksum does not match; nothing was imported."
                } catch {
                    self.message = "The selected configuration is invalid or unsupported."
                }
            }
        }
    }

    func applyImport() {
        guard let importCoordinator, let pendingImport else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await importCoordinator.apply(pendingImport)
                reloadPendingImports()
                self.pendingImport = nil
                message = "Configuration imported. A pre-change backup was saved; scripts and extensions require manual reconnection."
            } catch ConfigurationImportTransactionError.rollbackFailed {
                message = "The import failed and automatic rollback was incomplete. Restore the pre-import backup."
            } catch ConfigurationImportTransactionError.completionFailed {
                message = "The import was committed, but its settings could not be completed. Restart Keyestro to retry recovery."
            } catch {
                message = "The import failed before changes could be completed."
            }
        }
    }
}

private struct ConfigurationSettingsView: View {
    @StateObject private var model: ConfigurationSettingsModel
    @ObservedObject var navigation: SettingsNavigationModel

    init(
        service: ConfigurationService?,
        settings: SettingsStore,
        navigation: SettingsNavigationModel
    ) {
        _model = StateObject(wrappedValue: ConfigurationSettingsModel(service: service, settings: settings))
        self.navigation = navigation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration").font(.headline)
            Text(
                "Exports contain non-secret settings, quick links, script registration metadata, and extension manifests. They never contain Keychain values, clipboard payloads, script bodies, or private environment values."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export Configuration…") { model.exportConfiguration() }
                Button("Import Configuration…") { model.chooseImport() }
            }
            .disabled(model.isWorking)
            if let pending = model.pendingImport {
                GroupBox("Import Preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(pending.preview.addedQuicklinks) quick links added · \(pending.preview.replacedQuicklinks) replaced")
                        Text("\(pending.preview.settingsCount) non-secret settings merged")
                        Text("\(pending.preview.ignoredSettingsCount) unsupported settings ignored")
                        Text(
                            "\(pending.preview.scriptsRequiringReconnection) scripts require reconnection · \(pending.preview.extensionsRequiringReinstallation) extensions require reinstallation"
                        )
                        Text("A backup is written before the transactional quick-link merge.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") { model.pendingImport = nil }
                            Spacer()
                            Button("Apply Import") { model.applyImport() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            if model.pendingScriptCount > 0 || model.pendingExtensionCount > 0 {
                GroupBox("Imported Code Requires Confirmation") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(
                            "\(model.pendingScriptCount) scripts still require reconnection · \(model.pendingExtensionCount) extensions still require reinstallation"
                        )
                        Text("Imported code remains disabled and unavailable until you select and review its local source.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if model.pendingScriptCount > 0 {
                                Button("Reconnect Scripts…") { navigation.selection = .features }
                            }
                            if model.pendingExtensionCount > 0 {
                                Button("Reinstall Extensions…") { navigation.selection = .extensions }
                            }
                        }
                    }
                }
            }
            if let message = model.message { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { model.reloadPendingImports() }
    }
}

@MainActor
final class ScriptSettingsModel: ObservableObject {
    struct ReconnectCandidate {
        let registration: ExportedScriptRegistration
        let source: URL
    }

    @Published var scripts: [ScriptDefinition] = []
    @Published var pendingImports: [ExportedScriptRegistration] = []
    @Published var error: String?
    @Published var editingScript: ScriptDefinition?
    @Published var linkCandidate: URL?
    @Published var reconnectCandidate: ReconnectCandidate?
    @Published var reconfirmCandidate: ScriptDefinition?
    @Published var editTitle = ""
    @Published var editTimeoutSeconds = 30
    @Published var editArguments: [QuicklinkArgumentDraft] = []
    private let store: any ScriptStoring
    private let installer: ManagedScriptInstaller?
    private let pendingImportStore: PendingConfigurationImportStore

    init(
        store: any ScriptStoring,
        installer: ManagedScriptInstaller?,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.installer = installer
        pendingImportStore = PendingConfigurationImportStore(defaults: defaults)
        reload()
        reloadPendingImports()
    }

    func reloadPendingImports() {
        do {
            pendingImports = try pendingImportStore.scripts()
        } catch {
            pendingImports = []
            self.error = "Pending script reconnections could not be read."
        }
    }

    func reload() {
        Task {
            do {
                scripts = try await store.allScripts()
                error = nil
            } catch {
                self.error = "Scripts could not be loaded."
            }
        }
    }

    func chooseAndInstall() {
        guard let installer else {
            error = "Managed script storage is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    _ = try await installer.install(from: url)
                    self.reload()
                } catch {
                    self.error = "Choose an executable file. The script was not installed."
                }
            }
        }
    }

    func chooseAndLinkOriginal() {
        guard installer != nil else {
            error = "Managed script storage is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Linked Script"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self.linkCandidate = url }
        }
    }

    func confirmLinkOriginal() {
        guard let installer, let source = linkCandidate else { return }
        linkCandidate = nil
        Task {
            do {
                _ = try await installer.linkOriginal(from: source)
                reload()
            } catch {
                self.error = "Choose an executable file. The linked script was not added."
            }
        }
    }

    func chooseAndReconnect(_ registration: ExportedScriptRegistration) {
        guard installer != nil else {
            error = "Managed script storage is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review Reconnected Script"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.reconnectCandidate = ReconnectCandidate(registration: registration, source: url)
            }
        }
    }

    func confirmReconnect() {
        guard let installer, let candidate = reconnectCandidate else { return }
        reconnectCandidate = nil
        Task {
            do {
                _ = try await installer.reconnect(candidate.registration, from: candidate.source)
                try pendingImportStore.removeScript(candidate.registration)
                reloadPendingImports()
                reload()
            } catch let descriptor as ErrorDescriptor {
                self.error = descriptor.message
            } catch {
                self.error = "The selected script does not match the imported registration."
            }
        }
    }

    func confirmReconfirmation() {
        guard let installer, let script = reconfirmCandidate else { return }
        reconfirmCandidate = nil
        Task {
            do {
                _ = try await installer.reconfirmLinkedOriginal(script)
                reload()
            } catch {
                self.error = "The linked script could not be reconfirmed."
            }
        }
    }

    func remove(_ script: ScriptDefinition) {
        guard let installer else { return }
        Task {
            do {
                try await installer.remove(script)
                reload()
            } catch let descriptor as ErrorDescriptor {
                self.error = descriptor.message
            } catch {
                self.error = "The script could not be removed."
            }
        }
    }

    func configure(_ script: ScriptDefinition) {
        editingScript = script
        editTitle = script.title
        editTimeoutSeconds = script.timeoutSeconds
        editArguments = script.arguments.map(QuicklinkArgumentDraft.init)
    }

    func addArgument() {
        editArguments.append(QuicklinkArgumentDraft(name: "argument\(editArguments.count + 1)"))
    }

    func removeArgument(id: UUID) {
        editArguments.removeAll { $0.id == id }
    }

    func saveConfiguration() {
        guard let script = editingScript else { return }
        do {
            let updated = try ScriptDefinition(
                id: script.id,
                title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                executablePath: script.executablePath,
                arguments: try editArguments.map { try $0.definition() },
                environment: script.environment,
                timeoutSeconds: editTimeoutSeconds,
                contentHash: script.contentHash,
                linkedFileIdentity: script.linkedFileIdentity,
                enabled: script.enabled,
                createdAt: script.createdAt,
                updatedAt: Date()
            )
            Task {
                do {
                    try await store.saveScript(updated)
                    editingScript = nil
                    reload()
                } catch {
                    self.error = "The script configuration could not be saved."
                }
            }
        } catch let descriptor as ErrorDescriptor {
            self.error = descriptor.message
        } catch {
            self.error = "The script configuration is invalid."
        }
    }
}

private struct ScriptSettingsView: View {
    @StateObject private var model: ScriptSettingsModel
    @State private var removal: ScriptDefinition?

    init(store: any ScriptStoring, installer: ManagedScriptInstaller?) {
        _model = StateObject(wrappedValue: ScriptSettingsModel(store: store, installer: installer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Script Commands").font(.headline)
                Spacer()
                Menu("Add Script…") {
                    Button("Install Managed Copy…") { model.chooseAndInstall() }
                    Button("Link Original File…") { model.chooseAndLinkOriginal() }
                }
            }
            Text(
                "Scripts are trusted local code with your user permissions. Managed copies are the default. Linked originals stay in place and must be reconfirmed after their file identity or contents change. Arguments are never interpolated into a shell command."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !model.pendingImports.isEmpty {
                GroupBox("Imported Scripts Requiring Reconnection") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Select the original executable for each registration. Its SHA-256 must match before Keyestro creates a managed copy."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.pendingImports, id: \.id) { registration in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(registration.title)
                                    Text(registration.executableName)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reconnect…") { model.chooseAndReconnect(registration) }
                            }
                        }
                    }
                }
            }
            ForEach(model.scripts) { script in
                HStack {
                    Image(systemName: "terminal")
                    VStack(alignment: .leading) {
                        Text(script.title)
                        Text(script.executablePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(script.isLinkedOriginal ? "Linked Original" : "Managed Copy")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if script.isLinkedOriginal {
                        Button("Reconfirm…") { model.reconfirmCandidate = script }
                    }
                    Button("Configure…") { model.configure(script) }
                    Button(role: .destructive) {
                        removal = script
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(script.title)")
                }
            }
            if let error = model.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.red) }
        }
        .onAppear {
            model.reload()
            model.reloadPendingImports()
        }
        .sheet(
            isPresented: Binding(
                get: { model.editingScript != nil },
                set: { if !$0 { model.editingScript = nil } }
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Configure Script").font(.title2.bold())
                TextField("Title", text: $model.editTitle).textFieldStyle(.roundedBorder)
                Stepper(
                    "Timeout: \(model.editTimeoutSeconds) seconds",
                    value: $model.editTimeoutSeconds,
                    in: 1...300
                )
                HStack {
                    Text("Parameters").font(.headline)
                    Spacer()
                    Button("Add Parameter") { model.addArgument() }
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($model.editArguments) { $argument in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField("Name", text: $argument.name).textFieldStyle(.roundedBorder)
                                    TextField("Title", text: $argument.title).textFieldStyle(.roundedBorder)
                                    Picker("Type", selection: $argument.type) {
                                        ForEach(QuicklinkArgumentType.allCases) { type in Text(type.title).tag(type) }
                                    }
                                    .labelsHidden()
                                    Toggle("Required", isOn: $argument.required)
                                    Button(role: .destructive) {
                                        model.removeArgument(id: argument.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                if argument.type == .choice {
                                    TextField("Choices (comma-separated)", text: $argument.choices)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(8)
                            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack {
                    Button("Cancel") { model.editingScript = nil }
                    Spacer()
                    Button("Save") { model.saveConfiguration() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 680, height: 460)
        }
        .confirmationDialog(
            "Remove \(removal?.title ?? "script")?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible
        ) {
            if let removal {
                Button("Remove Script", role: .destructive) {
                    model.remove(removal)
                    self.removal = nil
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            if let removal {
                Text(
                    removal.isLinkedOriginal
                        ? "This removes only the registration for \(removal.executablePath). The original file is not deleted."
                        : "This permanently removes the registration and managed copy at \(removal.executablePath)."
                )
            }
        }
        .confirmationDialog(
            "Link this script without copying it?",
            isPresented: Binding(get: { model.linkCandidate != nil }, set: { if !$0 { model.linkCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Trust and Link Original") { model.confirmLinkOriginal() }
            Button("Cancel", role: .cancel) { model.linkCandidate = nil }
        } message: {
            Text(
                "The file remains at its current path and runs with your user permissions. Keyestro records its identity and SHA-256 and refuses to run it after either changes until you reconfirm."
            )
        }
        .confirmationDialog(
            "Reconnect \(model.reconnectCandidate?.registration.title ?? "imported script")?",
            isPresented: Binding(
                get: { model.reconnectCandidate != nil },
                set: { if !$0 { model.reconnectCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Verify and Reconnect") { model.confirmReconnect() }
            Button("Cancel", role: .cancel) { model.reconnectCandidate = nil }
        } message: {
            Text("Keyestro will copy the selected executable only if its SHA-256 matches the exported registration.")
        }
        .confirmationDialog(
            "Trust the current contents of \(model.reconfirmCandidate?.title ?? "linked script")?",
            isPresented: Binding(
                get: { model.reconfirmCandidate != nil },
                set: { if !$0 { model.reconfirmCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reconfirm Identity and Contents") { model.confirmReconfirmation() }
            Button("Cancel", role: .cancel) { model.reconfirmCandidate = nil }
        } message: {
            Text("Keyestro will replace the trusted file identity and SHA-256 with the values currently on disk.")
        }
    }
}

@MainActor
final class ClipboardSettingsModel: ObservableObject {
    @Published var state: ClipboardStoreState = .disabled
    @Published var message: String?
    let store: ClipboardStore?
    private var stateTask: Task<Void, Never>?

    init(store: ClipboardStore?) {
        self.store = store
        observeState()
    }

    deinit {
        stateTask?.cancel()
    }

    func refresh() {
        guard let store else { return }
        Task { state = await store.currentState() }
    }

    private func observeState() {
        guard let store else { return }
        stateTask = Task { [weak self] in
            let updates = await store.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.state = state
            }
        }
    }

    func clear() {
        guard let store else { return }
        Task {
            switch await store.clear() {
            case .success: message = "Clipboard history cleared."
            case let .failure(error): message = error.message
            }
            refresh()
        }
    }

    func clear(type: ClipboardContentType) {
        guard let store else { return }
        Task {
            switch await store.clear(type: type) {
            case .success: message = "Selected clipboard history cleared."
            case let .failure(error): message = error.message
            }
            refresh()
        }
    }

    func recover() {
        guard let store else { return }
        Task {
            switch await store.recoverMissingKeyByDeletingHistory() {
            case .success: message = "Clipboard encryption was reinitialized."
            case let .failure(error): message = error.message
            }
            refresh()
        }
    }
}

private struct ClipboardPrivacyView: View {
    @StateObject private var model: ClipboardSettingsModel
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case clear
        case recover
        case clearText
        case clearURLs
        case clearFiles
        case clearImages
        var id: String { rawValue }
    }

    init(store: ClipboardStore?) {
        _model = StateObject(wrappedValue: ClipboardSettingsModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Clipboard History", systemImage: "doc.on.clipboard")
                Spacer()
                Text(stateLabel).foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") { model.refresh() }
                Button("Clear History…", role: .destructive) { confirmation = .clear }
                    .disabled(model.store == nil)
                Menu("Clear by Type") {
                    Button("Text…") { confirmation = .clearText }
                    Button("URLs…") { confirmation = .clearURLs }
                    Button("Files…") { confirmation = .clearFiles }
                    Button("Images…") { confirmation = .clearImages }
                }
                .disabled(model.store == nil)
                if case .keyMissing = model.state {
                    Button("Delete Undecryptable History and Reinitialize…", role: .destructive) {
                        confirmation = .recover
                    }
                }
            }
            if let message = model.message { Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog(
            confirmation == .recover ? "Delete undecryptable clipboard history?" : "Clear clipboard history?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch confirmation {
            case .clear:
                Button("Delete All Clipboard Items", role: .destructive) { model.clear() }
            case .recover:
                Button("Delete and Reinitialize Encryption", role: .destructive) { model.recover() }
            case .clearText:
                Button("Delete Text Items", role: .destructive) { model.clear(type: .text) }
            case .clearURLs:
                Button("Delete URL Items", role: .destructive) { model.clear(type: .url) }
            case .clearFiles:
                Button("Delete File Items", role: .destructive) { model.clear(type: .files) }
            case .clearImages:
                Button("Delete Image Items", role: .destructive) { model.clear(type: .image) }
            case .none:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            switch confirmation {
            case .clear, .clearText, .clearURLs, .clearFiles, .clearImages:
                Text("This permanently deletes the selected encrypted clipboard entries from this Mac.")
            case .recover: Text("The old encryption key is missing. Existing entries cannot be recovered and will be permanently deleted.")
            case .none: EmptyView()
            }
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .disabled: "Disabled"
        case .loading: "Loading"
        case let .ready(count): "\(count) items"
        case let .keyMissing(count): "Key missing · \(count) items"
        case .failed: "Error"
        }
    }
}

enum QuicklinkArgumentType: String, CaseIterable, Identifiable {
    case text
    case password
    case choice
    case file
    case directory

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: L10n.text("Text")
        case .password: L10n.text("Password")
        case .choice: L10n.text("Choice")
        case .file: L10n.text("File")
        case .directory: L10n.text("Directory")
        }
    }
}

struct QuicklinkArgumentDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var title: String
    var type: QuicklinkArgumentType
    var required: Bool
    var choices: String

    init(
        name: String,
        title: String? = nil,
        type: QuicklinkArgumentType = .text,
        required: Bool = true,
        choices: String = ""
    ) {
        self.name = name
        self.title = title ?? name.capitalized
        self.type = type
        self.required = required
        self.choices = choices
    }

    init(_ definition: ArgumentDefinition) {
        name = definition.id
        title = definition.title
        required = definition.required
        switch definition.kind {
        case .text:
            type = .text
            choices = ""
        case .password:
            type = .password
            choices = ""
        case let .choice(options):
            type = .choice
            choices = options.joined(separator: ", ")
        case .file:
            type = .file
            choices = ""
        case .directory:
            type = .directory
            choices = ""
        }
    }

    func definition() throws -> ArgumentDefinition {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanTitle.isEmpty else {
            throw ErrorDescriptor(code: "quicklinks.invalidArgumentDraft", message: "Every parameter needs a name and title.")
        }
        let kind: ArgumentKind
        switch type {
        case .text: kind = .text
        case .password: kind = .password
        case .file: kind = .file
        case .directory: kind = .directory
        case .choice:
            let options = choices.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !options.isEmpty else {
                throw ErrorDescriptor(code: "quicklinks.emptyChoices", message: "Choice parameters need at least one option.")
            }
            kind = .choice(options: options)
        }
        return ArgumentDefinition(id: cleanName, title: cleanTitle, kind: kind, required: required)
    }
}

@MainActor
final class QuicklinkSettingsModel: ObservableObject {
    @Published var links: [QuicklinkDefinition] = []
    @Published var title = ""
    @Published var template = "https://example.com/search?q={query}"
    @Published var keywords = ""
    @Published var iconName = "link"
    @Published var browserBundleIdentifier = ""
    @Published var arguments = [QuicklinkArgumentDraft(name: "query")]
    @Published var error: String?
    private let store: any QuicklinkStoring

    init(store: any QuicklinkStoring) {
        self.store = store
        reload()
    }

    func reload() {
        Task {
            do {
                links = try await store.allQuicklinks()
                error = nil
            } catch {
                self.error = "Quick links could not be loaded."
            }
        }
    }

    func add() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, URL(string: cleanTemplate)?.scheme != nil else {
            error = "Enter a title and an absolute URL template."
            return
        }
        do {
            guard NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil else {
                throw ErrorDescriptor(code: "quicklinks.invalidIcon", message: "Enter a valid SF Symbol name.")
            }
            let definitions = try arguments.map { try $0.definition() }
            let parsedKeywords = keywords.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let cleanBrowserBundleIdentifier = browserBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = try QuicklinkDefinition(
                id: UUID().uuidString.lowercased(),
                title: cleanTitle,
                urlTemplate: cleanTemplate,
                arguments: definitions,
                keywords: parsedKeywords,
                iconName: iconName,
                browserBundleIdentifier: cleanBrowserBundleIdentifier.isEmpty ? nil : cleanBrowserBundleIdentifier
            )
            Task {
                do {
                    try await store.saveQuicklink(definition)
                    title = ""
                    keywords = ""
                    browserBundleIdentifier = ""
                    reload()
                } catch {
                    self.error = "The quick link could not be saved."
                }
            }
        } catch let descriptor as ErrorDescriptor {
            self.error = descriptor.message
        } catch {
            self.error = "The quick link is invalid."
        }
    }

    func synchronizeParameters() {
        let names = QuicklinkDefinition.placeholders(in: template).sorted()
        arguments = names.map { name in
            arguments.first(where: { $0.name == name }) ?? QuicklinkArgumentDraft(name: name)
        }
    }

    func addParameter() {
        var index = arguments.count + 1
        var name = "parameter\(index)"
        while arguments.contains(where: { $0.name == name }) {
            index += 1
            name = "parameter\(index)"
        }
        arguments.append(QuicklinkArgumentDraft(name: name))
    }

    func removeParameter(id: UUID) {
        arguments.removeAll { $0.id == id }
    }

    func delete(_ link: QuicklinkDefinition) {
        Task {
            do {
                guard try await store.deleteQuicklink(ifUnchanged: link) else {
                    throw ErrorDescriptor(
                        code: "quicklinks.staleRegistration",
                        message: "The quick link changed after the deletion confirmation.",
                        recoverySuggestion: "Review the current quick link and confirm deletion again."
                    )
                }
                reload()
            } catch let descriptor as ErrorDescriptor {
                self.error = descriptor.message
            } catch {
                self.error = "The quick link could not be deleted."
            }
        }
    }
}

private struct QuicklinkSettingsView: View {
    @StateObject private var model: QuicklinkSettingsModel
    @State private var removal: QuicklinkDefinition?

    init(store: any QuicklinkStoring) {
        _model = StateObject(wrappedValue: QuicklinkSettingsModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Links").font(.headline)
            ForEach(model.links) { link in
                HStack {
                    VStack(alignment: .leading) {
                        Text(link.title)
                        Text(link.urlTemplate).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let browserBundleIdentifier = link.browserBundleIdentifier {
                            Text(browserBundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        removal = link
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(link.title)")
                }
            }
            TextField("Title", text: $model.title).textFieldStyle(.roundedBorder)
            TextField("URL template", text: $model.template).textFieldStyle(.roundedBorder)
            TextField("Browser bundle identifier (optional)", text: $model.browserBundleIdentifier)
                .textFieldStyle(.roundedBorder)
            HStack {
                Image(systemName: model.iconName.isEmpty ? "link" : model.iconName)
                    .frame(width: 24)
                TextField("SF Symbol icon", text: $model.iconName).textFieldStyle(.roundedBorder)
                TextField("Keywords (comma-separated)", text: $model.keywords).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Parameters").font(.callout.weight(.semibold))
                Spacer()
                Button("Sync from Template") { model.synchronizeParameters() }
                Button("Add Parameter") { model.addParameter() }
            }
            ForEach($model.arguments) { $argument in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $argument.name).textFieldStyle(.roundedBorder)
                        TextField("Title", text: $argument.title).textFieldStyle(.roundedBorder)
                        Picker("Type", selection: $argument.type) {
                            ForEach(QuicklinkArgumentType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .labelsHidden()
                        Toggle("Required", isOn: $argument.required)
                        Button(role: .destructive) {
                            model.removeParameter(id: argument.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    if argument.type == .choice {
                        TextField("Choices (comma-separated)", text: $argument.choices)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(8)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("Use placeholders such as {query}; values are percent-encoded.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Quick Link") { model.add() }
            }
            if let error = model.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.red) }
        }
        .confirmationDialog(
            "Delete \(removal?.title ?? "quick link")?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible
        ) {
            if let removal {
                Button("Delete Quick Link", role: .destructive) {
                    model.delete(removal)
                    self.removal = nil
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            if let removal {
                Text("This permanently deletes the quick link targeting \(removal.urlTemplate).")
            }
        }
    }
}

private struct PermissionsView: View {
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        permissionRow(
            title: "Accessibility",
            detail: "Used only for window management and optional automatic paste.",
            granted: accessibilityGranted,
            request: requestAccessibility,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        Divider()
        permissionRow(
            title: "Screen Recording",
            detail: "Used only when you start screenshot capture or a window preview.",
            granted: screenCaptureGranted,
            request: requestScreenCapture,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        if isAdHocDevelopmentBuild {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Development build permissions", systemImage: "hammer.circle")
                    .font(.callout.weight(.semibold))
                Text(
                    "This ad-hoc development build gets a new macOS identity after every rebuild. If System Settings is enabled but this page says Not allowed, remove the old Keyestro entry and add this exact copy again, or use a stably signed local build. Refreshing or restarting cannot repair an identity mismatch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Show This Copy in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
        }
        Button("Refresh status") {
            refresh()
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        request: @escaping () -> Void,
        settingsURL: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .primary)
                Spacer()
                Text(L10n.text(granted ? "Allowed" : "Not Allowed")).foregroundStyle(.secondary)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
            HStack {
                if !granted { Button("Request Access", action: request) }
                Button("Open System Settings") {
                    if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var isAdHocDevelopmentBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "KeyestroCodeSignatureKind") as? String == "adhoc"
    }

    private func requestAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestScreenCapture() {
        screenCaptureGranted = CGRequestScreenCaptureAccess()
    }

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }
}
