import AppKit
import Foundation
import KeyestroCore
import KeyestroDomain

struct QuickPasteTargetApplication: Equatable, Sendable {
    let name: String?
    let bundleIdentifier: String
    let processIdentifier: Int32
}

enum QuickPasteMessageStyle: Equatable, Sendable {
    case success
    case information
    case error
}

struct QuickPasteMessage: Equatable, Sendable {
    let code: String
    let text: String
    let style: QuickPasteMessageStyle
}

@MainActor
final class QuickPasteCoordinator {
    var onMessage: (QuickPasteMessage) -> Void = { _ in }
    var onFallbackToHistory: () -> Void = {}

    private let store: ClipboardStore?
    private let actions: ClipboardActionService?
    private let settings: SettingsStore
    private let targetApplication: @MainActor @Sendable () -> QuickPasteTargetApplication?
    private var executionTask: Task<Void, Never>?

    private(set) var isExecuting = false

    init(
        store: ClipboardStore?,
        actions: ClipboardActionService?,
        settings: SettingsStore,
        targetApplication: @escaping @MainActor @Sendable () -> QuickPasteTargetApplication? = {
            guard let application = NSWorkspace.shared.frontmostApplication,
                let bundleIdentifier = application.bundleIdentifier,
                !application.isTerminated
            else { return nil }
            return QuickPasteTargetApplication(
                name: application.localizedName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: application.processIdentifier
            )
        }
    ) {
        self.store = store
        self.actions = actions
        self.settings = settings
        self.targetApplication = targetApplication
    }

    func invoke() {
        guard !isExecuting else { return }
        guard settings.quickPasteEnabled, settings.quickPasteShortcut != nil else {
            present(
                code: "quickPaste.notConfigured",
                text: "Enable Quick Paste and record its shortcut in Keyestro Settings.",
                style: .information
            )
            return
        }
        guard let target = targetApplication(),
            target.bundleIdentifier != Bundle.main.bundleIdentifier,
            target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            present(
                code: "quickPaste.targetUnavailable",
                text: "Keep the destination application and field frontmost, then try again.",
                style: .error
            )
            return
        }

        isExecuting = true
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await perform(target: target)
            isExecuting = false
            executionTask = nil
        }
    }

    private func perform(target: QuickPasteTargetApplication) async {
        guard let store, let actions else {
            present(
                code: "quickPaste.historyUnavailable",
                text: "Clipboard history is unavailable. Enable it in Keyestro Settings and copy an item first.",
                style: .error
            )
            return
        }

        let latest: ClipboardSearchEntry
        switch await store.latestEntry() {
        case let .success(entry?):
            latest = entry
        case .success(nil):
            present(
                code: "quickPaste.emptyHistory",
                text: "Clipboard history is empty. Copy text or a URL, then try again.",
                style: .information
            )
            return
        case let .failure(error):
            present(
                code: error.code,
                text: error.recoverySuggestion
                    ?? "Clipboard history is unavailable. Enable it in Keyestro Settings and try again.",
                style: .error
            )
            return
        }

        guard latest.contentType == .text || latest.contentType == .url else {
            onFallbackToHistory()
            present(
                code: "quickPaste.unsupportedContent",
                text: "Quick Paste supports text and URLs. Choose the latest item in Clipboard History instead.",
                style: .information
            )
            return
        }
        guard settings.quickPasteAllowsSensitiveContent || !latest.isSensitive else {
            onFallbackToHistory()
            present(
                code: "quickPaste.sensitiveContentBlocked",
                text: "Sensitive-looking content was not pasted. Review it in Clipboard History instead.",
                style: .information
            )
            return
        }

        let result = await actions.quickPaste(
            itemID: latest.id,
            target: AutoPasteTarget(
                bundleIdentifier: target.bundleIdentifier,
                processIdentifier: target.processIdentifier,
                activationPolicy: .requireFrontmost
            )
        )
        switch result {
        case .success:
            present(
                code: "quickPaste.success",
                text: L10n.format("quickPaste.success", target.name ?? target.bundleIdentifier),
                style: .success
            )
        case .cancelled:
            present(
                code: "quickPaste.cancelled",
                text: "Quick Paste was cancelled before sending a keystroke.",
                style: .information
            )
        case let .failure(error):
            present(error)
        }
    }

    private func present(_ error: ErrorDescriptor) {
        let text =
            switch error.code {
            case "clipboard.autoPaste.permissionDenied":
                "Accessibility permission is required. Open Keyestro Settings → Permissions, grant access, and try again."
            case "clipboard.autoPaste.targetChanged":
                "Paste was cancelled because the frontmost application changed. Return to the destination field and try again."
            case "clipboard.autoPaste.targetUnavailable":
                "The destination application is unavailable. Keep it open and frontmost, then try again."
            default:
                error.recoverySuggestion ?? error.message
            }
        present(code: error.code, text: text, style: .error)
    }

    private func present(code: String, text: String, style: QuickPasteMessageStyle) {
        onMessage(QuickPasteMessage(code: code, text: L10n.text(text), style: style))
    }
}

@MainActor
final class QuickPasteHUDController {
    private let panel: QuickPasteHUDPanel
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        panel = QuickPasteHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 22),
        ])
        panel.contentView = effect
    }

    func show(_ message: QuickPasteMessage) {
        hideTask?.cancel()
        label.stringValue = message.text
        let symbolName =
            switch message.style {
            case .success: "checkmark.circle.fill"
            case .information: "info.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor =
            switch message.style {
            case .success: .systemGreen
            case .information: .controlAccentColor
            case .error: .systemOrange
            }
        let screen =
            NSWorkspace.shared.frontmostApplication == nil
            ? NSScreen.main
            : NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.maxY - panel.frame.height - 28
                )
            )
        }
        panel.orderFrontRegardless()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

private final class QuickPasteHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
