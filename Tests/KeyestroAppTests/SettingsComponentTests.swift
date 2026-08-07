import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor
func settingsWindowRendersEverySectionAsAComponentStory() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let suiteName = "com.keyestro.settings-component-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let quicklink = try QuicklinkDefinition.inferred(
        id: "component-story",
        title: "Component Story Search",
        urlTemplate: "https://example.invalid/search?q={query}"
    )
    let script = try ScriptDefinition(
        id: "component-story",
        title: "Component Story Script",
        executablePath: "/usr/bin/true",
        arguments: [ArgumentDefinition(id: "query", title: "Query", kind: .text, required: false)],
        contentHash: String(repeating: "0", count: 64)
    )
    let extensionManifest = ExtensionManifest(
        id: "com.keyestro.component-story",
        name: "Component Story Extension",
        version: "1.0.0",
        description: "Exercises every host-rendered preference component.",
        author: "Keyestro",
        license: "Apache-2.0",
        executable: "extension",
        minimumHostVersion: "0.1.0",
        searchPolicy: .global,
        commands: [ExtensionCommandManifest(id: "search", title: "Search", mode: "search")],
        preferences: [
            ExtensionPreferenceManifest(name: "text", title: "Text", type: .text, required: false),
            ExtensionPreferenceManifest(name: "password", title: "Password", type: .password, required: false),
            ExtensionPreferenceManifest(
                name: "choice",
                title: "Choice",
                type: .choice,
                required: false,
                choices: ["First", "Second"]
            ),
            ExtensionPreferenceManifest(name: "file", title: "File", type: .file, required: false),
            ExtensionPreferenceManifest(name: "directory", title: "Directory", type: .directory, required: false),
            ExtensionPreferenceManifest(name: "toggle", title: "Toggle", type: .toggle, required: false),
        ]
    )
    let manifestJSON = try JSONEncoder().encode(extensionManifest)
    let extensionRegistration = ExtensionRegistration(
        manifest: extensionManifest,
        installPath: "/tmp/keyestro-component-story",
        manifestJSON: manifestJSON,
        contentHash: String(repeating: "1", count: 64),
        enabled: true
    )
    let extensionStore = InMemoryExtensionStore(registrations: [extensionRegistration])
    let extensionSupervisor = ExtensionSupervisor(store: extensionStore)
    let extensionAuthorization = InMemoryExtensionSearchAuthorization(
        enabledIDs: [extensionRegistration.id]
    )
    let extensionPreferences = ExtensionPreferenceService(
        store: extensionStore,
        keychain: InMemoryKeychainService(),
        bundleIdentifier: suiteName
    )
    let controller = SettingsWindowController(
        settings: SettingsStore(defaults: defaults),
        quicklinks: InMemoryQuicklinkStore(definitions: [quicklink]),
        clipboardStore: nil,
        scripts: InMemoryScriptStore(scripts: [script]),
        scriptInstaller: nil,
        extensions: extensionStore,
        extensionInstaller: nil,
        extensionSupervisor: extensionSupervisor,
        extensionAuthorization: extensionAuthorization,
        extensionPreferences: extensionPreferences,
        updateService: SparkleUpdateService(bundle: Bundle(for: SettingsComponentBundleMarker.self), defaults: defaults),
        configurationService: nil,
        diagnosticsService: nil,
        clearCaches: { "Component story caches cleared." },
        beginHotKeyRecording: {},
        endHotKeyRecording: {},
        deleteAllLocalData: {},
        rankingStore: nil
    )
    defer {
        controller.close()
        SettingsComponentControllerRetainer.retain(controller)
    }

    for section in SettingsSection.allCases {
        controller.show(section: section)
        try await renderSettingsComponent(controller)

        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        #expect(window.contentLayoutRect.height >= 480)
        #expect(contentView.fittingSize.height <= window.contentLayoutRect.height + 1)
        let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let renderedPNG = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(renderedPNG.count > 1_000)
    }
}

@MainActor
private enum SettingsComponentControllerRetainer {
    // The settings window hosts multiple SwiftUI graphs whose metadata may
    // still be finishing on AttributeGraph's utility queue after bitmap QA.
    private static var retainedControllers: [SettingsWindowController] = []

    static func retain(_ controller: SettingsWindowController) {
        retainedControllers.append(controller)
    }
}

private final class SettingsComponentBundleMarker: NSObject {}

@MainActor
private func renderSettingsComponent(_ controller: SettingsWindowController) async throws {
    let window = try #require(controller.window)
    let contentView = try #require(window.contentView)
    for _ in 0..<12 {
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        await Task.yield()
    }
}
