import AppKit
import KeyestroCore
import KeyestroDomain
import Testing
@testable import KeyestroApp

@Test @MainActor func capturePermissionIsJustInTimePromptedOnceAndRecoversAfterExternalGrant() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = RecordingCaptureService(permission: .notDeterminedOrDenied, permissionRequestResult: false)
    let selector = StubCaptureSelector(result: nil)
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        selectionDelay: .zero,
        makeSelector: { selector }
    )

    var snapshot = await capture.snapshot()
    #expect(snapshot.permissionRequests == 0)
    #expect(await coordinator.perform(.copyImage) == .failure(CaptureError.permissionDenied.descriptor))
    #expect(await coordinator.perform(.copyImage) == .failure(CaptureError.permissionDenied.descriptor))
    snapshot = await capture.snapshot()
    #expect(snapshot.permissionRequests == 1)
    #expect(snapshot.captures == 0)
    #expect(selector.selectionRequests == 0)

    await capture.setPermission(.allowed)
    #expect(await coordinator.perform(.copyImage) == .cancelled)
    snapshot = await capture.snapshot()
    #expect(snapshot.permissionRequests == 1)
    #expect(selector.selectionRequests == 1)
}

@Test @MainActor func captureForwardsSelfExclusionAndWritesOnlyThroughPasteboardBoundary() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let display = CaptureDisplayDescriptor(
        displayID: 42,
        appKitFrame: CGRect(x: -200, y: 0, width: 400, height: 300),
        captureFrame: CGRect(x: -200, y: 0, width: 400, height: 300),
        backingScale: 2
    )
    let selector = StubCaptureSelector(
        result: (CGRect(x: -100, y: 50, width: 80, height: 40), [display])
    )
    let capture = RecordingCaptureService(permission: .allowed, image: try makeCaptureImage())
    let pasteboard = RecordingCapturePasteboard()
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        pasteboard: pasteboard,
        selectionDelay: .zero,
        exclusionBundleIdentifier: "com.keyestro.tests.capture",
        makeSelector: { selector }
    )
    var willSelectCount = 0
    coordinator.onWillSelect = { willSelectCount += 1 }

    let result = await coordinator.perform(.copyImage)
    let snapshot = await capture.snapshot()

    #expect(result == .success(message: "Screenshot copied"))
    #expect(willSelectCount == 1)
    #expect(snapshot.permissionRequests == 0)
    #expect(snapshot.captures == 1)
    #expect(snapshot.excludedBundleIdentifier == "com.keyestro.tests.capture")
    #expect(snapshot.plan?.pixelWidth == 160)
    #expect(snapshot.plan?.pixelHeight == 80)
    #expect(pasteboard.pngWrites == 1)
    #expect(pasteboard.lastPNGByteCount > 0)
}

@Test @MainActor func cancellingCaptureLeavesNoImageOrCaptureWorkBehind() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let selector = StubCaptureSelector(result: nil)
    let capture = RecordingCaptureService(permission: .allowed)
    let pasteboard = RecordingCapturePasteboard()
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        pasteboard: pasteboard,
        selectionDelay: .zero,
        makeSelector: { selector }
    )

    #expect(await coordinator.perform(.copyImage) == .cancelled)
    let snapshot = await capture.snapshot()
    #expect(snapshot.captures == 0)
    #expect(pasteboard.pngWrites == 0)
    #expect(selector.selectionRequests == 1)
}

@Test @MainActor func taskCancellationDuringCaptureDelayNeverStartsSelectionOrCapture() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let selector = StubCaptureSelector(result: nil)
    let capture = RecordingCaptureService(permission: .allowed)
    let pasteboard = RecordingCapturePasteboard()
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        pasteboard: pasteboard,
        selectionDelay: .seconds(1),
        makeSelector: { selector }
    )
    var reachedDelay = false
    coordinator.onWillSelect = { reachedDelay = true }

    let operation = Task { await coordinator.perform(.copyImage) }
    for _ in 0..<1_000 where !reachedDelay { await Task.yield() }
    #expect(reachedDelay)
    operation.cancel()

    #expect(await operation.value == .cancelled)
    #expect(selector.selectionRequests == 0)
    #expect((await capture.snapshot()).captures == 0)
    #expect(pasteboard.pngWrites == 0)
}

