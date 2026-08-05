import Foundation
import KeyestroDomain

public struct WindowProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "windows",
        displayName: "Windows",
        supportedModes: [.all, .commands],
        supportsEmptyQuery: false
    )
    private let accessibility: any AccessibilityServicing

    public init(accessibility: any AccessibilityServicing) {
        self.accessibility = accessibility
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let task = Task {
            guard !request.normalizedText.isEmpty else {
                continuation.yield(.items([], isFinal: true))
                continuation.finish()
                return
            }
            do {
                guard await accessibility.isTrusted() else {
                    continuation.yield(.status(.permissionDenied(AccessibilityServiceError.permissionDenied.descriptor)))
                    continuation.yield(.items([], isFinal: true))
                    continuation.finish()
                    return
                }
                let windows = try await accessibility.windows()
                let items = windows.compactMap { window -> LauncherItem? in
                    let match = FuzzyMatcher.evaluate(
                        query: request.normalizedText,
                        title: window.title,
                        subtitle: window.applicationName,
                        keywords: [window.applicationName, window.bundleIdentifier].compactMap { $0 }
                    )
                    guard match.tier != .none else { return nil }
                    let itemID = ItemID(providerID: descriptor.id, providerStableID: window.id)
                    let focus = Self.action(.focus, title: "Focus Window", symbol: "macwindow")
                    let actions = [
                        focus,
                        Self.action(.leftHalf, title: "Left Half", symbol: "rectangle.lefthalf.inset.filled"),
                        Self.action(.rightHalf, title: "Right Half", symbol: "rectangle.righthalf.inset.filled"),
                        Self.action(.topHalf, title: "Top Half", symbol: "rectangle.tophalf.inset.filled"),
                        Self.action(.bottomHalf, title: "Bottom Half", symbol: "rectangle.bottomhalf.inset.filled"),
                        Self.action(.topLeftQuarter, title: "Top Left Quarter", symbol: "rectangle.tophalf.inset.filled"),
                        Self.action(.topRightQuarter, title: "Top Right Quarter", symbol: "rectangle.tophalf.inset.filled"),
                        Self.action(.bottomLeftQuarter, title: "Bottom Left Quarter", symbol: "rectangle.bottomhalf.inset.filled"),
                        Self.action(.bottomRightQuarter, title: "Bottom Right Quarter", symbol: "rectangle.bottomhalf.inset.filled"),
                        Self.action(.maximize, title: "Maximize", symbol: "arrow.up.left.and.arrow.down.right"),
                        Self.action(.center, title: "Center", symbol: "rectangle.center.inset.filled"),
                        Self.action(.restore, title: "Restore Previous Frame", symbol: "arrow.uturn.backward"),
                        Self.action(.nextDisplay, title: "Move to Next Display", symbol: "rectangle.on.rectangle"),
                    ]
                    return LauncherItem(
                        id: itemID,
                        providerID: descriptor.id,
                        title: window.title,
                        subtitle: [
                            window.applicationName,
                            window.isMinimized ? "Minimized" : nil,
                            window.screenName ?? window.screenIdentifier.map { "Display \($0)" },
                        ]
                        .compactMap { $0 }
                        .joined(separator: " · "),
                        icon: .systemSymbol("macwindow"),
                        canonicalResource: .command("window:\(window.id)"),
                        keywords: [window.applicationName, window.bundleIdentifier].compactMap { $0 },
                        actions: actions,
                        defaultActionID: focus.id,
                        scoreFeatures: ScoreFeatures(providerPrior: 0.5)
                    )
                }
                continuation.yield(.items(items, isFinal: true))
            } catch let error as AccessibilityServiceError {
                let status: ProviderStatus =
                    error == .permissionDenied
                    ? .permissionDenied(error.descriptor)
                    : .failed(error.descriptor)
                continuation.yield(.status(status))
                continuation.yield(.items([], isFinal: true))
            } catch {
                continuation.yield(.status(.failed(ErrorDescriptor(code: "windows.searchFailed", message: "Windows could not be listed."))))
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id,
            let action = WindowLayoutAction(rawValue: request.actionID.rawValue)
        else { return .failure(ErrorDescriptor(code: "windows.invalidAction", message: "The window action is invalid.")) }
        do {
            try await accessibility.perform(action, windowID: request.itemID.providerStableID)
            return .success(message: action == .focus ? nil : "Window updated")
        } catch let error as AccessibilityServiceError {
            return .failure(error.descriptor)
        } catch {
            return .failure(ErrorDescriptor(code: "windows.actionFailed", message: "The window action failed."))
        }
    }

    private static func action(_ action: WindowLayoutAction, title: String, symbol: String) -> ActionDescriptor {
        ActionDescriptor(
            id: ActionID(action.rawValue),
            title: title,
            icon: .systemSymbol(symbol),
            behavior: action == .focus ? .closeLauncher : .keepLauncherOpen
        )
    }
}
