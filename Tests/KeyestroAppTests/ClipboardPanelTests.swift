import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KeyestroCore
import KeyestroDomain
import SwiftUI
import Testing
@testable import KeyestroApp

@Test @MainActor
func clipboardPanelLoadsTimelineAndIntersectsNormalizedSearchWithTypeFilter() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let textID = try #require(
        (await fixture.store.capture(
            .text("synthetic oldest"),
            sourceBundleIdentifier: "com.example.notes",
            at: Date(timeIntervalSince1970: 100)
        )).successValue
    )
    let fileID = try #require(
        (await fixture.store.capture(
            .files([URL(fileURLWithPath: "/tmp/synthetic-needle.txt")]),
            sourceBundleIdentifier: "com.example.files",
            at: Date(timeIntervalSince1970: 200)
        )).successValue
    )
    let syntheticURL = try #require(URL(string: "https://example.invalid/synthetic-needle"))
    let urlID = try #require(
        (await fixture.store.capture(
            .url(syntheticURL),
            sourceBundleIdentifier: "com.example.browser",
            at: Date(timeIntervalSince1970: 300)
        )).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.entries.count == 3 }

    #expect(model.entries.map(\.id) == [urlID, fileID, textID])
    model.queryDidChange("ＳＹＮＴＨＥＴＩＣ－ＮＥＥＤＬＥ", isComposing: true)
    #expect(model.entries.count == 3)
    model.queryDidChange("ＳＹＮＴＨＥＴＩＣ－ＮＥＥＤＬＥ", isComposing: false)
    model.applyFilter(.links)
    try await waitForClipboardPanel { model.entries.map(\.id) == [urlID] }

    model.queryDidChange("", isComposing: false)
    try await waitForClipboardPanel { model.entries.map(\.id) == [urlID] }
    #expect(model.filter == .links)
}

@Test @MainActor
func clipboardPanelPreservesSelectionAndClearsSensitiveRevealsOnDismiss() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let sensitiveID = try #require(
        (await fixture.store.capture(
            .text("password=synthetic-placeholder"),
            sourceBundleIdentifier: nil,
            at: Date(timeIntervalSince1970: 100)
        )).successValue
    )
    let middleID = try #require(
        (await fixture.store.capture(
            .text("synthetic middle"),
            sourceBundleIdentifier: nil,
            at: Date(timeIntervalSince1970: 200)
        )).successValue
    )
    let latestID = try #require(
        (await fixture.store.capture(
            .text("synthetic latest"),
            sourceBundleIdentifier: nil,
            at: Date(timeIntervalSince1970: 300)
        )).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.entries.count == 3 }

    model.selectItem(middleID)
    _ = await fixture.store.delete(id: latestID)
    try await waitForClipboardPanel { model.entries.count == 2 }
    #expect(model.selectedItemID == middleID)

    _ = await fixture.store.delete(id: middleID)
    try await waitForClipboardPanel { model.entries.count == 1 }
    #expect(model.selectedItemID == sensitiveID)
    model.toggleSensitivePreview(sensitiveID)
    #expect(model.isSensitivePreviewRevealed(sensitiveID))

    model.didDismiss()
    #expect(!model.isSensitivePreviewRevealed(sensitiveID))
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.entries.count == 1 }
    #expect(!model.isSensitivePreviewRevealed(sensitiveID))
}

@Test @MainActor
func clipboardPanelReturnPastesDirectlyIntoTheCapturedTarget() async throws {
    let autoPaste = RecordingClipboardPanelAutoPaste()
    let fixture = try ClipboardPanelFixture(autoPaste: autoPaste)
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let payload = "password=synthetic-action-placeholder"
    let itemID = try #require(
        (await fixture.store.capture(.text(payload), sourceBundleIdentifier: nil)).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    var dismissalCount = 0
    model.onDismiss = { dismissalCount += 1 }
    model.invoke(
        context: QueryContext(
            frontmostBundleIdentifier: "com.example.original-target",
            frontmostApplicationName: "Original Target",
            frontmostProcessIdentifier: 42
        )
    )
    try await waitForClipboardPanel { model.selectedItemID == itemID }

    model.requestDeleteSelected()
    let deleteConfirmation = try #require(model.pendingConfirmationPresentation)
    #expect(deleteConfirmation.message.contains(itemID))
    #expect(!deleteConfirmation.message.contains(payload))
    model.cancelPendingAction()

    model.executeDefault()
    #expect(model.pendingConfirmation == nil)
    try await waitForClipboardPanel { !model.isExecuting && dismissalCount == 1 }
    let target = await autoPaste.lastTarget
    #expect(target?.bundleIdentifier == "com.example.original-target")
    #expect(target?.processIdentifier == 42)
    #expect(target?.activationPolicy == .activateIfNeeded)
    #expect(fixture.pasteboard.writtenContent == .text(payload))
}

