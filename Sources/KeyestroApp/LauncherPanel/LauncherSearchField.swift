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
    case executeIndex(Int)
    case tab
}

enum LauncherCommandInterpretation: Equatable {
    case passThrough
    case swallow
    case command(LauncherCommand)
}

enum LauncherKeyInterpreter {
    static func commandEquivalent(key: String, commandModified: Bool, isComposing: Bool) -> LauncherCommand? {
        guard commandModified, !isComposing else { return nil }
        switch key.lowercased() {
        case "k": return .openActions
        case "l": return .selectAll
        case ",": return .openSettings
        case "1"..."9": return key.first?.wholeNumberValue.map { .executeIndex($0 - 1) }
        default: return nil
        }
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
                isComposing: false
            )
        else {
            return super.performKeyEquivalent(with: event)
        }
        if commandHandler?(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct LauncherSearchField: NSViewRepresentable {
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
        field.focusRingType = .exterior
        field.font = .systemFont(ofSize: 23, weight: .regular)
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
        var parent: LauncherSearchField
        var lastFocusToken = -1

        init(parent: LauncherSearchField) {
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
