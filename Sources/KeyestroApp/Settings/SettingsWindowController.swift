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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let localizedWindowTitle = L10n.text("settings.title")
        window.title = localizedWindowTitle == "settings.title" ? "Keyestro Settings" : localizedWindowTitle
        window.minSize = NSSize(width: 720, height: 480)
        window.titlebarSeparatorStyle = .none
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
        let candidateFormat = localizedFormat ?? L10n.text("about.version.format")
        let format = candidateFormat == "about.version.format" ? "Keyestro %@ (%@)" : candidateFormat
        return String(
            format: format,
            locale: Locale.current,
            arguments: [version, build]
        )
    }
}

private struct SettingsView: View {
    private enum PageAnchor: Hashable {
        case top
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var selectedSection: SettingsSection {
        navigation.selection ?? .general
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(navigation: navigation)
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: SettingsLayout.Spacing.xxLarge)
                            .id(PageAnchor.top)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                            SettingsPageHeader(section: selectedSection)
                            if let error = settings.persistenceError {
                                SettingsNotice(
                                    title: L10n.text("Settings could not be saved"),
                                    message: L10n.text(error),
                                    systemImage: "exclamationmark.triangle.fill",
                                    tone: .danger
                                )
                            }
                            detail(for: selectedSection)
                        }
                    }
                    .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, SettingsLayout.pagePadding)
                    .padding(.bottom, SettingsLayout.Spacing.xxxLarge)
                }
                .accessibilityIdentifier("settings.detail.scroll")
                .background(palette.surfaceBase)
                .onChange(of: selectedSection) { _, _ in
                    DispatchQueue.main.async {
                        guard navigation.pendingScrollRequest == nil else { return }
                        if reduceMotion {
                            proxy.scrollTo(PageAnchor.top, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(PageAnchor.top, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: navigation.pendingScrollRequest) { _, request in
                    guard let request else { return }
                    DispatchQueue.main.async {
                        guard navigation.pendingScrollRequest == request else { return }
                        if reduceMotion {
                            proxy.scrollTo(request.anchor, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(request.anchor, anchor: .top)
                            }
                        }
                        navigation.consumePendingScrollRequest(request)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .background(palette.surfaceBase)
        .tint(palette.accent)
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
            GeneralSettingsSection(settings: settings)
        case .shortcuts:
            ShortcutSettingsSection(
                settings: settings,
                beginRecording: beginHotKeyRecording,
                endRecording: endHotKeyRecording
            )
        case .features:
            FeatureSettingsSection(
                settings: settings,
                quicklinks: quicklinks,
                scripts: scripts,
                scriptInstaller: scriptInstaller,
                openPermissions: { navigation.selection = .permissions }
            )
        case .extensions:
            ExtensionSettingsView(
                store: extensions,
                installer: extensionInstaller,
                supervisor: extensionSupervisor,
                authorization: extensionAuthorization,
                preferences: extensionPreferences
            )
            .id(SettingsAnchor.extensionsInstalled)
        case .permissions:
            PermissionsView()
        case .privacy:
            SettingsNotice(
                title: L10n.text("Local by default"),
                message: L10n.text(
                    "Raw queries are never persisted. Clipboard, screenshots, and diagnostics remain local unless you explicitly export them."
                ),
                systemImage: "checkmark.shield.fill",
                tone: .local
            )
            .id(SettingsAnchor.privacySummary)

            SettingsCard(
                title: L10n.text("Ranking & learning"),
                subtitle: L10n.text("Control whether successful actions improve future ordering."),
                systemImage: "chart.line.uptrend.xyaxis"
            ) {
                SettingsToggleRow(
                    title: L10n.text("Learn from successful actions"),
                    detail: L10n.text(
                        "When disabled, saved usage history is neither applied nor updated. Manual pins still affect ranking."
                    ),
                    isOn: $settings.rankingLearningEnabled
                )
                .id(SettingsAnchor.privacyRanking)

                Divider()

                SettingsRow(
                    title: L10n.text("Learned ranking history"),
                    detail: L10n.text("Remove local usage events while keeping your manual pins.")
                ) {
                    Button("Clear History…", role: .destructive) {
                        destructiveSettingsAction = .clearRankingHistory
                    }
                    .disabled(rankingStore == nil || isClearingRanking)
                }

                if let rankingMessage {
                    SettingsNotice(message: L10n.text(rankingMessage))
                }
            }

            SettingsCard(
                title: L10n.text("Clipboard privacy"),
                subtitle: L10n.text("Inspect or remove encrypted clipboard history stored on this Mac."),
                systemImage: "lock.doc",
                tone: .private
            ) {
                ClipboardPrivacyView(store: clipboardStore)
            }
            .id(SettingsAnchor.privacyClipboard)

            SettingsDangerZone(
                title: L10n.text("Delete local data"),
                subtitle: L10n.text("This removes all Keyestro data from this Mac and cannot be undone.")
            ) {
                SettingsRow(
                    title: L10n.text("Delete All Local Data and Quit"),
                    detail: L10n.text("Database, caches, clipboard history, managed code, keys, and preferences are removed.")
                ) {
                    Button("Delete…", role: .destructive) {
                        confirmsDeleteAllData = true
                    }
                }
            }
            .id(SettingsAnchor.privacyDelete)
        case .updates:
            SettingsCard(
                title: L10n.text("Automatic updates"),
                subtitle: L10n.text("Stay current while keeping control of downloads."),
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                SettingsToggleRow(
                    title: L10n.text("Automatically check for updates"),
                    detail: L10n.text("Keyestro periodically checks the selected channel."),
                    isOn: Binding(
                        get: { updateService.automaticallyChecksForUpdates },
                        set: { updateService.setAutomaticallyChecksForUpdates($0) }
                    ),
                    isEnabled: updateService.isConfigured
                )
                .id(SettingsAnchor.updatesAutomatic)

                Divider()

                SettingsToggleRow(
                    title: L10n.text("Automatically download updates"),
                    detail: L10n.text("Download new versions in the background when available."),
                    isOn: Binding(
                        get: { updateService.automaticallyDownloadsUpdates },
                        set: { updateService.setAutomaticallyDownloadsUpdates($0) }
                    ),
                    isEnabled: updateService.isConfigured
                )
            }

            SettingsCard(
                title: L10n.text("Update channel"),
                subtitle: L10n.text("Stable is recommended; Beta receives previews earlier."),
                systemImage: "shippingbox"
            ) {
                SettingsRow(title: L10n.text("Release channel")) {
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
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!updateService.isConfigured)
                }
                .id(SettingsAnchor.updatesChannel)

                Divider()

                SettingsRow(
                    title: AboutVersionLabel.current,
                    detail: updateService.isConfigured
                        ? L10n.text("Check for a newer Keyestro version now.")
                        : L10n.text("Update service is unavailable in this build.")
                ) {
                    Button("Check Now") { updateService.checkForUpdates() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updateService.canCheckForUpdates)
                }
                .id(SettingsAnchor.updatesCheck)

                if let error = updateService.lastErrorMessage {
                    SettingsNotice(
                        message: L10n.text(error),
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }
            }
        case .advanced:
            PerformanceSettingsView(pasteboard: pasteboard)
                .id(SettingsAnchor.advancedPerformance)
            DiagnosticsSettingsView(service: diagnosticsService, settings: settings)
                .id(SettingsAnchor.advancedDiagnostics)
            ConfigurationSettingsView(
                service: configurationService,
                settings: settings,
                navigation: navigation
            )
            .id(SettingsAnchor.advancedConfiguration)

            SettingsCard(
                title: L10n.text("Maintenance"),
                subtitle: L10n.text("Repair local caches or return preferences to their defaults."),
                systemImage: "wrench.and.screwdriver"
            ) {
                SettingsRow(
                    title: L10n.text("Caches"),
                    detail: L10n.text("Clear derived local data; your settings and saved items remain intact.")
                ) {
                    Button("Clear Caches") {
                        isClearingCaches = true
                        cacheMessage = nil
                        Task {
                            cacheMessage = await clearCaches()
                            isClearingCaches = false
                        }
                    }
                    .disabled(isClearingCaches)
                }
                .id(SettingsAnchor.advancedCaches)

                if let cacheMessage {
                    SettingsNotice(message: L10n.text(cacheMessage))
                }

                Divider()

                SettingsRow(
                    title: L10n.text("Restore default settings"),
                    detail: L10n.text("Reset preferences while keeping quick links, scripts, extensions, and saved data.")
                ) {
                    Button("Restore…", role: .destructive) {
                        destructiveSettingsAction = .restoreDefaults
                    }
                }
                .id(SettingsAnchor.advancedDefaults)

                if let defaultSettingsMessage {
                    SettingsNotice(message: L10n.text(defaultSettingsMessage))
                }
            }
        case .about:
            SettingsCard(tone: .local) {
                VStack(spacing: SettingsLayout.Spacing.large) {
                    Image(systemName: "command")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 64, height: 64)
                        .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.accent.opacity(0.28), lineWidth: 1)
                        }
                        .accessibilityHidden(true)

                    VStack(spacing: SettingsLayout.Spacing.xSmall) {
                        Text(verbatim: AboutVersionLabel.current)
                            .font(.system(size: 20, weight: .bold))
                        Text("Native, open source, and local-first.")
                            .font(SettingsLayout.Typography.body)
                        Text("Apache-2.0 licensed.")
                            .font(SettingsLayout.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SettingsLayout.Spacing.xxLarge)
            }
            .id(SettingsAnchor.aboutVersion)
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

struct ShortcutRecorder: View {
    @ObservedObject var settings: SettingsStore
    let beginRecording: () -> Void
    let endRecording: () -> Void
    @State private var recordingAction: HotKeyAction?
    @State private var eventMonitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            shortcutRow(for: .launcher)
            Divider()
            shortcutRow(for: .clipboardHistory)
            Divider()
            shortcutRow(for: .quickPaste)
            Divider()
            Text("Use Command, Option, or Control with another key. Conflicts remain visible and the menu bar stays available.")
                .font(SettingsLayout.Typography.metadata)
                .foregroundStyle(.secondary)
                .padding(.top, SettingsLayout.Spacing.medium)
            if let message = validationMessage ?? settings.shortcutValidationError ?? settings.persistenceError {
                Text(L10n.text(message))
                    .font(SettingsLayout.Typography.metadata)
                    .foregroundStyle(.red)
                    .padding(.top, SettingsLayout.Spacing.small)
            }
            if let message = settings.hotKeyRegistrationError(for: .launcher) {
                Text(L10n.text(message)).font(SettingsLayout.Typography.metadata).foregroundStyle(.red)
            }
            if let message = settings.hotKeyRegistrationError(for: .clipboardHistory) {
                Text(L10n.text(message)).font(SettingsLayout.Typography.metadata).foregroundStyle(.red)
            }
            if let message = settings.hotKeyRegistrationError(for: .quickPaste) {
                Text(L10n.text(message)).font(SettingsLayout.Typography.metadata).foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func shortcutRow(for action: HotKeyAction) -> some View {
        SettingsRow(title: L10n.text(label(for: action))) {
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
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(minWidth: 108)
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

struct QuickPasteSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let openPermissions: () -> Void
    @State private var confirmsEnable = false

    var body: some View {
        SettingsCard(
            title: L10n.text("Quick Paste"),
            subtitle: L10n.text("Paste the latest eligible clipboard item into the active app."),
            systemImage: "arrow.up.doc.on.clipboard",
            tone: .private
        ) {
            SettingsToggleRow(
                title: L10n.text("Enable Quick Paste for the latest text or URL"),
                detail: L10n.text("Requires Accessibility access and a unique global shortcut."),
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

            Divider()

            SettingsToggleRow(
                title: L10n.text("Allow sensitive-looking text"),
                detail: L10n.text("When off, sensitive-looking items open Clipboard History instead."),
                isOn: $settings.quickPasteAllowsSensitiveContent,
                isEnabled: settings.quickPasteEnabled
            )

            if settings.quickPasteShortcut == nil {
                SettingsNotice(
                    message: L10n.text("Record a unique Quick Paste shortcut in Shortcuts before it can run."),
                    systemImage: "keyboard.badge.ellipsis",
                    tone: .private
                )
            }

            SettingsRow(
                title: L10n.text("Accessibility permission"),
                detail: L10n.text("Review the macOS access used to send Command-V to the frontmost app.")
            ) {
                Button("Review Permission", action: openPermissions)
            }
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

struct LoginItemSettingsView: View {
    private let service = MacLoginItemService()
    @State private var status: LoginItemStatus = .disabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.Spacing.small) {
            SettingsToggleRow(
                title: L10n.text("Launch at Login"),
                detail: loginItemDetail,
                isOn: Binding(
                    get: { status == .enabled },
                    set: { enabled in update(enabled) }
                )
            )
            if let error {
                SettingsNotice(
                    message: L10n.text(error),
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .danger
                )
            }
        }
        .onAppear { status = service.status() }
    }

    private var loginItemDetail: String {
        if status == .requiresApproval {
            return L10n.text("macOS requires approval in System Settings → General → Login Items.")
        }
        return L10n.text("Open Keyestro automatically after you sign in to this Mac.")
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
        VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
            SettingsCard(
                title: L10n.text("Installed Extensions"),
                subtitle: L10n.text("Add and manage explicitly trusted local workflows."),
                systemImage: "puzzlepiece.extension"
            ) {
                HStack {
                    SettingsStatusBadge(
                        L10n.format("%lld installed", Int64(model.registrations.count)),
                        systemImage: "shippingbox.fill"
                    )
                    Spacer()
                    Button("Install Local Extension…") { model.choosePackage() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking)
                }
                SettingsNotice(
                    message: L10n.text(
                        "Native extensions run with your user permissions. Process isolation protects Keyestro from crashes, but it is not a security sandbox. Install only code you trust."
                    ),
                    systemImage: "exclamationmark.shield.fill",
                    tone: .private
                )
            }

            if !model.pendingImports.isEmpty {
                SettingsCard(
                    title: L10n.text("Imported Extensions Requiring Reinstallation"),
                    subtitle: L10n.text(
                        "Select the exact exported package. Its identifier, version, and SHA-256 must all match."
                    ),
                    systemImage: "arrow.clockwise.circle",
                    tone: .private
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.pendingImports, id: \.manifest.id) { registration in
                            SettingsRow(
                                title: registration.manifest.name,
                                detail: "\(registration.manifest.id) · \(registration.manifest.version)"
                            ) {
                                Button("Select Package…") { model.choosePackage(for: registration) }
                                    .disabled(model.isWorking)
                            }
                        }
                    }
                }
            }

            if let inspected = model.inspected {
                SettingsCard(
                    title: L10n.text("Review Before Installing"),
                    subtitle: L10n.text("Verify the package identity and system security checks before enabling it."),
                    systemImage: "checkmark.shield",
                    tone: .private
                ) {
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
                SettingsCard {
                    ContentUnavailableView(
                        "No extensions installed",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Choose a local .extension directory to inspect it before installation.")
                    )
                    .frame(minHeight: 150)
                }
            }
            ForEach(model.registrations) { registration in
                SettingsCard(
                    title: registration.manifest.name,
                    subtitle: "\(registration.id) · \(registration.manifest.version)",
                    systemImage: "puzzlepiece.extension",
                    tone: registration.enabled ? .standard : .private
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsToggleRow(
                            title: L10n.text("Enabled"),
                            detail: L10n.text("Allow this extension to run its declared local commands."),
                            isOn: Binding(
                                get: { registration.enabled },
                                set: { model.setEnabled($0, registration: registration) }
                            )
                        )
                        Divider()
                        Text(registration.manifest.description).foregroundStyle(.secondary)
                        if registration.manifest.searchPolicy == .global {
                            SettingsToggleRow(
                                title: L10n.text("Share global query text with this extension"),
                                detail: L10n.text("Off by default. When enabled, this extension receives queries outside @ mode."),
                                isOn: Binding(
                                    get: { model.globalSearchEnabled[registration.id] == true },
                                    set: { model.setGlobalSearch($0, registration: registration) }
                                )
                            )
                        } else {
                            SettingsNotice(
                                message: L10n.text(
                                    "Explicit search: query text is shared only after you open one of this extension’s commands in @ mode."
                                ),
                                systemImage: "at"
                            )
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
            if let error = model.error {
                SettingsNotice(
                    message: L10n.text(error),
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .danger
                )
            }
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
        SettingsCard(
            title: L10n.text("Local Performance Diagnostics"),
            subtitle: L10n.text("Measure launcher responsiveness without recording private content."),
            systemImage: "gauge.with.dots.needle.67percent"
        ) {
            Text(
                "Keyestro keeps only bounded timing samples in memory. Queries, result titles, clipboard content, and file paths are never recorded."
            )
            .font(SettingsLayout.Typography.label)
            .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack {
                    performanceActions
                }
                VStack(alignment: .leading, spacing: SettingsLayout.Spacing.small) {
                    performanceActions
                }
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
                SettingsNotice(message: L10n.text(message))
            }
        }
    }

    @ViewBuilder
    private var performanceActions: some View {
        Button("Run Local Performance Diagnostics") { model.run() }
            .disabled(model.isWorking)
        Button("Copy Performance Report") { model.copy() }
            .disabled(model.report?.summaries.isEmpty != false)
        Button("Clear Performance Samples") { model.reset() }
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
        SettingsCard(
            title: L10n.text("Diagnostics"),
            subtitle: L10n.text("Preview exactly what will be included before creating an archive."),
            systemImage: "stethoscope"
        ) {
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
            if let message = model.message {
                SettingsNotice(message: L10n.text(message))
            }
        }
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
        SettingsCard(
            title: L10n.text("Configuration"),
            subtitle: L10n.text("Move portable preferences and registrations between Macs."),
            systemImage: "arrow.up.arrow.down.square"
        ) {
            Text(
                "Exports contain portable, non-secret preferences, quick links, script registration metadata, and extension manifests. They never contain local capability approvals, safety consent, Keychain values, clipboard payloads, script bodies, or private environment values."
            )
            .font(SettingsLayout.Typography.label)
            .foregroundStyle(.secondary)
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
                        Text("\(pending.preview.ignoredSettingsCount) unsupported or locally authorized settings ignored")
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
            if let message = model.message {
                SettingsNotice(message: L10n.text(message))
            }
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

struct ScriptSettingsView: View {
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
        VStack(alignment: .leading, spacing: SettingsLayout.Spacing.medium) {
            SettingsRow(
                title: L10n.text("Encrypted history"),
                detail: L10n.text("Entries stay on this Mac and are encrypted before persistence.")
            ) {
                SettingsStatusBadge(
                    L10n.text(stateLabel),
                    systemImage: stateSymbol,
                    tone: stateTone
                )
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    clipboardActions
                }
                VStack(alignment: .leading, spacing: SettingsLayout.Spacing.small) {
                    clipboardActions
                }
            }
            if let message = model.message {
                SettingsNotice(message: L10n.text(message))
            }
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

    @ViewBuilder
    private var clipboardActions: some View {
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

    private var stateLabel: String {
        switch model.state {
        case .disabled: "Disabled"
        case .loading: "Loading"
        case let .ready(count): "\(count) items"
        case let .keyMissing(count): "Key missing · \(count) items"
        case .failed: "Error"
        }
    }

    private var stateSymbol: String {
        switch model.state {
        case .disabled: "pause.circle.fill"
        case .loading: "clock.fill"
        case .ready: "checkmark.circle.fill"
        case .keyMissing, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var stateTone: SettingsTone {
        switch model.state {
        case .ready: .local
        case .disabled, .loading: .standard
        case .keyMissing, .failed: .danger
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

struct QuicklinkSettingsView: View {
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
        VStack(spacing: SettingsLayout.pageSpacing) {
            SettingsNotice(
                title: L10n.text("Requested only when needed"),
                message: L10n.text(
                    "Keyestro explains why access is needed before macOS asks. You can review or revoke access at any time."
                ),
                systemImage: "hand.raised.fill",
                tone: .private
            )

            permissionRow(
                title: "Accessibility",
                detail: "Used only for window management and optional automatic paste.",
                symbol: "hand.raised",
                granted: accessibilityGranted,
                request: requestAccessibility,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            .id(SettingsAnchor.permissionsAccessibility)

            permissionRow(
                title: "Screen Recording",
                detail: "Used only when you start screenshot capture or a window preview.",
                symbol: "rectangle.dashed.badge.record",
                granted: screenCaptureGranted,
                request: requestScreenCapture,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            .id(SettingsAnchor.permissionsScreenRecording)

            if isAdHocDevelopmentBuild {
                SettingsCard(
                    title: L10n.text("Development build permissions"),
                    subtitle: L10n.text(
                        "This copy receives a new macOS identity after each rebuild, so an older permission entry may no longer apply."
                    ),
                    systemImage: "hammer.circle",
                    tone: .private
                ) {
                    Text(
                        "If System Settings is enabled but this page says Not Allowed, remove the old Keyestro entry and add this exact copy again, or use a stably signed local build."
                    )
                    .font(SettingsLayout.Typography.label)
                    .foregroundStyle(.secondary)
                    Button("Show This Copy in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh Status") { refresh() }
                    .controlSize(.small)
            }
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
        symbol: String,
        granted: Bool,
        request: @escaping () -> Void,
        settingsURL: String
    ) -> some View {
        SettingsCard(
            title: L10n.text(title),
            subtitle: L10n.text(detail),
            systemImage: symbol,
            tone: granted ? .local : .private
        ) {
            HStack(spacing: SettingsLayout.Spacing.medium) {
                SettingsStatusBadge(
                    L10n.text(granted ? "Allowed" : "Not Allowed"),
                    systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    tone: granted ? .local : .private
                )
                Spacer()
                if !granted {
                    Button("Request Access", action: request)
                        .buttonStyle(.borderedProminent)
                }
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
