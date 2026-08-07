import AppKit
import SwiftUI

enum ViewportConstrainedChoicePickerLayout {
    static let maximumVisibleItemCount = 8
    static let estimatedItemHeight: CGFloat = 28
    static let viewportVerticalSafetyMargin: CGFloat = 80
    static let fallbackViewportHeight: CGFloat = 560

    static func visibleItemCount(optionCount: Int, viewportHeight: CGFloat) -> Int {
        let safeOptionCount = max(1, optionCount)
        let safeViewportHeight =
            viewportHeight.isFinite
            ? max(0, viewportHeight)
            : fallbackViewportHeight
        let availableHeight = max(
            estimatedItemHeight,
            safeViewportHeight - viewportVerticalSafetyMargin
        )
        let fittingItemCount = max(1, Int((availableHeight / estimatedItemHeight).rounded(.down)))
        return min(safeOptionCount, min(maximumVisibleItemCount, fittingItemCount))
    }
}

/// A native choice control whose expanded list stays bounded to the current display
/// and scrolls when more choices are available than can be shown safely.
struct ViewportConstrainedChoicePicker: View {
    let title: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        ViewportConstrainedComboBoxRepresentable(
            title: title,
            options: options,
            selection: $selection
        )
        .frame(minWidth: 160, idealWidth: 240)
        .frame(height: 26)
    }
}

private struct ViewportConstrainedComboBoxRepresentable: NSViewRepresentable {
    let title: String
    let options: [String]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ViewportConstrainedComboBox {
        let comboBox = ViewportConstrainedComboBox()
        comboBox.delegate = context.coordinator
        comboBox.isEditable = false
        comboBox.usesDataSource = false
        comboBox.completes = false
        comboBox.controlSize = .regular
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
        comboBox.cell?.lineBreakMode = .byTruncatingTail
        comboBox.setAccessibilityLabel(title)
        return comboBox
    }

    func updateNSView(_ comboBox: ViewportConstrainedComboBox, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        comboBox.setAccessibilityLabel(title)
        comboBox.isEnabled = !options.isEmpty
        comboBox.updateOptions(options)
        if let selectedIndex = options.firstIndex(of: selection) {
            if comboBox.indexOfSelectedItem != selectedIndex {
                comboBox.selectItem(at: selectedIndex)
            }
        } else {
            let selectedIndex = comboBox.indexOfSelectedItem
            if selectedIndex >= 0 { comboBox.deselectItem(at: selectedIndex) }
            if comboBox.stringValue != selection { comboBox.stringValue = selection }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ViewportConstrainedComboBoxRepresentable
        var isUpdating = false

        init(parent: ViewportConstrainedComboBoxRepresentable) {
            self.parent = parent
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !isUpdating,
                let comboBox = notification.object as? NSComboBox,
                let option = comboBox.objectValueOfSelectedItem as? String,
                option != parent.selection
            else { return }
            parent.selection = option
        }
    }
}

private final class ViewportConstrainedComboBox: NSComboBox {
    private var representedOptions: [String] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        updateVisibleItemCount()
    }

    func updateOptions(_ options: [String]) {
        guard representedOptions != options else {
            updateVisibleItemCount()
            return
        }
        representedOptions = options
        removeAllItems()
        addItems(withObjectValues: options)
        updateVisibleItemCount()
    }

    @objc private func windowDidChangeScreen() {
        updateVisibleItemCount()
    }

    private func updateVisibleItemCount() {
        let viewportHeight =
            window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? ViewportConstrainedChoicePickerLayout.fallbackViewportHeight
        numberOfVisibleItems = ViewportConstrainedChoicePickerLayout.visibleItemCount(
            optionCount: representedOptions.count,
            viewportHeight: viewportHeight
        )
    }
}
