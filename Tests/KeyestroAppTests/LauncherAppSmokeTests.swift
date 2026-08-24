import AppKit
import Carbon
import Foundation
import KeyestroCore
import KeyestroDomain
import SwiftUI
import Testing
@testable import KeyestroApp

@Test @MainActor func launcherFrontmostWindowFallbackChoosesTheDisplayWithTheLargestIntersection() {
    let displays = [
        CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        CGRect(x: 1_920, y: -200, width: 2_560, height: 1_440),
        CGRect(x: -1_280, y: 0, width: 1_280, height: 1_024),
    ]
    #expect(
        LauncherPanelController.targetDisplayIndex(
            windowBounds: CGRect(x: 1_800, y: 100, width: 900, height: 700),
            displayBounds: displays
        ) == 1
    )
    #expect(
        LauncherPanelController.targetDisplayIndex(
            windowBounds: CGRect(x: 9_000, y: 9_000, width: 100, height: 100),
            displayBounds: displays
        ) == nil
    )
}

@Test @MainActor func launcherSwiftUIViewBuildsAnAccessibleSearchFieldAndResultsContainer() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = AppTestProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { !model.results.isEmpty && !model.isSearching }

    let hosting = NSHostingView(rootView: LauncherView(model: model))
    hosting.frame = NSRect(
        x: 0,
        y: 0,
        width: LauncherPanelLayout.windowWidth,
        height: LauncherPanelLayout.windowHeight
    )
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    hosting.displayIfNeeded()
    await Task.yield()

    let labels = accessibilityLabels(in: hosting as Any)
    #expect(labels.contains(L10n.text("launcher.search.placeholder")))
    let item = try #require(model.results.first?.item)
    #expect(LauncherAccessibility.resultLabel(for: item, previewHidden: false) == "Alpha Application")
    #expect(LauncherAccessibility.resultLabel(for: item, previewHidden: true) == L10n.text("Sensitive item"))
}

@Test @MainActor func launcherViewModelKeepsStableSelectionAcrossStreamingReplacement() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = AppTestProvider(streamReplacement: true)
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { model.results.count == 2 }
    let selected = model.results[1].id
    model.selectItem(selected)
    await provider.publishReplacementKeepingSecondItem()
    try await waitUntil { model.results.first?.item.title == "Updated Application" }

    #expect(model.selectedItemID == selected)
}

@Test @MainActor func destructiveConfirmationReResolvesAndShowsTheCurrentConcreteTarget() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = ConfirmationTestProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { model.results.first?.item.title == "Old Target" }
    model.executeDefault()
    try await waitUntil { model.pendingConfirmation?.targetTitle == "Record Old Target" }

    await provider.replaceTarget(title: "Current Target")
    try await waitUntil { model.results.first?.item.title == "Current Target" }
    model.confirmPendingAction()
    try await waitUntil { model.pendingConfirmation?.targetTitle == "Record Current Target" }
    #expect(await provider.executionCount == 0)

    model.confirmPendingAction()
    try await waitUntil { !model.isExecuting && model.pendingConfirmation == nil }
    #expect(await provider.executionCount == 1)
}

@Test @MainActor func panelGeometryStaysInsideNegativeOriginVisibleFrameAtTheSpecifiedTopOffset() {
    let visible = NSRect(x: -1_920, y: -80, width: 1_920, height: 1_080)
    let frame = LauncherPanelController.frame(in: visible)

    #expect(visible.contains(frame))
    #expect(abs(frame.midX - visible.midX) < 0.001)
    let actualTopOffset = visible.maxY - frame.maxY
    #expect(abs(actualTopOffset - visible.height * 0.18) < 0.001)
}

@Test @MainActor func panelKeepsTheApprovedGeometryAcrossContentStatesAndClampsToTheVisibleDisplay() {
    #expect(LauncherPanelController.preferredHeight(resultCount: 0) == LauncherPanelLayout.windowHeight)
    #expect(LauncherPanelController.preferredHeight(resultCount: 1) == LauncherPanelLayout.windowHeight)
    #expect(LauncherPanelController.preferredHeight(resultCount: 8) == LauncherPanelLayout.windowHeight)
    #expect(LauncherPanelController.preferredHeight(resultCount: 50) == LauncherPanelLayout.windowHeight)
    #expect(
        LauncherPanelController.preferredHeight(
            resultCount: 0,
            showsRecoveryState: true
        ) == LauncherPanelLayout.recoveryHeight
    )

    let smallDisplay = NSRect(x: -800, y: 20, width: 640, height: 400)
    let frame = LauncherPanelController.frame(in: smallDisplay)
    #expect(frame.size == smallDisplay.size)
    #expect(smallDisplay.contains(frame))
}

@Test @MainActor func launcherPermissionRecoveryComponentFitsItsExpandedPanel() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = PermissionDeniedAppTestProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { model.requiresExpandedEmptyState && !model.isSearching }

    let panelHeight = LauncherPanelController.preferredHeight(
        resultCount: model.results.count,
        showsRecoveryState: model.requiresExpandedEmptyState
    )
    let component = LauncherEmptyStateView(
        symbol: "lock.trianglebadge.exclamationmark",
        title: L10n.text("Accessibility permission is required for window management."),
        detail: L10n.text("Open Settings → Permissions to grant access, then refresh."),
        actions: .permissionsAndRetry
    )
    let hosting = NSHostingView(rootView: component.frame(width: LauncherPanelLayout.windowWidth))
    hosting.layoutSubtreeIfNeeded()

    let requiredContentHeight = hosting.fittingSize.height + LauncherPanelLayout.emptyStateVerticalMargins
    let availableContentHeight = LauncherPanelLayout.availableContentHeight(panelHeight: panelHeight)
    #expect(panelHeight == LauncherPanelLayout.recoveryHeight)
    #expect(requiredContentHeight <= availableContentHeight)
}

@Test @MainActor func lifecycleWindowGateAllowsOnlyOneTransientInvisibleSystemHelper() {
    #expect(
        PackagedLifecycleHarness.windowCountsPass(
            panelVisibleAfterCompletion: false,
            baselineWindowCount: 3,
            maximumWindowCount: 4,
            finalWindowCount: 3,
            baselineVisibleWindowCount: 1,
            maximumVisibleWindowCount: 1,
            finalVisibleWindowCount: 0,
            baselineLauncherPanelCount: 1,
            maximumLauncherPanelCount: 1,
            finalLauncherPanelCount: 1
        )
    )
    #expect(
        !PackagedLifecycleHarness.windowCountsPass(
            panelVisibleAfterCompletion: false,
            baselineWindowCount: 3,
            maximumWindowCount: 5,
            finalWindowCount: 3,
            baselineVisibleWindowCount: 1,
            maximumVisibleWindowCount: 1,
            finalVisibleWindowCount: 0,
            baselineLauncherPanelCount: 1,
            maximumLauncherPanelCount: 1,
            finalLauncherPanelCount: 1
        )
    )
    #expect(
        !PackagedLifecycleHarness.windowCountsPass(
            panelVisibleAfterCompletion: false,
            baselineWindowCount: 3,
            maximumWindowCount: 4,
            finalWindowCount: 3,
            baselineVisibleWindowCount: 1,
            maximumVisibleWindowCount: 2,
            finalVisibleWindowCount: 0,
            baselineLauncherPanelCount: 1,
            maximumLauncherPanelCount: 1,
            finalLauncherPanelCount: 1
        )
    )
    #expect(
        !PackagedLifecycleHarness.windowCountsPass(
            panelVisibleAfterCompletion: false,
            baselineWindowCount: 3,
            maximumWindowCount: 4,
            finalWindowCount: 3,
            baselineVisibleWindowCount: 1,
            maximumVisibleWindowCount: 1,
            finalVisibleWindowCount: 0,
            baselineLauncherPanelCount: 1,
            maximumLauncherPanelCount: 2,
            finalLauncherPanelCount: 1
        )
    )
    #expect(
        !PackagedLifecycleHarness.windowCountsPass(
            panelVisibleAfterCompletion: false,
            baselineWindowCount: 3,
            maximumWindowCount: 4,
            finalWindowCount: 4,
            baselineVisibleWindowCount: 1,
            maximumVisibleWindowCount: 1,
            finalVisibleWindowCount: 0,
            baselineLauncherPanelCount: 1,
            maximumLauncherPanelCount: 1,
            finalLauncherPanelCount: 1
        )
    )
}

