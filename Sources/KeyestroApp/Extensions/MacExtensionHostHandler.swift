import AppKit
import KeyestroCore
import OSLog

@MainActor
final class MacExtensionHostHandler: ExtensionHostRequestHandling {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.keyestro.launcher", category: "Extensions")
    private let preferences: ExtensionPreferenceService
    private var hudWindow: NSPanel?
    private var hudToken = UUID()

    init(preferences: ExtensionPreferenceService) {
        self.preferences = preferences
    }

    func showHUD(extensionID: String, message: String) async {
        let token = UUID()
        hudToken = token
        let panel = hudWindow ?? makeHUDWindow()
        hudWindow = panel
        (panel.contentView as? NSTextField)?.stringValue = message
        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.midX - panel.frame.width / 2,
                y: screen.visibleFrame.maxY - panel.frame.height - 56
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.hudToken == token else { return }
            self?.hudWindow?.orderOut(nil)
        }
        logger.info("Extension HUD requested by \(extensionID, privacy: .public)")
    }

    func openURL(extensionID: String, url: URL) async -> Bool {
        logger.info("Opening validated URL for \(extensionID, privacy: .public)")
        return NSWorkspace.shared.open(url)
    }

    func readPreference(extensionID: String, name: String) async -> JSONValue? {
        do {
            return try await preferences.read(extensionID: extensionID, name: name)
        } catch {
            logger.error(
                "A declared preference could not be read for \(extensionID, privacy: .public); name hash: \(name, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }

    func log(extensionID: String, level: String, message: String) async {
        logger.log(
            level: .info, "[\(extensionID, privacy: .public)] [\(level, privacy: .public)] \(message, privacy: .private(mask: .hash))")
    }

    private func makeHUDWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.96)
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 18, y: 12, width: 344, height: 40)
        label.setAccessibilityLabel(L10n.text("extension.hud.accessibility"))
        panel.contentView = label
        return panel
    }
}
