import AppKit
import KeyestroCore
import KeyestroDomain
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var insetSurface: Color { palette.surfaceInset }
    private let headerFilters: [ClipboardPanelFilter] = [.all, .text, .images, .links]
    var isOpenActionsButtonDisabled: Bool { !model.canExecuteSelectedEntry }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                searchHeader
                content
                    .frame(height: ClipboardPanelLayout.contentHeight)
                footer
            }
            .background(Color.clear)

            if model.layer == .results,
                model.canBrowse,
                model.isQuickViewPresented,
                let entry = model.selectedEntry
            {
                quickViewContent(for: entry)
                    .frame(
                        width: ClipboardPanelLayout.quickViewWidth,
                        height: ClipboardPanelLayout.quickViewHeight
                    )
                    .padding(.top, ClipboardPanelLayout.quickViewTop)
                    .padding(.trailing, ClipboardPanelLayout.quickViewTrailing)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(4)
            }

            if let message = model.message {
                messageOverlay(message)
                    .zIndex(8)
            }
            if let confirmation = model.pendingConfirmationPresentation {
                confirmationOverlay(confirmation)
                    .zIndex(10)
            }
            if model.isExecuting {
                executingOverlay
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
        .preferredColorScheme(model.launcherAppearance.preferredColorScheme)
        .clipShape(
            RoundedRectangle(
                cornerRadius: ClipboardPanelLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                LauncherSearchField(
                    text: $model.query,
                    focusRequest: model.queryFocusRequest,
                    placeholder: L10n.text("Search Clipboard History"),
                    isEmbedded: true,
                    fontSize: 14,
                    onChange: { value, isComposing in
                        model.queryDidChange(value, isComposing: isComposing)
                    },
                    onCommand: handle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("Searching"))
                }
                Text("Esc")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .frame(minWidth: 26)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: ClipboardPanelLayout.toolbarHeight)
            .transientPanelGlassSurface(
                cornerRadius: 12,
                variant: .clear,
                tint: colorScheme == .dark
                    ? Color(red: 0.008, green: 0.025, blue: 0.055).opacity(0.20)
                    : Color.white.opacity(0.02),
                fallback: insetSurface,
                edge: palette.border,
                interactive: true
            )

            HStack(spacing: 0) {
                ForEach(headerFilters) { filter in
                    filterTab(filter)
                }
            }
            .padding(3)
            .frame(width: 280, height: ClipboardPanelLayout.toolbarHeight)
            .transientPanelGlassSurface(
                cornerRadius: 12,
                variant: .clear,
                tint: colorScheme == .dark
                    ? Color(red: 0.008, green: 0.025, blue: 0.055).opacity(0.16)
                    : Color.white.opacity(0.02),
                fallback: insetSurface.opacity(0.82),
                edge: palette.border,
                interactive: true
            )
        }
        .padding(.horizontal, 16)
        .frame(height: ClipboardPanelLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func filterTab(_ filter: ClipboardPanelFilter) -> some View {
        let selected = filter == model.filter
        return Button {
            model.applyFilter(filter)
        } label: {
            Text(L10n.text(filter.title))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(selected ? palette.accent : palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    selected ? palette.accentSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.canBrowse)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        switch model.layer {
        case .actions:
            actionList
        case .filters:
            filterList
        case .results:
            switch model.state {
            case .ready:
                if model.entries.isEmpty { emptyState } else { resultWorkspace }
            case .disabled, .loading, .keyMissing, .failed:
                storeState
            }
        }
    }

    private var resultWorkspace: some View {
        resultsColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            if model.isEnabled, model.isPaused { pausedBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(resultGroups) { group in
                            Text(L10n.text(group.title).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 8)
                                .frame(
                                    height: ClipboardPanelLayout.sectionHeaderHeight,
                                    alignment: .bottomLeading
                                )
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.entries) { entry in
                                resultRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.text("Clipboard History"))
                }
                .onChange(of: model.selectedItemID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color.clear)
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(palette.privateStatusForeground)
            Text("Clipboard monitoring is paused. Existing history remains available.")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Resume Monitoring") { model.resumeMonitoring() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.privateStatusForeground)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(palette.privateStatusSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.privateStatus.opacity(0.45)).frame(height: 1)
        }
    }

    private func quickViewContent(for entry: ClipboardSearchEntry) -> some View {
        let previewHidden = hidesPreview(for: entry)
        let primaryActionTitle = L10n.text("Paste to Active App")
        let secondaryActionTitle = L10n.text("Copy")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if previewHidden {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(palette.privateStatusForeground)
                    } else {
                        ClipboardPanelIcon(reference: icon(for: entry))
                            .foregroundStyle(palette.textPrimary)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text(entry.contentType.displayName).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(palette.textSecondary)
                    Text(previewHidden ? L10n.text("Sensitive content") : entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .padding(.top, 8)
                    Text(previewHidden ? L10n.text("Preview hidden") : quickViewMetadata(for: entry))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .padding(.trailing, 24)

            quickViewPreview(for: entry, hidden: previewHidden)
                .frame(maxWidth: .infinity, minHeight: 224, maxHeight: 224, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.border.opacity(0.68))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }

            Spacer(minLength: 8)

            Button {
                model.executeDefault()
            } label: {
                HStack {
                    Text(primaryActionTitle)
                    Spacer()
                    Text("↩")
                        .font(.system(size: 16, weight: .regular))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .foregroundStyle(Color(red: 0.027, green: 0.075, blue: 0.118))
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canExecuteSelectedEntry)
            .help(primaryActionTitle)
            .accessibilityIdentifier("clipboard.quickView.primaryAction")
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.accent.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.20), radius: 8, y: 4)
            .padding(.horizontal, 16)

            Spacer().frame(height: 8)

            Button {
                model.executeSecondary()
            } label: {
                HStack {
                    Text(secondaryActionTitle)
                    Spacer()
                    Text("⌘ C")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .background(insetSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canExecuteSelectedEntry)
            .help(secondaryActionTitle)
            .accessibilityIdentifier("clipboard.quickView.secondaryAction")
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                model.closeQuickView()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Close Quick View"))
            .accessibilityLabel(L10n.text("Close Quick View"))
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .background(
            palette.surfaceElevated.opacity(colorScheme == .dark ? 0.94 : 0.90),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .transientPanelGlassSurface(
            cornerRadius: 24,
            variant: .regular,
            tint: palette.surfaceElevated.opacity(0.32),
            fallback: palette.surfaceElevated,
            edge: palette.border,
            interactive: true
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.18), radius: 28, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("QUICK VIEW"))
    }

    @ViewBuilder
    private func quickViewPreview(for entry: ClipboardSearchEntry, hidden: Bool) -> some View {
        if hidden {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "eye.slash")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(palette.privateStatusForeground)
                Text(L10n.text("Sensitive preview is hidden"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.privateStatusForeground)
                Button(L10n.text("Show sensitive preview")) {
                    model.toggleSensitivePreview(entry.id)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .accessibilityIdentifier("clipboard.quickView.sensitivePreview")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if case let .imagePNG(data) = model.quickViewContent,
            let image = NSImage(data: data)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let data = entry.thumbnailPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ScrollView {
                Text(quickViewPreviewText(for: entry))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func quickViewPreviewText(for entry: ClipboardSearchEntry) -> String {
        switch model.quickViewContent {
        case let .text(text):
            let lines = text.components(separatedBy: .newlines)
            guard let titleIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                lines[titleIndex].trimmingCharacters(in: .whitespaces) == entry.title,
                titleIndex + 1 < lines.count
            else { return text }
            return lines[(titleIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case let .url(url): return url.absoluteString
        case let .files(urls): return urls.map(\.path).joined(separator: "\n")
        case .imagePNG, .none: return entry.title
        }
    }

    private func resultRow(_ entry: ClipboardSearchEntry) -> some View {
        let selected = model.selectedItemID == entry.id
        let previewHidden = hidesPreview(for: entry)
        return HStack(spacing: 12) {
            Group {
                if previewHidden {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(palette.privateStatusForeground)
                } else {
                    ClipboardPanelIcon(reference: icon(for: entry))
                        .foregroundStyle(selected ? palette.accent : palette.textSecondary)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewHidden ? L10n.text("Sensitive content") : entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(previewHidden ? L10n.text("Preview hidden") : subtitle(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if selected, entry.isSensitive {
                Button {
                    model.toggleSensitivePreview(entry.id)
                } label: {
                    Image(systemName: previewHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(previewHidden ? L10n.text("Show sensitive preview") : L10n.text("Hide sensitive preview"))
            }
            Text(L10n.text(entry.contentType.displayName).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(insetSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(palette.border.opacity(0.86), lineWidth: 1)
                }
        }
        .padding(.leading, 16)
        .padding(
            .trailing,
            selected && model.isQuickViewPresented
                ? ClipboardPanelLayout.quickViewWidth + ClipboardPanelLayout.quickViewTrailing
                : 16
        )
        .frame(height: ClipboardPanelLayout.rowHeight)
        .transientPanelSelectionStyle(
            isSelected: selected,
            cornerRadius: 12,
            showsLeadingIndicator: false
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectItem(entry.id)
            model.executeDefault()
        }
        .onTapGesture { model.selectItem(entry.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            previewHidden
                ? L10n.text("Sensitive content, preview hidden")
                : "\(entry.title), \(subtitle(for: entry))"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(.default) {
            model.selectItem(entry.id)
            model.executeDefault()
        }
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            listHeading(L10n.text("Clipboard Actions"))
            ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 12) {
                    ClipboardPanelIcon(reference: action.icon)
                        .frame(width: 24, height: 24)
                    Text(L10n.text(action.title))
                    Spacer()
                    if action.risk != .safe {
                        Image(
                            systemName: action.risk == .destructive
                                ? "exclamationmark.triangle.fill"
                                : "exclamationmark.circle"
                        )
                        .foregroundStyle(action.risk == .destructive ? .red : .orange)
                    }
                }
                .font(.system(size: 14, weight: .regular))
                .padding(.horizontal, 16)
                .frame(height: ClipboardPanelLayout.rowHeight)
                .transientPanelSelectionStyle(
                    isSelected: index == model.selectedActionIndex,
                    cornerRadius: 12,
                    showsLeadingIndicator: false
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedActionIndex = index
                    model.executeSelectedAction()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == model.selectedActionIndex ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.clear)
    }

    private var filterList: some View {
        VStack(spacing: 0) {
            listHeading(L10n.text("Filter by Type"))
            ForEach(Array(model.filters.enumerated()), id: \.element.id) { index, filter in
                HStack(spacing: 12) {
                    Image(systemName: filter.symbol).frame(width: 24)
                    Text(L10n.text(filter.title))
                    Spacer()
                    if filter == model.filter { Image(systemName: "checkmark") }
                }
                .font(.system(size: 14, weight: .regular))
                .padding(.horizontal, 16)
                .frame(height: ClipboardPanelLayout.rowHeight)
                .transientPanelSelectionStyle(
                    isSelected: index == model.selectedFilterIndex,
                    cornerRadius: 12,
                    showsLeadingIndicator: false
                )
                .contentShape(Rectangle())
                .onTapGesture { model.applyFilter(filter) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == model.selectedFilterIndex ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.clear)
    }

    private func listHeading(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(palette.textSecondary)
            Spacer()
            Text("Esc")
                .font(.caption.monospaced())
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(palette.textSecondary)
            Text(model.query.isEmpty ? L10n.text("No Clipboard History") : L10n.text("No Matching Clipboard Items"))
                .font(.headline)
            Text(
                model.query.isEmpty
                    ? L10n.text("Copied items matching the current type will appear here.")
                    : L10n.text("Try another search or clipboard type.")
            )
            .font(.callout)
            .foregroundStyle(palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    @ViewBuilder
    private var storeState: some View {
        VStack(spacing: 10) {
            Spacer()
            switch model.state {
            case .disabled:
                stateIcon("doc.on.clipboard")
                Text("Clipboard History Is Off").font(.headline)
                Text("Enable clipboard history to save future copied items locally with encryption.")
                    .stateDetailStyle()
                Button("Enable Clipboard History") { model.enableHistory() }
            case .loading:
                ProgressView().controlSize(.regular)
                Text("Loading Clipboard History…").font(.headline)
                Text("Encrypted clipboard metadata is being prepared.").stateDetailStyle()
            case let .keyMissing(count):
                stateIcon("key.slash")
                Text("Clipboard Encryption Key Is Missing").font(.headline)
                Text(L10n.format("clipboard.keyMissing.format", Int64(count))).stateDetailStyle()
                Button("Open Privacy Settings") { model.onOpenPrivacy?() }
            case let .failed(error):
                stateIcon("exclamationmark.triangle")
                Text(L10n.errorMessage(error)).font(.headline).multilineTextAlignment(.center)
                if let recovery = L10n.recoverySuggestion(error) { Text(recovery).stateDetailStyle() }
                HStack {
                    Button("Retry") { model.retry() }
                    Button("Open Privacy Settings") { model.onOpenPrivacy?() }
                }
            case .ready:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    private func stateIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 28))
            .foregroundStyle(palette.textSecondary)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(footerStatus)
                .lineLimit(1)
                .foregroundStyle(palette.textSecondary)
            Spacer()
            switch model.layer {
            case .actions, .filters:
                footerShortcut("↩", label: "Choose")
                footerShortcut("Esc", label: "Back")
            case .results:
                if case .ready = model.state {
                    footerShortcut("↩", label: "Paste")
                    footerShortcut("⌘ C", label: "Copy")
                }
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 24)
        .frame(height: ClipboardPanelLayout.footerHeight)
        .background(Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Action hint"))
    }

    private var footerStatus: String {
        switch model.state {
        case .disabled:
            return L10n.text("Clipboard history is off")
        case .loading:
            return L10n.text("Loading clipboard history")
        case .keyMissing, .failed:
            return L10n.text("Clipboard history unavailable")
        case .ready:
            break
        }

        switch model.layer {
        case .actions:
            return L10n.format("%lld actions", Int64(model.visibleActions.count))
        case .filters:
            return L10n.format("%lld clipboard types", Int64(model.filters.count))
        case .results:
            return model.filter == .all
                ? L10n.format("%lld items", Int64(model.entries.count))
                : L10n.format("%lld matching items", Int64(model.entries.count))
        }
    }

    private func footerShortcut(_ keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(L10n.text(label))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func messageOverlay(_ message: String) -> some View {
        VStack(spacing: 3) {
            Text(message).font(.callout.weight(.medium))
            if let detail = model.messageDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if model.messageOffersPermissions {
                Button("Open Permissions Settings") { model.onOpenPermissions?() }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(palette.surfaceElevated)
        }
        .overlay { Capsule().stroke(palette.border, lineWidth: 1) }
        .shadow(radius: 8)
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func confirmationOverlay(_ confirmation: ClipboardPanelViewModel.ConfirmationPresentation) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label(confirmation.title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(confirmation.message)
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
                HStack {
                    Button("Cancel") { model.cancelPendingAction() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if confirmation.isDestructive {
                        Button(confirmation.buttonTitle, role: .destructive) { model.confirmPendingAction() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(confirmation.buttonTitle) { model.confirmPendingAction() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(22)
            .frame(width: 440)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(palette.surfaceElevated)
            }
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(palette.border, lineWidth: 1) }
            .shadow(radius: 18)
        }
    }

    private var executingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView()
                .controlSize(.regular)
                .padding(24)
                .background {
                    RoundedRectangle(cornerRadius: 14).fill(palette.surfaceElevated)
                }
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(palette.border, lineWidth: 1) }
                .shadow(radius: 12)
                .accessibilityLabel(L10n.text("Executing action"))
        }
    }

    private func handle(_ command: LauncherCommand) -> Bool {
        switch command {
        case .moveUp: model.moveSelection(-1)
        case .moveDown: model.moveSelection(1)
        case .submit:
            if model.pendingConfirmation != nil {
                model.confirmPendingAction()
            } else if model.layer == .actions {
                model.executeSelectedAction()
            } else if model.layer == .filters {
                model.applySelectedFilter()
            } else {
                model.executeDefault()
            }
        case .submitSecondary: model.executeSecondary()
        case .openFilters: model.openFilters()
        case .openActions: model.openActions()
        case .copySelection: model.executeSecondary()
        case .deleteSelection: model.requestDeleteSelected()
        case .escape: model.handleEscape()
        case .selectAll: model.requestQueryFocus(selectAll: true)
        case .actionShortcut, .openSettings, .executeIndex, .tab: return false
        }
        return true
    }

    private var resultGroups: [ClipboardEntryGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var entriesByGroup: [String: [ClipboardSearchEntry]] = [:]
        for entry in model.entries {
            let group = dateGroup(for: entry.lastCopiedAt)
            if entriesByGroup[group.id] == nil {
                order.append(group.id)
                titles[group.id] = group.title
            }
            entriesByGroup[group.id, default: []].append(entry)
        }
        return order.map { id in
            ClipboardEntryGroup(
                id: id,
                title: titles[id] ?? id,
                entries: entriesByGroup[id] ?? []
            )
        }
    }

    private func dateGroup(for date: Date) -> (id: String, title: String) {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return ("today", "Today") }
        if calendar.isDateInYesterday(date) { return ("yesterday", "Yesterday") }
        return ("earlier", "Earlier")
    }

    private func hidesPreview(for entry: ClipboardSearchEntry) -> Bool {
        entry.isSensitive && !model.isSensitivePreviewRevealed(entry.id)
    }

    private func icon(for entry: ClipboardSearchEntry) -> IconReference {
        return .systemSymbol(entry.contentType.symbol)
    }

    private func quickViewMetadata(for entry: ClipboardSearchEntry) -> String {
        subtitle(for: entry)
    }

    private func subtitle(for entry: ClipboardSearchEntry) -> String {
        switch entry.contentType {
        case .text:
            return L10n.format("Copied %@", relativeDate(for: entry))
        case .url:
            return URL(string: entry.title)?.host ?? L10n.format("Copied %@", relativeDate(for: entry))
        case .files, .image:
            return entry.subtitle ?? L10n.format("Copied %@", relativeDate(for: entry))
        }
    }

    private func relativeDate(for entry: ClipboardSearchEntry) -> String {
        if abs(Date().timeIntervalSince(entry.lastCopiedAt)) < 45 {
            return L10n.text("just now")
        }
        return RelativeDateTimeFormatter().localizedString(for: entry.lastCopiedAt, relativeTo: Date())
    }
}

private struct ClipboardEntryGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let entries: [ClipboardSearchEntry]
}

private extension ClipboardContentType {
    var symbol: String {
        switch self {
        case .text: "doc.text"
        case .url: "link"
        case .files: "doc.on.doc"
        case .image: "photo"
        }
    }

    var displayName: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .files: "File"
        case .image: "Image"
        }
    }
}

private extension View {
    func stateDetailStyle() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
    }
}

private struct ClipboardPanelIcon: View {
    let reference: IconReference?

    var body: some View {
        Group {
            switch reference {
            case let .systemSymbol(name):
                Image(systemName: name).resizable().scaledToFit().padding(5)
            case let .thumbnailPNG(data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "photo").resizable().scaledToFit().padding(5)
                }
            default:
                Image(systemName: "doc.on.clipboard").resizable().scaledToFit().padding(5)
            }
        }
        .accessibilityHidden(true)
    }
}