@Test @MainActor
func clipboardQuickViewRunsItsDescriptorBackedPrimaryAndSecondaryButtons() async throws {
    let autoPaste = RecordingClipboardPanelAutoPaste()
    let fixture = try ClipboardPanelFixture(autoPaste: autoPaste)
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let payload = "quick-view-action-payload"
    let itemID = try #require(
        (await fixture.store.capture(.text(payload), sourceBundleIdentifier: nil)).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    var dismissalCount = 0
    model.onDismiss = { dismissalCount += 1 }
    model.invoke(
        context: QueryContext(
            frontmostBundleIdentifier: "com.example.quick-view-target",
            frontmostApplicationName: "Quick View Target"
        )
    )
    try await waitForClipboardPanel {
        model.selectedItemID == itemID && !model.isSearching && model.canExecuteSelectedEntry
    }

    #expect(model.actionDescriptor(for: .autoPaste)?.title == "Paste to Active App")
    #expect(model.actionDescriptor(for: .copy)?.title == "Copy to Clipboard")

    model.executeDefault()
    try await waitForClipboardPanel {
        !model.isExecuting
            && dismissalCount == 1
            && fixture.pasteboard.changeCount == 1
    }
    #expect((await autoPaste.lastTarget)?.bundleIdentifier == "com.example.quick-view-target")

    model.executeSecondary()
    #expect(model.pendingConfirmation == nil)
    try await waitForClipboardPanel {
        !model.isExecuting && dismissalCount == 2 && fixture.pasteboard.changeCount == 2
    }
    #expect(fixture.pasteboard.writtenContent == .text(payload))
}

@Test @MainActor
func clipboardOpenActionsButtonDisabledStateMirrorsModelExecutability() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let itemID = try #require(
        (await fixture.store.capture(.text("open-actions-state"), sourceBundleIdentifier: nil)).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel {
        model.selectedItemID == itemID && model.canExecuteSelectedEntry
    }

    let view = ClipboardPanelView(model: model)
    #expect(!view.isOpenActionsButtonDisabled)

    model.requestDeleteSelected()
    #expect(model.pendingConfirmation == .delete(id: itemID))
    #expect(!model.canExecuteSelectedEntry)
    #expect(model.selectedEntry != nil)
    #expect(view.isOpenActionsButtonDisabled)
    model.cancelPendingAction()
}

@Test @MainActor
func clipboardPasteFallbackLocalizesOnlyAnUnavailableTargetInSimplifiedChinese() throws {
    let zhHansTranslations = try keyestroAppTranslations(localeIdentifier: "zh-Hans")
    let localize: (String) -> String = { key in
        zhHansTranslations[key] ?? key
    }
    let fallback = ClipboardPanelViewModel.pasteConfirmationTarget(
        applicationName: nil,
        bundleIdentifier: nil,
        localizeFallback: localize
    )
    #expect(fallback == "上一个应用程序（当前不可用）")

    let messageFormat = localize("Clipboard content will be pasted into %@.")
    let message = String(
        format: messageFormat,
        locale: Locale(identifier: "zh-Hans"),
        arguments: [fallback]
    )
    #expect(message == "剪贴板内容将粘贴到 上一个应用程序（当前不可用）。")

    var localizedRealTargets: [String] = []
    let preserveRealTarget: (String) -> String = { key in
        localizedRealTargets.append(key)
        return "unexpected localization"
    }
    #expect(
        ClipboardPanelViewModel.pasteConfirmationTarget(
            applicationName: "Original Target",
            bundleIdentifier: "com.example.original-target",
            localizeFallback: preserveRealTarget
        ) == "Original Target (com.example.original-target)"
    )
    #expect(
        ClipboardPanelViewModel.pasteConfirmationTarget(
            applicationName: "Original Target",
            bundleIdentifier: nil,
            localizeFallback: preserveRealTarget
        ) == "Original Target"
    )
    #expect(
        ClipboardPanelViewModel.pasteConfirmationTarget(
            applicationName: nil,
            bundleIdentifier: "com.example.original-target",
            localizeFallback: preserveRealTarget
        ) == "com.example.original-target"
    )
    #expect(localizedRealTargets.isEmpty)
}