@Test @MainActor func launcherKeyInterpreterProtectsMarkedTextAndReturnKeyRepeat() {
    #expect(
        LauncherKeyInterpreter.interpret(
            selector: #selector(NSResponder.insertNewline(_:)),
            isComposing: true,
            isRepeat: false,
            commandModified: false
        ) == .passThrough
    )
    #expect(
        LauncherKeyInterpreter.interpret(
            selector: #selector(NSResponder.insertNewline(_:)),
            isComposing: false,
            isRepeat: true,
            commandModified: false
        ) == .swallow
    )
    #expect(
        LauncherKeyInterpreter.interpret(
            selector: #selector(NSResponder.insertNewline(_:)),
            isComposing: false,
            isRepeat: false,
            commandModified: true
        ) == .command(.submitSecondary)
    )
    #expect(LauncherKeyInterpreter.commandEquivalent(key: "1", commandModified: true, isComposing: false) == .executeIndex(0))
    #expect(LauncherKeyInterpreter.commandEquivalent(key: "p", commandModified: true, isComposing: false) == .openFilters)
    #expect(
        LauncherKeyInterpreter.commandEquivalent(
            key: "x",
            commandModified: false,
            controlModified: true,
            isComposing: false
        ) == .deleteSelection
    )
    #expect(LauncherKeyInterpreter.commandEquivalent(key: "k", commandModified: true, isComposing: true) == nil)
    #expect(LauncherKeyInterpreter.commandEquivalent(key: "k", commandModified: true, isComposing: false) == nil)
}

@Test @MainActor func launcherQuickViewKeepsPrimaryAndSecondaryActionsDistinct() throws {
    let primary = ActionDescriptor(
        id: "open",
        title: "Open",
        shortcut: KeyEquivalent(key: "return", modifiers: [.command])
    )
    let reveal = ActionDescriptor(id: "reveal", title: "Show in Finder")
    let item = LauncherItem(
        id: ItemID(providerID: "quick-view-test", providerStableID: "file"),
        providerID: "quick-view-test",
        title: "Quick View File",
        canonicalResource: .file(URL(fileURLWithPath: "/tmp/quick-view.txt")),
        actions: [primary, reveal],
        defaultActionID: primary.id
    )

    #expect(LauncherViewModel.primaryAction(for: item) == primary)
    #expect(LauncherViewModel.secondaryAction(for: item) == reveal)

    let primaryOnly = LauncherItem(
        id: ItemID(providerID: "quick-view-test", providerStableID: "primary-only"),
        providerID: "quick-view-test",
        title: "Primary Only",
        actions: [primary],
        defaultActionID: primary.id
    )
    #expect(LauncherViewModel.secondaryAction(for: primaryOnly) == nil)
}

@Test @MainActor func launcherKeepsLongActionSelectionVisible() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = LongActionListTestProvider()
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: [provider]),
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { model.visibleActions.count == 13 && !model.isSearching }
    model.openActions()

    let hosting = NSHostingView(rootView: LauncherView(model: model))
    hosting.frame = NSRect(
        x: 0,
        y: 0,
        width: LauncherPanelLayout.windowWidth,
        height: LauncherPanelLayout.windowHeight
    )
    let window = KeyestroTransientPanel(
        contentRect: hosting.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    defer { window.orderOut(nil) }
    window.contentView = hosting
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    hosting.displayIfNeeded()
    await Task.yield()

    #expect(model.layer == .actions)
    #expect(model.selectedActionIndex == 0)
    let scrollView = try #require(firstSubview(of: NSScrollView.self, in: hosting))
    let initialOrigin = scrollView.contentView.bounds.origin
    model.moveSelection(12)
    for _ in 0..<10 {
        await Task.yield()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
    }

    #expect(model.selectedActionIndex == 12)
    #expect(scrollView.contentView.bounds.origin != initialOrigin)
}

@Test @MainActor func launcherReopenKeepsPermissionDeniedResultViewportStable() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = PermissionDeniedLongResultTestProvider()
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: [provider]),
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    let controller = LauncherPanelController(viewModel: model, restoresPreviousApplication: false)
    defer { controller.dismiss(restoringFocus: false) }

    controller.show()
    try await waitUntil { controller.isVisible && model.results.count == 20 && !model.isSearching }
    let panel = try #require(
        NSApplication.shared.windows.first { $0.identifier == LauncherPanelController.panelWindowIdentifier }
    )
    let contentView = try #require(panel.contentView)
    try await waitUntil {
        panel.layoutIfNeeded()
        contentView.displayIfNeeded()
        return firstSubview(of: NSScrollView.self, in: contentView) != nil
    }
    let scrollView = try #require(firstSubview(of: NSScrollView.self, in: contentView))

    model.selectItem(model.results[15].id)
    for _ in 0..<10 {
        await Task.yield()
        panel.layoutIfNeeded()
        contentView.displayIfNeeded()
    }
    let selectedOrigin = scrollView.contentView.bounds.origin
    #expect(selectedOrigin.y > 120)
    scrollView.contentView.scroll(to: NSPoint(x: selectedOrigin.x, y: selectedOrigin.y - 120))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let originBeforeReopen = scrollView.contentView.bounds.origin

    let previousGeneration = model.generation
    controller.dismiss(restoringFocus: false)
    controller.show()
    try await waitUntil {
        controller.isVisible
            && model.generation > previousGeneration
            && model.results.count == 20
            && !model.isSearching
    }
    for _ in 0..<10 {
        await Task.yield()
        panel.layoutIfNeeded()
        contentView.displayIfNeeded()
    }

    let reopenedScrollView = try #require(firstSubview(of: NSScrollView.self, in: contentView))
    let reopenedOrigin = reopenedScrollView.contentView.bounds.origin
    #expect(abs(reopenedOrigin.x - originBeforeReopen.x) < 0.5)
    #expect(abs(reopenedOrigin.y - originBeforeReopen.y) < 0.5)
}

@Test @MainActor func launcherRetainedResultsStayDisabledUntilRefreshCompletes() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = RetainedResultRefreshTestProvider()
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: [provider]),
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )

    model.invoke(context: QueryContext())
    try await waitUntil { model.results.count == 1 && !model.isSearching }
    let retainedItemID = try #require(model.selectedItemID)
    #expect(model.canExecuteSelectedResult)

    let hosting = NSHostingView(rootView: LauncherView(model: model))
    hosting.frame = NSRect(
        x: 0,
        y: 0,
        width: LauncherPanelLayout.windowWidth,
        height: LauncherPanelLayout.windowHeight
    )
    let window = LauncherInteractionTestWindow(
        contentRect: hosting.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: 120, y: 120))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    await settleLauncherView(hosting, in: window)

    model.openActions()
    model.selectedActionIndex = 1
    await settleLauncherView(hosting, in: window)
    try await startHeldRefresh(model: model, provider: provider, retainedItemID: retainedItemID)

    model.executeSelectedAction()
    await expectRefreshExecutionBlocked(model: model, provider: provider)

    triggerLauncherActionListClick(at: 1, model: model)
    await settleLauncherView(hosting, in: window)
    await expectRefreshExecutionBlocked(model: model, provider: provider)

    model.closeActions()
    await settleLauncherView(hosting, in: window)

    try submitLauncherKeyboardCommand(in: hosting, window: window)
    await expectRefreshExecutionBlocked(model: model, provider: provider)

    triggerLauncherResultDoubleClick(itemID: retainedItemID, model: model)
    await settleLauncherView(hosting, in: window)
    await expectRefreshExecutionBlocked(model: model, provider: provider)

    triggerLauncherResultAccessibilityDefaultAction(itemID: retainedItemID, model: model)
    await expectRefreshExecutionBlocked(model: model, provider: provider)

    await provider.finishRefresh()
    try await waitUntil { !model.isSearching }

    model.openActions()
    model.selectedActionIndex = 2
    model.enterParameterForm()
    #expect(model.layer == .parameters)
    #expect(model.parameterForm?.actionID == "parameterized")

    try await startHeldRefresh(model: model, provider: provider, retainedItemID: retainedItemID)
    model.updateParameter(id: "value", value: "refresh-safe")
    model.submitParameters()
    await expectRefreshExecutionBlocked(model: model, provider: provider)
    #expect(model.layer == .parameters)
    #expect(model.parameterForm?.values["value"] == "refresh-safe")

    model.handleEscape()
    model.enterParameterForm()
    await expectRefreshExecutionBlocked(model: model, provider: provider)
    #expect(model.layer == .results)
    #expect(model.parameterForm == nil)

    await provider.finishRefresh()
    try await waitUntil { !model.isSearching }
    #expect(model.canExecuteSelectedResult)

    model.openActions()
    model.selectedActionIndex = 1
    model.executeSelectedAction()
    try await waitForExecutionCount(1, model: model, provider: provider)
    #expect(model.message == nil)

    await settleLauncherView(hosting, in: window)
    triggerLauncherActionListClick(at: 1, model: model)
    try await waitForExecutionCount(2, model: model, provider: provider)
    #expect(model.message == nil)

    model.selectedActionIndex = 2
    model.enterParameterForm()
    model.updateParameter(id: "value", value: "refresh-complete")
    model.submitParameters()
    try await waitForExecutionCount(3, model: model, provider: provider)
    #expect(model.message == nil)

    await settleLauncherView(hosting, in: window)
    try submitLauncherKeyboardCommand(in: hosting, window: window)
    try await waitForExecutionCount(4, model: model, provider: provider)
    #expect(model.message == nil)

    triggerLauncherResultDoubleClick(itemID: retainedItemID, model: model)
    try await waitForExecutionCount(5, model: model, provider: provider)
    #expect(model.message == nil)

    triggerLauncherResultAccessibilityDefaultAction(itemID: retainedItemID, model: model)
    try await waitForExecutionCount(6, model: model, provider: provider)
    #expect(model.message == nil)

    #expect(
        await provider.executedActionIDs == [
            "reveal",
            "reveal",
            "parameterized",
            "open",
            "open",
            "open",
        ]
    )
    #expect(await provider.lastParameterizedArguments["value"] == .text("refresh-complete"))
}

