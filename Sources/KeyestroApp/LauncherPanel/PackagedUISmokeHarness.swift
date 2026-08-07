import AppKit
import KeyestroCore
import KeyestroDomain

enum PackagedUISmokeError: Error {
    case conditionTimedOut(String)
    case panelOutsideVisibleFrame
    case incorrectQueryMode
}

@MainActor
enum PackagedUISmokeHarness {
    static func run() async throws {
        let suiteName = "com.keyestro.launcher.packaged-ui-smoke"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PackagedUISmokeError.conditionTimedOut("isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = PackagedSmokeProvider()
        let coordinator = QueryCoordinator(providers: [provider])
        let settings = SettingsStore(defaults: defaults)
        let model = LauncherViewModel(
            coordinator: coordinator,
            actionRunner: ActionRunner(providers: [provider]),
            settings: settings
        )
        let controller = LauncherPanelController(viewModel: model, restoresPreviousApplication: false)
        controller.show()
        try await wait("initial result") {
            controller.isVisible && model.results.first?.item.title == "Alpha Application"
        }
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(controller.frame) }),
            !screen.visibleFrame.contains(controller.frame)
        {
            throw PackagedUISmokeError.panelOutsideVisibleFrame
        }

        model.queryDidChange("/alpha", isComposing: true)
        try await wait("composed query") { await provider.requests.count >= 2 }
        guard let composed = await provider.requests.last,
            composed.mode == .all,
            composed.normalizedText == "/alpha"
        else { throw PackagedUISmokeError.incorrectQueryMode }

        model.queryDidChange("/alpha", isComposing: false)
        try await wait("prefixed query") { await provider.requests.count >= 3 }
        guard let committed = await provider.requests.last,
            committed.mode == .files,
            committed.normalizedText == "alpha"
        else { throw PackagedUISmokeError.incorrectQueryMode }

        model.queryDidChange("permission", isComposing: false)
        try await wait("expanded permission recovery state") {
            model.requiresExpandedEmptyState
                && abs(controller.frame.height - LauncherPanelLayout.recoveryHeight) < 0.001
        }

        controller.dismiss()
        guard !controller.isVisible else {
            throw PackagedUISmokeError.conditionTimedOut("panel dismissal")
        }

        var onboardingFinished = false
        let onboarding = OnboardingWindowController(settings: settings) { onboardingFinished = true }
        onboarding.show()
        guard onboarding.window?.isVisible == true else {
            throw PackagedUISmokeError.conditionTimedOut("onboarding presentation")
        }
        onboarding.complete()
        guard onboardingFinished, settings.onboardingCompleted, onboarding.window?.isVisible == false else {
            throw PackagedUISmokeError.conditionTimedOut("onboarding completion")
        }
    }

    private static func wait(
        _ name: String,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw PackagedUISmokeError.conditionTimedOut(name)
    }
}

private actor PackagedSmokeProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "packaged-ui-smoke",
        displayName: "Packaged UI Smoke",
        supportedModes: [.all, .files],
        supportsEmptyQuery: true
    )
    private(set) var requests: [QueryRequest] = []

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await record(request)
                if request.normalizedText == "permission" {
                    continuation.yield(
                        .status(
                            .permissionDenied(
                                ErrorDescriptor(
                                    code: "accessibility.permissionDenied",
                                    message: "Accessibility permission is required for window management.",
                                    recoverySuggestion: "Open Settings → Permissions to grant access, then refresh."
                                )
                            )
                        )
                    )
                    continuation.yield(.items([], isFinal: true))
                } else {
                    continuation.yield(.items([Self.item], isFinal: true))
                }
                continuation.finish()
            }
        }
    }

    func execute(request: ProviderActionRequest) -> ActionResult { .success() }

    private func record(_ request: QueryRequest) {
        requests.append(request)
    }

    nonisolated private static var item: LauncherItem {
        let action = ActionDescriptor(id: "open", title: "Open")
        return LauncherItem(
            id: ItemID(providerID: "packaged-ui-smoke", providerStableID: "alpha"),
            providerID: "packaged-ui-smoke",
            title: "Alpha Application",
            actions: [action],
            defaultActionID: action.id
        )
    }
}
