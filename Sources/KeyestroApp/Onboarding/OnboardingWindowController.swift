import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case shortcut
    case features
    case permissions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shortcut: L10n.text("Your launcher shortcut")
        case .features: L10n.text("Search and act locally")
        case .permissions: L10n.text("Permissions are requested only when needed")
        }
    }

    var symbol: String {
        switch self {
        case .shortcut: "keyboard"
        case .features: "command.square"
        case .permissions: "hand.raised"
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let completion: OnboardingCompletion

    init(settings: SettingsStore, onFinish: @escaping () -> Void) {
        let completion = OnboardingCompletion(settings: settings, onFinish: onFinish)
        self.completion = completion
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Welcome to Keyestro")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(settings: settings, onFinish: completion.finish)
        )
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func complete() {
        window?.orderOut(nil)
        completion.finish()
    }
}

@MainActor
private final class OnboardingCompletion {
    private let settings: SettingsStore
    private let onFinish: () -> Void
    private var didFinish = false

    init(settings: SettingsStore, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.onFinish = onFinish
    }

    func finish() {
        guard !didFinish else { return }
        guard settings.completeOnboarding() else { return }
        didFinish = true
        onFinish()
    }
}

private struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    let onFinish: () -> Void
    @State private var stepIndex = 0

    private var step: OnboardingStep { OnboardingStep.allCases[stepIndex] }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases) { candidate in
                    Capsule()
                        .fill(candidate.rawValue <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: candidate == step ? 38 : 18, height: 5)
                        .accessibilityHidden(true)
                }
            }

            Image(systemName: step.symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(step.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            stepContent
                .frame(maxWidth: 460)
                .frame(maxHeight: .infinity)

            if let error = settings.persistenceError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityElement(children: .combine)
            }

            HStack {
                Button("Skip setup") { finish() }
                Spacer()
                if stepIndex > 0 {
                    Button("Back") { stepIndex -= 1 }
                }
                Button(stepIndex == OnboardingStep.allCases.count - 1 ? "Done" : "Continue") {
                    if stepIndex == OnboardingStep.allCases.count - 1 {
                        finish()
                    } else {
                        stepIndex += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 600, height: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.format("Onboarding step %lld of %lld", Int64(stepIndex + 1), Int64(OnboardingStep.allCases.count))
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .shortcut:
            VStack(spacing: 14) {
                Text(settings.launcherShortcut.displayName)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(
                        L10n.format("Current launcher shortcut: %@", settings.launcherShortcut.displayName)
                    )
                Text("Use this shortcut from any application. You can change it later in Shortcuts settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .features:
            VStack(alignment: .leading, spacing: 12) {
                onboardingFeature("magnifyingglass", "Find applications and Spotlight-indexed files")
                onboardingFeature("function", "Calculate and convert units without a network request")
                onboardingFeature("bolt", "Run only the local workflows you explicitly enable")
            }
        case .permissions:
            VStack(spacing: 14) {
                Text("Keyestro does not request Accessibility or Screen Recording during setup.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("onboarding.permissions.explanation")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func onboardingFeature(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: symbol)
            .font(.body)
            .accessibilityElement(children: .combine)
    }

    private func finish() {
        onFinish()
    }
}
