import AppKit
import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor func appDelegateWiresAndExercisesEverySafeHostInteraction() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let suiteName = "com.keyestro.app-delegate-component-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = SettingsStore(defaults: defaults)
    #expect(settings.completeOnboarding())
    let preexistingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
    let delegate = AppDelegate(settings: settings)

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    for _ in 0..<20 { await Task.yield() }

    delegate.openLauncher()
    delegate.openLauncher()
    delegate.openClipboardHistory()
    delegate.openClipboardHistory()
    delegate.openSettings()
    delegate.openPermissions()
    delegate.openPrivacy()
    delegate.checkForUpdates()

    settings.clipboardEnabled = false
    settings.clipboardPaused = false
    delegate.toggleClipboardMonitoring()
    #expect(settings.clipboardEnabled)
    delegate.toggleClipboardMonitoring()
    #expect(settings.clipboardPaused)
    delegate.toggleClipboardMonitoring()
    #expect(!settings.clipboardPaused)
    delegate.updateClipboardMenu(enabled: false, paused: false)
    delegate.updateClipboardMenu(enabled: true, paused: true)
    delegate.updateClipboardMenu(enabled: true, paused: false)
    delegate.presentClipboardIssue(
        ErrorDescriptor(
            code: "clipboard.componentStory",
            message: String(repeating: "Component story issue ", count: 12),
            recoverySuggestion: "Open Privacy settings."
        )
    )

    delegate.menuWillOpen(NSMenu())
    delegate.updatePermissionAndUpdateMenu()
    delegate.updateHotKeyStatus(action: .launcher, state: .registered)
    delegate.updateHotKeyStatus(action: .clipboardHistory, state: .unavailable(status: -9876))
    delegate.beginHotKeyRecording()
    delegate.beginHotKeyRecording()
    delegate.endHotKeyRecording()
    delegate.endHotKeyRecording()
    delegate.scheduleConfiguredHotKeyRegistration()
    delegate.scheduleConfiguredHotKeyRegistration()
    for _ in 0..<10 { await Task.yield() }
    delegate.registerConfiguredHotKeys()

    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    await delegate.shutdown()

    for window in NSApplication.shared.windows where !preexistingWindows.contains(ObjectIdentifier(window)) {
        window.orderOut(nil)
        window.close()
    }
    AppDelegateComponentRetainer.retain(delegate)
}

@MainActor
private enum AppDelegateComponentRetainer {
    // AppDelegate owns several SwiftUI-backed controllers. Retain the assembled
    // graph after shutdown so concurrent component stories cannot race teardown.
    private static var retainedDelegates: [AppDelegate] = []

    static func retain(_ delegate: AppDelegate) {
        retainedDelegates.append(delegate)
    }
}