@Test @MainActor func launcherRefreshAppendsPartialResultsWithoutReorderingVisibleItems() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = RetainedResultRefreshTestProvider()
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: [provider]),
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )

    model.invoke(context: QueryContext())
    try await waitUntil { model.results.count == 1 && !model.isSearching }
    let retainedItemID = try #require(model.selectedItemID)

    try await startHeldRefresh(model: model, provider: provider, retainedItemID: retainedItemID)
    await provider.publishIntermediateRefresh()
    for _ in 0..<100 { await Task.yield() }

    #expect(model.results.map(\.id).first == retainedItemID)
    #expect(model.results.map(\.item.title) == ["Retained Result", "Intermediate Result"])

    await provider.finishRefresh()
    try await waitUntil { !model.isSearching }
    #expect(model.results.map(\.id) == [retainedItemID])
}

@Test @MainActor func tabEntersTheSelectedActionsParameterFormWithoutExecuting() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = ParameterTestProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { !model.results.isEmpty && !model.isSearching }

    model.enterParameterForm()

    #expect(model.layer == .parameters)
    #expect(model.parameterForm?.definitions.map(\.id) == ["query", "scope"])
    #expect(model.parameterForm?.values["scope"] == "All")
    #expect(await provider.executionCount == 0)
}

@Test @MainActor func executingActionIsVisibleAndEscapeCancelsTheProviderTask() async throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let provider = CancellableActionTestProvider()
    let coordinator = QueryCoordinator(providers: [provider])
    let model = LauncherViewModel(
        coordinator: coordinator,
        actionRunner: ActionRunner(providers: [provider]),
        settings: SettingsStore(defaults: defaults)
    )
    model.invoke(context: QueryContext())
    try await waitUntil { !model.results.isEmpty && !model.isSearching }

    model.executeDefault()
    for _ in 0..<1_000 {
        if model.isExecuting, await provider.executionStarted { break }
        await Task.yield()
    }
    #expect(model.isExecuting)
    #expect(await provider.executionStarted)
    model.handleEscape()
    for _ in 0..<1_000 {
        if await provider.executionCancelled { break }
        await Task.yield()
    }

    #expect(!model.isExecuting)
    #expect(model.message == L10n.text("Cancelled"))
    #expect(await provider.executionCount == 1)
    #expect(await provider.executionCancelled)
}

@Test @MainActor func settingsExposeEveryRequiredTopLevelSection() {
    #expect(
        SettingsSection.allCases.map(\.rawValue) == [
            "General", "Shortcuts", "Features", "Extensions", "Permissions", "Privacy", "Updates", "Advanced",
            "About",
        ]
    )
    #expect(SettingsSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
}

@Test func aboutVersionLabelUsesThePackagedMarketingVersionAndBuildNumber() {
    let label = AboutVersionLabel.text(
        marketingVersion: "1.2.3",
        buildNumber: "456",
        localizedFormat: "Keyestro %@ (%@)"
    )
    #expect(label.contains("1.2.3"))
    #expect(label.contains("456"))
    #expect(!label.contains("0.1.0"))
}

@Test @MainActor func firstRunOnboardingIsBoundedSkippableAndPersisted() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let settings = SettingsStore(defaults: defaults)
    var completionCount = 0
    let controller = OnboardingWindowController(settings: settings) { completionCount += 1 }

    #expect(!settings.onboardingCompleted)
    #expect(OnboardingStep.allCases.count == 3)
    #expect(OnboardingStep.allCases.count <= 4)
    controller.show()
    #expect(controller.window?.isVisible == true)
    controller.complete()
    controller.complete()

    #expect(settings.onboardingCompleted)
    #expect(completionCount == 1)
    #expect(controller.window?.isVisible == false)
    #expect(SettingsStore(defaults: defaults).onboardingCompleted)
}

@Test @MainActor func onboardingRendersEveryStepAndPersistenceErrorAsComponentStories() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    persistence.failingKey = "search.prefixesEnabled"
    settings.prefixesEnabled = false
    #expect(settings.persistenceError != nil)

    var hosts: [NSView] = []
    for (index, step) in OnboardingStep.allCases.enumerated() {
        #expect(!step.title.isEmpty)
        #expect(!step.symbol.isEmpty)
        let view = OnboardingView(settings: settings, onFinish: {}, initialStepIndex: index)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 440)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(try #require(bitmap.representation(using: .png, properties: [:])).count > 1_000)
        hosts.append(host)
    }

    let archive = try NSKeyedArchiver.archivedData(withRootObject: "onboarding", requiringSecureCoding: false)
    let coder = try NSKeyedUnarchiver(forReadingFrom: archive)
    #expect(OnboardingWindowController(coder: coder) == nil)
    coder.finishDecoding()
    OnboardingComponentHostRetainer.retain(hosts)
}

@MainActor
private enum OnboardingComponentHostRetainer {
    // SwiftUI can finish AttributeGraph work after the synchronous bitmap pass.
    // Keep off-screen hosts alive through process exit so adjacent component
    // stories cannot race their graph teardown.
    private static var retainedHosts: [NSView] = []

    static func retain(_ hosts: [NSView]) {
        retainedHosts.append(contentsOf: hosts)
    }
}

@Test func visualAccessibilityPolicyHonorsSystemAdaptations() {
    let ordinary = LauncherVisualAccessibilityPolicy(
        reduceMotion: false,
        reduceTransparency: false,
        differentiateWithoutColor: false,
        increaseContrast: false
    )
    let adapted = LauncherVisualAccessibilityPolicy(
        reduceMotion: true,
        reduceTransparency: true,
        differentiateWithoutColor: true,
        increaseContrast: true
    )

    #expect(!ordinary.usesStrongSelectionOutline)
    #expect(adapted.usesStrongSelectionOutline)
    #expect(adapted.selectionOpacity > ordinary.selectionOpacity)
}

@Test @MainActor func launcherAppearanceDefaultsToSystemAndPersistsManualOverrides() throws {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)

    #expect(settings.launcherAppearance == .automatic)
    #expect(settings.launcherAppearance.preferredColorScheme == nil)

    settings.launcherAppearance = .dark
    #expect(SettingsStore(persistence: persistence).launcherAppearance == .dark)
    #expect(settings.launcherAppearance.preferredColorScheme == .dark)

    persistence.failingKey = "appearance.launcher"
    settings.launcherAppearance = .light
    #expect(settings.launcherAppearance == .dark)

    persistence.failingKey = nil
    try settings.restoreDefaults()
    #expect(settings.launcherAppearance == .automatic)
}

@Test @MainActor func failedSettingWriteRestoresTheLastValidValueAndSurfacesAnError() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    #expect(settings.prefixesEnabled)

    persistence.failingKey = "search.prefixesEnabled"
    settings.prefixesEnabled = false

    #expect(settings.prefixesEnabled)
    #expect(settings.persistenceError == "The setting could not be saved. The previous value was restored.")
    #expect(persistence.object(forKey: "search.prefixesEnabled") == nil)

    persistence.failingKey = nil
    settings.prefixesEnabled = false
    #expect(!settings.prefixesEnabled)
    #expect(settings.persistenceError == nil)
    #expect(persistence.object(forKey: "search.prefixesEnabled") as? Bool == false)
}

@Test @MainActor func rankingLearningPreferenceAppliesImmediatelyAndRollsBackOnWriteFailure() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    #expect(settings.rankingLearningEnabled)
    #expect(settings.rankingLearningPreferences.isEnabled())

    settings.rankingLearningEnabled = false
    #expect(!settings.rankingLearningPreferences.isEnabled())
    #expect(SettingsStore(persistence: persistence).rankingLearningEnabled == false)

    persistence.failingKey = "ranking.learningEnabled"
    settings.rankingLearningEnabled = true
    #expect(settings.rankingLearningEnabled == false)
    #expect(!settings.rankingLearningPreferences.isEnabled())
}

@Test @MainActor func rapidFileSearchSettingChangesConvergeOnTheLatestCompleteSnapshot() async {
    let settings = SettingsStore(persistence: FaultingSettingsPersistence())
    settings.fileContentSearchEnabled = true
    settings.fileHiddenFilesEnabled = true
    settings.fileSystemLocationsEnabled = true
    settings.fileTrashEnabled = true
    settings.fileContentSearchEnabled = false
    settings.fileSystemLocationsEnabled = false

    var options = await settings.fileSearchPreferences.options()
    for _ in 0..<1_000 {
        options = await settings.fileSearchPreferences.options()
        if options
            == SpotlightSearchOptions(
                searchContents: false,
                includeHiddenFiles: true,
                includeSystemLocations: false,
                includeTrash: true
            )
        {
            break
        }
        await Task.yield()
    }
    #expect(
        options
            == SpotlightSearchOptions(
                searchContents: false,
                includeHiddenFiles: true,
                includeSystemLocations: false,
                includeTrash: true
            )
    )
}

