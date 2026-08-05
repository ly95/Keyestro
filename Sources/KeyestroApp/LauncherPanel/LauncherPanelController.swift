import AppKit
import Combine
import CoreGraphics
import KeyestroCore
import KeyestroDomain
import SwiftUI

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let panelWindowIdentifier = NSUserInterfaceItemIdentifier("com.keyestro.launcher.panel")

    private let panel: LauncherPanel
    private let viewModel: LauncherViewModel
    private let restoresPreviousApplication: Bool
    private weak var previousApplication: NSRunningApplication?
    private var isDismissing = false
    private var isPreviewing = false
    private var presentationPending = false
    private var resizeScheduled = false
    private var resignDismissTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    private(set) var firstFrameGeneration: UInt64 = 0
    private(set) var lastInvokeToFirstFrameDuration: Duration?
    private(set) var lastFirstFrameMainThreadSegment: Duration?
    private(set) var lastPresentationMainThreadSegments: [Duration] = []

    init(viewModel: LauncherViewModel, restoresPreviousApplication: Bool = true) {
        self.viewModel = viewModel
        self.restoresPreviousApplication = restoresPreviousApplication
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 220),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.identifier = Self.panelWindowIdentifier
        panel.contentView = NSHostingView(rootView: LauncherView(model: viewModel))
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.needsDisplay = true
        panel.contentView?.displayIfNeeded()
        panel.setFrameAutosaveName("")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        viewModel.objectWillChange
            .sink { [weak self] in self?.scheduleContentResize() }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { presentationPending || panel.isVisible }
    var frame: NSRect { panel.frame }

    static func launcherPanelWindowCount() -> Int {
        NSApplication.shared.windows.count { $0.identifier == panelWindowIdentifier }
    }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    func show() {
        guard !isVisible else { return }
        resignDismissTask?.cancel()
        resignDismissTask = nil
        let startedAt = ContinuousClock.now
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationPending = true
        lastPresentationMainThreadSegments = []
        PerformanceSignposts.launcherInvoked()
        if restoresPreviousApplication {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication = frontmost
            }
        }
        recordPresentationSegment(startedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.preparePresentation(generation: generation, invokedAt: startedAt)
        }
    }

    private func preparePresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant
    ) {
        guard presentationIsCurrent(generation) else { return }
        let segmentStartedAt = ContinuousClock.now
        let screen = targetScreen()
        positionPanel(on: screen)
        recordPresentationSegment(segmentStartedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.orderPresentation(generation: generation, invokedAt: invokedAt, screen: screen)
        }
    }

    private func orderPresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant,
        screen: NSScreen?
    ) {
        guard presentationIsCurrent(generation) else { return }
        let segmentStartedAt = ContinuousClock.now
        panel.orderFrontRegardless()
        recordPresentationSegment(segmentStartedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.activatePresentation(generation: generation, invokedAt: invokedAt, screen: screen)
        }
    }

    private func activatePresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant,
        screen: NSScreen?
    ) {
        guard presentationIsCurrent(generation), panel.isVisible else { return }
        let segmentStartedAt = ContinuousClock.now
        NSApplication.shared.activate()
        recordPresentationSegment(segmentStartedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.focusPresentation(generation: generation, invokedAt: invokedAt, screen: screen)
        }
    }

    private func focusPresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant,
        screen: NSScreen?
    ) {
        guard presentationIsCurrent(generation), panel.isVisible else { return }
        let segmentStartedAt = ContinuousClock.now
        panel.makeKey()
        resignDismissTask?.cancel()
        resignDismissTask = nil
        recordPresentationSegment(segmentStartedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.displayPresentation(generation: generation, invokedAt: invokedAt, screen: screen)
        }
    }

    private func displayPresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant,
        screen: NSScreen?
    ) {
        guard presentationIsCurrent(generation), panel.isVisible else { return }
        let segmentStartedAt = ContinuousClock.now
        panel.displayIfNeeded()
        let firstFrameAt = ContinuousClock.now
        let invokeDuration = invokedAt.duration(to: firstFrameAt)
        lastInvokeToFirstFrameDuration = invokeDuration
        PerformanceSignposts.firstFrame()
        Task {
            await PerformanceRecorder.shared.record(
                .invokeToFirstFrame,
                duration: invokeDuration
            )
        }

        let context = QueryContext(
            frontmostBundleIdentifier: previousApplication?.bundleIdentifier,
            frontmostApplicationName: previousApplication?.localizedName,
            mouseScreenIdentifier: screen.flatMap(screenIdentifier)
        )
        // Providers begin only after the panel has completed its first frame.
        viewModel.invoke(context: context)
        let displaySegment = segmentStartedAt.duration(to: .now)
        lastFirstFrameMainThreadSegment = displaySegment
        recordPresentationSegment(displaySegment)
        presentationPending = false
        firstFrameGeneration &+= 1
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        resignDismissTask?.cancel()
        resignDismissTask = nil
        presentationGeneration &+= 1
        presentationPending = false
        if panel.isVisible { panel.orderOut(nil) }
        viewModel.didDismiss()
        previousApplication?.activate()
        previousApplication = nil
        isDismissing = false
    }

    private func presentationIsCurrent(_ generation: UInt64) -> Bool {
        presentationPending && presentationGeneration == generation
    }

    private func recordPresentationSegment(_ duration: Duration) {
        lastPresentationMainThreadSegments.append(duration)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !isPreviewing else { return }
        let generation = presentationGeneration
        resignDismissTask?.cancel()
        resignDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self,
                presentationGeneration == generation,
                panel.isVisible,
                !panel.isKeyWindow,
                !isPreviewing
            else { return }
            dismiss()
        }
    }

    func previewWillOpen() {
        isPreviewing = true
    }

    func previewDidClose() {
        isPreviewing = false
        guard panel.isVisible else { return }
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
        viewModel.requestQueryFocus(selectAll: false)
    }

    func displayIfNeeded() {
        panel.displayIfNeeded()
    }

    @objc private func screenParametersChanged() {
        if panel.isVisible { positionPanel(on: targetScreen()) }
    }

    private func positionPanel(on screen: NSScreen?) {
        guard let screen else {
            panel.center()
            return
        }
        panel.setFrame(
            Self.frame(in: screen.visibleFrame, preferredHeight: preferredHeight),
            display: false
        )
    }

    static func frame(in visible: NSRect, preferredHeight: CGFloat = 520) -> NSRect {
        let size = NSSize(
            width: min(720, visible.width),
            height: min(max(1, preferredHeight), min(560, visible.height))
        )
        let x = visible.midX - size.width / 2
        let preferredTopOffset = visible.height * 0.18
        let y = max(visible.minY, visible.maxY - preferredTopOffset - size.height)
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        return frame.intersection(visible)
    }

    static func preferredHeight(resultCount: Int, actionCount: Int = 0, isParameterForm: Bool = false) -> CGFloat {
        if isParameterForm { return 520 }
        let visibleRows = min(8, max(0, actionCount > 0 ? actionCount : resultCount))
        guard visibleRows > 0 else { return 220 }
        let chrome: CGFloat = 64 + 39 + 16
        let rows = CGFloat(visibleRows) * 52
        let spacing = CGFloat(max(0, visibleRows - 1)) * 4
        return min(560, max(220, chrome + rows + spacing))
    }

    private var preferredHeight: CGFloat {
        Self.preferredHeight(
            resultCount: viewModel.results.count,
            actionCount: viewModel.layer == .actions ? viewModel.visibleActions.count : 0,
            isParameterForm: viewModel.layer == .parameters
        )
    }

    private func scheduleContentResize() {
        guard panel.isVisible, !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resizeScheduled = false
            guard panel.isVisible else { return }
            positionPanel(on: targetScreen())
        }
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let screen = frontmostWindowScreen() { return screen }
        return panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Uses public window metadata only as the specified fallback when the pointer is outside every display.
    private func frontmostWindowScreen() -> NSScreen? {
        guard let processIdentifier = previousApplication?.processIdentifier,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let screens = NSScreen.screens
        let displayBounds = screens.map { screen -> CGRect in
            guard let displayID = Self.displayID(for: screen) else { return .null }
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
                let index = Self.targetDisplayIndex(windowBounds: bounds, displayBounds: displayBounds)
            else { continue }
            return screens[index]
        }
        return nil
    }

    static func targetDisplayIndex(windowBounds: CGRect, displayBounds: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, display) in displayBounds.enumerated() {
            let intersection: CGRect = windowBounds.intersection(display)
            let width = Swift.max(CGFloat.zero, intersection.width)
            let height = Swift.max(CGFloat.zero, intersection.height)
            let area = width * height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func screenIdentifier(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }
}
