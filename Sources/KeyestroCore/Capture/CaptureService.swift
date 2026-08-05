import CoreGraphics
import Foundation
import KeyestroDomain
import ScreenCaptureKit

public struct CaptureDisplayDescriptor: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let appKitFrame: CGRect
    public let captureFrame: CGRect
    public let backingScale: CGFloat

    public init(
        displayID: CGDirectDisplayID,
        appKitFrame: CGRect,
        captureFrame: CGRect,
        backingScale: CGFloat
    ) {
        self.displayID = displayID
        self.appKitFrame = appKitFrame
        self.captureFrame = captureFrame
        self.backingScale = max(1, backingScale)
    }
}

public struct CaptureSegmentPlan: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let sourceRect: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let destinationRect: CGRect

    public init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        destinationRect: CGRect
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.destinationRect = destinationRect
    }
}

public struct CaptureRegionPlan: Equatable, Sendable {
    public let selection: CGRect
    public let outputScale: CGFloat
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let segments: [CaptureSegmentPlan]

    public init(
        selection: CGRect,
        outputScale: CGFloat,
        pixelWidth: Int,
        pixelHeight: Int,
        segments: [CaptureSegmentPlan]
    ) {
        self.selection = selection
        self.outputScale = outputScale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.segments = segments
    }
}

public enum CaptureGeometry {
    /// Converts an AppKit-global (bottom-left) selection into per-display, top-left logical
    /// source rectangles and a common-scale compositing plan.
    public static func plan(
        selection rawSelection: CGRect,
        displays: [CaptureDisplayDescriptor],
        maximumPixels: Int = 100_000_000
    ) throws -> CaptureRegionPlan {
        let selection = rawSelection.standardized.integral
        guard selection.width >= 2, selection.height >= 2 else { throw CaptureError.emptySelection }
        let intersections = displays.compactMap { display -> (CaptureDisplayDescriptor, CGRect)? in
            let intersection = selection.intersection(display.appKitFrame)
            return intersection.isNull || intersection.isEmpty ? nil : (display, intersection)
        }
        guard !intersections.isEmpty else { throw CaptureError.emptySelection }
        let outputScale = intersections.map(\.0.backingScale).max() ?? 1
        let pixelWidth = Int(ceil(selection.width * outputScale))
        let pixelHeight = Int(ceil(selection.height * outputScale))
        guard pixelWidth > 0, pixelHeight > 0,
            pixelWidth <= 32_768,
            pixelHeight <= 32_768,
            pixelWidth <= maximumPixels / pixelHeight
        else { throw CaptureError.tooLarge }

        let segments = intersections.map { display, intersection in
            let localX = intersection.minX - display.appKitFrame.minX
            let localTop = display.appKitFrame.maxY - intersection.maxY
            let source = CGRect(x: localX, y: localTop, width: intersection.width, height: intersection.height)
            let destination = CGRect(
                x: (intersection.minX - selection.minX) * outputScale,
                y: (intersection.minY - selection.minY) * outputScale,
                width: intersection.width * outputScale,
                height: intersection.height * outputScale
            )
            return CaptureSegmentPlan(
                displayID: display.displayID,
                sourceRect: source,
                pixelWidth: max(1, Int(ceil(intersection.width * display.backingScale))),
                pixelHeight: max(1, Int(ceil(intersection.height * display.backingScale))),
                destinationRect: destination
            )
        }
        return CaptureRegionPlan(
            selection: selection,
            outputScale: outputScale,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            segments: segments
        )
    }
}

/// CGImage is an immutable Core Foundation object. The wrapper allows it to cross actor
/// boundaries without exposing mutable pixel storage.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }
}

public enum ScreenCapturePermission: Equatable, Sendable {
    case allowed
    case notDeterminedOrDenied
}

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case emptySelection
    case displayUnavailable
    case captureFailed
    case tooLarge
    case imageCreationFailed

    public var descriptor: ErrorDescriptor {
        switch self {
        case .permissionDenied:
            ErrorDescriptor(
                code: "capture.permissionDenied", message: "Screen Recording access is required.",
                recoverySuggestion:
                    "Allow Keyestro in System Settings → Privacy & Security → Screen Recording. If macOS still reports access as denied, quit and reopen Keyestro."
            )
        case .emptySelection:
            ErrorDescriptor(code: "capture.emptySelection", message: "Drag a region at least 2 × 2 points.")
        case .displayUnavailable:
            ErrorDescriptor(code: "capture.displayUnavailable", message: "A selected display is no longer available.")
        case .captureFailed:
            ErrorDescriptor(code: "capture.failed", message: "The selected region could not be captured.")
        case .tooLarge:
            ErrorDescriptor(code: "capture.tooLarge", message: "The selected region is too large to process safely.")
        case .imageCreationFailed:
            ErrorDescriptor(code: "capture.imageCreationFailed", message: "The captured image could not be assembled.")
        }
    }
}

public protocol CaptureServicing: Sendable {
    func permissionStatus() async -> ScreenCapturePermission
    func requestPermission() async -> Bool
    func capture(
        plan: CaptureRegionPlan,
        excludingApplicationBundleIdentifier: String?
    ) async throws -> CapturedImage
}

public actor MacScreenCaptureService: CaptureServicing {
    public init() {}

    public func permissionStatus() -> ScreenCapturePermission {
        CGPreflightScreenCaptureAccess() ? .allowed : .notDeterminedOrDenied
    }

    public func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func capture(
        plan: CaptureRegionPlan,
        excludingApplicationBundleIdentifier bundleIdentifier: String?
    ) async throws -> CapturedImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.captureFailed
        }
        let displayByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let excludedApplications =
            bundleIdentifier.map { identifier in
                content.applications.filter { $0.bundleIdentifier == identifier }
            } ?? []

        struct SegmentImage: @unchecked Sendable {
            let plan: CaptureSegmentPlan
            let image: CGImage
        }
        var images: [SegmentImage] = []
        for segment in plan.segments {
            try Task.checkCancellation()
            guard let display = displayByID[segment.displayID] else { throw CaptureError.displayUnavailable }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = segment.sourceRect
            configuration.width = segment.pixelWidth
            configuration.height = segment.pixelHeight
            configuration.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                try Task.checkCancellation()
                images.append(SegmentImage(plan: segment, image: image))
            } catch {
                throw CaptureError.captureFailed
            }
        }
        try Task.checkCancellation()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: plan.pixelWidth,
                height: plan.pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.imageCreationFailed }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
        for segment in images {
            context.draw(segment.image, in: segment.plan.destinationRect)
        }
        guard let result = context.makeImage() else { throw CaptureError.imageCreationFailed }
        return CapturedImage(result)
    }
}