@Test
func quickViewDynamicLocalizationKeysHaveSimplifiedChineseTranslations() throws {
    let translations = try keyestroAppTranslations(localeIdentifier: "zh-Hans")
    let expected = [
        "Today": "今天",
        "Yesterday": "昨天",
        "Earlier": "更早",
        "Choose": "选择",
        "Actions": "操作",
        "Open actions": "打开操作",
        "Executing action": "正在执行操作",
    ]

    for (key, value) in expected {
        #expect(translations[key] == value, "Missing or stale Simplified Chinese Quick View key: \(key)")
    }
}

@Test @MainActor
func clipboardPanelShowsDisabledAndPausedStatesWithoutSilentlyEnablingCapture() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    await fixture.store.initialize(enabled: false)
    let model = fixture.makeModel()
    defer { model.didDismiss() }
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.state == .disabled }
    #expect(!fixture.settings.clipboardEnabled)

    model.enableHistory()
    #expect(fixture.settings.clipboardEnabled)
    #expect(!fixture.settings.clipboardPaused)
    await fixture.store.initialize(enabled: true)
    try await waitForClipboardPanel { model.state == .ready(itemCount: 0) }

    fixture.settings.clipboardPaused = true
    try await waitForClipboardPanel { model.isPaused }
    #expect(model.state == .ready(itemCount: 0))
    model.resumeMonitoring()
    #expect(!fixture.settings.clipboardPaused)
}

@Test @MainActor
func clipboardPanelUsesTheLocalLensAppearanceAndFixedGeometry() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    let model = fixture.makeModel()

    #expect(model.launcherAppearance == .automatic)
    fixture.settings.launcherAppearance = .dark
    try await waitForClipboardPanel { model.launcherAppearance == .dark }
    fixture.settings.launcherAppearance = .light
    try await waitForClipboardPanel { model.launcherAppearance == .light }

    let frame = ClipboardPanelController.frame(
        in: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )
    #expect(frame.width == ClipboardPanelLayout.windowWidth)
    #expect(frame.height == ClipboardPanelLayout.windowHeight)
    #expect(ClipboardPanelLayout.windowWidth == 800)
    #expect(ClipboardPanelLayout.windowHeight == 620)
    #expect(ClipboardPanelLayout.headerHeight == 72)
    #expect(ClipboardPanelLayout.contentHeight == 496)
    #expect(ClipboardPanelLayout.footerHeight == 52)
    #expect(ClipboardPanelLayout.rowHeight == 60)
    #expect(ClipboardPanelLayout.quickViewWidth == 320)
    #expect(ClipboardPanelLayout.quickViewHeight == 464)
    #expect(ClipboardPanelLayout.quickViewTop == 140)
    #expect(
        ClipboardPanelLayout.headerHeight
            + ClipboardPanelLayout.contentHeight
            + ClipboardPanelLayout.footerHeight
            == ClipboardPanelLayout.windowHeight
    )
    #expect(
        ClipboardPanelLayout.windowHeight
            - ClipboardPanelLayout.quickViewTop
            - ClipboardPanelLayout.quickViewHeight
            == 16
    )
}

@Test @MainActor
func clipboardEscapeClosesQuickViewBeforeClearingQueryOrDismissing() async throws {
    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let itemID = try #require(
        (await fixture.store.capture(
            .text("quick-view-escape"),
            sourceBundleIdentifier: nil
        )).successValue
    )
    let model = fixture.makeModel()
    defer { model.didDismiss() }

    var dismissalCount = 0
    model.onDismiss = { dismissalCount += 1 }
    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.selectedItemID == itemID && !model.isSearching }

    #expect(model.isQuickViewPresented)
    model.openActions()
    #expect(!model.isQuickViewPresented)
    model.handleEscape()
    #expect(model.layer == .results)
    #expect(!model.isQuickViewPresented)

    model.selectItem(itemID)
    model.queryDidChange("quick-view", isComposing: false)
    try await waitForClipboardPanel { !model.isSearching }
    model.handleEscape()
    #expect(!model.isQuickViewPresented)
    #expect(model.query == "quick-view")
    #expect(dismissalCount == 0)

    model.handleEscape()
    #expect(model.query.isEmpty)
    try await waitForClipboardPanel { !model.isSearching }
    model.handleEscape()
    #expect(dismissalCount == 1)
}