@Test @MainActor func taskCancellationClosesAnActiveCaptureSelection() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let selector = BlockingCaptureSelector()
    let capture = RecordingCaptureService(permission: .allowed)
    let pasteboard = RecordingCapturePasteboard()
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        pasteboard: pasteboard,
        selectionDelay: .zero,
        makeSelector: { selector }
    )

    let operation = Task { await coordinator.perform(.copyImage) }
    for _ in 0..<1_000 where !selector.isSelecting { await Task.yield() }
    #expect(selector.isSelecting)
    operation.cancel()

    #expect(await operation.value == .cancelled)
    #expect(selector.cancellationCount == 1)
    #expect(!selector.isSelecting)
    #expect((await capture.snapshot()).captures == 0)
    #expect(pasteboard.pngWrites == 0)
}

@Test @MainActor func captureOCRUsesAccurateLocalLanguageSelectionWithoutAutomaticPaste() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let display = CaptureDisplayDescriptor(
        displayID: 7,
        appKitFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
        captureFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
        backingScale: 1
    )
    let selector = StubCaptureSelector(result: (CGRect(x: 10, y: 10, width: 80, height: 40), [display]))
    let capture = RecordingCaptureService(permission: .allowed, image: try makeCaptureImage())
    let pasteboard = RecordingCapturePasteboard()
    let expectedResult = OCRResult(
        lines: [OCRTextLine(text: "low confidence 文本", confidence: 0.2, boundingBox: .zero)]
    )
    let ocr = RecordingOCRService(result: expectedResult)
    var presentedResult: OCRResult?
    let coordinator = CaptureCoordinator(
        captureService: capture,
        ocrService: ocr,
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        pasteboard: pasteboard,
        selectionDelay: .zero,
        makeSelector: { selector },
        ocrResultHandler: { presentedResult = $0 }
    )

    #expect(await coordinator.perform(.recognizeText) == .success(message: "Text recognition complete"))
    let ocrSnapshot = await ocr.snapshot()
    #expect(ocrSnapshot.calls == 1)
    #expect(ocrSnapshot.languages == ["en-US", "zh-Hans"])
    #expect(ocrSnapshot.accurate)
    #expect(presentedResult == expectedResult)
    #expect(pasteboard.pngWrites == 0)
}

@Test @MainActor func captureProviderPublishesFiltersAndRoutesEveryCommandSafely() async throws {
    let (defaults, suiteName) = try captureDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = CaptureCoordinator(
        captureService: RecordingCaptureService(permission: .notDeterminedOrDenied),
        ocrService: StubOCRService(),
        settings: SettingsStore(defaults: defaults),
        defaults: defaults,
        selectionDelay: .zero,
        makeSelector: { StubCaptureSelector(result: nil) }
    )
    let provider = CaptureProvider(coordinator: coordinator)

    let allItems = try await captureProviderItems(provider, query: "")
    #expect(allItems.count == 3)
    #expect(Set(allItems.map(\.id.providerStableID)) == Set(CaptureOperation.allCoverageRawValues))
    #expect(try await captureProviderItems(provider, query: "recognize").map(\.id.providerStableID) == ["recognizeText"])
    #expect(try await captureProviderItems(provider, query: "no-capture-command").isEmpty)

    let invalid = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: CaptureProvider.providerID, providerStableID: "unknown"),
            actionID: "wrong",
            arguments: [:]
        )
    )
    #expect(invalid == .failure(ErrorDescriptor(code: "capture.invalidAction", message: "The capture action is unavailable.")))

    let denied = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: CaptureProvider.providerID, providerStableID: CaptureOperation.copyImage.rawValue),
            actionID: "run",
            arguments: [:]
        )
    )
    #expect(denied == .failure(CaptureError.permissionDenied.descriptor))
}

