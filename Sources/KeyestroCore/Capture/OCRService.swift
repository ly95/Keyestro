import CoreGraphics
import Foundation
import Vision

public struct OCRTextLine: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct OCRResult: Equatable, Sendable {
    public let lines: [OCRTextLine]

    public init(lines: [OCRTextLine]) {
        self.lines = lines
    }

    public var fullText: String { lines.map(\.text).joined(separator: "\n") }
    public var highConfidenceText: String {
        lines.filter { $0.confidence >= 0.5 }.map(\.text).joined(separator: "\n")
    }
}

public enum OCRError: Error, Equatable, Sendable {
    case imageTooLarge
    case imageConversionFailed
    case recognitionFailed
}

public protocol OCRServicing: Sendable {
    func supportedLanguages() async -> [String]
    func recognize(
        image: CapturedImage,
        languages: [String],
        accurate: Bool
    ) async throws -> OCRResult
}

public actor LocalVisionOCRService: OCRServicing {
    public static let maximumInputPixels = 100_000_000
    public static let processingPixels = 20_000_000

    public init() {}

    public func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    public func recognize(
        image: CapturedImage,
        languages: [String] = ["en-US", "zh-Hans"],
        accurate: Bool = true
    ) async throws -> OCRResult {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0,
            image.width <= Self.maximumInputPixels / image.height
        else { throw OCRError.imageTooLarge }
        let prepared = try Self.downscaledIfNeeded(image.cgImage, maximumPixels: Self.processingPixels)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let selected = languages.filter(supported.contains)
        if selected.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = selected
        }
        let handler = VNImageRequestHandler(cgImage: prepared, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OCRError.recognitionFailed
        }
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let verticalDelta = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(verticalDelta) > 0.02 { return verticalDelta > 0 }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let lines = observations.compactMap { observation -> OCRTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextLine(
                text: candidate.string.limitedToUnicodeScalars(16_384),
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
        return OCRResult(lines: lines)
    }

    private static func downscaledIfNeeded(_ image: CGImage, maximumPixels: Int) throws -> CGImage {
        let pixels = image.width * image.height
        guard pixels > maximumPixels else { return image }
        let ratio = sqrt(Double(maximumPixels) / Double(pixels))
        let width = max(1, Int(Double(image.width) * ratio))
        let height = max(1, Int(Double(image.height) * ratio))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw OCRError.imageConversionFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw OCRError.imageConversionFailed }
        return result
    }
}
