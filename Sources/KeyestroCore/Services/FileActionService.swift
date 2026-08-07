import AppKit
import Foundation
@preconcurrency import QuickLookUI

public protocol FileActionServicing: Sendable {
    @MainActor func open(_ url: URL) -> Bool
    @MainActor func reveal(_ url: URL)
    @MainActor func copy(_ value: String)
    @MainActor func preview(_ url: URL) -> Bool
}

@MainActor
public final class MacFileActionService: NSObject, FileActionServicing,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate
{
    public var onPreviewWillOpen: (() -> Void)?
    public var onPreviewDidClose: (() -> Void)?
    private var previewItems: [PreviewItem] = []
    private let pasteboard: any PasteboardServicing

    public init(pasteboard: any PasteboardServicing = MacPasteboardService()) {
        self.pasteboard = pasteboard
        super.init()
    }

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func copy(_ value: String) {
        _ = pasteboard.write(.text(value))
    }

    public func preview(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let panel = QLPreviewPanel.shared() else {
            return false
        }
        previewItems = [PreviewItem(url: url)]
        onPreviewWillOpen?()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index]
    }

    public func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        previewItems = []
        onPreviewDidClose?()
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        previewItemURL = url
    }
}
