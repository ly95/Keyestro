import CoreGraphics
import CoreText
import Foundation
import KeyestroCore
import Testing

@Test func capturePlanHandlesMixedScaleAndNegativeDisplayCoordinates() throws {
    let displays = [
        CaptureDisplayDescriptor(
            displayID: 1,
            appKitFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            captureFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            backingScale: 1
        ),
        CaptureDisplayDescriptor(
            displayID: 2,
            appKitFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            captureFrame: CGRect(x: -1_440, y: 180, width: 1_440, height: 900),
            backingScale: 2
        ),
    ]
    let plan = try CaptureGeometry.plan(
        selection: CGRect(x: -100, y: 100, width: 200, height: 100),
        displays: displays
    )
    #expect(plan.outputScale == 2)
    #expect(plan.pixelWidth == 400)
    #expect(plan.pixelHeight == 200)
    #expect(plan.segments.count == 2)

    let left = try #require(plan.segments.first(where: { $0.displayID == 2 }))
    #expect(left.sourceRect == CGRect(x: 1_340, y: 700, width: 100, height: 100))
    #expect(left.pixelWidth == 200)
    #expect(left.destinationRect == CGRect(x: 0, y: 0, width: 200, height: 200))

    let primary = try #require(plan.segments.first(where: { $0.displayID == 1 }))
    #expect(primary.sourceRect == CGRect(x: 0, y: 880, width: 100, height: 100))
    #expect(primary.pixelWidth == 100)
    #expect(primary.destinationRect == CGRect(x: 200, y: 0, width: 200, height: 200))
}

@Test func capturePlanRejectsEmptyAndUnboundedSelections() {
    let display = CaptureDisplayDescriptor(
        displayID: 1,
        appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        captureFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        backingScale: 2
    )
    #expect(throws: CaptureError.emptySelection) {
        try CaptureGeometry.plan(selection: CGRect(x: 10, y: 10, width: 1, height: 1), displays: [display])
    }
    #expect(throws: CaptureError.tooLarge) {
        try CaptureGeometry.plan(
            selection: CGRect(x: 0, y: 0, width: 10_000, height: 10_000),
            displays: [
                CaptureDisplayDescriptor(
                    displayID: 1,
                    appKitFrame: CGRect(x: 0, y: 0, width: 10_000, height: 10_000),
                    captureFrame: CGRect(x: 0, y: 0, width: 10_000, height: 10_000),
                    backingScale: 2
                )
            ]
        )
    }
}

@Test func visionOCRRecognizesSyntheticTextLocally() async throws {
    let width = 1_200
    let height = 300
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributed = NSAttributedString(
        string: "KEYESTRO LOCAL OCR",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 92, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 70, y: 105)
    CTLineDraw(line, context)
    let image = try #require(context.makeImage())

    let service = LocalVisionOCRService()
    let result = try await service.recognize(image: CapturedImage(image), languages: ["en-US"], accurate: true)
    #expect(result.fullText.uppercased().contains("KEYESTRO"))
    #expect(result.fullText.uppercased().contains("OCR"))
}
