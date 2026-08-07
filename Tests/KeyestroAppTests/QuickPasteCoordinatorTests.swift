import Carbon.HIToolbox
import Foundation
import KeyestroCore
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor
func quickPasteSendsOnlyLatestSupportedContentToTheFrozenFrontmostProcess() async throws {
    let fixture = try QuickPasteFixture()
    defer { fixture.remove() }
    await fixture.store.initialize(enabled: true)
    _ = await fixture.store.capture(
        .text("older text"),
        sourceBundleIdentifier: "com.example.source",
        at: Date(timeIntervalSince1970: 100)
    )
    let latestURL = try #require(URL(string: "https://example.invalid/latest"))
    let latestID = try #require(
        (await fixture.store.capture(
            .url(latestURL),
            sourceBundleIdentifier: "com.example.browser",
            at: Date(timeIntervalSince1970: 200)
        )).successValue
    )
    let coordinator = fixture.makeCoordinator()
    var messages: [QuickPasteMessage] = []
    var fallbackCount = 0
    coordinator.onMessage = { messages.append($0) }
    coordinator.onFallbackToHistory = { fallbackCount += 1 }

    coordinator.invoke()
    try await waitForQuickPaste(coordinator)

    #expect(fixture.pasteboard.writtenContent == .url(latestURL))
    let targets = await fixture.autoPaste.pastedTargets
    #expect(targets.count == 1)
    #expect(targets.first?.bundleIdentifier == "com.example.target")
    #expect(targets.first?.processIdentifier == 42)
    #expect(targets.first?.activationPolicy == .requireFrontmost)
    #expect(await fixture.autoPaste.itemWasValidatedBeforePaste)
    #expect(messages.last?.code == "quickPaste.success")
    #expect(fallbackCount == 0)
    #expect((await fixture.store.search("", limit: 1)).successValue?.first?.id == latestID)
}

@Test @MainActor
func quickPasteFallsBackForUnsupportedAndConservativelyBlockedSensitiveItems() async throws {
    let fixture = try QuickPasteFixture()
    defer { fixture.remove() }
    await fixture.store.initialize(enabled: true)
    _ = await fixture.store.capture(
        .files([URL(fileURLWithPath: "/tmp/latest-file")]),
        sourceBundleIdentifier: nil
    )
    let coordinator = fixture.makeCoordinator()
    var messages: [QuickPasteMessage] = []
    var fallbackCount = 0
    coordinator.onMessage = { messages.append($0) }
    coordinator.onFallbackToHistory = { fallbackCount += 1 }

    coordinator.invoke()
    try await waitForQuickPaste(coordinator)
    #expect(messages.last?.code == "quickPaste.unsupportedContent")
    #expect(fallbackCount == 1)
    #expect(fixture.pasteboard.writtenContent == nil)
    #expect(await fixture.autoPaste.pastedTargets.isEmpty)

    _ = await fixture.store.capture(.text("password=synthetic"), sourceBundleIdentifier: nil)
    fixture.settings.quickPasteAllowsSensitiveContent = false
    coordinator.invoke()
    try await waitForQuickPaste(coordinator)
    #expect(messages.last?.code == "quickPaste.sensitiveContentBlocked")
    #expect(fallbackCount == 2)
    #expect(fixture.pasteboard.writtenContent == nil)
    #expect(await fixture.autoPaste.pastedTargets.isEmpty)
}

@Test @MainActor
func quickPastePermissionOrTargetChangeProducesNoClipboardWriteOrPasteKeystroke() async throws {
    let failures = [
        ErrorDescriptor(
            code: "clipboard.autoPaste.permissionDenied",
            message: "Accessibility permission is required."
        ),
        ErrorDescriptor(
            code: "clipboard.autoPaste.targetChanged",
            message: "The target changed."
        ),
    ]
    for failure in failures {
        let fixture = try QuickPasteFixture(validationResult: .failure(failure))
        defer { fixture.remove() }
        await fixture.store.initialize(enabled: true)
        _ = await fixture.store.capture(.text("never expose this body"), sourceBundleIdentifier: nil)
        let coordinator = fixture.makeCoordinator()
        var messages: [QuickPasteMessage] = []
        coordinator.onMessage = { messages.append($0) }

        coordinator.invoke()
        try await waitForQuickPaste(coordinator)

        #expect(fixture.pasteboard.writtenContent == nil)
        #expect(await fixture.autoPaste.pastedTargets.isEmpty)
        #expect(messages.last?.code == failure.code)
        #expect(messages.last?.text.contains("never expose this body") == false)
    }
}

