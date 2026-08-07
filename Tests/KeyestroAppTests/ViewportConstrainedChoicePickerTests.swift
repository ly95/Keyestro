import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import KeyestroApp

@Test func choicePickerLimitsLongListsAndAdaptsToTheViewport() {
    #expect(
        ViewportConstrainedChoicePickerLayout.visibleItemCount(
            optionCount: 50,
            viewportHeight: 900
        ) == ViewportConstrainedChoicePickerLayout.maximumVisibleItemCount
    )

    let compactViewportHeight: CGFloat = 220
    let compactVisibleCount = ViewportConstrainedChoicePickerLayout.visibleItemCount(
        optionCount: 50,
        viewportHeight: compactViewportHeight
    )
    #expect(compactVisibleCount == 5)
    #expect(
        CGFloat(compactVisibleCount) * ViewportConstrainedChoicePickerLayout.estimatedItemHeight
            <= compactViewportHeight - ViewportConstrainedChoicePickerLayout.viewportVerticalSafetyMargin
    )
}

@Test func choicePickerShowsAllShortListsAndKeepsAtLeastOneVisibleRow() {
    #expect(
        ViewportConstrainedChoicePickerLayout.visibleItemCount(
            optionCount: 3,
            viewportHeight: 900
        ) == 3
    )
    #expect(
        ViewportConstrainedChoicePickerLayout.visibleItemCount(
            optionCount: 0,
            viewportHeight: 0
        ) == 1
    )
    #expect(
        ViewportConstrainedChoicePickerLayout.visibleItemCount(
            optionCount: 50,
            viewportHeight: .infinity
        ) == ViewportConstrainedChoicePickerLayout.maximumVisibleItemCount
    )
}

@Test @MainActor func choicePickerRendersLongListsAsABoundedNativeControl() throws {
    let options = (1...50).map { "Choice \($0)" }
    let hostingView = NSHostingView(
        rootView: ViewportConstrainedChoicePicker(
            title: "Scope",
            options: options,
            selection: .constant("Choice 42")
        )
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.layoutIfNeeded()

    let comboBox = try #require(firstComboBox(in: hostingView))
    #expect(comboBox.numberOfItems == options.count)
    #expect(comboBox.numberOfVisibleItems <= ViewportConstrainedChoicePickerLayout.maximumVisibleItemCount)
    #expect(comboBox.indexOfSelectedItem == 41)
    #expect(!comboBox.isEditable)
    #expect(comboBox.isEnabled)
}

@MainActor
private func firstComboBox(in view: NSView) -> NSComboBox? {
    if let comboBox = view as? NSComboBox { return comboBox }
    for subview in view.subviews {
        if let comboBox = firstComboBox(in: subview) { return comboBox }
    }
    return nil
}