@Test @MainActor
func transientPanelCoordinatorDismissesThePreviousPanelWithoutRestoringFocus() {
    let coordinator = TransientPanelCoordinator()
    var launcherDismissals: [Bool] = []
    var clipboardDismissals: [Bool] = []
    coordinator.register(.launcher) { launcherDismissals.append($0) }
    coordinator.register(.clipboardHistory) { clipboardDismissals.append($0) }

    coordinator.willShow(.launcher)
    coordinator.willShow(.clipboardHistory)
    #expect(launcherDismissals == [false])
    #expect(clipboardDismissals.isEmpty)
    #expect(coordinator.visiblePanel == .clipboardHistory)

    coordinator.willShow(.launcher)
    #expect(clipboardDismissals == [false])
    #expect(coordinator.visiblePanel == .launcher)
    coordinator.didDismiss(.launcher)
    #expect(coordinator.visiblePanel == nil)
}

@Test @MainActor
func clipboardPanelRendersEveryStateAndInteractionLayerAsAComponentStory() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let autoPaste = GatedClipboardPanelAutoPaste()
    let fixture = try ClipboardPanelFixture(autoPaste: autoPaste)
    defer { fixture.remove() }
    let model = fixture.makeModel()
    let renderer = ClipboardPanelStoryRenderer(model: model)
    defer { renderer.close() }
    defer { model.didDismiss() }

    model.invoke(context: QueryContext())
    try await waitForClipboardPanel { model.state == .disabled }
    try await renderer.render()

    fixture.settings.clipboardEnabled = true
    try await waitForClipboardPanel { model.state == .loading }
    try await renderer.render()

    await fixture.store.initialize(enabled: true)
    let now = Date()
    let textID = try #require(
        (await fixture.store.capture(
            .text("password=component-story-sensitive"),
            sourceBundleIdentifier: "com.example.unknown-component-story",
            at: now.addingTimeInterval(-900)
        )).successValue
    )
    let storyURL = try #require(URL(string: "https://platform.openai.com/docs"))
    _ = try #require(
        (await fixture.store.capture(
            .url(storyURL),
            sourceBundleIdentifier: nil,
            at: now.addingTimeInterval(-300)
        )).successValue
    )
    _ = try #require(
        (await fixture.store.capture(
            .text("Meeting notes and follow-ups\nReview the launcher action flow and clipboard privacy states."),
            sourceBundleIdentifier: "com.apple.Notes",
            at: now.addingTimeInterval(-3_600)
        )).successValue
    )
    _ = try #require(
        (await fixture.store.capture(
            .imagePNG(try clipboardPanelStoryPNG()),
            sourceBundleIdentifier: nil,
            at: now.addingTimeInterval(-600)
        )).successValue
    )
    let referenceTextID = try #require(
        (await fixture.store.capture(
            .text(
                """
                Product brief — Keyestro

                Keyestro is a native macOS productivity tool that keeps commands, clipboard history, and shortcuts at your fingertips.

                • Fast launcher
                • Clipboard history with quick paste
                • Secure, local-first

                — End of brief —
                """
            ),
            sourceBundleIdentifier: "com.apple.TextEdit",
            at: now.addingTimeInterval(-120)
        )).successValue
    )
    let keyestroURL = try #require(URL(string: "https://keyestro.app"))
    _ = try #require(
        (await fixture.store.capture(
            .url(keyestroURL),
            sourceBundleIdentifier: nil,
            at: now.addingTimeInterval(-90_000)
        )).successValue
    )
    model.invoke(
        context: QueryContext(
            frontmostBundleIdentifier: "com.example.previous",
            frontmostApplicationName: "Previous App"
        )
    )
    try await waitForClipboardPanel { model.entries.count == 6 && !model.isSearching }
    model.selectItem(referenceTextID)
    try await waitForClipboardPanel { model.quickViewContent != nil }
    for appearance in [LauncherAppearancePreference.light, .dark] {
        fixture.settings.launcherAppearance = appearance
        try await waitForClipboardPanel { model.launcherAppearance == appearance }
        try await renderer.render(snapshotName: "clipboard-local-lens-\(appearance.rawValue)")
    }

    model.selectItem(textID)
    try await renderer.render()
    model.toggleSensitivePreview(textID)
    try await renderer.render()

    fixture.settings.clipboardPaused = true
    try await waitForClipboardPanel { model.isPaused }
    try await renderer.render()
    fixture.settings.clipboardPaused = false

    model.openActions()
    model.moveSelection(1)
    try await renderer.render()
    model.openFilters()
    model.moveSelection(1)
    try await renderer.render()
    model.applySelectedFilter()
    try await waitForClipboardPanel { model.layer == .results && !model.isSearching }

    model.applyFilter(.images)
    try await waitForClipboardPanel { model.entries.count == 1 && !model.isSearching }
    try await renderer.render()
    model.queryDidChange("no-component-story-match", isComposing: false)
    try await waitForClipboardPanel { model.entries.isEmpty && !model.isSearching }
    try await renderer.render()

    model.queryDidChange("", isComposing: false)
    model.applyFilter(.all)
    try await waitForClipboardPanel { model.entries.count == 6 && !model.isSearching }
    model.selectItem(textID)
    model.requestDeleteSelected()
    try await renderer.render()
    model.cancelPendingAction()
    model.requestClearAll()
    try await renderer.render()
    model.cancelPendingAction()

    model.executeDefault()
    try await waitForClipboardPanel { model.isExecuting }
    try await renderer.render()
    for _ in 0..<2_000 {
        if await autoPaste.isWaiting { break }
        await Task.yield()
    }
    #expect(await autoPaste.isWaiting)
    try await renderer.render()
    await autoPaste.finish(
        .failure(
            ErrorDescriptor(
                code: "clipboard.autoPaste.permissionDenied",
                message: "Accessibility permission is required for automatic paste.",
                recoverySuggestion: "Open Settings → Permissions to grant access, then try again."
            )
        )
    )
    try await waitForClipboardPanel { !model.isExecuting && model.message != nil }
    try await renderer.render()

    try await fixture.keyManager.deleteClipboardKey()
    await fixture.store.initialize(enabled: true)
    try await waitForClipboardPanel {
        if case .keyMissing = model.state { true } else { false }
    }
    try await renderer.render()

    let unavailableDefaultsName = "com.keyestro.clipboard-unavailable-story.\(UUID().uuidString)"
    let unavailableDefaults = try #require(UserDefaults(suiteName: unavailableDefaultsName))
    unavailableDefaults.removePersistentDomain(forName: unavailableDefaultsName)
    defer { unavailableDefaults.removePersistentDomain(forName: unavailableDefaultsName) }
    let unavailableSettings = SettingsStore(defaults: unavailableDefaults)
    unavailableSettings.clipboardEnabled = true
    let unavailableModel = ClipboardPanelViewModel(store: nil, actions: nil, settings: unavailableSettings)
    let unavailableRenderer = ClipboardPanelStoryRenderer(model: unavailableModel)
    defer { unavailableRenderer.close() }
    unavailableModel.invoke(context: QueryContext())
    try await waitForClipboardPanel {
        if case .failed = unavailableModel.state { true } else { false }
    }
    try await unavailableRenderer.render()
    unavailableModel.didDismiss()
}