@Test @MainActor func importedSettingsRollbackAllEarlierChangesWhenOneWriteFails() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    persistence.failingKey = "ranking.learningEnabled"

    #expect(throws: SettingsImportError.persistenceFailed) {
        try settings.applyImportedConfiguration([
            "search.prefixesEnabled": .bool(false),
            "ranking.learningEnabled": .bool(false),
        ])
    }

    #expect(settings.prefixesEnabled)
    #expect(settings.rankingLearningEnabled)
    #expect(settings.rankingLearningPreferences.isEnabled())
    #expect(persistence.object(forKey: "search.prefixesEnabled") as? Bool == true)
}

@Test @MainActor func restoringDefaultsIsCompensatingAndNeverLeavesAPartialReset() throws {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    settings.prefixesEnabled = false
    settings.rankingLearningEnabled = false
    settings.clipboardEnabled = true

    persistence.failingKey = "ranking.learningEnabled"
    #expect(throws: SettingsImportError.persistenceFailed) { try settings.restoreDefaults() }
    #expect(!settings.prefixesEnabled)
    #expect(!settings.rankingLearningEnabled)
    #expect(settings.clipboardEnabled)

    persistence.failingKey = nil
    try settings.restoreDefaults()
    #expect(settings.prefixesEnabled)
    #expect(settings.rankingLearningEnabled)
    #expect(!settings.clipboardEnabled)
    #expect(settings.launcherShortcut == .optionSpace)
    #expect(settings.quickPasteShortcut == nil)
    #expect(!settings.quickPasteEnabled)
    #expect(settings.quickPasteAllowsSensitiveContent)
    #expect(settings.launcherAppearance == .automatic)
}

@Test @MainActor func shortcutPersistenceUsesOneValidatedValueAndRollsBackAtomically() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    let prior = settings.launcherShortcut
    let replacement = HotKeyShortcut(keyCode: 0, modifiers: UInt32(cmdKey | shiftKey))

    persistence.failingKey = "shortcuts.launcher.combined"
    settings.launcherShortcut = replacement
    #expect(settings.launcherShortcut == prior)

    persistence.failingKey = nil
    settings.launcherShortcut = replacement
    #expect(SettingsStore(persistence: persistence).launcherShortcut == replacement)
}

@Test @MainActor func clipboardShortcutDefaultsPersistsAndRejectsInternalDuplicates() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    #expect(settings.launcherShortcut == .optionSpace)
    #expect(settings.clipboardHistoryShortcut == .optionShiftV)

    let originalClipboardShortcut = settings.clipboardHistoryShortcut
    settings.clipboardHistoryShortcut = settings.launcherShortcut
    #expect(settings.clipboardHistoryShortcut == originalClipboardShortcut)
    #expect(settings.shortcutValidationError == "Keyestro shortcuts must be different.")

    let replacement = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey))
    persistence.failingKey = "shortcuts.clipboardHistory.combined"
    settings.clipboardHistoryShortcut = replacement
    #expect(settings.clipboardHistoryShortcut == originalClipboardShortcut)

    persistence.failingKey = nil
    settings.clipboardHistoryShortcut = replacement
    #expect(SettingsStore(persistence: persistence).clipboardHistoryShortcut == replacement)
}

@Test @MainActor func quickPasteRequiresAnExplicitUniqueShortcutAndPersistsItsPrivacyMode() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    #expect(settings.quickPasteShortcut == nil)
    #expect(!settings.quickPasteEnabled)
    #expect(settings.quickPasteAllowsSensitiveContent)

    settings.quickPasteShortcut = settings.launcherShortcut
    #expect(settings.quickPasteShortcut == nil)
    #expect(settings.shortcutValidationError == "Keyestro shortcuts must be different.")

    let shortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey)
    )
    settings.quickPasteShortcut = shortcut
    settings.quickPasteEnabled = true
    settings.quickPasteAllowsSensitiveContent = false
    let reloaded = SettingsStore(persistence: persistence)
    #expect(reloaded.quickPasteShortcut == shortcut)
    #expect(reloaded.quickPasteEnabled)
    #expect(!reloaded.quickPasteAllowsSensitiveContent)

    let priorLauncher = settings.launcherShortcut
    settings.launcherShortcut = shortcut
    #expect(settings.launcherShortcut == priorLauncher)

    #expect(throws: SettingsImportError.persistenceFailed) {
        try settings.applyImportedConfiguration([
            "shortcuts.quickPaste.combined": .string(
                "\(settings.clipboardHistoryShortcut.keyCode):\(settings.clipboardHistoryShortcut.modifiers)"
            )
        ])
    }
    #expect(settings.quickPasteShortcut == shortcut)
}

@Test @MainActor func quickPasteConfigurationRoundTripsThroughExportPreviewAndImport() async throws {
    let source = SettingsStore(persistence: FaultingSettingsPersistence())
    let shortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey)
    )
    source.quickPasteShortcut = shortcut
    source.quickPasteEnabled = true
    source.quickPasteAllowsSensitiveContent = false

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ConfigurationService(
        quicklinks: InMemoryQuicklinkStore(),
        scripts: InMemoryScriptStore(),
        extensions: InMemoryExtensionStore(),
        paths: try AppPaths(
            bundleIdentifier: "com.keyestro.quick-paste-round-trip-tests",
            applicationSupportRoot: root.appendingPathComponent("Support"),
            cachesRoot: root.appendingPathComponent("Caches")
        ),
        appVersion: "1.0.0"
    )
    let exported = source.exportedConfiguration()
    let data = try await service.export(settings: exported)
    let validated = try await service.inspectImport(data)
    #expect(validated.preview.settingsCount == exported.count)
    #expect(validated.preview.ignoredSettingsCount == 0)

    let imported = SettingsStore(persistence: FaultingSettingsPersistence())
    try imported.applyImportedConfiguration(validated.document.payload.settings)
    #expect(imported.quickPasteShortcut == shortcut)
    #expect(imported.quickPasteEnabled)
    #expect(!imported.quickPasteAllowsSensitiveContent)
}

@Test func simplifiedChineseShortcutConflictCoversAllConfiguredShortcuts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let catalogURL =
        repositoryRoot
        .appendingPathComponent("Sources/KeyestroApp/Resources/Localizable.xcstrings")
    let catalogData = try Data(contentsOf: catalogURL)
    let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings["Keyestro shortcuts must be different."] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let simplifiedChinese = try #require(localizations["zh-Hans"] as? [String: Any])
    let stringUnit = try #require(simplifiedChinese["stringUnit"] as? [String: Any])

    #expect(stringUnit["value"] as? String == "Keyestro 的快捷键必须互不相同。")
}

@Test @MainActor func importedDuplicateShortcutsAreRejectedWithoutPartialMutation() {
    let persistence = FaultingSettingsPersistence()
    let settings = SettingsStore(persistence: persistence)
    let originalLauncher = settings.launcherShortcut
    let originalClipboard = settings.clipboardHistoryShortcut

    #expect(throws: SettingsImportError.persistenceFailed) {
        try settings.applyImportedConfiguration([
            "shortcuts.launcher.keyCode": .integer(Int64(originalLauncher.keyCode)),
            "shortcuts.launcher.modifiers": .integer(Int64(originalLauncher.modifiers)),
            "shortcuts.clipboardHistory.keyCode": .integer(Int64(originalLauncher.keyCode)),
            "shortcuts.clipboardHistory.modifiers": .integer(Int64(originalLauncher.modifiers)),
        ])
    }
    #expect(settings.launcherShortcut == originalLauncher)
    #expect(settings.clipboardHistoryShortcut == originalClipboard)
}

@Test @MainActor func hotKeyConflictKeepsTheConfiguredShortcutAndSurfacesRecoveryStatus() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let settings = SettingsStore(defaults: defaults)
    let configuredShortcut = settings.launcherShortcut
    let backend = FaultingHotKeyRegistrationBackend(status: OSStatus(eventHotKeyExistsErr))
    let service = HotKeyService(backend: backend)
    var presentation: HotKeyStatusPresentation?
    service.onStateChange = { action, state in
        let value = HotKeyStatusPresentation(action: action, state: state, shortcut: settings.launcherShortcut)
        settings.setHotKeyRegistrationError(value.errorMessage, for: action)
        presentation = value
    }

    service.register(configuredShortcut, for: .launcher)

    #expect(settings.launcherShortcut == configuredShortcut)
    #expect(settings.hotKeyRegistrationError == presentation?.errorMessage)
    #expect(presentation?.errorMessage != nil)
    #expect(presentation?.menuTitle.isEmpty == false)
    #expect(backend.registeredShortcuts == [.launcher: configuredShortcut])
}

