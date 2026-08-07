import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor func quicklinkAndScriptSettingsModelsExerciseEveryEditorShape() async throws {
    for type in QuicklinkArgumentType.allCases {
        #expect(!type.title.isEmpty)
        let choices = type == .choice ? "First, Second" : ""
        let definition = try QuicklinkArgumentDraft(name: type.rawValue, type: type, choices: choices).definition()
        #expect(definition.id == type.rawValue)
    }
    #expect(throws: ErrorDescriptor.self) { try QuicklinkArgumentDraft(name: " ").definition() }
    #expect(throws: ErrorDescriptor.self) {
        try QuicklinkArgumentDraft(name: "choice", type: .choice, choices: " , \n ").definition()
    }

    let quicklinks = InMemoryQuicklinkStore()
    let quicklinkModel = QuicklinkSettingsModel(store: quicklinks)
    await componentYield()
    quicklinkModel.add()
    #expect(quicklinkModel.error == "Enter a title and an absolute URL template.")
    quicklinkModel.title = "Component Search"
    quicklinkModel.iconName = "not-a-real-symbol-name"
    quicklinkModel.add()
    #expect(quicklinkModel.error == "Enter a valid SF Symbol name.")

    quicklinkModel.iconName = "link"
    quicklinkModel.template = "https://example.invalid/?q={query}&kind={kind}"
    quicklinkModel.synchronizeParameters()
    #expect(quicklinkModel.arguments.map(\.name) == ["kind", "query"])
    quicklinkModel.keywords = "component, settings\nstory"
    quicklinkModel.browserBundleIdentifier = "com.apple.Safari"
    quicklinkModel.addParameter()
    let addedParameter = try #require(quicklinkModel.arguments.last)
    quicklinkModel.removeParameter(id: addedParameter.id)
    quicklinkModel.add()
    try await waitForComponent { !(await quicklinks.allQuicklinks()).isEmpty }
    let savedQuicklinks = await quicklinks.allQuicklinks()
    let savedQuicklink = try #require(savedQuicklinks.first)
    #expect(savedQuicklink.arguments.count == 2)

    let replacement = try QuicklinkDefinition(
        id: savedQuicklink.id,
        title: "Changed after confirmation",
        urlTemplate: savedQuicklink.urlTemplate,
        arguments: savedQuicklink.arguments,
        iconName: savedQuicklink.iconName
    )
    await quicklinks.saveQuicklink(replacement)
    quicklinkModel.delete(savedQuicklink)
    try await waitForComponent { quicklinkModel.error?.contains("changed") == true }
    quicklinkModel.reload()
    try await waitForComponent { quicklinkModel.links.first?.title == replacement.title }
    quicklinkModel.delete(replacement)
    try await waitForComponent { await quicklinks.allQuicklinks().isEmpty }

    let arguments = try QuicklinkArgumentType.allCases.map { type in
        try QuicklinkArgumentDraft(
            name: "argument-\(type.rawValue)",
            type: type,
            choices: type == .choice ? "One, Two" : ""
        ).definition()
    }
    for argument in arguments {
        #expect(try QuicklinkArgumentDraft(argument).definition() == argument)
    }
    let script = try ScriptDefinition(
        id: "component-script",
        title: "Component Script",
        executablePath: "/usr/bin/true",
        arguments: arguments,
        contentHash: String(repeating: "a", count: 64)
    )
    let scripts = InMemoryScriptStore(scripts: [script])
    let suite = try componentDefaults(prefix: "scripts")
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let scriptModel = ScriptSettingsModel(store: scripts, installer: nil, defaults: suite.defaults)
    try await waitForComponent { scriptModel.scripts == [script] }
    scriptModel.chooseAndInstall()
    #expect(scriptModel.error == "Managed script storage is unavailable.")
    scriptModel.chooseAndLinkOriginal()
    scriptModel.chooseAndReconnect(ExportedScriptRegistration(script))
    scriptModel.confirmLinkOriginal()
    scriptModel.confirmReconnect()
    scriptModel.confirmReconfirmation()
    scriptModel.remove(script)
    scriptModel.saveConfiguration()

    scriptModel.configure(script)
    let originalCount = scriptModel.editArguments.count
    scriptModel.addArgument()
    #expect(scriptModel.editArguments.count == originalCount + 1)
    scriptModel.removeArgument(id: try #require(scriptModel.editArguments.last).id)
    scriptModel.editTitle = " "
    scriptModel.saveConfiguration()
    #expect(scriptModel.error != nil)
    scriptModel.configure(script)
    scriptModel.editTitle = "Updated Script"
    scriptModel.saveConfiguration()
    try await waitForComponent { await scripts.script(id: script.id)?.title == "Updated Script" }
}

