import AppKit
import Combine
import CoreGraphics
import KeyestroCore
import KeyestroDomain
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let panelWindowIdentifier = NSUserInterfaceItemIdentifier("com.keyestro.launcher.panel")

    private let panel: KeyestroTransientPanel
    private let viewModel: LauncherViewModel
    private let restoresPreviousApplication: Bool
    private let focusCoordinator: TransientPanelFocusCoordinator
    private let presentationCoordinator: TransientPanelCoordinator
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

    init(
        viewModel: LauncherViewModel,
        restoresPreviousApplication: Bool = true,
        focusCoordinator: TransientPanelFocusCoordinator = TransientPanelFocusCoordinator(),
        presentationCoordinator: TransientPanelCoordinator = TransientPanelCoordinator()
    ) {
        self.viewModel = viewModel
        self.restoresPreviousApplication = restoresPreviousApplication
        self.focusCoordinator = focusCoordinator
        self.presentationCoordinator = presentationCoordinator
        panel = KeyestroTransientPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LauncherPanelLayout.windowWidth,
                height: LauncherPanelLayout.windowHeight
            ),
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
        viewModel.$launcherAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in self?.panel.appearance = appearance.panelAppearance }
            .store(in: &cancellables)
        presentationCoordinator.register(.launcher) { [weak self] restoringFocus in
            self?.dismiss(restoringFocus: restoringFocus)
        }
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
            focusCoordinator.captureFrontmostApplication()
        }
        presentationCoordinator.willShow(.launcher)
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
            frontmostBundleIdentifier: focusCoordinator.previousApplication?.bundleIdentifier,
            frontmostApplicationName: focusCoordinator.previousApplication?.localizedName,
            mouseScreenIdentifier: screen.flatMap(TransientPanelPlacement.screenIdentifier)
        )
        // Providers begin only after the panel has completed its first frame.
        viewModel.invoke(context: context)
        let displaySegment = segmentStartedAt.duration(to: .now)
        lastFirstFrameMainThreadSegment = displaySegment
        recordPresentationSegment(displaySegment)
        presentationPending = false
        firstFrameGeneration &+= 1
    }

    func dismiss(restoringFocus: Bool = true) {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        resignDismissTask?.cancel()
        resignDismissTask = nil
        presentationGeneration &+= 1
        presentationPending = false
        if panel.isVisible { panel.orderOut(nil) }
        viewModel.didDismiss()
        presentationCoordinator.didDismiss(.launcher)
        if restoringFocus, restoresPreviousApplication {
            focusCoordinator.restorePreviousApplication()
        }
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

    static func frame(
        in visible: NSRect,
        preferredHeight: CGFloat = LauncherPanelLayout.windowHeight
    ) -> NSRect {
        TransientPanelPlacement.frame(
            in: visible,
            preferredHeight: preferredHeight,
            preferredWidth: LauncherPanelLayout.windowWidth,
            maximumHeight: LauncherPanelLayout.windowHeight
        )
    }

    static func preferredHeight(
        resultCount: Int,
        actionCount: Int = 0,
        isParameterForm: Bool = false,
        showsRecoveryState: Bool = false
    ) -> CGFloat {
        _ = (resultCount, actionCount, isParameterForm, showsRecoveryState)
        return LauncherPanelLayout.windowHeight
    }

    private var preferredHeight: CGFloat {
        Self.preferredHeight(
            resultCount: viewModel.results.count,
            actionCount: viewModel.layer == .actions ? viewModel.visibleActions.count : 0,
            isParameterForm: viewModel.layer == .parameters,
            showsRecoveryState: viewModel.requiresExpandedEmptyState
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
        TransientPanelPlacement.targetScreen(
            for: panel,
            previousApplication: focusCoordinator.previousApplication
        )
    }

    static func targetDisplayIndex(windowBounds: CGRect, displayBounds: [CGRect]) -> Int? {
        TransientPanelPlacement.targetDisplayIndex(windowBounds: windowBounds, displayBounds: displayBounds)
    }
}

enum LauncherPanelLayout {
    static let windowWidth: CGFloat = 800
    static let windowHeight: CGFloat = 620
    static let headerHeight: CGFloat = 80
    static let footerHeight: CGFloat = 52
    static let quickViewWidth: CGFloat = 260
    static let contentHeight = windowHeight - headerHeight - footerHeight - 2
    static let compactHeight = windowHeight
    static let recoveryHeight = windowHeight
    static let chromeHeight = headerHeight + footerHeight + 2
    static let emptyStateVerticalMargins: CGFloat = 32

    static func availableContentHeight(panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - chromeHeight)
    }
}