@Test @MainActor func hotKeyServiceRoutesThreeUniqueActionsThroughOneBackend() {
    let backend = FaultingHotKeyRegistrationBackend(status: noErr)
    let service = HotKeyService(backend: backend)
    var invocations: [HotKeyAction] = []
    service.onInvocation = { invocations.append($0) }

    service.register(.optionSpace, for: .launcher)
    service.register(.optionShiftV, for: .clipboardHistory)
    let quickPasteShortcut = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey)
    )
    service.register(quickPasteShortcut, for: .quickPaste)
    backend.invoke(.quickPaste)
    backend.invoke(.clipboardHistory)
    backend.invoke(.launcher)

    #expect(
        backend.registeredShortcuts == [
            .launcher: .optionSpace,
            .clipboardHistory: .optionShiftV,
            .quickPaste: quickPasteShortcut,
        ]
    )
    #expect(invocations == [.quickPaste, .clipboardHistory, .launcher])
}

@Test @MainActor
func launcherRendersEveryResultLayerAndRecoveryStateAsAComponentStory() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let suiteName = "com.keyestro.launcher-component-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let primary = LauncherComponentStoryProvider.primary()
    let system = LauncherComponentStoryProvider.builtIn(providerID: "system", title: "Sleep")
    let files = LauncherComponentStoryProvider.builtIn(
        providerID: "files",
        title: "Component Story File",
        subtitle: "Content match · /tmp/component-story.txt"
    )
    let capture = LauncherComponentStoryProvider.builtIn(
        providerID: "builtin.capture",
        title: "Capture Screenshot"
    )
    let providers: [any LauncherProvider] = [primary, system, files, capture]
    let settings = SettingsStore(defaults: defaults)
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: providers),
        actionRunner: ActionRunner(providers: providers),
        settings: settings
    )
    let renderer = LauncherComponentStoryRenderer(model: model)
    defer { renderer.retainUntilProcessExit() }
    defer { model.didDismiss() }

    var dismissalCount = 0
    model.onDismiss = { dismissalCount += 1 }
    model.invoke(context: QueryContext(frontmostApplicationName: "Component Story App"))
    try await waitUntil { model.results.count >= 10 && !model.isSearching }
    try await renderer.render()

    for appearance in [LauncherAppearancePreference.light, .dark] {
        settings.launcherAppearance = appearance
        try await waitUntil { model.launcherAppearance == appearance }
        try await renderer.render()
    }
    settings.launcherAppearance = .automatic

    for query in ["/alpha", ">alpha", "=alpha", "@alpha"] {
        model.queryDidChange(query, isComposing: false)
        try await waitUntil { !model.results.isEmpty && !model.isSearching }
        try await renderer.render()
    }

    await primary.holdNextSearch()
    model.queryDidChange("alpha", isComposing: false)
    try await waitUntil { model.isSearching }
    try await renderer.render()
    await primary.releaseSearch()
    try await waitUntil { !model.isSearching }

    for itemID in await primary.iconStoryItemIDs() {
        model.selectItem(itemID)
        try await renderer.render()
    }
    let sensitiveID = await primary.sensitiveItemID()
    model.selectItem(sensitiveID)
    try await renderer.render()
    model.toggleSensitivePreview(sensitiveID)
    try await renderer.render()
    model.selectItem(await primary.secretItemID())
    try await renderer.render()

    let primaryID = await primary.primaryItemID()
    model.selectItem(primaryID)
    model.openActions()
    model.moveSelection(1)
    try await renderer.render()

    let parameterIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "parameters" })
    model.selectedActionIndex = parameterIndex
    model.enterParameterForm()
    try await renderer.render()
    model.submitParameters()
    try await renderer.render()
    for (id, value) in [
        ("text", "component story"),
        ("password", "synthetic-placeholder"),
        ("choice", "Second"),
        ("file", "/tmp/component-story.txt"),
        ("directory", "/tmp"),
    ] {
        model.updateParameter(id: id, value: value)
    }
    model.submitParameters()
    try await waitUntil { !model.isExecuting && model.layer == .results }
    try await renderer.render()

    model.selectItem(primaryID)
    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "external" })
    model.executeSelectedAction()
    try await waitUntil { model.pendingConfirmation != nil && !model.isExecuting }
    try await renderer.render()
    model.cancelPendingAction()

    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "destructive" })
    model.executeSelectedAction()
    try await waitUntil { model.pendingConfirmation != nil }
    try await renderer.render()
    model.confirmPendingAction()
    try await waitUntil { model.pendingConfirmation == nil && !model.isExecuting }
    try await renderer.render()

    await primary.holdNextExecution()
    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "gated" })
    model.executeSelectedAction()
    try await waitUntil { model.isExecuting }
    for _ in 0..<2_000 {
        if await primary.executionIsWaiting() { break }
        await Task.yield()
    }
    #expect(await primary.executionIsWaiting())
    try await renderer.render()
    await primary.releaseExecution(
        with: .failure(
            ErrorDescriptor(
                code: "component.story.failure",
                message: "Component story execution failed.",
                recoverySuggestion: "Retry the component story."
            )
        )
    )
    try await waitUntil { !model.isExecuting && model.messageDetail != nil }
    try await renderer.render()

    model.selectItem(primaryID)
    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "cancelled" })
    model.executeSelectedAction()
    try await waitUntil { !model.isExecuting && model.message != nil }
    try await renderer.render()

    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "replace" })
    model.executeSelectedAction()
    try await waitUntil { model.query == "alpha replacement" && !model.isSearching }
    try await renderer.render()

    model.queryDidChange("", isComposing: false)
    try await waitUntil { model.results.contains(where: { $0.id == primaryID }) && !model.isSearching }
    model.selectItem(primaryID)
    model.openActions()
    model.selectedActionIndex = try #require(model.visibleActions.firstIndex { $0.id.rawValue == "close" })
    model.executeSelectedAction()
    try await waitUntil { dismissalCount == 1 && !model.isExecuting }

    for query in ["permission", "unavailable", "failed", "empty"] {
        model.queryDidChange(query, isComposing: false)
        try await waitUntil { model.results.isEmpty && !model.isSearching }
        try await renderer.render()
    }
}

@Test @MainActor
func launcherRendersTheLocalLensReferenceStateWithoutThemeLayoutShift() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let suiteName = "com.keyestro.local-lens-reference-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let providers: [any LauncherProvider] = LocalLensReferenceProvider.makeProviders()
    let filesProvider = try #require(
        providers.compactMap { $0 as? LocalLensReferenceProvider }
            .first { $0.descriptor.id == "files" }
    )
    let settings = SettingsStore(defaults: defaults)
    let model = LauncherViewModel(
        coordinator: QueryCoordinator(providers: providers),
        actionRunner: ActionRunner(providers: providers),
        settings: settings
    )
    let renderer = LauncherComponentStoryRenderer(model: model)
    defer { renderer.retainUntilProcessExit() }
    defer { model.didDismiss() }

    model.invoke(context: QueryContext(frontmostApplicationName: "Figma"))
    model.queryDidChange("design spec", isComposing: false)
    try await waitUntil { model.results.count == 4 && !model.isSearching }
    let selectedFileID = try #require(
        model.displayOrderedResults.first { $0.item.title == "Product design brief.md" }?.id
    )
    model.selectItem(selectedFileID)

    let outputDirectory = ProcessInfo.processInfo.environment["KEYESTRO_LAUNCHER_QA_OUTPUT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    for appearance in [LauncherAppearancePreference.light, .dark] {
        settings.launcherAppearance = appearance
        try await waitUntil { model.launcherAppearance == appearance }
        let outputURL = outputDirectory?.appendingPathComponent("implementation-\(appearance.rawValue).png")
        try await renderer.render(to: outputURL, focusesSearchField: false)
    }

    #expect(model.query == "design spec")
    let displayedTitles = model.displayOrderedResults.map(\.item.title)
    #expect(
        Set(displayedTitles)
            == Set([
                "Figma",
                "Product design brief.md",
                "Keyestro roadmap.pdf",
                "“Local-first command launcher…”",
            ])
    )
    let briefIndex = try #require(displayedTitles.firstIndex(of: "Product design brief.md"))
    let roadmapIndex = try #require(displayedTitles.firstIndex(of: "Keyestro roadmap.pdf"))
    #expect(briefIndex < roadmapIndex)
    #expect(model.selectedItem?.title == "Product design brief.md")

    #expect(model.selectedPrimaryAction?.id == "open")
    #expect(model.selectedSecondaryAction?.id == "show-in-finder")
    model.executeDefault()
    for _ in 0..<1_000 {
        if !model.isExecuting, await filesProvider.lastExecutedActionID() == "open" { break }
        await Task.yield()
    }
    #expect(!model.isExecuting)
    #expect(await filesProvider.lastExecutedActionID() == "open")

    model.executeAction(try #require(model.selectedSecondaryAction).id)
    for _ in 0..<1_000 {
        if await filesProvider.lastExecutedActionID() == "show-in-finder" { break }
        await Task.yield()
    }
    #expect(await filesProvider.lastExecutedActionID() == "show-in-finder")
}

