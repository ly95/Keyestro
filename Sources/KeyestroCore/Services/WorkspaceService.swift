import AppKit
import Foundation

public protocol WorkspaceServicing: Sendable {
    @MainActor func openApplication(at url: URL, bundleIdentifier: String?) async throws
    @MainActor func reveal(_ url: URL)
    @MainActor func copyText(_ value: String)
}

public struct MacWorkspaceService: WorkspaceServicing, Sendable {
    public init() {}

    @MainActor
    public func openApplication(at url: URL, bundleIdentifier: String?) async throws {
        if let bundleIdentifier,
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        {
            running.activate()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @MainActor
    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    public func copyText(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
