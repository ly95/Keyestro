import Foundation

/// SwiftUI's off-screen AppKit renderer can schedule AttributeGraph work beyond
/// an individual layout pass. Keep component stories deterministic by allowing
/// only one story to mutate and render a graph at a time.
@MainActor
enum ComponentStorySerialization {
    private static var isAvailable = true
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    static func release() {
        guard !waiters.isEmpty else {
            isAvailable = true
            return
        }
        waiters.removeFirst().resume()
    }
}
