import AppKit
import KeyestroCore

@MainActor
protocol CaptureRegionSelecting: AnyObject, Sendable {
    func selectRegion() async -> (CGRect, [CaptureDisplayDescriptor])?
    func cancelSelection()
}

@MainActor
final class CaptureSelectionController: CaptureRegionSelecting {
    private var windows: [CaptureOverlayWindow] = []
    private var continuation: CheckedContinuation<(CGRect, [CaptureDisplayDescriptor])?, Never>?
    private var anchor: CGPoint?
    private(set) var selection: CGRect?

    func selectRegion() async -> (CGRect, [CaptureDisplayDescriptor])? {
        guard continuation == nil else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        windows = screens.map { screen in
            let window = CaptureOverlayWindow(screen: screen, controller: self)
            window.orderFrontRegardless()
            return window
        }
        NSApplication.shared.activate()
        windows.first?.makeKey()
        NSCursor.crosshair.push()
        return await withCheckedContinuation { continuation = $0 }
    }

    func begin(at globalPoint: CGPoint) {
        anchor = globalPoint
        selection = CGRect(origin: globalPoint, size: .zero)
        redraw()
    }

    func update(to globalPoint: CGPoint) {
        guard let anchor else { return }
        selection = CGRect(
            x: min(anchor.x, globalPoint.x),
            y: min(anchor.y, globalPoint.y),
            width: abs(globalPoint.x - anchor.x),
            height: abs(globalPoint.y - anchor.y)
        )
        redraw()
    }

    func finishDragging(at globalPoint: CGPoint) {
        update(to: globalPoint)
        anchor = nil
    }

    func confirm() {
        guard let selection = selection?.standardized, selection.width >= 2, selection.height >= 2 else {
            NSSound.beep()
            return
        }
        let descriptors = windows.compactMap(\.displayDescriptor)
        complete((selection, descriptors))
    }

    func cancel() {
        complete(nil)
    }

    func cancelSelection() {
        cancel()
    }

    private func complete(_ result: (CGRect, [CaptureDisplayDescriptor])?) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        anchor = nil
        selection = nil
        NSCursor.pop()
        continuation.resume(returning: result)
    }

    private func redraw() {
        windows.forEach { $0.contentView?.needsDisplay = true }
    }
}

@MainActor
final class CaptureOverlayWindow: NSWindow {
    let displayDescriptor: CaptureDisplayDescriptor?

    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, controller: CaptureSelectionController) {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        if let displayID {
            displayDescriptor = CaptureDisplayDescriptor(
                displayID: displayID,
                appKitFrame: screen.frame,
                captureFrame: CGDisplayBounds(displayID),
                backingScale: screen.backingScaleFactor
            )
        } else {
            displayDescriptor = nil
        }
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        contentView = CaptureSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), controller: controller)
    }
}

@MainActor
private final class CaptureSelectionView: NSView {
    private weak var controller: CaptureSelectionController?

    init(frame: NSRect, controller: CaptureSelectionController) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityLabel(L10n.text("Screen capture region selector"))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.begin(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.update(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.finishDragging(at: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel()
        case 36, 76: controller?.confirm()
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dimPath = NSBezierPath(rect: bounds)
        if let globalSelection = controller?.selection, let window {
            let localOrigin = window.convertPoint(fromScreen: globalSelection.origin)
            let localSelection = CGRect(origin: localOrigin, size: globalSelection.size).intersection(bounds)
            if !localSelection.isNull { dimPath.appendRect(localSelection) }
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            dimPath.fill()
            if !localSelection.isNull {
                let border = NSBezierPath(rect: localSelection.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                border.stroke()
                drawSize(localSelection.size, near: localSelection)
            }
        } else {
            NSColor.black.withAlphaComponent(0.42).setFill()
            bounds.fill()
        }
        drawInstructions()
    }

    private func drawInstructions() {
        let text = L10n.text("capture.selection.instructions")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72),
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 28),
            withAttributes: attributes
        )
    }

    private func drawSize(_ size: CGSize, near rect: CGRect) {
        let text = "\(Int(size.width)) × \(Int(size.height)) pt"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.75),
        ]
        text.draw(at: CGPoint(x: rect.minX + 5, y: max(4, rect.minY - 22)), withAttributes: attributes)
    }
}
