import AppKit
import CoreGraphics

final class KeyestroTransientPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum TransientPanelKind: Hashable {
    case launcher
    case clipboardHistory
}

@MainActor
final class TransientPanelCoordinator {
    typealias DismissHandler = (_ restoringFocus: Bool) -> Void

    private var dismissHandlers: [TransientPanelKind: DismissHandler] = [:]
    private(set) var visiblePanel: TransientPanelKind?

    func register(_ panel: TransientPanelKind, dismiss: @escaping DismissHandler) {
        dismissHandlers[panel] = dismiss
    }

    func unregister(_ panel: TransientPanelKind) {
        dismissHandlers[panel] = nil
        if visiblePanel == panel { visiblePanel = nil }
    }

    func willShow(_ panel: TransientPanelKind) {
        if let visiblePanel, visiblePanel != panel {
            dismissHandlers[visiblePanel]?(false)
        }
        visiblePanel = panel
    }

    func didDismiss(_ panel: TransientPanelKind) {
        if visiblePanel == panel { visiblePanel = nil }
    }
}

@MainActor
final class TransientPanelFocusCoordinator {
    private(set) weak var previousApplication: NSRunningApplication?

    func captureFrontmostApplication() {
        let application = NSWorkspace.shared.frontmostApplication
        guard application?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApplication = application
    }

    func restorePreviousApplication() {
        previousApplication?.activate()
        previousApplication = nil
    }
}

enum TransientPanelPlacement {
    static func frame(
        in visible: NSRect,
        preferredHeight: CGFloat,
        preferredWidth: CGFloat = 720,
        maximumHeight: CGFloat = 560
    ) -> NSRect {
        let size = NSSize(
            width: min(preferredWidth, visible.width),
            height: min(max(1, preferredHeight), min(maximumHeight, visible.height))
        )
        let x = visible.midX - size.width / 2
        let preferredTopOffset = visible.height * 0.18
        let y = max(visible.minY, visible.maxY - preferredTopOffset - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size).intersection(visible)
    }

    @MainActor
    static func targetScreen(
        for panel: NSPanel,
        previousApplication: NSRunningApplication?
    ) -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let screen = frontmostWindowScreen(for: previousApplication) { return screen }
        return panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func targetDisplayIndex(windowBounds: CGRect, displayBounds: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, display) in displayBounds.enumerated() {
            let intersection = windowBounds.intersection(display)
            let area = max(CGFloat.zero, intersection.width) * max(CGFloat.zero, intersection.height)
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    static func screenIdentifier(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    @MainActor
    private static func frontmostWindowScreen(for application: NSRunningApplication?) -> NSScreen? {
        guard let processIdentifier = application?.processIdentifier,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let screens = NSScreen.screens
        let displayBounds = screens.map { screen -> CGRect in
            guard let displayID = displayID(for: screen) else { return .null }
            return CGDisplayBounds(displayID)
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                bounds.width > 1,
                bounds.height > 1,
                let index = targetDisplayIndex(windowBounds: bounds, displayBounds: displayBounds)
            else { continue }
            return screens[index]
        }
        return nil
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
