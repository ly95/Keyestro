import AppKit
import KeyestroDomain
import SwiftUI

enum LauncherCommand: Equatable {
    case moveUp
    case moveDown
    case submit
    case submitSecondary
    case escape
    case selectAll
    case openSettings
    case openFilters
    case openActions
    case copySelection
    case actionShortcut(key: String, modifiers: Set<KeyModifier>)
    case deleteSelection
    case executeIndex(Int)
    case tab
}

enum LauncherCommandInterpretation: Equatable {
    case passThrough
    case swallow
    case command(LauncherCommand)
}

struct LauncherSearchFocusRequest: Equatable {
    let id: Int
    let selectAll: Bool

    static let initial = Self(id: 0, selectAll: false)

    func next(selectAll: Bool) -> Self {
        Self(id: id + 1, selectAll: selectAll)
    }
}

enum LauncherKeyInterpreter {
    static func commandEquivalent(
        key: String,
        commandModified: Bool,
        controlModified: Bool = false,
        optionModified: Bool = false,
        shiftModified: Bool = false,
        isComposing: Bool
    ) -> LauncherCommand? {
        guard !isComposing else { return nil }
        let normalizedKey = normalizedKey(key)
        var modifiers = Set<KeyModifier>()
        if commandModified { modifiers.insert(.command) }
        if controlModified { modifiers.insert(.control) }
        if optionModified { modifiers.insert(.option) }
        if shiftModified { modifiers.insert(.shift) }

        if modifiers == [.command] {
            switch normalizedKey {
            case "return": return .submitSecondary
            case "a", "l": return .selectAll
            case "c": return .copySelection
            case "k": return .openActions
            case "p": return .openFilters
            case ",": return .openSettings
            case "1"..."9": return normalizedKey.first?.wholeNumberValue.map { .executeIndex($0 - 1) }
            default: break
            }
        }
        if modifiers == [.control], normalizedKey == "x" { return .deleteSelection }
        if !modifiers.isEmpty {
            return .actionShortcut(key: normalizedKey, modifiers: modifiers)
        }
        return nil
    }

    static func normalizedKey(_ key: String) -> String {
        switch key.lowercased() {
        case "\r", "\n", "return", "enter": "return"
        case "\u{1b}", "escape": "escape"
        case "\u{7f}", "\u{8}", "delete", "backspace": "delete"
        case " ", "space": "space"
        case let normalized: normalized
        }
    }

    static func shouldSwallowRepeat(_ command: LauncherCommand, isRepeat: Bool) -> Bool {
        guard isRepeat else { return false }
        return command == .submit || command == .submitSecondary
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

final class CommandFieldEditor: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if selectAllIfRequested(by: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !selectAllIfRequested(by: event) else { return }
        super.keyDown(with: event)
    }

    private func selectAllIfRequested(by event: NSEvent) -> Bool {
        guard !hasMarkedText(),
            let key = event.charactersIgnoringModifiers
        else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard
            LauncherKeyInterpreter.commandEquivalent(
                key: key,
                commandModified: modifiers.contains(.command),
                controlModified: modifiers.contains(.control),
                optionModified: modifiers.contains(.option),
                shiftModified: modifiers.contains(.shift),
                isComposing: false
            ) == .selectAll
        else { return false }
        selectAll(nil)
        return true
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
                optionModified: modifiers.contains(.option),
                shiftModified: modifiers.contains(.shift),
                isComposing: false
            )
        else {
            return super.performKeyEquivalent(with: event)
        }
        if LauncherKeyInterpreter.shouldSwallowRepeat(command, isRepeat: event.isARepeat) {
            return true
        }
        if command == .selectAll,
            let editor = currentEditor() as? NSTextView
        {
            editor.selectAll(nil)
            return true
        }
        if command == .copySelection,
            let editor = currentEditor() as? NSTextView,
            editor.selectedRange().length > 0
        {
            editor.copy(nil)
            return true
        }
        if commandHandler?(command) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct LauncherSearchField: View {
    @Binding var text: String
    let focusRequest: LauncherSearchFocusRequest
    let placeholder: String
    var isEmbedded = false
    var fontSize: CGFloat = 14
    let onChange: (String, Bool) -> Void
    let onCommand: (LauncherCommand) -> Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let field = LauncherSearchTextField(
            text: $text,
            focusRequest: focusRequest,
            placeholder: placeholder,
            fontSize: fontSize,
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
    let focusRequest: LauncherSearchFocusRequest
    let placeholder: String
    let fontSize: CGFloat
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
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.prepareFieldEditor()
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequestID != focusRequest.id {
            context.coordinator.lastFocusRequestID = focusRequest.id
            DispatchQueue.main.async {
                field.prepareFieldEditor()
                field.window?.makeFirstResponder(field)
                if focusRequest.selectAll {
                    field.currentEditor()?.selectAll(nil)
                } else if let editor = field.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchTextField
        var lastFocusRequestID = -1

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
                    optionModified: event.modifierFlags.contains(.option),
                    shiftModified: event.modifierFlags.contains(.shift),
                    isComposing: false
                )
            {
                if LauncherKeyInterpreter.shouldSwallowRepeat(command, isRepeat: event.isARepeat) {
                    return true
                }
                if command == .selectAll {
                    textView.selectAll(nil)
                    return true
                }
                if command == .copySelection, textView.selectedRange().length > 0 {
                    textView.copy(nil)
                    return true
                }
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