@Test @MainActor func extensionAndClipboardSettingsModelsExerciseStoredAndUnavailableStates() async throws {
    let suite = try componentDefaults(prefix: "extensions")
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let declarations = [
        ExtensionPreferenceManifest(name: "text", title: "Text", type: .text, required: false),
        ExtensionPreferenceManifest(name: "password", title: "Password", type: .password, required: false),
        ExtensionPreferenceManifest(
            name: "choice",
            title: "Choice",
            type: .choice,
            required: false,
            choices: ["First", "Second"]
        ),
        ExtensionPreferenceManifest(name: "toggle", title: "Toggle", type: .toggle, required: false),
    ]
    let manifest = ExtensionManifest(
        id: "com.keyestro.settings-model",
        name: "Settings Model",
        version: "1.0.0",
        description: "Component model fixture",
        author: "Keyestro",
        license: "Apache-2.0",
        executable: "bin/extension",
        minimumHostVersion: "0.1.0",
        searchPolicy: .global,
        preferences: declarations
    )
    let registration = ExtensionRegistration(
        manifest: manifest,
        installPath: "/tmp/SettingsModel.extension",
        manifestJSON: try JSONEncoder().encode(manifest),
        contentHash: String(repeating: "b", count: 64),
        enabled: true
    )
    let store = InMemoryExtensionStore(registrations: [registration])
    let authorization = InMemoryExtensionSearchAuthorization()
    let preferences = ExtensionPreferenceService(
        store: store,
        keychain: InMemoryKeychainService(),
        bundleIdentifier: suite.name
    )
    try await preferences.set(.string("initial"), extensionID: registration.id, name: "text")
    try await preferences.set(.bool(true), extensionID: registration.id, name: "toggle")
    let supervisor = ExtensionSupervisor(store: store)
    let model = ExtensionSettingsModel(
        store: store,
        installer: nil,
        supervisor: supervisor,
        authorization: authorization,
        preferences: preferences,
        defaults: suite.defaults
    )
    try await waitForComponent { model.registrations.count == 1 && model.text(extensionID: registration.id, name: "text") == "initial" }
    #expect(model.toggle(extensionID: registration.id, name: "toggle"))
    #expect(model.isPreferenceSet(extensionID: registration.id, name: "text"))
    model.setText("updated", extensionID: registration.id, name: "text")
    model.setToggle(false, extensionID: registration.id, name: "toggle")
    model.savePreference(declarations[0], registration: registration)
    model.savePreference(declarations[1], registration: registration)
    model.savePreference(declarations[2], registration: registration)
    model.savePreference(declarations[3], registration: registration)
    try await waitForComponent {
        model.text(extensionID: registration.id, name: "text") == "updated"
            && !model.toggle(extensionID: registration.id, name: "toggle")
    }
    model.clearPreference(declarations[0], registration: registration)
    try await waitForComponent { !model.isPreferenceSet(extensionID: registration.id, name: "text") }
    model.setGlobalSearch(true, registration: registration)
    try await waitForComponent { model.globalSearchEnabled[registration.id] == true }
    model.setEnabled(false, registration: registration)
    try await waitForComponent { model.registrations.first?.enabled == false }
    model.retry(registration)
    try await waitForComponent { model.error == "The extension may start again on its next query." }
    model.choosePackage()
    #expect(model.error == "Managed extension storage is unavailable.")
    model.choosePackage(for: ExportedExtensionRegistration(registration))
    model.installInspected()
    model.remove(registration)
    await supervisor.shutdownAll()

    suite.defaults.set(Data("invalid".utf8), forKey: PendingConfigurationImportStore.extensionsKey)
    model.reloadPendingImports()
    #expect(model.pendingImports.isEmpty)
    #expect(model.error == "Pending extension reinstallations could not be read.")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-settings-model",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let clipboard = ClipboardStore(
        database: database,
        keyManager: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.clipboard-settings-model"
        )
    )
    await clipboard.initialize(enabled: true)
    _ = await clipboard.capture(.text("component"), sourceBundleIdentifier: nil)
    let clipboardModel = ClipboardSettingsModel(store: clipboard)
    clipboardModel.refresh()
    try await waitForComponent { clipboardModel.state == .ready(itemCount: 1) }
    clipboardModel.clear(type: .text)
    try await waitForComponent { clipboardModel.message == "Selected clipboard history cleared." }
    clipboardModel.message = nil
    clipboardModel.clear(type: .url)
    try await waitForComponent { clipboardModel.message == "Selected clipboard history cleared." }
    clipboardModel.message = nil
    clipboardModel.clear(type: .files)
    try await waitForComponent { clipboardModel.message == "Selected clipboard history cleared." }
    clipboardModel.message = nil
    clipboardModel.clear(type: .image)
    try await waitForComponent { clipboardModel.message == "Selected clipboard history cleared." }
    clipboardModel.message = nil
    clipboardModel.clear()
    try await waitForComponent { clipboardModel.message == "Clipboard history cleared." }
    clipboardModel.message = nil
    clipboardModel.recover()
    try await waitForComponent { clipboardModel.message == "Clipboard recovery is not required." }

    let unavailableClipboard = ClipboardSettingsModel(store: nil)
    unavailableClipboard.refresh()
    unavailableClipboard.clear()
    unavailableClipboard.clear(type: .text)
    unavailableClipboard.recover()
    #expect(unavailableClipboard.state == .disabled)
    await database.close()
}

