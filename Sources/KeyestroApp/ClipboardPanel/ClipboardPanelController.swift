import AppKit
import Combine
import KeyestroDomain
import SwiftUI

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let panelWindowIdentifier = NSUserInterfaceItemIdentifier("com.keyestro.clipboard-history.panel")

    private let panel: KeyestroTransientPanel
    private let viewModel: ClipboardPanelViewModel
    private let focusCoordinator: TransientPanelFocusCoordinator
    private let presentationCoordinator: TransientPanelCoordinator
    private var presentationPending = false
    private var presentationGeneration: UInt64 = 0
    private var isDismissing = false
    private var resignDismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(
        viewModel: ClipboardPanelViewModel,
        focusCoordinator: TransientPanelFocusCoordinator,
        presentationCoordinator: TransientPanelCoordinator
    ) {
        self.viewModel = viewModel
        self.focusCoordinator = focusCoordinator
        self.presentationCoordinator = presentationCoordinator
        panel = KeyestroTransientPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardPanelLayout.windowWidth,
                height: ClipboardPanelLayout.windowHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        TransientPanelPresentation.configure(panel, identifier: Self.panelWindowIdentifier)
        panel.contentView = ClipboardPanelVisualHost.makeView(model: viewModel)
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
        presentationCoordinator.register(.clipboardHistory) { [weak self] restoringFocus in
            self?.dismiss(restoringFocus: restoringFocus)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { presentationPending || panel.isVisible }
    var frame: NSRect { panel.frame }

    static func clipboardPanelWindowCount() -> Int {
        NSApplication.shared.windows.count { $0.identifier == panelWindowIdentifier }
    }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    func show() {
        guard !isVisible else { return }
        resignDismissTask?.cancel()
        resignDismissTask = nil
        focusCoordinator.captureFrontmostApplication()
        presentationCoordinator.willShow(.clipboardHistory)
        presentationGeneration &+= 1
        let generation = presentationGeneration
        presentationPending = true
        DispatchQueue.main.async { [weak self] in
            self?.present(generation: generation)
        }
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
        presentationCoordinator.didDismiss(.clipboardHistory)
        if restoringFocus { focusCoordinator.restorePreviousApplication() }
        isDismissing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        let generation = presentationGeneration
        resignDismissTask?.cancel()
        resignDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self,
                generation == presentationGeneration,
                panel.isVisible,
                !panel.isKeyWindow,
                !viewModel.isAutoPasting
            else { return }
            dismiss()
        }
    }

    private func present(generation: UInt64) {
        guard presentationPending, generation == presentationGeneration else { return }
        let screen = targetScreen()
        positionPanel(on: screen)
        let context = QueryContext(
            frontmostBundleIdentifier: focusCoordinator.previousApplication?.bundleIdentifier,
            frontmostApplicationName: focusCoordinator.previousApplication?.localizedName,
            frontmostProcessIdentifier: focusCoordinator.previousApplication?.processIdentifier,
            mouseScreenIdentifier: screen.flatMap(TransientPanelPlacement.screenIdentifier)
        )
        viewModel.invoke(context: context)
        TransientPanelPresentation.orderHidden(panel)
        DispatchQueue.main.async { [weak self] in
            self?.reveal(generation: generation)
        }
    }

    private func reveal(generation: UInt64) {
        guard presentationPending,
            generation == presentationGeneration,
            TransientPanelPresentation.reveal(panel)
        else { return }
        presentationPending = false
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

    static func frame(in visible: NSRect) -> NSRect {
        TransientPanelPlacement.frame(
            in: visible,
            preferredHeight: ClipboardPanelLayout.windowHeight,
            preferredWidth: ClipboardPanelLayout.windowWidth,
            maximumHeight: ClipboardPanelLayout.windowHeight
        )
    }

    private func targetScreen() -> NSScreen? {
        TransientPanelPlacement.targetScreen(
            for: panel,
            previousApplication: focusCoordinator.previousApplication
        )
    }

    @objc private func screenParametersChanged() {
        if panel.isVisible { positionPanel(on: targetScreen()) }
    }
}

enum ClipboardPanelLayout {
    static let windowWidth: CGFloat = 800
    static let windowHeight: CGFloat = 620
    static let headerHeight: CGFloat = 72
    static let footerHeight: CGFloat = 52
    static let panelCornerRadius: CGFloat = 24
    static let toolbarHeight: CGFloat = 44
    static let rowHeight: CGFloat = 60
    static let sectionHeaderHeight: CGFloat = 40
    static let quickViewWidth: CGFloat = 320
    static let quickViewHeight: CGFloat = 464
    static let quickViewTop: CGFloat = 140
    static let quickViewTrailing: CGFloat = 16
    static let contentHeight = windowHeight - headerHeight - footerHeight
}

@MainActor
private enum ClipboardPanelVisualHost {
    static func makeView(model: ClipboardPanelViewModel) -> NSView {
        let backdrop = LauncherPanelBackdropView()
        backdrop.setCornerRadius(ClipboardPanelLayout.panelCornerRadius)
        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model))
        backdrop.install(contentView: hosting)
        return backdrop
    }
}