private let defaultsSuiteName = "com.keyestro.app-tests"

@MainActor
private func isolatedDefaults() throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    return defaults
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    throw AppTestError.conditionTimedOut
}

private enum AppTestError: Error {
    case conditionTimedOut
}

@MainActor
private final class FaultingSettingsPersistence: SettingsPersisting {
    enum Failure: Error { case rejected }

    var failingKey: String?
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Bool, forKey key: String) throws {
        try check(key)
        values[key] = value
    }

    func set(_ value: String, forKey key: String) throws {
        try check(key)
        values[key] = value
    }

    private func check(_ key: String) throws {
        if failingKey == key { throw Failure.rejected }
    }
}

@MainActor
private final class FaultingHotKeyRegistrationBackend: HotKeyRegistrationBackend {
    var onInvocation: ((HotKeyAction) -> Void)?
    private let status: OSStatus
    private(set) var registeredShortcuts: [HotKeyAction: HotKeyShortcut] = [:]

    init(status: OSStatus) {
        self.status = status
    }

    func register(_ shortcut: HotKeyShortcut, for action: HotKeyAction) -> OSStatus {
        registeredShortcuts[action] = shortcut
        return status
    }

    func invoke(_ action: HotKeyAction) {
        onInvocation?(action)
    }

    func suspend() {}
    func stop() {}
}

@MainActor
private func accessibilityLabels(in element: Any) -> [String] {
    var labels: [String] = []
    if let accessible = element as? NSAccessibilityElement {
        if let label = accessible.accessibilityLabel(), !label.isEmpty { labels.append(label) }
        for child in accessible.accessibilityChildren() ?? [] {
            labels.append(contentsOf: accessibilityLabels(in: child))
        }
    }
    if let view = element as? NSView {
        if let label = view.accessibilityLabel(), !label.isEmpty { labels.append(label) }
        for child in view.accessibilityChildren() ?? [] {
            labels.append(contentsOf: accessibilityLabels(in: child))
        }
        for child in view.subviews {
            labels.append(contentsOf: accessibilityLabels(in: child))
        }
    }
    return labels
}

@MainActor
private func firstSubview<View: NSView>(of type: View.Type, in root: NSView?) -> View? {
    guard let root else { return nil }
    if let match = root as? View { return match }
    return root.subviews.lazy.compactMap { firstSubview(of: type, in: $0) }.first
}

@MainActor
private final class LauncherInteractionTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private func settleLauncherView(_ hosting: NSHostingView<LauncherView>, in window: NSWindow) async {
    for _ in 0..<10 {
        await Task.yield()
        window.layoutIfNeeded()
        hosting.displayIfNeeded()
    }
}

@MainActor
private func startHeldRefresh(
    model: LauncherViewModel,
    provider: RetainedResultRefreshTestProvider,
    retainedItemID: ItemID
) async throws {
    model.retrySearch()
    for _ in 0..<1_000 {
        if model.isSearching,
            await provider.refreshIsPending()
        {
            #expect(model.results.map(\.id) == [retainedItemID])
            #expect(!model.canExecuteSelectedResult)
            return
        }
        await Task.yield()
    }
    throw AppTestError.conditionTimedOut
}

@MainActor
private func expectRefreshExecutionBlocked(
    model: LauncherViewModel,
    provider: RetainedResultRefreshTestProvider
) async {
    for _ in 0..<20 { await Task.yield() }
    #expect(await provider.executionCount == 0)
    #expect(!model.isExecuting)
    #expect(model.message == nil)
}

@MainActor
private func waitForExecutionCount(
    _ expectedCount: Int,
    model: LauncherViewModel,
    provider: RetainedResultRefreshTestProvider
) async throws {
    for _ in 0..<1_000 {
        if await provider.executionCount == expectedCount, !model.isExecuting { return }
        await Task.yield()
    }
    throw AppTestError.conditionTimedOut
}

@MainActor
private func submitLauncherKeyboardCommand(
    in hosting: NSHostingView<LauncherView>,
    window: NSWindow
) throws {
    let field = try #require(firstSubview(of: CommandTextField.self, in: hosting))
    #expect(window.makeFirstResponder(field))
    field.prepareFieldEditor()
    let editor = try #require(field.currentEditor() as? NSTextView)
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )
    )
    editor.keyDown(with: event)
}

@MainActor
private func triggerLauncherActionListClick(at index: Int, model: LauncherViewModel) {
    // Matches LauncherView.actionList's tap callback.
    model.selectedActionIndex = index
    model.executeSelectedAction()
}

@MainActor
private func triggerLauncherResultDoubleClick(itemID: ItemID, model: LauncherViewModel) {
    // Matches LauncherView.resultRow's double-click callback.
    model.selectItem(itemID)
    model.executeDefault()
}

@MainActor
private func triggerLauncherResultAccessibilityDefaultAction(itemID: ItemID, model: LauncherViewModel) {
    // Matches LauncherView.resultRow's accessibility default-action callback.
    model.selectItem(itemID)
    model.executeDefault()
}

private actor AppTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "app-ui-test",
        displayName: "App UI Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    private let streamReplacement: Bool
    private var continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation?

    init(streamReplacement: Bool = false) {
        self.streamReplacement = streamReplacement
    }

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream()
        Task { await start(continuation) }
        return stream
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }

    func publishReplacementKeepingSecondItem() {
        guard streamReplacement else { return }
        continuation?.yield(
            .replacement(
                [Self.item(id: "one", title: "Updated Application"), Self.item(id: "two", title: "Beta Application")],
                isFinal: true
            )
        )
        continuation?.finish()
    }

    private func start(_ continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation) {
        self.continuation = continuation
        continuation.yield(
            .replacement(
                [Self.item(id: "one", title: "Alpha Application"), Self.item(id: "two", title: "Beta Application")],
                isFinal: !streamReplacement
            )
        )
        if !streamReplacement { continuation.finish() }
    }

    nonisolated private static func item(id: String, title: String) -> LauncherItem {
        let action = ActionDescriptor(id: "open", title: "Open")
        return LauncherItem(
            id: ItemID(providerID: "app-ui-test", providerStableID: id),
            providerID: "app-ui-test",
            title: title,
            actions: [action],
            defaultActionID: action.id
        )
    }
}

private actor LongActionListTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "long-action-list-test",
        displayName: "Long Action List Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let actions = (0..<13).map { index in
            ActionDescriptor(id: ActionID("action-\(index)"), title: "Action \(index + 1)")
        }
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "item"),
            providerID: descriptor.id,
            title: "Long Action List",
            actions: actions,
            defaultActionID: actions[0].id
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }
}

private actor PermissionDeniedLongResultTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "permission-denied-long-result-test",
        displayName: "Permission Denied Long Result Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let items = (0..<20).map { index in
            let action = ActionDescriptor(id: ActionID("open-\(index)"), title: "Open")
            return LauncherItem(
                id: ItemID(providerID: descriptor.id, providerStableID: "item-\(index)"),
                providerID: descriptor.id,
                title: "Permission Result \(index + 1)",
                actions: [action],
                defaultActionID: action.id
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .status(
                    .permissionDenied(
                        ErrorDescriptor(
                            code: "accessibility.permissionDenied",
                            message: "Accessibility permission is required for window management."
                        )
                    )
                )
            )
            continuation.yield(.items(items, isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }
}

private actor RetainedResultRefreshTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "retained-result-refresh-test",
        displayName: "Retained Result Refresh Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )
    private var searchCount = 0
    private var refreshContinuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation?
    private(set) var executionCount = 0
    private(set) var executedActionIDs: [ActionID] = []
    private(set) var lastParameterizedArguments: [String: ArgumentValue] = [:]

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream()
        Task { await start(continuation) }
        return stream
    }

    func execute(request: ProviderActionRequest) -> ActionResult {
        executionCount += 1
        executedActionIDs.append(request.actionID)
        if request.actionID == "parameterized" {
            lastParameterizedArguments = request.arguments
        }
        return .success()
    }

    func refreshIsPending() -> Bool {
        refreshContinuation != nil
    }

    func finishRefresh() {
        refreshContinuation?.yield(.replacement([Self.item()], isFinal: true))
        refreshContinuation?.finish()
        refreshContinuation = nil
    }

    func publishIntermediateRefresh() {
        refreshContinuation?.yield(.items([Self.intermediateItem()], isFinal: false))
    }

    private func start(_ continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation) {
        searchCount += 1
        guard searchCount > 1 else {
            continuation.yield(.items([Self.item()], isFinal: true))
            continuation.finish()
            return
        }

        refreshContinuation = continuation
        continuation.yield(
            .status(
                .permissionDenied(
                    ErrorDescriptor(
                        code: "accessibility.permissionDenied",
                        message: "Accessibility permission is required for window management."
                    )
                )
            )
        )
    }

    nonisolated private static func item() -> LauncherItem {
        let primary = ActionDescriptor(id: "open", title: "Open", behavior: .keepLauncherOpen)
        let secondary = ActionDescriptor(id: "reveal", title: "Reveal", behavior: .keepLauncherOpen)
        let parameterized = ActionDescriptor(
            id: "parameterized",
            title: "Parameterized Action",
            behavior: .keepLauncherOpen,
            arguments: [
                ArgumentDefinition(id: "value", title: "Value", kind: .text, required: true)
            ]
        )
        return LauncherItem(
            id: ItemID(providerID: "retained-result-refresh-test", providerStableID: "retained"),
            providerID: "retained-result-refresh-test",
            title: "Retained Result",
            actions: [primary, secondary, parameterized],
            defaultActionID: primary.id
        )
    }

    nonisolated private static func intermediateItem() -> LauncherItem {
        let action = ActionDescriptor(id: "open", title: "Open", behavior: .keepLauncherOpen)
        return LauncherItem(
            id: ItemID(providerID: "retained-result-refresh-test", providerStableID: "intermediate"),
            providerID: "retained-result-refresh-test",
            title: "Intermediate Result",
            actions: [action],
            defaultActionID: action.id
        )
    }
}

