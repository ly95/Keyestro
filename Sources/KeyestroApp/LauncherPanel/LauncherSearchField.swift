import AppKit
import SwiftUI

enum LauncherCommand: Equatable {
    case moveUp
    case moveDown
    case submit
    case submitSecondary
    case openActions
    case escape
    case selectAll
    case openSettings
    case openFilters
    case deleteSelection
    case executeIndex(Int)
    case tab
}

enum LauncherCommandInterpretation: Equatable {
    case passThrough
    case swallow
    case command(LauncherCommand)
}

enum LauncherKeyInterpreter {
    static func commandEquivalent(
        key: String,
        commandModified: Bool,
        controlModified: Bool = false,
        isComposing: Bool
    ) -> LauncherCommand? {
        guard !isComposing else { return nil }
        if commandModified {
            switch key.lowercased() {
            case "k": return .openActions
            case "l": return .selectAll
            case "p": return .openFilters
            case ",": return .openSettings
            case "1"..."9": return key.first?.wholeNumberValue.map { .executeIndex($0 - 1) }
            default: break
            }
        }
        if controlModified, key.lowercased() == "x" { return .deleteSelection }
        return nil
    }

    static func interpret(
        selector: Selector,
        isComposing: Bool,
        isRepeat: Bool,
        commandModified: Bool
    ) -> LauncherCommandInterpretation {
        guard !isComposing else { return .passThrough }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): return .command(.moveUp)
        case #selector(NSResponder.moveDown(_:)): return .command(.moveDown)
        case #selector(NSResponder.insertNewline(_:)):
            return isRepeat ? .swallow : .command(commandModified ? .submitSecondary : .submit)
        case #selector(NSResponder.cancelOperation(_:)): return .command(.escape)
        case #selector(NSResponder.insertTab(_:)): return .command(.tab)
        default: return .passThrough
        }
    }
}

final class CommandTextField: NSTextField {
    var commandHandler: ((LauncherCommand) -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        prepareFieldEditor()
    }

    func prepareFieldEditor() {
        guard let editor = window?.fieldEditor(true, for: self) as? NSTextView else { return }
        editor.insertionPointColor = TransientPanelVisualStyle.accentNSColor
        editor.selectedTextAttributes = [
            .backgroundColor: TransientPanelVisualStyle.selectedTextBackgroundNSColor,
            .foregroundColor: NSColor.labelColor,
        ]
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard (currentEditor() as? NSTextView)?.hasMarkedText() != true else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers,
            let command = LauncherKeyInterpreter.commandEquivalent(
                key: key,
                commandModified: modifiers.contains(.command),
                controlModified: modifiers.contains(.control),
                isComposing: false
            )
        else {
            return super.performKeyEquivalent(with: event)
        }
        if commandHandler?(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct LauncherSearchField: View {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    var isEmbedded = false
    let onChange: (String, Bool) -> Void
    let onCommand: (LauncherCommand) -> Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let field = LauncherSearchTextField(
            text: $text,
            focusToken: focusToken,
            placeholder: placeholder,
            onChange: onChange,
            onCommand: onCommand
        )

        if isEmbedded {
            field
        } else {
            field
                .padding(.horizontal, 12)
                .background(searchBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(searchStroke, lineWidth: usesStrongOutline ? 1.5 : 1)
                }
                .shadow(
                    color: reduceTransparency ? .clear : TransientPanelVisualStyle.accentColor.opacity(0.08),
                    radius: 4,
                    y: 1
                )
        }
    }

    private var usesStrongOutline: Bool {
        differentiateWithoutColor || colorSchemeContrast == .increased
    }

    private var searchBackground: Color {
        Color(nsColor: reduceTransparency ? .textBackgroundColor : .controlBackgroundColor)
            .opacity(reduceTransparency ? 1 : 0.72)
    }

    private var searchStroke: Color {
        usesStrongOutline ? .primary.opacity(0.72) : TransientPanelVisualStyle.accentColor.opacity(0.46)
    }
}

private struct LauncherSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let placeholder: String
    let onChange: (String, Bool) -> Void
    let onCommand: (LauncherCommand) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CommandTextField {
        let field = CommandTextField()
        field.delegate = context.coordinator
        field.commandHandler = onCommand
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .regular)
        field.isAutomaticTextCompletionEnabled = false
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(placeholder)
        return field
    }

    func updateNSView(_ field: CommandTextField, context: Context) {
        context.coordinator.parent = self
        field.commandHandler = onCommand
        field.placeholderString = placeholder
        field.prepareFieldEditor()
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.prepareFieldEditor()
                field.window?.makeFirstResponder(field)
                if focusToken.isMultiple(of: 2) {
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchTextField
        var lastFocusToken = -1

        init(parent: LauncherSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            parent.text = field.stringValue
            parent.onChange(field.stringValue, composing)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            let event = NSApplication.shared.currentEvent
            if !textView.hasMarkedText(),
                let event,
                let key = event.charactersIgnoringModifiers,
                let command = LauncherKeyInterpreter.commandEquivalent(
                    key: key,
                    commandModified: event.modifierFlags.contains(.command),
                    controlModified: event.modifierFlags.contains(.control),
                    isComposing: false
                )
            {
                return parent.onCommand(command)
            }
            let interpretation = LauncherKeyInterpreter.interpret(
                selector: commandSelector,
                isComposing: textView.hasMarkedText(),
                isRepeat: event?.isARepeat == true,
                commandModified: event?.modifierFlags.contains(.command) == true
            )
            switch interpretation {
            case .passThrough: return false
            case .swallow: return true
            case let .command(command): return parent.onCommand(command)
            }
        }
    }
}