@Test @MainActor func captureSelectionComponentExercisesPresentationDrawingAndInput() async throws {
    await ComponentStorySerialization.acquire()
    defer { ComponentStorySerialization.release() }

    #expect(await CaptureSelectionController(screensOverride: []).selectRegion() == nil)
    let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
    let controller = CaptureSelectionController()
    let selectionTask = Task { await controller.selectRegion() }
    for _ in 0..<1_000 where !controller.isSelecting { await Task.yield() }
    #expect(controller.isSelecting)
    #expect(!controller.overlayWindows.isEmpty)
    #expect(await controller.selectRegion() == nil)

    let start = CGPoint(x: screen.frame.midX - 20, y: screen.frame.midY - 10)
    let end = CGPoint(x: start.x + 40, y: start.y + 20)
    controller.update(to: end)
    controller.begin(at: start)
    controller.update(to: end)
    controller.finishDragging(at: end)
    controller.confirm()
    let completed = try #require(await selectionTask.value)
    #expect(completed.0.width == 40)
    #expect(completed.0.height == 20)
    #expect(!controller.isSelecting)

    let cancellationTask = Task { await controller.selectRegion() }
    for _ in 0..<1_000 where !controller.isSelecting { await Task.yield() }
    controller.cancelSelection()
    #expect(await cancellationTask.value == nil)
    controller.cancel()

    let overlay = CaptureOverlayWindow(screen: screen, controller: controller)
    #expect(overlay.canBecomeKey)
    let view = try #require(overlay.contentView as? CaptureSelectionView)
    view.frame = CGRect(x: 0, y: 0, width: 240, height: 140)
    #expect(view.acceptsFirstResponder)
    renderCaptureSelection(view)
    controller.begin(at: screen.frame.origin)
    controller.update(to: CGPoint(x: screen.frame.minX + 80, y: screen.frame.minY + 40))
    renderCaptureSelection(view)

    let mouse = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: overlay.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    )
    view.mouseDown(with: mouse)
    view.mouseDragged(with: mouse)
    view.mouseUp(with: mouse)

    controller.begin(at: .zero)
    controller.update(to: CGPoint(x: 20, y: 20))
    view.keyDown(with: try captureKeyEvent(keyCode: 36, characters: "\r"))
    view.keyDown(with: try captureKeyEvent(keyCode: 53, characters: "\u{1b}"))
    view.keyDown(with: try captureKeyEvent(keyCode: 0, characters: "a"))

    let archive = try NSKeyedArchiver.archivedData(withRootObject: "capture", requiringSecureCoding: false)
    let coder = try NSKeyedUnarchiver(forReadingFrom: archive)
    #expect(CaptureSelectionView(coder: coder) == nil)
    coder.finishDecoding()
    overlay.orderOut(nil)
}

@MainActor
private func renderCaptureSelection(_ view: CaptureSelectionView) {
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    if let bitmap { view.cacheDisplay(in: view.bounds, to: bitmap) }
}

private func captureKeyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}

private extension CaptureOperation {
    static let allCoverageRawValues = [copyImage, savePNG, recognizeText].map(\.rawValue)
}

private func captureProviderItems(_ provider: CaptureProvider, query: String) async throws -> [LauncherItem] {
    let request = QueryRequest(generation: 1, rawText: query, normalizedText: query, mode: .commands)
    for try await event in provider.search(request: request) {
        if case let .items(items, true) = event { return items }
    }
    return []
}

@MainActor
private final class StubCaptureSelector: CaptureRegionSelecting {
    let result: (CGRect, [CaptureDisplayDescriptor])?
    private(set) var selectionRequests = 0

    init(result: (CGRect, [CaptureDisplayDescriptor])?) {
        self.result = result
    }

    func selectRegion() async -> (CGRect, [CaptureDisplayDescriptor])? {
        selectionRequests += 1
        return result
    }