private actor PermissionDeniedAppTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "permission-denied-ui-test",
        displayName: "Permission Denied UI Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .status(
                    .permissionDenied(
                        ErrorDescriptor(
                            code: "accessibility.permissionDenied",
                            message: "Accessibility permission is required for window management.",
                            recoverySuggestion: "Open Settings → Permissions to grant access, then refresh."
                        )
                    )
                )
            )
            continuation.yield(.items([], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }
}

private actor CancellableActionTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "cancellable-action-test",
        displayName: "Cancellable Action Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )
    private(set) var executionStarted = false
    private(set) var executionCancelled = false
    private(set) var executionCount = 0

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let action = ActionDescriptor(id: "run", title: "Run")
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "task"),
            providerID: descriptor.id,
            title: "Long Task",
            actions: [action],
            defaultActionID: action.id
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult {
        executionCount += 1
        executionStarted = true
        do {
            try await Task.sleep(for: .seconds(60))
            return .success()
        } catch is CancellationError {
            executionCancelled = true
            return .cancelled
        } catch {
            return .failure(ErrorDescriptor(code: "test.failure", message: "Unexpected test failure."))
        }
    }
}

private actor ConfirmationTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "confirmation-ui-test",
        displayName: "Confirmation UI Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )
    private var continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation?
    private(set) var executionCount = 0

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream()
        Task { await start(continuation) }
        return stream
    }

    func execute(request: ProviderActionRequest) -> ActionResult {
        executionCount += 1
        return .success()
    }

    func replaceTarget(title: String) {
        continuation?.yield(.replacement([Self.item(title: title)], isFinal: true))
    }

    private func start(_ continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation) {
        self.continuation = continuation
        continuation.yield(.replacement([Self.item(title: "Old Target")], isFinal: true))
    }

    nonisolated private static func item(title: String) -> LauncherItem {
        let action = ActionDescriptor(
            id: "erase",
            title: "Erase",
            behavior: .keepLauncherOpen,
            risk: .destructive,
            confirmationTarget: "Record \(title)"
        )
        return LauncherItem(
            id: ItemID(providerID: "confirmation-ui-test", providerStableID: "stable-target"),
            providerID: "confirmation-ui-test",
            title: title,
            actions: [action],
            defaultActionID: action.id,
            privacy: .sensitive
        )
    }
}

private actor ParameterTestProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "parameter-ui-test",
        displayName: "Parameter UI Test",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )
    private(set) var executionCount = 0

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let action = ActionDescriptor(
            id: "run",
            title: "Run",
            arguments: [
                ArgumentDefinition(id: "query", title: "Query", kind: .text, required: true),
                ArgumentDefinition(
                    id: "scope",
                    title: "Scope",
                    kind: .choice(options: ["All", "Current"]),
                    required: true
                ),
            ]
        )
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "parameterized"),
            providerID: descriptor.id,
            title: "Parameterized Action",
            actions: [action],
            defaultActionID: action.id
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult {
        executionCount += 1
        return .success()
    }
}

private actor LauncherComponentStoryProvider: LauncherProvider {
    nonisolated let descriptor: ProviderDescriptor
    private let items: [LauncherItem]
    private let isPrimary: Bool
    private let primaryID: ItemID
    private let sensitiveID: ItemID
    private let secretID: ItemID
    private let iconIDs: [ItemID]
    private var shouldHoldSearch = false
    private var searchContinuation: CheckedContinuation<Void, Never>?
    private var shouldHoldExecution = false
    private var executionContinuation: CheckedContinuation<ActionResult, Never>?

    private init(providerID: ProviderID, items: [LauncherItem], isPrimary: Bool) {
        descriptor = ProviderDescriptor(
            id: providerID,
            displayName: "Component Story \(providerID.rawValue)",
            supportedModes: Set(QueryMode.allCases),
            supportsEmptyQuery: true
        )
        self.items = items
        self.isPrimary = isPrimary
        primaryID = ItemID(providerID: providerID, providerStableID: "primary")
        sensitiveID = ItemID(providerID: providerID, providerStableID: "sensitive")
        secretID = ItemID(providerID: providerID, providerStableID: "secret")
        iconIDs = items.map(\.id)
    }

    nonisolated static func primary() -> LauncherComponentStoryProvider {
        let providerID: ProviderID = "component-story"
        let safe = ActionDescriptor(
            id: "safe",
            title: "Safe Component Action",
            icon: .systemSymbol("checkmark.circle"),
            behavior: .keepLauncherOpen
        )
        let parameters = ActionDescriptor(
            id: "parameters",
            title: "Parameterized Component Action",
            icon: .systemSymbol("list.bullet.rectangle"),
            behavior: .keepLauncherOpen,
            arguments: [
                ArgumentDefinition(id: "text", title: "Text", kind: .text, required: true, placeholder: "Text"),
                ArgumentDefinition(
                    id: "password",
                    title: "Password",
                    kind: .password,
                    required: false,
                    placeholder: "Password"
                ),
                ArgumentDefinition(
                    id: "choice",
                    title: "Choice",
                    kind: .choice(options: ["First", "Second"]),
                    required: true
                ),
                ArgumentDefinition(id: "file", title: "File", kind: .file, required: false),
                ArgumentDefinition(id: "directory", title: "Directory", kind: .directory, required: false),
            ]
        )
        let external = ActionDescriptor(
            id: "external",
            title: "External Component Action",
            icon: .application(URL(fileURLWithPath: "/Applications/ComponentStory.app")),
            behavior: .keepLauncherOpen,
            risk: .externalSideEffect,
            confirmationTarget: "Component Story Target"
        )
        let destructive = ActionDescriptor(
            id: "destructive",
            title: "Destructive Component Action",
            icon: .systemSymbol("trash"),
            behavior: .keepLauncherOpen,
            risk: .destructive,
            confirmationTarget: "Component Story Record"
        )
        let gated = ActionDescriptor(id: "gated", title: "Long Component Action", behavior: .keepLauncherOpen)
        let cancelled = ActionDescriptor(id: "cancelled", title: "Cancelled Component Action", behavior: .keepLauncherOpen)
        let replace = ActionDescriptor(id: "replace", title: "Replace Query", behavior: .replaceContent)
        let close = ActionDescriptor(id: "close", title: "Close Launcher", behavior: .closeLauncher)
        let actions = [safe, parameters, external, destructive, gated, cancelled, replace, close]
        let validPNG =
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ) ?? Data()
        let stories: [(String, String, IconReference?, ItemPrivacy)] = [
            ("primary", "Alpha Primary Component", .systemSymbol("command"), .normal),
            ("sensitive", "Alpha Sensitive Component", .systemSymbol("eye.slash"), .sensitive),
            (
                "secret",
                "Alpha Secret Component",
                .application(URL(fileURLWithPath: "/Applications/ComponentStory.app")),
                .secret
            ),
            ("file-icon", "Alpha File Icon", .file(URL(fileURLWithPath: "/tmp/component-story.txt")), .normal),
            ("thumbnail", "Alpha Thumbnail", .thumbnailPNG(validPNG), .normal),
            ("invalid-thumbnail", "Alpha Invalid Thumbnail", .thumbnailPNG(Data("invalid".utf8)), .normal),
            (
                "extension-asset",
                "Alpha Extension Asset",
                .extensionAsset(extensionID: "com.keyestro.component-story", path: "icon.png"),
                .normal
            ),
            ("no-icon", "Alpha No Icon", nil, .normal),
            ("ninth", "Alpha Ninth Result", .systemSymbol("9.circle"), .normal),
            ("tenth", "Alpha Tenth Result", .systemSymbol("10.circle"), .normal),
        ]
        let items = stories.map { id, title, icon, privacy in
            LauncherItem(
                id: ItemID(providerID: providerID, providerStableID: id),
                providerID: providerID,
                title: title,
                subtitle: "Component Story Subtitle",
                icon: icon,
                keywords: ["alpha", "replacement", "component"],
                actions: id == "primary" ? actions : [safe],
                defaultActionID: safe.id,
                privacy: privacy
            )
        }
        return LauncherComponentStoryProvider(providerID: providerID, items: items, isPrimary: true)
    }

    nonisolated static func builtIn(
        providerID: ProviderID,
        title: String,
        subtitle: String? = nil
    ) -> LauncherComponentStoryProvider {
        let action = ActionDescriptor(id: "open", title: "Open", behavior: .keepLauncherOpen)
        let item = LauncherItem(
            id: ItemID(providerID: providerID, providerStableID: "built-in"),
            providerID: providerID,
            title: title,
            subtitle: subtitle,
            icon: .systemSymbol("sparkles"),
            keywords: ["alpha", "replacement", "component"],
            actions: [action],
            defaultActionID: action.id
        )
        return LauncherComponentStoryProvider(providerID: providerID, items: [item], isPrimary: false)
    }

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task { await emitSearch(request: request, continuation: continuation) }
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult {
        switch request.actionID.rawValue {
        case "gated" where shouldHoldExecution:
            shouldHoldExecution = false
            return await withCheckedContinuation { executionContinuation = $0 }
        case "cancelled":
            return .cancelled
        case "replace":
            return .success(message: "alpha replacement")
        default:
            return .success(message: "Component story completed.")
        }
    }

    func holdNextSearch() { shouldHoldSearch = true }
    func releaseSearch() {
        searchContinuation?.resume()
        searchContinuation = nil
    }

    func holdNextExecution() { shouldHoldExecution = true }
    func executionIsWaiting() -> Bool { executionContinuation != nil }
    func releaseExecution(with result: ActionResult) {
        executionContinuation?.resume(returning: result)
        executionContinuation = nil
    }

    func primaryItemID() -> ItemID { primaryID }
    func sensitiveItemID() -> ItemID { sensitiveID }
    func secretItemID() -> ItemID { secretID }
    func iconStoryItemIDs() -> [ItemID] { iconIDs }

    private func emitSearch(
        request: QueryRequest,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) async {
        if shouldHoldSearch {
            shouldHoldSearch = false
            await withCheckedContinuation { searchContinuation = $0 }
        }
        switch request.normalizedText {
        case "permission":
            if isPrimary {
                continuation.yield(
                    .status(
                        .permissionDenied(
                            ErrorDescriptor(
                                code: "component.permission",
                                message: "Component story permission is required.",
                                recoverySuggestion: "Open permissions and retry."
                            )
                        )
                    )
                )
            }
            continuation.yield(.items([], isFinal: true))
        case "unavailable":
            if isPrimary {
                continuation.yield(
                    .status(
                        .unavailable(
                            ErrorDescriptor(
                                code: "component.unavailable",
                                message: "Component story is unavailable.",
                                recoverySuggestion: "Retry the component story."
                            )
                        )
                    )
                )
            }
            continuation.yield(.items([], isFinal: true))
        case "failed":
            if isPrimary {
                continuation.yield(
                    .status(
                        .failed(
                            ErrorDescriptor(
                                code: "component.failed",
                                message: "Component story failed.",
                                recoverySuggestion: "Review the component and retry."
                            )
                        )
                    )
                )
            }
            continuation.yield(.items([], isFinal: true))
        case "empty":
            continuation.yield(.items([], isFinal: true))
        default:
            continuation.yield(.items(items, isFinal: true))
        }
        continuation.finish()
    }
}

