import Foundation
import SwiftUI

struct SettingsSidebar: View {
    private enum FocusedItem: Hashable {
        case searchField
        case section(SettingsSection)
        case searchResult(SettingsAnchor)
    }

    private struct SectionGroup: Identifiable {
        let id: String
        let title: String
        let sections: [SettingsSection]
    }

    @ObservedObject var navigation: SettingsNavigationModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedItem: FocusedItem?

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var trimmedQuery: String {
        navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SettingsSearchEntry] {
        SettingsSearchCatalog.search(trimmedQuery)
    }

    private var groups: [SectionGroup] {
        [
            SectionGroup(
                id: "basics",
                title: L10n.text("Basics"),
                sections: [.general, .shortcuts, .features]
            ),
            SectionGroup(
                id: "access",
                title: L10n.text("Access & Privacy"),
                sections: [.extensions, .permissions, .privacy]
            ),
            SectionGroup(
                id: "system",
                title: L10n.text("System"),
                sections: [.updates, .advanced]
            ),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            if trimmedQuery.isEmpty {
                navigationList
            } else {
                searchResults
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surfaceSubtle)
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        .accessibilityElement(children: .contain)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleArrowKey(press.key)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 32, height: 32)
                .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(palette.accent.opacity(0.22), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Keyestro")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("Settings")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var navigationList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: group.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.7)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 10)
                                .accessibilityHidden(true)

                            ForEach(group.sections) { section in
                                navigationButton(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Divider()
                .overlay(palette.border.opacity(0.55))

            navigationButton(.about)
                .padding(8)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .accessibilityIdentifier("settings.search.empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        HStack {
                            Text("Results")
                                .font(.caption2.weight(.semibold))
                                .tracking(0.7)
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            Text(results.count, format: .number)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(palette.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)

                        ForEach(results) { entry in
                            searchResultButton(entry)
                                .id(entry.anchor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .onChange(of: navigation.searchResultSelection) { _, anchor in
                    guard let anchor else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
        }
    }

    private func searchResultButton(_ entry: SettingsSearchEntry) -> some View {
        let isSelected = navigation.searchResultSelection == entry.anchor
        return Button {
            navigation.navigate(to: entry)
            focusedItem = .searchResult(entry.anchor)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 28)
                    .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.localizedTitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(2)
                    Text(verbatim: entry.section.title)
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                isSelected ? palette.selection : palette.surfaceElevated.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? palette.accent.opacity(0.58) : palette.border.opacity(0.55),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focusedItem, equals: .searchResult(entry.anchor))
        .accessibilityLabel(
            Text(verbatim: "\(entry.localizedTitle), \(entry.section.title)")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.search.result.\(entry.id)")
    }

    private func navigationButton(_ section: SettingsSection) -> some View {
        let isSelected = navigation.selection == section
        return Button {
            navigation.selection = section
            focusedItem = .section(section)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(isSelected ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: 3, height: 18)
                        .padding(.leading, 2)
                }
            }
            .overlay {
                if isSelected && (differentiateWithoutColor || colorSchemeContrast == .increased) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.accent.opacity(0.72), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focusedItem, equals: .section(section))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.sidebar.\(section.rawValue.lowercased())")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .accessibilityHidden(true)
            TextField("Search Settings", text: $navigation.searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focusedItem, equals: .searchField)
                .accessibilityIdentifier("settings.search.field")
                .onSubmit {
                    navigation.activateSearchSelection(in: results)
                }
            if !navigation.searchQuery.isEmpty {
                Button {
                    navigation.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.text("Clear")))
                .accessibilityIdentifier("settings.search.clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(palette.surfaceInset, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.border.opacity(0.68), lineWidth: 1)
        }
    }

    private func moveSectionSelection(_ direction: SettingsNavigationDirection) {
        navigation.moveSectionSelection(direction)
        if let section = navigation.selection {
            focusedItem = .section(section)
        }
    }

    private func moveSearchSelection(_ direction: SettingsNavigationDirection, moveFocus: Bool) {
        navigation.moveSearchSelection(direction, in: results)
        if moveFocus, let anchor = navigation.searchResultSelection {
            focusedItem = .searchResult(anchor)
        }
    }

    private func handleArrowKey(_ key: KeyEquivalent) -> KeyPress.Result {
        let direction: SettingsNavigationDirection
        switch key {
        case .upArrow:
            direction = .previous
        case .downArrow:
            direction = .next
        default:
            return .ignored
        }

        if trimmedQuery.isEmpty {
            moveSectionSelection(direction)
        } else {
            let moveFocus =
                focusedItem.map { item in
                    if case .searchResult = item { return true }
                    return false
                } ?? false
            moveSearchSelection(direction, moveFocus: moveFocus)
        }
        return .handled
    }
}
