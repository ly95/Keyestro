import AppKit
import Carbon
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
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
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

@Test @MainActor func panelHeightGrowsWithResultsAndClampsToTheVisibleDisplay() {
    #expect(LauncherPanelController.preferredHeight(resultCount: 0) == 220)
    #expect(LauncherPanelController.preferredHeight(resultCount: 1) == 220)
    #expect(LauncherPanelController.preferredHeight(resultCount: 8) == 560)
    #expect(LauncherPanelController.preferredHeight(resultCount: 50) == 560)

    let smallDisplay = NSRect(x: -800, y: 20, width: 640, height: 400)
    let frame = LauncherPanelController.frame(in: smallDisplay, preferredHeight: 560)
    #expect(frame.size == smallDisplay.size)
    #expect(smallDisplay.contains(frame))
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
    #expect(LauncherKeyInterpreter.commandEquivalent(key: "k", commandModified: true, isComposing: true) == nil)
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

@Test @MainActor func hotKeyConflictKeepsTheConfiguredShortcutAndSurfacesRecoveryStatus() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let settings = SettingsStore(defaults: defaults)
    let configuredShortcut = settings.launcherShortcut
    let backend = FaultingHotKeyRegistrationBackend(status: OSStatus(eventHotKeyExistsErr))
    let service = HotKeyService(backend: backend)
    var presentation: HotKeyStatusPresentation?
    service.onStateChange = { state in
        let value = HotKeyStatusPresentation(state: state, shortcut: settings.launcherShortcut)
        settings.setHotKeyRegistrationError(value.errorMessage)
        presentation = value
    }

    service.register(configuredShortcut)

    #expect(settings.launcherShortcut == configuredShortcut)
    #expect(settings.hotKeyRegistrationError == presentation?.errorMessage)
    #expect(presentation?.errorMessage != nil)
    #expect(presentation?.menuTitle.isEmpty == false)
    #expect(backend.registeredShortcuts == [configuredShortcut])
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
    var onInvocation: (() -> Void)?
    private let status: OSStatus
    private(set) var registeredShortcuts: [HotKeyShortcut] = []

    init(status: OSStatus) {
        self.status = status
    }

    func register(_ shortcut: HotKeyShortcut) -> OSStatus {
        registeredShortcuts.append(shortcut)
        return status
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
