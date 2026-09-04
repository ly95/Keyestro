import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain
import SwiftUI
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

    if ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_DIR"] == nil {
        controller.window?.setContentSize(NSSize(width: 720, height: 480))
    }

    for section in SettingsSection.allCases {
        controller.show(section: section)
        try await renderSettingsComponent(controller)

        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        #expect(window.contentLayoutRect.height >= 480)
        #expect(contentView.fittingSize.height <= window.contentLayoutRect.height + 1)

        let detailScrollView = try #require(
            subviews(of: NSScrollView.self, in: contentView).max {
                $0.frame.width < $1.frame.width
            }
        )
        #expect(detailScrollView.frame.width > contentView.bounds.width / 2)
        #expect(abs(detailScrollView.contentView.bounds.origin.y) <= 1)
        let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let renderedPNG = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(renderedPNG.count > 1_000)
        try writeSettingsSnapshotIfRequested(renderedPNG, section: section)
    }
}

@Test @MainActor
func settingsSidebarRendersNavigationAndKeyboardSearchSelectionIndependently() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    let originalActivationPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.accessory)
    defer { NSApplication.shared.setActivationPolicy(originalActivationPolicy) }

    let navigation = SettingsNavigationModel()
    let hosting = NSHostingView(rootView: SettingsSidebar(navigation: navigation))
    hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 720)
    let window = NSWindow(
        contentRect: hosting.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.title = "Settings Sidebar AX Test"
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    defer { window.orderOut(nil) }

    try await renderView(hosting, in: window)
    #expect(hosting.fittingSize.width <= hosting.bounds.width + 1)
    #expect(hosting.fittingSize.height <= hosting.bounds.height + 1)
    let initialRendering = try renderedPNG(of: hosting)

    let searchField = try #require(subviews(of: NSTextField.self, in: hosting).first)
    #expect(window.makeFirstResponder(searchField))
    for (index, section) in SettingsSection.allCases.dropFirst().enumerated() {
        window.sendEvent(try downArrowEvent(for: window, isRepeat: index > 0))
        #expect(navigation.selection == section)
    }
    window.sendEvent(try downArrowEvent(for: window, isRepeat: true))
    #expect(navigation.selection == .about)
    try await renderView(hosting, in: window)
    let movedSectionRendering = try renderedPNG(of: hosting)
    #expect(movedSectionRendering != initialRendering)

    navigation.searchQuery = "clipboard"
    let results = SettingsSearchCatalog.search(navigation.searchQuery)
    #expect(results.count > 1)
    try await renderView(hosting, in: window)
    let initialSearchRendering = try renderedPNG(of: hosting)
    #expect(initialSearchRendering != movedSectionRendering)

    #expect(window.makeFirstResponder(searchField))
    window.sendEvent(try downArrowEvent(for: window, isRepeat: false))
    try await renderView(hosting, in: window)
    #expect(navigation.searchResultSelection == results[1].anchor)
    let movedSearchRendering = try renderedPNG(of: hosting)
    #expect(movedSearchRendering != initialSearchRendering)
}

private func writeSettingsSnapshotIfRequested(_ data: Data, section: SettingsSection) throws {
    guard let directory = ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_DIR"] else { return }
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let appearance = ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_APPEARANCE"]
    let size = ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_SIZE"]
    let suffix = [appearance, size]
        .compactMap { $0?.lowercased() }
        .map { "-\($0)" }
        .joined()
    let filename = section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") + suffix + ".png"
    try data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
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
    if ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_DIR"] != nil {
        if ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_APPEARANCE"] == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.appearance = NSAppearance(named: .aqua)
        }
        if ProcessInfo.processInfo.environment["KEYESTRO_SETTINGS_SNAPSHOT_SIZE"] == "minimum" {
            window.setContentSize(NSSize(width: 720, height: 480))
        } else {
            window.setContentSize(NSSize(width: 980, height: 680))
        }
        window.orderFrontRegardless()
    }
    for _ in 0..<12 {
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        await Task.yield()
    }
}

@MainActor
private func renderView(_ view: NSView, in window: NSWindow) async throws {
    for _ in 0..<8 {
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        await Task.yield()
    }
}

@MainActor
private func renderedPNG(of view: NSView) throws -> Data {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor
private func downArrowEvent(for window: NSWindow, isRepeat: Bool) throws -> NSEvent {
    let characters = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    return try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: 125
        )
    )
}

@MainActor
private func subviews<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
    var matches = root.subviews.compactMap { $0 as? View }
    for subview in root.subviews {
        matches.append(contentsOf: subviews(of: type, in: subview))
    }
    return matches
}
