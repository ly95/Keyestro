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
        TransientPanelPresentation.configure(panel, identifier: Self.panelWindowIdentifier)
        panel.contentView = LauncherPanelVisualHost.makeView(model: viewModel)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.needsDisplay = true
        panel.contentView?.displayIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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

        let context = QueryContext(
            frontmostBundleIdentifier: focusCoordinator.previousApplication?.bundleIdentifier,
            frontmostApplicationName: focusCoordinator.previousApplication?.localizedName,
            frontmostProcessIdentifier: focusCoordinator.previousApplication?.processIdentifier,
            mouseScreenIdentifier: screen.flatMap(TransientPanelPlacement.screenIdentifier)
        )
        // Prepare the refresh state while the window is still invisible. Provider
        // updates only change content; they never drive window placement.
        viewModel.invoke(context: context)

        TransientPanelPresentation.orderHidden(panel)
        recordPresentationSegment(segmentStartedAt.duration(to: .now))
        DispatchQueue.main.async { [weak self] in
            self?.displayPresentation(generation: generation, invokedAt: invokedAt)
        }
    }

    private func displayPresentation(
        generation: UInt64,
        invokedAt: ContinuousClock.Instant
    ) {
        guard presentationIsCurrent(generation), panel.isVisible else { return }
        let segmentStartedAt = ContinuousClock.now
        guard TransientPanelPresentation.reveal(panel) else { return }

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
            Self.frame(in: screen.visibleFrame),
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
    static let windowWidth: CGFloat = 664
    static let windowHeight: CGFloat = 414
    static let headerHeight: CGFloat = 78
    static let footerHeight: CGFloat = 0
    static let quickViewWidth: CGFloat = 0
    static let panelCornerRadius: CGFloat = 28
    static let horizontalInset: CGFloat = 12
    static let searchFieldHeight: CGFloat = 54
    static let searchFieldCornerRadius: CGFloat = 22
    static let resultRowHeight: CGFloat = 66
    static let resultBottomInset: CGFloat = 6
    static let resultContentHorizontalInset: CGFloat = 26
    static let selectionCornerRadius: CGFloat = 14
    static let separatorHorizontalInset: CGFloat = 14
    static let contentHeight = windowHeight - headerHeight
    static let compactHeight = windowHeight
    static let recoveryHeight = windowHeight
    static let chromeHeight = headerHeight
    static let emptyStateVerticalMargins: CGFloat = 32

    static func availableContentHeight(panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - chromeHeight)
    }
}
