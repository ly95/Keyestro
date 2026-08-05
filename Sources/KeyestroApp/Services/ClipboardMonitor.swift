import AppKit
import Combine
import Foundation
import KeyestroCore
import KeyestroDomain

@MainActor
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let pasteboard: any PasteboardServicing
    private let settings: SettingsStore
    private let clock: any ClockServicing
    private let frontmostBundleIdentifier: @MainActor @Sendable () -> String?
    private let onCaptureIssue: @MainActor @Sendable (ErrorDescriptor) -> Void
    private var pollTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?
    private var settingsGeneration: UInt64 = 0
    private var isSystemSuspended = false
    private var lastChangeCount = 0

    init(
        store: ClipboardStore,
        pasteboard: any PasteboardServicing,
        settings: SettingsStore,
        clock: any ClockServicing = SystemClockService(),
        frontmostBundleIdentifier: @escaping @MainActor @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        onCaptureIssue: @escaping @MainActor @Sendable (ErrorDescriptor) -> Void = { _ in }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.settings = settings
        self.clock = clock
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.onCaptureIssue = onCaptureIssue
    }

    var isPolling: Bool { pollTask != nil }

    func start() {
        settingsCancellable = Publishers.CombineLatest4(
            settings.$clipboardEnabled,
            settings.$clipboardPaused,
            settings.$clipboardRetentionPreset,
            settings.$clipboardExcludedApplications
        )
        .sink { [weak self] enabled, paused, retentionPreset, excludedApplications in
            self?.applySettings(
                enabled: enabled,
                paused: paused,
                retentionPolicy: SettingsStore.clipboardRetentionPolicy(for: retentionPreset),
                excludedBundleIdentifiers: SettingsStore.excludedClipboardBundleIdentifiers(
                    from: excludedApplications
                )
            )
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributed.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        configurationTask?.cancel()
        configurationTask = nil
        settingsCancellable = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc func systemWillSleep() {
        isSystemSuspended = true
        pollTask?.cancel()
        pollTask = nil
    }

    @objc func systemDidWake() {
        isSystemSuspended = false
        applyCurrentSettings()
    }

    @objc func screenDidLock() {
        systemWillSleep()
    }

    @objc func screenDidUnlock() {
        systemDidWake()
    }

    private func applyCurrentSettings() {
        applySettings(
            enabled: settings.clipboardEnabled,
            paused: settings.clipboardPaused,
            retentionPolicy: settings.clipboardRetentionPolicy,
            excludedBundleIdentifiers: settings.excludedClipboardBundleIdentifiers
        )
    }

    private func applySettings(
        enabled: Bool,
        paused: Bool,
        retentionPolicy: ClipboardRetentionPolicy,
        excludedBundleIdentifiers: Set<String>
    ) {
        settingsGeneration &+= 1
        let generation = settingsGeneration
        pollTask?.cancel()
        pollTask = nil
        configurationTask?.cancel()
        configurationTask = nil
        guard enabled else {
            configurationTask = Task { [weak self] in
                guard let self, settingsGeneration == generation, !Task.isCancelled else { return }
                await store.initialize(enabled: false)
                if settingsGeneration == generation { configurationTask = nil }
            }
            return
        }

        guard !paused, !isSystemSuspended else {
            configurationTask = Task { [weak self] in
                guard let self, settingsGeneration == generation, !Task.isCancelled else { return }
                if case let .failure(error) = await store.updatePolicy(retentionPolicy) {
                    guard settingsGeneration == generation, !Task.isCancelled else { return }
                    onCaptureIssue(error)
                }
                guard settingsGeneration == generation, !Task.isCancelled else { return }
                await store.initialize(enabled: true)
                if settingsGeneration == generation { configurationTask = nil }
            }
            return
        }

        lastChangeCount = pasteboard.changeCount
        pollTask = Task { [weak self] in
            guard let self else { return }
            if case let .failure(error) = await store.updatePolicy(retentionPolicy) {
                guard settingsGeneration == generation, !Task.isCancelled else { return }
                onCaptureIssue(error)
            }
            guard settingsGeneration == generation, !Task.isCancelled else { return }
            await store.initialize(enabled: true)
            guard settingsGeneration == generation, !Task.isCancelled else { return }
            var unchangedTicks = 0
            while settingsGeneration == generation, !Task.isCancelled {
                let current = pasteboard.changeCount
                if current != lastChangeCount {
                    lastChangeCount = current
                    unchangedTicks = 0
                    switch pasteboard.readSupportedContentResult() {
                    case let .success(content?):
                        let source = frontmostBundleIdentifier()
                        if source == nil || !excludedBundleIdentifiers.contains(source ?? "") {
                            let result = await store.capture(
                                content,
                                sourceBundleIdentifier: source
                            )
                            guard settingsGeneration == generation, !Task.isCancelled else { return }
                            if case let .failure(error) = result {
                                onCaptureIssue(error)
                            }
                        }
                    case .success(nil):
                        break
                    case let .failure(error):
                        onCaptureIssue(error)
                    }
                } else {
                    unchangedTicks += 1
                }
                let delay: Duration = unchangedTicks >= 120 ? .seconds(2) : .milliseconds(500)
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    break
                }
            }
        }
    }
}