    func cancelSelection() {}
}

@MainActor
private final class BlockingCaptureSelector: CaptureRegionSelecting {
    private var continuation: CheckedContinuation<(CGRect, [CaptureDisplayDescriptor])?, Never>?
    private(set) var cancellationCount = 0
    var isSelecting: Bool { continuation != nil }

    func selectRegion() async -> (CGRect, [CaptureDisplayDescriptor])? {
        await withCheckedContinuation { continuation = $0 }
    }

    func cancelSelection() {
        guard let continuation else { return }
        self.continuation = nil
        cancellationCount += 1
        continuation.resume(returning: nil)
    }
}

private actor RecordingCaptureService: CaptureServicing {
    struct Snapshot: Sendable {
        let permissionRequests: Int
        let captures: Int
        let excludedBundleIdentifier: String?
        let plan: CaptureRegionPlan?
    }

    private var permission: ScreenCapturePermission
    private let permissionRequestResult: Bool
    private let image: CapturedImage?
    private var permissionRequests = 0
    private var captures = 0
    private var excludedBundleIdentifier: String?
    private var plan: CaptureRegionPlan?

    init(
        permission: ScreenCapturePermission,
        permissionRequestResult: Bool = false,
        image: CapturedImage? = nil
    ) {
        self.permission = permission
        self.permissionRequestResult = permissionRequestResult
        self.image = image
    }

    func permissionStatus() -> ScreenCapturePermission { permission }

    func requestPermission() -> Bool {
        permissionRequests += 1
        if permissionRequestResult { permission = .allowed }
        return permissionRequestResult
    }

    func capture(
        plan: CaptureRegionPlan,
        excludingApplicationBundleIdentifier: String?
    ) throws -> CapturedImage {
        captures += 1
        self.plan = plan
        excludedBundleIdentifier = excludingApplicationBundleIdentifier
        guard let image else { throw CaptureError.captureFailed }
        return image
    }

    func setPermission(_ permission: ScreenCapturePermission) {
        self.permission = permission
    }

    func snapshot() -> Snapshot {
        Snapshot(
            permissionRequests: permissionRequests,
            captures: captures,
            excludedBundleIdentifier: excludedBundleIdentifier,
            plan: plan
        )
    }
}

private actor StubOCRService: OCRServicing {
    func supportedLanguages() -> [String] { ["en-US", "zh-Hans"] }

    func recognize(
        image: CapturedImage,
        languages: [String],
        accurate: Bool
    ) throws -> OCRResult {
        OCRResult(lines: [])
    }
}

private actor RecordingOCRService: OCRServicing {
    struct Snapshot: Sendable {
        let calls: Int
        let languages: [String]
        let accurate: Bool
    }

    private let result: OCRResult
    private var calls = 0
    private var languages: [String] = []
    private var accurate = false

    init(result: OCRResult) {
        self.result = result
    }

    func supportedLanguages() -> [String] { ["en-US", "zh-Hans"] }

    func recognize(
        image: CapturedImage,
        languages: [String],
        accurate: Bool
    ) -> OCRResult {
        calls += 1
        self.languages = languages
        self.accurate = accurate
        return result
    }

    func snapshot() -> Snapshot {
        Snapshot(calls: calls, languages: languages, accurate: accurate)
    }
}

@MainActor
private final class RecordingCapturePasteboard: PasteboardServicing {
    var changeCount = 0
    private(set) var pngWrites = 0
    private(set) var lastPNGByteCount = 0

    func readSupportedContent() -> ClipboardContent? { nil }

    func write(_ content: ClipboardContent) -> Bool {
        guard case let .imagePNG(data) = content else { return false }
        pngWrites += 1
        lastPNGByteCount = data.count
        changeCount += 1
        return true
    }
}

@MainActor
private func captureDefaults() throws -> (UserDefaults, String) {
    let suiteName = "com.keyestro.capture-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func makeCaptureImage() throws -> CapturedImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return CapturedImage(try #require(context.makeImage()))
}