@Test @MainActor func diagnosticPerformanceAndConfigurationModelsRenderEveryNonModalState() async throws {
    await PerformanceRecorder.shared.reset()
    let performance = PerformanceSettingsModel()
    performance.copy()
    performance.run()
    performance.run()
    try await waitForComponent { !performance.isWorking }
    #expect(performance.message != nil)
    await PerformanceRecorder.shared.recordMilliseconds(12.5, for: .queryComplete)
    performance.run()
    try await waitForComponent { performance.report?.summaries.isEmpty == false }
    let previousPasteboard = NSPasteboard.general.string(forType: .string)
    performance.copy()
    #expect(performance.message?.contains("copied") == true)
    NSPasteboard.general.clearContents()
    if let previousPasteboard { NSPasteboard.general.setString(previousPasteboard, forType: .string) }
    performance.reset()
    try await waitForComponent { performance.report == nil && performance.message?.contains("cleared") == true }

    let suite = try componentDefaults(prefix: "diagnostics")
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let settings = SettingsStore(defaults: suite.defaults)
    let unavailableDiagnostics = DiagnosticsSettingsModel(service: nil, settings: settings)
    unavailableDiagnostics.preparePreview()
    unavailableDiagnostics.export()
    #expect(unavailableDiagnostics.message != nil)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-diagnostics-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.diagnostics-settings-model",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let diagnostics = DiagnosticsService(
        paths: paths,
        extensions: InMemoryExtensionStore(),
        database: nil,
        processService: SettingsModelProcessService(),
        bundleURL: root,
        appVersion: "1.0.0",
        buildVersion: "1"
    )
    let diagnosticsModel = DiagnosticsSettingsModel(service: diagnostics, settings: settings)
    diagnosticsModel.preparePreview()
    #expect(diagnosticsModel.preview?.files.contains("diagnostics.json") == true)

    let configuration = ConfigurationSettingsModel(service: nil, settings: settings, defaults: suite.defaults)
    configuration.exportConfiguration()
    #expect(configuration.message == "Configuration storage is unavailable.")
    configuration.chooseImport()
    #expect(configuration.message == "Configuration storage is unavailable.")
    configuration.applyImport()
    suite.defaults.set(Data("invalid".utf8), forKey: PendingConfigurationImportStore.scriptsKey)
    configuration.reloadPendingImports()
    #expect(configuration.message == "Pending imported registrations could not be read.")
}

@MainActor
private func componentYield(iterations: Int = 10) async {
    for _ in 0..<iterations { await Task.yield() }
}

@MainActor
private func waitForComponent(
    _ predicate: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<500 {
        if await predicate() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for settings component state")
}

@MainActor
private func componentDefaults(prefix: String) throws -> (defaults: UserDefaults, name: String) {
    let name = "com.keyestro.settings-model.\(prefix).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

private actor SettingsModelProcessService: ProcessServicing {
    func run(_ request: ProcessExecutionRequest) throws -> ProcessExecutionResult {
        ProcessExecutionResult(
            termination: .exited(0),
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            duration: .zero
        )
    }
}