@Test @MainActor
func clipboardPanelControllerPresentsResizesAndDismissesItsComponent() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let fixture = try ClipboardPanelFixture()
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    _ = await fixture.store.capture(.text("component controller"), sourceBundleIdentifier: nil)
    let model = fixture.makeModel()
    let baselineCount = ClipboardPanelController.clipboardPanelWindowCount()
    let controller = ClipboardPanelController(
        viewModel: model,
        focusCoordinator: TransientPanelFocusCoordinator(),
        presentationCoordinator: TransientPanelCoordinator()
    )
    #expect(ClipboardPanelController.clipboardPanelWindowCount() == baselineCount + 1)

    controller.show()
    for _ in 0..<50 where !controller.isVisible { await Task.yield() }
    #expect(controller.isVisible)
    try await waitForClipboardPanel { !model.entries.isEmpty }
    #expect(controller.frame.width == ClipboardPanelLayout.windowWidth)
    #expect(controller.frame.height == ClipboardPanelLayout.windowHeight)
    let resultsFrame = controller.frame
    let backdrop = try #require(
        NSApplication.shared.windows
            .first { $0.identifier == ClipboardPanelController.panelWindowIdentifier }?
            .contentView as? LauncherPanelBackdropView
    )
    #expect(backdrop.layer?.cornerRadius == ClipboardPanelLayout.panelCornerRadius)
    model.openActions()
    await Task.yield()
    #expect(controller.frame == resultsFrame)
    model.openFilters()
    await Task.yield()
    #expect(controller.frame == resultsFrame)
    controller.dismiss(restoringFocus: false)
    #expect(!controller.isVisible)

    controller.toggle()
    for _ in 0..<50 where !controller.isVisible { await Task.yield() }
    #expect(controller.isVisible)
    controller.toggle()
    #expect(!controller.isVisible)
}