@Test @MainActor
func quickPasteFailsClosedForEmptyHistoryAndForKeyestroAsTarget() async throws {
    let fixture = try QuickPasteFixture()
    defer { fixture.remove() }
    await fixture.store.initialize(enabled: true)
    var messages: [QuickPasteMessage] = []
    let emptyCoordinator = fixture.makeCoordinator()
    emptyCoordinator.onMessage = { messages.append($0) }

    emptyCoordinator.invoke()
    try await waitForQuickPaste(emptyCoordinator)
    #expect(messages.last?.code == "quickPaste.emptyHistory")
    #expect(fixture.pasteboard.writtenContent == nil)
    #expect(await fixture.autoPaste.pastedTargets.isEmpty)

    let ownTarget = QuickPasteTargetApplication(
        name: "Keyestro",
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.keyestro.tests",
        processIdentifier: ProcessInfo.processInfo.processIdentifier
    )
    let ownTargetCoordinator = fixture.makeCoordinator(target: ownTarget)
    ownTargetCoordinator.onMessage = { messages.append($0) }
    ownTargetCoordinator.invoke()
    #expect(!ownTargetCoordinator.isExecuting)
    #expect(messages.last?.code == "quickPaste.targetUnavailable")
    #expect(fixture.pasteboard.writtenContent == nil)
    #expect(await fixture.autoPaste.pastedTargets.isEmpty)
}

@MainActor
private final class QuickPasteFixture {
    let root: URL
    let database: LauncherDatabase
    let store: ClipboardStore
    let settings: SettingsStore
    let pasteboard = QuickPastePasteboard()
    let autoPaste: QuickPasteAutoPaste
    let actions: ClipboardActionService
    private let defaultsName: String

    init(validationResult: Result<Void, ErrorDescriptor> = .success(())) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyestro-quick-paste-\(UUID().uuidString)", isDirectory: true)
        let paths = try AppPaths(
            bundleIdentifier: "com.keyestro.quick-paste-tests",
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
            cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
        )
        database = LauncherDatabase(paths: paths)
        store = ClipboardStore(
            database: database,
            keyManager: InstallationKeyManager(
                keychain: InMemoryKeychainService(),
                service: "com.keyestro.quick-paste-tests"
            )
        )
        defaultsName = "com.keyestro.quick-paste-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw QuickPasteTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsName)
        settings = SettingsStore(defaults: defaults)
        settings.quickPasteShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(controlKey | optionKey)
        )
        settings.quickPasteEnabled = true
        autoPaste = QuickPasteAutoPaste(validationResult: validationResult)
        actions = ClipboardActionService(store: store, pasteboard: pasteboard, autoPaste: autoPaste)
    }

    func makeCoordinator(
        target: QuickPasteTargetApplication = QuickPasteTargetApplication(
            name: "Target Editor",
            bundleIdentifier: "com.example.target",
            processIdentifier: 42
        )
    ) -> QuickPasteCoordinator {
        QuickPasteCoordinator(
            store: store,
            actions: actions,
            settings: settings,
            targetApplication: { target }
        )
    }

    func remove() {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class QuickPastePasteboard: PasteboardServicing, @unchecked Sendable {
    var changeCount = 0
    var writtenContent: ClipboardContent?

    func readSupportedContent() -> ClipboardContent? { writtenContent }

    func write(_ content: ClipboardContent) -> Bool {
        writtenContent = content
        changeCount += 1
        return true
    }
}

private actor QuickPasteAutoPaste: AutoPasteServicing {
    private let validationResult: Result<Void, ErrorDescriptor>
    private(set) var pastedTargets: [AutoPasteTarget] = []
    private var validationCount = 0

    init(validationResult: Result<Void, ErrorDescriptor>) {
        self.validationResult = validationResult
    }

    var itemWasValidatedBeforePaste: Bool {
        validationCount > 0 && !pastedTargets.isEmpty
    }

    func paste(intoBundleIdentifier bundleIdentifier: String?) -> Result<Void, ErrorDescriptor> {
        .failure(ErrorDescriptor(code: "quickPaste.legacyRoute", message: "Unexpected legacy route."))
    }

    func validate(target: AutoPasteTarget) -> Result<Void, ErrorDescriptor> {
        validationCount += 1
        return validationResult
    }

    func paste(into target: AutoPasteTarget) -> Result<Void, ErrorDescriptor> {
        pastedTargets.append(target)
        return validationResult
    }
}

@MainActor
private func waitForQuickPaste(_ coordinator: QuickPasteCoordinator) async throws {
    for _ in 0..<10_000 {
        if !coordinator.isExecuting { return }
        await Task.yield()
    }
    throw QuickPasteTestError.conditionTimedOut
}

private enum QuickPasteTestError: Error {
    case conditionTimedOut
    case defaultsUnavailable
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self { return value }
        return nil
    }
}
