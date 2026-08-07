import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import KeyestroCore
import KeyestroDomain

@main
enum KeyestroApplication {
    @MainActor
    static func main() {
        let processStartedAt = ContinuousClock.now
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--smoke-test"] {
            let localized = L10n.text("launcher.empty")
            guard !localized.isEmpty, localized != "launcher.empty" else {
                FileHandle.standardError.write(Data("Packaged localization is unavailable.\n".utf8))
                return
            }
            print("Keyestro packaged-app smoke test passed")
            return
        }
        if arguments == ["--ui-smoke-test"] {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    try await PackagedUISmokeHarness.run()
                    print("Keyestro packaged UI smoke test passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("Keyestro packaged UI smoke test failed: \(error)\n".utf8))
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            application.run()
            return
        }
        if arguments.first == "--ui-performance-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    try await PackagedUIPerformanceHarness.run(
                        arguments: Array(arguments.dropFirst()),
                        processStartedAt: processStartedAt
                    )
                    print("Keyestro packaged UI performance test passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(
                        Data("Keyestro packaged UI performance test failed: \(error)\n".utf8)
                    )
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            application.run()
            return
        }
        if arguments.first == "--idle-performance-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    try await IdlePerformanceHarness.run(arguments: Array(arguments.dropFirst()))
                    print("Keyestro packaged idle performance test passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(
                        Data("Keyestro packaged idle performance test failed: \(error)\n".utf8)
                    )
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            application.run()
            return
        }
        if arguments.first == "--lifecycle-soak-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    try await PackagedLifecycleHarness.run(arguments: Array(arguments.dropFirst()))
                    print("Keyestro packaged lifecycle soak test passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(
                        Data("Keyestro packaged lifecycle soak test failed: \(error)\n".utf8)
                    )
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            application.run()
            return
        }
        if arguments.first == "--clipboard-query-soak-test" {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    try await PackagedSoakHarness.run(arguments: Array(arguments.dropFirst()))
                    print("Keyestro packaged clipboard/query soak test passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(
                        Data("Keyestro packaged clipboard/query soak test failed: \(error)\n".utf8)
                    )
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            application.run()
            return
        }
        if arguments.first == "--database-crash-writer" {
            Task {
                do {
                    try await DatabaseCrashHarness.writeUntilKilled(arguments: Array(arguments.dropFirst()))
                } catch {
                    FileHandle.standardError.write(Data("Database crash writer failed: \(error)\n".utf8))
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        }
        if arguments.first == "--database-crash-readback" {
            Task {
                do {
                    try await DatabaseCrashHarness.readBack(arguments: Array(arguments.dropFirst()))
                    print("Keyestro database crash readback passed")
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data("Database crash readback failed: \(error)\n".utf8))
                    Darwin.exit(EXIT_FAILURE)
                }
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings: SettingsStore
    private var statusItem: NSStatusItem?
    private var hotKeyService: HotKeyService?
    private var panelController: LauncherPanelController?
    private var clipboardPanelController: ClipboardPanelController?
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var hotKeyStatusItem: NSMenuItem?
    private var clipboardHotKeyStatusItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private var clipboardIssueItem: NSMenuItem?
    private var permissionStatusItem: NSMenuItem?
    private var checkUpdatesItem: NSMenuItem?
    private var clipboardMonitor: ClipboardMonitor?
    private var quickPasteCoordinator: QuickPasteCoordinator?
    private var quickPasteHUDController: QuickPasteHUDController?
    private var extensionSupervisor: ExtensionSupervisor?
    private var updateService: SparkleUpdateService?
    private var database: LauncherDatabase?
    private var storageConfiguration: ApplicationStorageConfiguration?
    private var terminationPending = false
    private var isRecordingHotKey = false
    private var hotKeyRegistrationTask: Task<Void, Never>?
    private var settingsCancellables = Set<AnyCancellable>()

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyActivationPolicy()

        let quicklinks: any QuicklinkBatchStoring
        let rankingStore: (any RankingServicing)?
        let database: LauncherDatabase?
        let appPaths: AppPaths?
        let storageConfiguration = ApplicationStorageConfiguration.current()
        let bundleIdentifier = storageConfiguration.bundleIdentifier
        let keychain = storageConfiguration.makeCredentialStore()
        let keyManager = InstallationKeyManager(
            keychain: keychain,
            service: bundleIdentifier
        )
        self.storageConfiguration = storageConfiguration
        if let paths = try? storageConfiguration.makePaths() {
            appPaths = paths
            let createdDatabase = LauncherDatabase(paths: paths)
            database = createdDatabase
            quicklinks = createdDatabase
            rankingStore = RankingStore(database: createdDatabase, keys: keyManager)
            Task { [weak self] in
                do {
                    try await createdDatabase.prepare()
                    if let report = await createdDatabase.latestRecoveryReport() {
                        self?.presentDatabaseRecovery(report)
                    }
                } catch let error as DatabaseError {
                    self?.presentDatabaseFailure(error.descriptor)
                } catch {
                    self?.presentDatabaseFailure(
                        ErrorDescriptor(
                            code: "database.prepareFailed",
                            message: "The local database could not be prepared.",
                            recoverySuggestion: "Review the Backups folder and export diagnostics before changing local data."
                        )
                    )
                }
            }
        } else {
            appPaths = nil
            database = nil
            quicklinks = InMemoryQuicklinkStore()
            rankingStore = nil
        }
        let clipboardInternalWriteRegistry = ClipboardInternalWriteRegistry()
        let pasteboard = InternalWriteTrackingPasteboardService(
            pasteboard: MacPasteboardService(),
            internalWriteRegistry: clipboardInternalWriteRegistry
        )
        let fileActions = MacFileActionService(pasteboard: pasteboard)
        let clipboardStore = database.map { ClipboardStore(database: $0, keyManager: keyManager) }
        let clipboardActions = clipboardStore.map {
            ClipboardActionService(
                store: $0,
                pasteboard: pasteboard,
                autoPaste: MacAutoPasteService()
            )
        }
        let scriptStore: any ScriptStoring
        if let database {
            scriptStore = database
        } else {
            scriptStore = InMemoryScriptStore()
        }
        let scriptInstaller = appPaths.map { ManagedScriptInstaller(paths: $0, store: scriptStore) }
        let extensionStore: any ExtensionStoring
        if let database {
            extensionStore = database
        } else {
            extensionStore = InMemoryExtensionStore()
        }
        let extensionPreferences = ExtensionPreferenceService(
            store: extensionStore,
            keychain: keychain,
            bundleIdentifier: bundleIdentifier
        )
        let extensionAuthorization = UserDefaultsExtensionSearchAuthorization()
        let extensionSupervisor = ExtensionSupervisor(
            store: extensionStore,
            hostVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            hostHandler: MacExtensionHostHandler(preferences: extensionPreferences)
        )
        let extensionInstaller = appPaths.map { ExtensionInstaller(paths: $0, store: extensionStore) }
        let updateService = SparkleUpdateService()
        let processService = FoundationProcessService()
        let configurationService = appPaths.map {
            ConfigurationService(
                quicklinks: quicklinks,
                scripts: scriptStore,
                extensions: extensionStore,
                paths: $0,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            )
        }
        let diagnosticsService = appPaths.map {
            DiagnosticsService(
                paths: $0,
                extensions: extensionStore,
                database: database,
                processService: processService,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            )
        }
        let accessibilityService = MacAccessibilityService()
        let captureCoordinator = CaptureCoordinator(
            captureService: MacScreenCaptureService(),
            ocrService: LocalVisionOCRService(),
            settings: settings,
            pasteboard: pasteboard
        )
        var providers: [any LauncherProvider] = [
            ApplicationProvider(
                workspace: MacWorkspaceService(pasteboard: pasteboard),
                rankingStore: rankingStore
            ),
            CalculatorProvider(pasteboard: pasteboard),
            FileProvider(actions: fileActions, preferences: settings.fileSearchPreferences),
            QuicklinkProvider(
                store: quicklinks,
                schemeAuthorization: UserDefaultsURLSchemeAuthorization()
            ),
            ScriptProvider(store: scriptStore, processService: processService),
            WindowProvider(accessibility: accessibilityService),
            SystemCommandProvider(confirmation: settings),
            CaptureProvider(coordinator: captureCoordinator),
            ExtensionProvider(
                store: extensionStore,
                supervisor: extensionSupervisor,
                authorization: extensionAuthorization
            ),
        ]
        if let clipboardStore, let clipboardActions {
            providers.append(
                ClipboardProvider(
                    store: clipboardStore,
                    actions: clipboardActions
                )
            )
        }
        let coordinator = QueryCoordinator(
            providers: providers,
            rankingStore: rankingStore,
            rankingLearning: settings.rankingLearningPreferences
        )
        let runner = ActionRunner(
            providers: providers,
            rankingStore: rankingStore,
            rankingLearning: settings.rankingLearningPreferences
        )
        let viewModel = LauncherViewModel(coordinator: coordinator, actionRunner: runner, settings: settings)
        let focusCoordinator = TransientPanelFocusCoordinator()
        let presentationCoordinator = TransientPanelCoordinator()
        let panelController = LauncherPanelController(
            viewModel: viewModel,
            focusCoordinator: focusCoordinator,
            presentationCoordinator: presentationCoordinator
        )
        let clipboardViewModel = ClipboardPanelViewModel(
            store: clipboardStore,
            actions: clipboardActions,
            settings: settings
        )
        let clipboardPanelController = ClipboardPanelController(
            viewModel: clipboardViewModel,
            focusCoordinator: focusCoordinator,
            presentationCoordinator: presentationCoordinator
        )
        let quickPasteCoordinator = QuickPasteCoordinator(
            store: clipboardStore,
            actions: clipboardActions,
            settings: settings
        )
        let quickPasteHUDController = QuickPasteHUDController()
        let settingsController = SettingsWindowController(
            settings: settings,
            quicklinks: quicklinks,
            clipboardStore: clipboardStore,
            pasteboard: pasteboard,
            scripts: scriptStore,
            scriptInstaller: scriptInstaller,
            extensions: extensionStore,
            extensionInstaller: extensionInstaller,
            extensionSupervisor: extensionSupervisor,
            extensionAuthorization: extensionAuthorization,
            extensionPreferences: extensionPreferences,
            updateService: updateService,
            configurationService: configurationService,
            diagnosticsService: diagnosticsService,
            clearCaches: {
                guard let appPaths else { return L10n.text("The application cache path is unavailable.") }
                let error = await Task.detached(priority: .utility) { () -> ErrorDescriptor? in
                    do {
                        try LocalCacheService(paths: appPaths).clear()
                        return nil
                    } catch let error as ErrorDescriptor {
                        return error
                    } catch {
                        return ErrorDescriptor(
                            code: "cache.clearFailed",
                            message: "Caches could not be cleared."
                        )
                    }
                }.value
                if let error {
                    return L10n.errorMessage(error)
                } else {
                    return L10n.text("Caches cleared.")
                }
            },
            beginHotKeyRecording: { [weak self] in self?.beginHotKeyRecording() },
            endHotKeyRecording: { [weak self] in self?.endHotKeyRecording() },
            deleteAllLocalData: { [weak self] in
                self?.deleteAllLocalData(
                    paths: appPaths,
                    database: database,
                    keys: keyManager,
                    bundleIdentifier: bundleIdentifier,
                    extensionSupervisor: extensionSupervisor,
                    extensionPreferences: extensionPreferences
                )
            },
            rankingStore: rankingStore
        )
        viewModel.onDismiss = { [weak panelController] in panelController?.dismiss() }
        viewModel.onOpenSettings = { [weak settingsController] in settingsController?.show() }
        viewModel.onOpenPermissions = { [weak settingsController] in settingsController?.show(section: .permissions) }
        clipboardViewModel.onDismiss = { [weak clipboardPanelController] in clipboardPanelController?.dismiss() }
        clipboardViewModel.onOpenPrivacy = { [weak settingsController, weak clipboardPanelController] in
            clipboardPanelController?.dismiss()
            settingsController?.show(section: .privacy)
        }
        clipboardViewModel.onOpenPermissions = { [weak settingsController, weak clipboardPanelController] in
            clipboardPanelController?.dismiss()
            settingsController?.show(section: .permissions)
        }
        quickPasteCoordinator.onFallbackToHistory = { [weak clipboardPanelController] in
            clipboardPanelController?.show()
        }
        quickPasteCoordinator.onMessage = { [weak quickPasteHUDController] message in
            quickPasteHUDController?.show(message)
        }
        captureCoordinator.onWillSelect = { [weak panelController] in panelController?.dismiss() }
        fileActions.onPreviewWillOpen = { [weak panelController] in panelController?.previewWillOpen() }
        fileActions.onPreviewDidClose = { [weak panelController] in panelController?.previewDidClose() }
        self.panelController = panelController
        self.clipboardPanelController = clipboardPanelController
        self.quickPasteCoordinator = quickPasteCoordinator
        self.quickPasteHUDController = quickPasteHUDController
        self.settingsController = settingsController
        self.extensionSupervisor = extensionSupervisor
        self.updateService = updateService
        self.database = database

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Keyestro")
        let menu = NSMenu()
        menu.delegate = self
        let open = menu.addItem(withTitle: L10n.text("menu.open"), action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        let hotKeyStatus = NSMenuItem(
            title: L10n.format("launcher.shortcut.status", settings.launcherShortcut.displayName),
            action: nil,
            keyEquivalent: ""
        )
        hotKeyStatus.isEnabled = false
        menu.addItem(hotKeyStatus)
        hotKeyStatusItem = hotKeyStatus
        let openClipboardHistory = menu.addItem(
            withTitle: L10n.text("menu.clipboardHistory.open"),
            action: #selector(openClipboardHistory),
            keyEquivalent: ""
        )
        openClipboardHistory.target = self
        let clipboardHotKeyStatus = NSMenuItem(
            title: L10n.format("clipboard.shortcut.status", settings.clipboardHistoryShortcut.displayName),
            action: nil,
            keyEquivalent: ""
        )
        clipboardHotKeyStatus.isEnabled = false
        menu.addItem(clipboardHotKeyStatus)
        clipboardHotKeyStatusItem = clipboardHotKeyStatus
        menu.addItem(.separator())
        let clipboardItem = menu.addItem(
            withTitle: L10n.text("menu.clipboard.off"),
            action: #selector(toggleClipboardMonitoring),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        clipboardMenuItem = clipboardItem
        let clipboardIssue = NSMenuItem(
            title: L10n.text("Clipboard issue"),
            action: #selector(openPrivacy),
            keyEquivalent: ""
        )
        clipboardIssue.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Clipboard warning")
        clipboardIssue.target = self
        clipboardIssue.isHidden = true
        menu.addItem(clipboardIssue)
        clipboardIssueItem = clipboardIssue
        let permissions = menu.addItem(
            withTitle: L10n.text("menu.permissions"),
            action: #selector(openPermissions),
            keyEquivalent: ""
        )
        permissions.target = self
        permissionStatusItem = permissions
        menu.addItem(.separator())
        let settingsItem = menu.addItem(
            withTitle: L10n.text("menu.settings"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        let checkUpdates = menu.addItem(
            withTitle: L10n.text("menu.checkUpdates"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        checkUpdatesItem = checkUpdates
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: L10n.text("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        item.menu = menu
        statusItem = item

        let hotKeyService = HotKeyService()
        hotKeyService.onInvocation = {
            [weak panelController, weak clipboardPanelController, weak quickPasteCoordinator] action in
            switch action {
            case .launcher: panelController?.toggle()
            case .clipboardHistory: clipboardPanelController?.toggle()
            case .quickPaste: quickPasteCoordinator?.invoke()
            }
        }
        hotKeyService.onStateChange = { [weak self] action, state in
            self?.updateHotKeyStatus(action: action, state: state)
        }
        self.hotKeyService = hotKeyService
        registerConfiguredHotKeys()
        Publishers.CombineLatest4(
            settings.$launcherShortcut,
            settings.$clipboardHistoryShortcut,
            settings.$quickPasteShortcut,
            settings.$quickPasteEnabled
        )
        .dropFirst()
        .sink { [weak self] _, _, _, _ in
            guard let self, !isRecordingHotKey else { return }
            scheduleConfiguredHotKeyRegistration()
        }
        .store(in: &settingsCancellables)

        if let clipboardStore {
            let monitor = ClipboardMonitor(
                store: clipboardStore,
                pasteboard: pasteboard,
                settings: settings,
                internalWriteRegistry: clipboardInternalWriteRegistry,
                onCaptureIssue: { [weak self] error in self?.presentClipboardIssue(error) }
            )
            monitor.start()
            clipboardMonitor = monitor
        }
        settings.$clipboardEnabled
            .combineLatest(settings.$clipboardPaused)
            .sink { [weak self] enabled, paused in
                self?.updateClipboardMenu(enabled: enabled, paused: paused)
            }
            .store(in: &settingsCancellables)
        updatePermissionAndUpdateMenu()

        if settings.onboardingCompleted {
            panelController.show()
        } else {
            let onboardingController = OnboardingWindowController(settings: settings) { [weak self, weak panelController] in
                self?.onboardingController?.window?.orderOut(nil)
                self?.onboardingController = nil
                panelController?.show()
            }
            self.onboardingController = onboardingController
            onboardingController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyRegistrationTask?.cancel()
        hotKeyService?.stop()
        clipboardMonitor?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateNow }
        terminationPending = true
        Task {
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func shutdown() async {
        await extensionSupervisor?.shutdownAll()
        await database?.close()
        try? storageConfiguration?.removeEphemeralData()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panelController?.show() }
        return true
    }

    @objc func openLauncher() {
        panelController?.toggle()
    }

    @objc func openClipboardHistory() {
        clipboardPanelController?.toggle()
    }

    @objc func openSettings() {
        panelController?.dismiss()
        clipboardPanelController?.dismiss()
        settingsController?.show()
    }

    @objc func openPermissions() {
        panelController?.dismiss()
        clipboardPanelController?.dismiss()
        settingsController?.show(section: .permissions)
    }

    @objc func openPrivacy() {
        panelController?.dismiss()
        clipboardPanelController?.dismiss()
        settingsController?.show(section: .privacy)
    }

    @objc func checkForUpdates() {
        updateService?.checkForUpdates()
    }

    @objc func toggleClipboardMonitoring() {
        if settings.clipboardEnabled {
            settings.clipboardPaused.toggle()
        } else {
            settings.clipboardEnabled = true
            settings.clipboardPaused = false
        }
    }

    func updateClipboardMenu(enabled: Bool, paused: Bool) {
        if !enabled {
            clipboardMenuItem?.title = L10n.text("menu.clipboard.enable")
        } else if paused {
            clipboardMenuItem?.title = L10n.text("menu.clipboard.resume")
        } else {
            clipboardMenuItem?.title = L10n.text("menu.clipboard.pause")
        }
    }

    func presentClipboardIssue(_ error: ErrorDescriptor) {
        let message = L10n.errorMessage(error).limitedToUnicodeScalars(120)
        clipboardIssueItem?.title = L10n.format("Clipboard capture skipped: %@", message)
        clipboardIssueItem?.toolTip = L10n.recoverySuggestion(error)
        clipboardIssueItem?.isHidden = false
        statusItem?.button?.toolTip = message
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionAndUpdateMenu()
    }

    func updatePermissionAndUpdateMenu() {
        let accessibility = AXIsProcessTrusted() ? L10n.text("Allowed") : L10n.text("Not Allowed")
        let capture = CGPreflightScreenCaptureAccess() ? L10n.text("Allowed") : L10n.text("Not Allowed")
        permissionStatusItem?.title = L10n.format("menu.permissions.status", accessibility, capture)
        checkUpdatesItem?.isEnabled = updateService?.canCheckForUpdates == true
    }

    func registerConfiguredHotKeys() {
        guard let hotKeyService else { return }
        hotKeyService.suspend()
        hotKeyService.register(settings.launcherShortcut, for: .launcher)
        hotKeyService.register(settings.clipboardHistoryShortcut, for: .clipboardHistory)
        if settings.quickPasteEnabled, let shortcut = settings.quickPasteShortcut {
            hotKeyService.register(shortcut, for: .quickPaste)
        } else {
            settings.setHotKeyRegistrationError(nil, for: .quickPaste)
        }
    }

    func beginHotKeyRecording() {
        hotKeyRegistrationTask?.cancel()
        hotKeyRegistrationTask = nil
        isRecordingHotKey = true
        hotKeyService?.suspend()
    }

    func endHotKeyRecording() {
        guard isRecordingHotKey else { return }
        isRecordingHotKey = false
        registerConfiguredHotKeys()
    }

    func scheduleConfiguredHotKeyRegistration() {
        hotKeyRegistrationTask?.cancel()
        hotKeyRegistrationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !isRecordingHotKey else { return }
            hotKeyRegistrationTask = nil
            registerConfiguredHotKeys()
        }
    }

    func updateHotKeyStatus(action: HotKeyAction, state: HotKeyRegistrationState) {
        guard let shortcut = settings.shortcut(for: action) else {
            settings.setHotKeyRegistrationError(nil, for: action)
            return
        }
        let presentation = HotKeyStatusPresentation(
            action: action,
            state: state,
            shortcut: shortcut
        )
        settings.setHotKeyRegistrationError(presentation.errorMessage, for: action)
        switch action {
        case .launcher: hotKeyStatusItem?.title = presentation.menuTitle
        case .clipboardHistory: clipboardHotKeyStatusItem?.title = presentation.menuTitle
        case .quickPaste: break
        }
    }

    private func deleteAllLocalData(
        paths: AppPaths?,
        database: LauncherDatabase?,
        keys: InstallationKeyManager,
        bundleIdentifier: String,
        extensionSupervisor: ExtensionSupervisor,
        extensionPreferences: ExtensionPreferenceService
    ) {
        guard let paths else {
            presentDeletionFailure([L10n.text("error.deletion.paths")])
            return
        }
        clipboardMonitor?.stop()
        hotKeyService?.stop()
        panelController?.dismiss()
        clipboardPanelController?.dismiss()
        settingsController?.window?.orderOut(nil)
        Task {
            await extensionSupervisor.shutdownAll()
            var preferenceDeletionFailed = false
            do {
                try await extensionPreferences.deleteAllKnownSecrets()
            } catch {
                preferenceDeletionFailed = true
            }
            await database?.close()
            let service = LocalDataDeletionService(paths: paths, keys: keys)
            let report = await service.deleteAllOwnedData()
            var failures = report.failedTargets
            if preferenceDeletionFailed { failures.append("Extension preference Keychain values") }
            let loginItem = MacLoginItemService()
            if loginItem.status() == .enabled || loginItem.status() == .requiresApproval {
                do { try loginItem.setEnabled(false) } catch { failures.append("Login item registration") }
            }
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            if failures.isEmpty {
                NSApplication.shared.terminate(nil)
            } else {
                presentDeletionFailure(failures)
            }
        }
    }

    private func presentDeletionFailure(_ failures: [String]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("error.deletion.partial")
        alert.informativeText = failures.map { "• \(L10n.text($0))" }.joined(separator: "\n")
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    private func presentDatabaseRecovery(_ report: DatabaseRecoveryReport) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("The local database was recovered")
        var details = L10n.format(
            "The damaged original was preserved at %@. %lld rows were recovered into a healthy database.",
            report.quarantineDirectory.path,
            Int64(report.recoveredRowCount)
        )
        if !report.failedTables.isEmpty {
            details += "\n\n" + L10n.format("Tables that could not be fully recovered: %@", report.failedTables.joined(separator: ", "))
        }
        alert.informativeText = details
        alert.addButton(withTitle: L10n.text("Show Backup"))
        alert.addButton(withTitle: L10n.text("OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([report.quarantineDirectory])
        }
    }

    private func presentDatabaseFailure(_ error: ErrorDescriptor) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.errorMessage(error)
        alert.informativeText = L10n.recoverySuggestion(error) ?? L10n.text("Export diagnostics before changing local data.")
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}