@Test @MainActor
func clipboardPanelKeepsAutoPasteAliveWhenTargetActivationResignsTheWindow() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let autoPaste = GatedClipboardPanelAutoPaste()
    let fixture = try ClipboardPanelFixture(autoPaste: autoPaste)
    defer { fixture.remove() }
    fixture.settings.clipboardEnabled = true
    await fixture.store.initialize(enabled: true)
    let itemID = try #require(
        (await fixture.store.capture(.text("focus-race-regression"), sourceBundleIdentifier: nil)).successValue
    )
    let model = fixture.makeModel()
    let focusCoordinator = TransientPanelFocusCoordinator()
    let presentationCoordinator = TransientPanelCoordinator()
    var controller: ClipboardPanelController?
    controller = ClipboardPanelController(
        viewModel: model,
        focusCoordinator: focusCoordinator,
        presentationCoordinator: presentationCoordinator
    )
    model.onDismiss = { controller?.dismiss(restoringFocus: false) }
    let panelController = try #require(controller)
    defer { panelController.dismiss(restoringFocus: false) }

    panelController.show()
    try await waitForClipboardPanel { panelController.isVisible && model.selectedItemID == itemID }
    model.invoke(
        context: QueryContext(
            frontmostBundleIdentifier: "com.example.focus-target",
            frontmostApplicationName: "Focus Target",
            frontmostProcessIdentifier: 77
        )
    )
    try await waitForClipboardPanel { model.selectedItemID == itemID && !model.isSearching }
    model.executeDefault()
    try await waitForClipboardPanel { model.isAutoPasting && model.isExecuting }
    for _ in 0..<2_000 {
        if await autoPaste.isWaiting { break }
        await Task.yield()
    }
    #expect(await autoPaste.isWaiting)

    let panel = try #require(
        NSApplication.shared.windows.first { $0.identifier == ClipboardPanelController.panelWindowIdentifier }
    )
    panel.resignKey()
    panelController.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
    try await Task.sleep(for: .milliseconds(90))

    #expect(panelController.isVisible)
    #expect(model.isAutoPasting)
    await autoPaste.finish(.success(()))
    try await waitForClipboardPanel { !panelController.isVisible && !model.isExecuting }
}

@MainActor
private final class ClipboardPanelFixture {
    let root: URL
    let database: LauncherDatabase
    let store: ClipboardStore
    let settings: SettingsStore
    let pasteboard = ClipboardPanelPasteboard()
    let actions: ClipboardActionService
    let keyManager: InstallationKeyManager
    private let defaultsName: String

