import AppKit
import Foundation
import ImageIO
import KeyestroDomain

public protocol PasteboardServicing: Sendable {
    @MainActor var changeCount: Int { get }
    @MainActor func readSupportedContent() -> ClipboardContent?
    @MainActor func readSupportedContentResult() -> Result<ClipboardContent?, ErrorDescriptor>
    @MainActor func write(_ content: ClipboardContent) -> Bool
}

extension PasteboardServicing {
    @MainActor
    public func readSupportedContentResult() -> Result<ClipboardContent?, ErrorDescriptor> {
        .success(readSupportedContent())
    }
}

public struct MacPasteboardService: PasteboardServicing, Sendable {
    public init() {}

    @MainActor
    public var changeCount: Int { NSPasteboard.general.changeCount }

    @MainActor
    public func readSupportedContent() -> ClipboardContent? {
        switch readSupportedContentResult() {
        case let .success(content): content
        case .failure: nil
        }
    }

    @MainActor
    public func readSupportedContentResult() -> Result<ClipboardContent?, ErrorDescriptor> {
        let pasteboard = NSPasteboard.general
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [NSURL],
            !objects.isEmpty
        {
            return .success(.files(objects.map { ($0 as URL).standardizedFileURL }))
        }
        if let png = pasteboard.data(forType: .png) {
            return .success(.imagePNG(png))
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            guard tiff.count <= 25 * 1_024 * 1_024 else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.imageTooLarge",
                        message: "This clipboard image exceeds the 25 MiB limit."
                    )
                )
            }
            guard Self.hasBoundedPixelCount(tiff),
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.invalidImage",
                        message: "The clipboard image is invalid or exceeds 100 megapixels."
                    )
                )
            }
            guard png.count <= 25 * 1_024 * 1_024 else {
                return .failure(
                    ErrorDescriptor(
                        code: "clipboard.imageTooLarge",
                        message: "This clipboard image exceeds the 25 MiB limit."
                    )
                )
            }
            return .success(.imagePNG(png))
        }
        if let value = pasteboard.string(forType: .URL), let url = URL(string: value) {
            return .success(.url(url))
        }
        if let value = pasteboard.string(forType: .string) {
            if let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty {
                return .success(.url(url))
            }
            return .success(.text(value))
        }
        return .success(nil)
    }

    @MainActor
    public func write(_ content: ClipboardContent) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content {
        case let .text(text):
            return pasteboard.setString(text, forType: .string)
        case let .url(url):
            return pasteboard.writeObjects([url as NSURL])
        case let .files(urls):
            return pasteboard.writeObjects(urls.map { $0 as NSURL })
        case let .imagePNG(data):
            return pasteboard.setData(data, forType: .png)
        }
    }

    private static func hasBoundedPixelCount(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.int64Value > 0,
            height.int64Value > 0,
            width.int64Value <= 100_000_000 / height.int64Value
        else { return false }
        return true
    }
}
