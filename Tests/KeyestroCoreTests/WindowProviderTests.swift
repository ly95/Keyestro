import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func windowPermissionLifecycleFailsSafelyWhileOtherProvidersRemainAvailable() async throws {
    let accessibility = MutableAccessibilityService(
        windows: [
            AccessibleWindowRecord(
                id: "window-1",
                processIdentifier: 101,
                applicationName: "Alpha App",
                bundleIdentifier: "com.example.alpha",
                title: "Alpha Document",
                isMinimized: true,
                frame: CGRect(x: -800, y: 100, width: 600, height: 400),
                screenIdentifier: "secondary",
                screenName: "Studio Display"
            )
        ]
    )
    let windowProvider = WindowProvider(accessibility: accessibility)
    let companionProvider = WindowCompanionProvider()
    let coordinator = QueryCoordinator(providers: [windowProvider, companionProvider])

    var finalSnapshot = try await completedSnapshot(from: await coordinator.search(rawText: "alpha"))
    #expect(finalSnapshot.items.map(\.item.title) == ["Alpha Companion"])
    guard case .permissionDenied = finalSnapshot.statuses[windowProvider.descriptor.id] else {
        Issue.record("Window provider did not expose a permission-denied state")
        return
    }

    await accessibility.setTrusted(true)
    finalSnapshot = try await completedSnapshot(from: await coordinator.search(rawText: "alpha"))
    let windowItem = try #require(finalSnapshot.items.first(where: { $0.item.providerID == windowProvider.descriptor.id })?.item)
    #expect(windowItem.title == "Alpha Document")
    #expect(windowItem.subtitle == "Alpha App · Minimized · Studio Display")
    #expect(windowItem.actions.count == 13)
    #expect(windowItem.defaultActionID == "focus")

    let unmatched = try await collectedWindowEvents(
        windowProvider.search(
            request: QueryRequest(
                generation: 9,
                rawText: "zzzz-no-window-matches",
                normalizedText: "zzzz-no-window-matches",
                mode: .all
            )
        )
    )
    #expect(
        unmatched.contains { event in
            if case let .items(items, isFinal) = event { return items.isEmpty && isFinal }
            return false
        })

    let moveRequest = ProviderActionRequest(
        executionID: UUID(),
        itemID: windowItem.id,
        actionID: ActionID(WindowLayoutAction.nextDisplay.rawValue),
        arguments: [:]
    )
    #expect(await windowProvider.execute(request: moveRequest) == .success(message: "Window updated"))

    await accessibility.setTrusted(false)
    #expect(
        await windowProvider.execute(request: moveRequest)
            == .failure(AccessibilityServiceError.permissionDenied.descriptor)
    )
    finalSnapshot = try await completedSnapshot(from: await coordinator.search(rawText: "alpha"))
    #expect(finalSnapshot.items.contains(where: { $0.item.title == "Alpha Companion" }))
    #expect(!finalSnapshot.items.contains(where: { $0.item.providerID == windowProvider.descriptor.id }))
}

@Test func windowProviderCoversEmptyQueriesAndTypedAndUnknownFailures() async throws {
    let accessibility = FailingAccessibilityService()
    let provider = WindowProvider(accessibility: accessibility)

    let empty = try await collectedWindowEvents(
        provider.search(request: QueryRequest(generation: 1, rawText: "", normalizedText: "", mode: .all))
    )
    #expect(empty.count == 1)
    #expect(
        empty.contains { event in
            if case let .items(items, isFinal) = event { return items.isEmpty && isFinal }
            return false
        })

    await accessibility.setFailure(.accessibility(.windowNotFound))
    let typed = try await collectedWindowEvents(
        provider.search(request: QueryRequest(generation: 2, rawText: "window", normalizedText: "window", mode: .all))
    )
    #expect(
        typed.contains { event in
            if case .status(.failed) = event { return true }
            return false
        })

    await accessibility.setFailure(.unknown)
    let unknown = try await collectedWindowEvents(
        provider.search(request: QueryRequest(generation: 3, rawText: "window", normalizedText: "window", mode: .all))
    )
    #expect(
        unknown.contains { event in
            if case .status(.failed) = event { return true }
            return false
        })

    let execute = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: "window"),
            actionID: ActionID(WindowLayoutAction.focus.rawValue),
            arguments: [:]
        )
    )
    #expect(execute == .failure(ErrorDescriptor(code: "windows.actionFailed", message: "The window action failed.")))

    let invalid = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "other", providerStableID: "window"),
            actionID: "not-an-action",
            arguments: [:]
        )
    )
    #expect(invalid == .failure(ErrorDescriptor(code: "windows.invalidAction", message: "The window action is invalid.")))
}

private actor MutableAccessibilityService: AccessibilityServicing {
    private var trusted = false
    private let records: [AccessibleWindowRecord]

    init(windows: [AccessibleWindowRecord]) {
        records = windows
    }

    func isTrusted() -> Bool { trusted }

    func windows() throws -> [AccessibleWindowRecord] {
        guard trusted else { throw AccessibilityServiceError.permissionDenied }
        return records
    }

    func perform(_ action: WindowLayoutAction, windowID: String) throws {
        guard trusted else { throw AccessibilityServiceError.permissionDenied }
        guard records.contains(where: { $0.id == windowID }) else {
            throw AccessibilityServiceError.windowNotFound
        }
        _ = action
    }

    func setTrusted(_ value: Bool) {
        trusted = value
    }
}

private actor FailingAccessibilityService: AccessibilityServicing {
    enum Failure {
        case accessibility(AccessibilityServiceError)
        case unknown
    }

    private var failure: Failure = .unknown

    func isTrusted() -> Bool { true }

    func windows() throws -> [AccessibleWindowRecord] {
        try fail()
    }

    func perform(_ action: WindowLayoutAction, windowID: String) throws {
        _ = action
        _ = windowID
        try fail()
    }

    func setFailure(_ value: Failure) {
        failure = value
    }

    private func fail() throws -> Never {
        switch failure {
        case let .accessibility(error): throw error
        case .unknown: throw WindowProviderTestError.forcedFailure
        }
    }
}

private struct WindowCompanionProvider: LauncherProvider {
    let descriptor = ProviderDescriptor(
        id: "window-companion",
        displayName: "Window Companion",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )

    func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let action = ActionDescriptor(id: "open", title: "Open")
        let item = LauncherItem(
            id: ItemID(providerID: descriptor.id, providerStableID: "alpha"),
            providerID: descriptor.id,
            title: "Alpha Companion",
            actions: [action],
            defaultActionID: action.id
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.items([item], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }
}

private enum WindowProviderTestError: Error {
    case missingCompletedSnapshot
    case forcedFailure
}

private func completedSnapshot(
    from stream: AsyncStream<QuerySnapshot>
) async throws -> QuerySnapshot {
    for await snapshot in stream where snapshot.isComplete {
        return snapshot
    }
    throw WindowProviderTestError.missingCompletedSnapshot
}

private func collectedWindowEvents(
    _ stream: AsyncThrowingStream<ProviderEvent, any Error>
) async throws -> [ProviderEvent] {
    var events: [ProviderEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