    init(autoPaste: any AutoPasteServicing = RecordingClipboardPanelAutoPaste()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-clipboard-panel-\(UUID().uuidString)", isDirectory: true)
        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.clipboard-panel-tests",
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
        )
        database = LauncherDatabase(paths: paths)
        keyManager = InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.clipboard-panel-tests"
        )
        store = ClipboardStore(database: database, keyManager: keyManager)
        defaultsName = "com.keyestro.clipboard-panel-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw ClipboardPanelTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsName)
        settings = SettingsStore(defaults: defaults)
        actions = ClipboardActionService(store: store, pasteboard: pasteboard, autoPaste: autoPaste)
    }

    func makeModel() -> ClipboardPanelViewModel {
        ClipboardPanelViewModel(store: store, actions: actions, settings: settings)
    }

    func remove() {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ClipboardPanelPasteboard: PasteboardServicing, @unchecked Sendable {
    var changeCount = 0
    var writtenContent: ClipboardContent?

    func readSupportedContent() -> ClipboardContent? { nil }

    func write(_ content: ClipboardContent) -> Bool {
        writtenContent = content
        changeCount += 1
        return true
    }
}

private actor RecordingClipboardPanelAutoPaste: AutoPasteServicing {
    private(set) var lastTarget: AutoPasteTarget?

    func paste(intoBundleIdentifier bundleIdentifier: String?) -> Result<Void, ErrorDescriptor> {
        lastTarget = bundleIdentifier.map {
            AutoPasteTarget(bundleIdentifier: $0, activationPolicy: .activateIfNeeded)
        }
        return .success(())
    }

    func paste(into target: AutoPasteTarget) -> Result<Void, ErrorDescriptor> {
        lastTarget = target
        return .success(())
    }
}

private actor GatedClipboardPanelAutoPaste: AutoPasteServicing {
    private var continuation: CheckedContinuation<Result<Void, ErrorDescriptor>, Never>?

    var isWaiting: Bool { continuation != nil }

    func paste(intoBundleIdentifier bundleIdentifier: String?) async -> Result<Void, ErrorDescriptor> {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ result: Result<Void, ErrorDescriptor>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class ClipboardPanelStoryRenderer {
    // AttributeGraph computes view metadata on a utility queue. Keeping the two
    // off-screen renderers alive for the short-lived test process avoids racing
    // that work with NSHostingView teardown between adjacent component tests.
    private static var retainedRenderers: [ClipboardPanelStoryRenderer] = []

    private let hosting: NSHostingView<ClipboardPanelStoryRenderRoot>
    private let window: NSWindow
    private var isRetained = false

    init(model: ClipboardPanelViewModel) {
        hosting = NSHostingView(rootView: ClipboardPanelStoryRenderRoot(model: model))
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: ClipboardPanelLayout.windowWidth,
            height: ClipboardPanelLayout.windowHeight
        )
        window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
    }

    func render(snapshotName: String? = nil) async throws {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            await Task.yield()
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let renderedPNG = try #require(
            bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        )
        #expect(renderedPNG.count > 1_000)
        #expect(hosting.fittingSize.width <= hosting.bounds.width + 1)
        #expect(hosting.fittingSize.height <= hosting.bounds.height + 1)
        if let snapshotName,
            let directory = ProcessInfo.processInfo.environment["KEYESTRO_CLIPBOARD_SNAPSHOT_DIR"]
        {
            let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try renderedPNG.write(
                to: outputDirectory.appendingPathComponent("\(snapshotName).png"),
                options: .atomic
            )
        }
    }

    func close() {
        window.orderOut(nil)
        guard !isRetained else { return }
        isRetained = true
        Self.retainedRenderers.append(self)
    }
}

private struct ClipboardPanelStoryRenderRoot: View {
    @ObservedObject var model: ClipboardPanelViewModel

    var body: some View {
        ZStack {
            if model.launcherAppearance == .light {
                LinearGradient(
                    colors: [
                        Color(red: 0.83, green: 0.90, blue: 0.97),
                        Color(red: 0.97, green: 0.92, blue: 0.90),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.07, blue: 0.13),
                        Color(red: 0.08, green: 0.16, blue: 0.29),
                        Color(red: 0.02, green: 0.04, blue: 0.08),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            ClipboardPanelView(model: model)
                .environment(\.launcherNativeGlassEnabled, false)
        }
    }
}

private func keyestroAppTranslations(localeIdentifier: String) throws -> [String: String] {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot =
        testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let catalogURL = packageRoot.appendingPathComponent(
        "Sources/KeyestroApp/Resources/Localizable.xcstrings"
    )
    let catalog = try JSONDecoder().decode(
        ClipboardPanelLocalizationCatalog.self,
        from: Data(contentsOf: catalogURL)
    )
    return catalog.strings.compactMapValues {
        $0.localizations?[localeIdentifier]?.stringUnit.value
    }
}

private struct ClipboardPanelLocalizationCatalog: Decodable {
    let strings: [String: Entry]

    struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit
    }

    struct StringUnit: Decodable {
        let value: String
    }
}

private func clipboardPanelStoryPNG() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

@MainActor
private func waitForClipboardPanel(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    throw ClipboardPanelTestError.conditionTimedOut
}

private enum ClipboardPanelTestError: Error {
    case conditionTimedOut
    case defaultsUnavailable
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self { return value }
        return nil
    }
}
