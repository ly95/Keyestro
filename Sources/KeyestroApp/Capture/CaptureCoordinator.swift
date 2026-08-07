import AppKit
import ImageIO
import KeyestroCore
import KeyestroDomain
import UniformTypeIdentifiers

enum CaptureOperation: String, Sendable {
    case copyImage
    case savePNG
    case recognizeText
}

@MainActor
final class CaptureCoordinator {
    var onWillSelect: (() -> Void)?

    private let captureService: any CaptureServicing
    private let ocrService: any OCRServicing
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let pasteboard: any PasteboardServicing
    private let clock: any ClockServicing
    private let selectionDelay: Duration
    private let exclusionBundleIdentifier: String?
    private let makeSelector: @MainActor () -> any CaptureRegionSelecting
    private let ocrResultHandler: (@MainActor (OCRResult) -> Void)?
    private var resultWindows: [OCRResultWindowController] = []
    private weak var activeSavePanel: NSSavePanel?

    init(
        captureService: any CaptureServicing,
        ocrService: any OCRServicing,
        settings: SettingsStore,
        defaults: UserDefaults = .standard,
        pasteboard: any PasteboardServicing = MacPasteboardService(),
        clock: any ClockServicing = SystemClockService(),
        selectionDelay: Duration = .milliseconds(160),
        exclusionBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        makeSelector: @escaping @MainActor () -> any CaptureRegionSelecting = { CaptureSelectionController() },
        ocrResultHandler: (@MainActor (OCRResult) -> Void)? = nil
    ) {
        self.captureService = captureService
        self.ocrService = ocrService
        self.settings = settings
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.clock = clock
        self.selectionDelay = min(max(.zero, selectionDelay), .seconds(1))
        self.exclusionBundleIdentifier = exclusionBundleIdentifier
        self.makeSelector = makeSelector
        self.ocrResultHandler = ocrResultHandler
    }

    func perform(_ operation: CaptureOperation) async -> ActionResult {
        let permission = await captureService.permissionStatus()
        if permission != .allowed {
            let promptKey = "capture.screenRecordingPromptAttempted"
            guard !defaults.bool(forKey: promptKey) else {
                return .failure(CaptureError.permissionDenied.descriptor)
            }
            defaults.set(true, forKey: promptKey)
            guard await captureService.requestPermission() else {
                return .failure(CaptureError.permissionDenied.descriptor)
            }
        }

        onWillSelect?()
        if selectionDelay > .zero {
            do {
                try await clock.sleep(for: selectionDelay)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(
                    ErrorDescriptor(code: "capture.delayFailed", message: "The capture operation could not start.")
                )
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        let selector = makeSelector()
        let selectedRegion = await withTaskCancellationHandler {
            await selector.selectRegion()
        } onCancel: {
            Task { @MainActor in selector.cancelSelection() }
        }
        guard let (selection, displays) = selectedRegion else { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        do {
            let plan = try CaptureGeometry.plan(selection: selection, displays: displays)
            let image = try await captureService.capture(
                plan: plan,
                excludingApplicationBundleIdentifier: exclusionBundleIdentifier
            )
            try Task.checkCancellation()
            switch operation {
            case .copyImage:
                try await copyImage(image)
                return .success(message: "Screenshot copied")
            case .savePNG:
                guard let destination = await chooseSaveURL() else { return .cancelled }
                let data = try await Task.detached(priority: .userInitiated) {
                    try Self.pngData(image)
                }.value
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: destination, options: [.atomic])
                }.value
                // Once the atomic file commit starts it is intentionally non-cancellable: a saved file is reported as success.
                return .success(message: "Screenshot saved")
            case .recognizeText:
                let result = try await ocrService.recognize(
                    image: image,
                    languages: settings.ocrRecognitionLanguages,
                    accurate: true
                )
                try Task.checkCancellation()
                if let ocrResultHandler {
                    ocrResultHandler(result)
                } else {
                    showOCRResult(result)
                }
                return .success(message: "Text recognition complete")
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as CaptureError {
            return .failure(error.descriptor)
        } catch is OCRError {
            return .failure(ErrorDescriptor(code: "ocr.failed", message: "Text could not be recognized in the selected image."))
        } catch {
            return .failure(ErrorDescriptor(code: "capture.failed", message: "The capture operation failed."))
        }
    }

    private func copyImage(_ image: CapturedImage) async throws {
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.pngData(image)
        }.value
        try Task.checkCancellation()
        guard pasteboard.write(.imagePNG(data)) else { throw CaptureError.captureFailed }
    }

    private func chooseSaveURL() async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let panel = NSSavePanel()
                activeSavePanel = panel
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue =
                    "Keyestro Capture \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png"
                panel.begin { [weak self] response in
                    self?.activeSavePanel = nil
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.activeSavePanel?.cancel(nil) }
        }
    }

    private func showOCRResult(_ result: OCRResult) {
        let controller = OCRResultWindowController(result: result, pasteboard: pasteboard) { [weak self] controller in
            self?.resultWindows.removeAll { $0 === controller }
        }
        resultWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    nonisolated private static func pngData(_ image: CapturedImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw CaptureError.imageCreationFailed }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.imageCreationFailed }
        return data as Data
    }
}

@MainActor
private final class OCRResultWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: (OCRResultWindowController) -> Void
    private let pasteboard: any PasteboardServicing
    private let textView = NSTextView()

    init(
        result: OCRResult,
        pasteboard: any PasteboardServicing,
        onClose: @escaping (OCRResultWindowController) -> Void
    ) {
        self.onClose = onClose
        self.pasteboard = pasteboard
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Recognized Text")
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 64, width: 580, height: 350))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.string = result.fullText
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.setAccessibilityLabel(L10n.text("Recognized Text"))
        scroll.documentView = textView
        content.addSubview(scroll)
        let copy = NSButton(title: L10n.text("Copy Text"), target: nil, action: nil)
        copy.frame = NSRect(x: 500, y: 20, width: 100, height: 30)
        copy.bezelStyle = .rounded
        content.addSubview(copy)
        let note = NSTextField(
            labelWithString: result.lines.contains(where: { $0.confidence < 0.5 })
                ? L10n.text("Review highlighted-quality output before copying; low-confidence text is never inserted automatically.")
                : L10n.text("Review the local Vision result before copying."))
        note.frame = NSRect(x: 20, y: 24, width: 460, height: 20)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        content.addSubview(note)
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        copy.target = self
        copy.action = #selector(copyText)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func copyText() {
        _ = pasteboard.write(.text(textView.string))
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }
}