private actor LocalLensReferenceProvider: LauncherProvider {
    nonisolated let descriptor: ProviderDescriptor
    private let items: [LauncherItem]
    private var executedActionIDs: [ActionID] = []

    private init(id: ProviderID, items: [LauncherItem]) {
        descriptor = ProviderDescriptor(
            id: id,
            displayName: id.rawValue.capitalized,
            supportedModes: Set(QueryMode.allCases),
            supportsEmptyQuery: true
        )
        self.items = items
    }

    nonisolated static func makeProviders() -> [any LauncherProvider] {
        let openFile = ActionDescriptor(id: "open", title: "Open file")
        let quickLook = ActionDescriptor(
            id: "quick-look",
            title: "Quick Look",
            shortcut: KeyEquivalent(key: "y", modifiers: [.command]),
            behavior: .keepLauncherOpen
        )
        let showInFinder = ActionDescriptor(
            id: "show-in-finder",
            title: "Show in Finder",
            shortcut: KeyEquivalent(key: "return", modifiers: [.command]),
            behavior: .keepLauncherOpen
        )
        let openApplication = ActionDescriptor(id: "open", title: "Open")
        let paste = ActionDescriptor(id: "paste", title: "Paste")

        let filesID: ProviderID = "files"
        let applicationsID: ProviderID = "applications"
        let clipboardID: ProviderID = "clipboard"
        return [
            LocalLensReferenceProvider(
                id: filesID,
                items: [
                    LauncherItem(
                        id: ItemID(providerID: filesID, providerStableID: "product-design-brief"),
                        providerID: filesID,
                        title: "Product design brief.md",
                        subtitle: "Documents · edited 4 min ago",
                        icon: .systemSymbol("text.alignleft"),
                        canonicalResource: .file(URL(fileURLWithPath: "/Documents/Product design brief.md")),
                        keywords: ["design spec"],
                        accessories: [.badge("FILE"), .text("24 KB · local")],
                        actions: [openFile, quickLook, showInFinder],
                        defaultActionID: openFile.id,
                        scoreFeatures: ScoreFeatures(context: 1, providerPrior: 1)
                    ),
                    LauncherItem(
                        id: ItemID(providerID: filesID, providerStableID: "keyestro-roadmap"),
                        providerID: filesID,
                        title: "Keyestro roadmap.pdf",
                        subtitle: "Downloads · yesterday",
                        icon: .systemSymbol("text.alignleft"),
                        canonicalResource: .file(URL(fileURLWithPath: "/Downloads/Keyestro roadmap.pdf")),
                        keywords: ["design spec"],
                        actions: [openFile, quickLook, showInFinder],
                        defaultActionID: openFile.id,
                        scoreFeatures: ScoreFeatures(context: 0.9, providerPrior: 1)
                    ),
                ]
            ),
            LocalLensReferenceProvider(
                id: applicationsID,
                items: [
                    LauncherItem(
                        id: ItemID(providerID: applicationsID, providerStableID: "figma"),
                        providerID: applicationsID,
                        title: "Figma",
                        subtitle: "Application · currently open",
                        icon: .systemSymbol("f.square.fill"),
                        canonicalResource: .application(bundleIdentifier: "com.figma.Desktop"),
                        keywords: ["design spec"],
                        accessories: [.text("↩")],
                        actions: [openApplication],
                        defaultActionID: openApplication.id,
                        scoreFeatures: ScoreFeatures(context: 0.7, providerPrior: 0.7)
                    )
                ]
            ),
            LocalLensReferenceProvider(
                id: clipboardID,
                items: [
                    LauncherItem(
                        id: ItemID(providerID: clipboardID, providerStableID: "local-first-command-launcher"),
                        providerID: clipboardID,
                        title: "“Local-first command launcher…”",
                        subtitle: "Copied from Safari · 8 min ago",
                        icon: .systemSymbol("clipboard"),
                        keywords: ["design spec"],
                        actions: [paste],
                        defaultActionID: paste.id,
                        scoreFeatures: ScoreFeatures(context: 0.4, providerPrior: 0.4)
                    )
                ]
            ),
        ]
    }

    nonisolated func search(request _: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task { await emit(into: continuation) }
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult {
        executedActionIDs.append(request.actionID)
        return .success()
    }

    func lastExecutedActionID() -> ActionID? { executedActionIDs.last }

    private func emit(into continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation) {
        continuation.yield(.items(items, isFinal: true))
        continuation.finish()
    }
}

@MainActor
private final class LauncherComponentStoryRenderer {
    // SwiftUI computes AttributeGraph metadata on a utility queue; retain this
    // off-screen host for the lifetime of the test process to avoid teardown races.
    private static var retainedRenderers: [LauncherComponentStoryRenderer] = []

    private let hosting: NSHostingView<LauncherView>
    private let window: NSWindow
    private var isRetained = false

    init(model: LauncherViewModel) {
        hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: LauncherPanelLayout.windowWidth,
            height: LauncherPanelLayout.windowHeight
        )
        window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
    }

    func render(to outputURL: URL? = nil, focusesSearchField: Bool = true) async throws {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            await Task.yield()
        }
        if !focusesSearchField {
            window.makeFirstResponder(nil)
            hosting.displayIfNeeded()
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let renderedPNG = try #require(
            bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        )
        #expect(renderedPNG.count > 1_000)
        #expect(hosting.fittingSize.height <= hosting.bounds.height + 1)
        if let outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try renderedPNG.write(to: outputURL, options: .atomic)
        }
    }

    func retainUntilProcessExit() {
        window.orderOut(nil)
        guard !isRetained else { return }
        isRetained = true
        Self.retainedRenderers.append(self)
    }
}
