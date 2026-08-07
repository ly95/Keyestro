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

    private var panelSurface: Color { palette.surfaceElevated }
    private var insetSurface: Color { palette.surfaceInset }
    var isOpenActionsButtonDisabled: Bool { !model.canExecuteSelectedEntry }
    private var iconSurface: Color {
        colorScheme == .dark ? palette.surfaceSubtle : palette.surfaceElevated
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchHeader
                Rectangle().fill(palette.border).frame(height: 1)
                content
                    .frame(height: LauncherPanelLayout.contentHeight)
                Rectangle().fill(palette.border).frame(height: 1)
                footer
            }
            .background(panelSurface)

            if let message = model.message {
                messageOverlay(message)
            }
            if let confirmation = model.pendingConfirmationPresentation {
                confirmationOverlay(confirmation)
            }
            if model.isExecuting {
                executingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
        .preferredColorScheme(model.launcherAppearance.preferredColorScheme)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                LauncherSearchField(
                    text: $model.query,
                    focusToken: model.queryFocusToken,
                    placeholder: L10n.text("Search Clipboard History"),
                    isEmbedded: true,
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
                Text("⌘ P")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .frame(minWidth: 58, minHeight: 24)
                    .background(iconSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    }
            }
            .padding(.leading, 13)
            .padding(.trailing, 16)
            .frame(height: 44)
            .background(insetSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.border, lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
            }

            Spacer().frame(width: 14)

            Button {
                model.openFilters()
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(palette.accent).frame(width: 8, height: 8)
                    Text(L10n.text(model.filter.title)).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 80, height: 44)
                .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canBrowse)
            .help(L10n.text("Filter clipboard history (Command-P)"))
            .accessibilityLabel(L10n.text("Filter by Type"))

            Spacer().frame(width: 25)

            Button {
                model.openActions()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(insetSurface, in: Circle())
                    .overlay { Circle().stroke(palette.border, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(isOpenActionsButtonDisabled)
            .help(L10n.text("Open actions"))
            .accessibilityLabel(L10n.text("Open actions"))
        }
        .padding(.leading, 22)
        .padding(.trailing, 35)
        .frame(height: LauncherPanelLayout.headerHeight)
        .background(panelSurface)
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
        HStack(spacing: 0) {
            resultsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(palette.border)
                .frame(width: 1)
                .accessibilityHidden(true)
            quickView
                .frame(width: LauncherPanelLayout.quickViewWidth)
                .frame(maxHeight: .infinity)
        }
        .background(panelSurface)
    }

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            if model.isEnabled, model.isPaused { pausedBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(resultGroups) { group in
                            Text(L10n.text(group.title).uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.top, group.id == resultGroups.first?.id ? 20 : 18)
                                .padding(.bottom, 11)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.entries) { entry in
                                resultRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.text("Clipboard History"))
                }
                .onChange(of: model.selectedItemID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            privacyNotice
                .padding(.horizontal, 16)
                .padding(.bottom, 36)
        }
        .background(panelSurface)
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

    private var privacyNotice: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.privateStatusForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sensitive previews stay hidden")
                    .font(.system(size: 13, weight: .semibold))
                Text("Reveal only after explicit selection")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.privateStatusForeground.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .foregroundStyle(palette.privateStatusForeground)
        .background(palette.privateStatusSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.privateStatus.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var quickView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("QUICK VIEW"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 50)

            if let entry = model.selectedEntry {
                quickViewContent(for: entry)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 30))
                    Text(L10n.text("Select a clipboard item to preview it"))
                        .font(.callout)
                }
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(panelSurface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("QUICK VIEW"))
    }

    private func quickViewContent(for entry: ClipboardSearchEntry) -> some View {
        let previewHidden = hidesPreview(for: entry)
        let primaryActionTitle = L10n.text(
            model.actionDescriptor(for: .copy)?.title ?? "Copy to Clipboard"
        )
        let secondaryActionTitle = L10n.text(
            model.actionDescriptor(for: .autoPaste)?.title ?? "Paste into Previous App"
        )
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                Group {
                    if previewHidden {
                        Image(systemName: "lock.shield")
                            .resizable()
                            .scaledToFit()
                            .padding(15)
                            .foregroundStyle(palette.privateStatusForeground)
                    } else {
                        ClipboardPanelIcon(reference: icon(for: entry))
                            .padding(8)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(width: 56, height: 72)
                .background(iconSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text(entry.contentType.displayName).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text(previewHidden ? L10n.text("Sensitive content") : entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(3)
                        .padding(.top, 8)
                    Text(previewHidden ? L10n.text("Preview hidden") : quickViewMetadata(for: entry))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 21)
            .padding(.trailing, 12)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
            .background(insetSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            }

            if entry.isSensitive {
                let previewButtonTitle = L10n.text(
                    previewHidden ? "Show sensitive preview" : "Hide sensitive preview"
                )
                Button {
                    model.toggleSensitivePreview(entry.id)
                } label: {
                    Text(previewButtonTitle)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .frame(height: 18)
                .help(previewButtonTitle)
                .accessibilityIdentifier("clipboard.quickView.sensitivePreview")
            } else {
                Spacer().frame(height: 18)
            }

            Button {
                model.executeDefault()
            } label: {
                HStack {
                    Text(primaryActionTitle)
                    Spacer()
                    Text("↩")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 28, height: 24)
                        .background(
                            (colorScheme == .dark ? palette.surfaceBase : Color.white).opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 20)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
                .foregroundStyle(colorScheme == .dark ? palette.surfaceBase : Color.white)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canExecuteSelectedEntry)
            .help(primaryActionTitle)
            .accessibilityIdentifier("clipboard.quickView.primaryAction")

            Spacer().frame(height: 8)

            Button {
                model.executeSecondary()
            } label: {
                HStack {
                    Text(secondaryActionTitle)
                    Spacer()
                    Text("⌘↩")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
                .background(insetSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canExecuteSelectedEntry)
            .help(secondaryActionTitle)
            .accessibilityIdentifier("clipboard.quickView.secondaryAction")

            Spacer().frame(height: 26)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.localStatus)
                        .accessibilityHidden(true)
                    Text("Encrypted on this Mac")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("Clipboard history is encrypted and searched on device.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                Text("CLIPBOARD · LOCAL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.localStatus)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .frame(minHeight: 105, maxHeight: 105, alignment: .topLeading)
            .background(palette.localStatusSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.localStatus.opacity(0.25), lineWidth: 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ entry: ClipboardSearchEntry) -> some View {
        let selected = model.selectedItemID == entry.id
        let previewHidden = hidesPreview(for: entry)
        return HStack(spacing: 14) {
            Group {
                if previewHidden {
                    Image(systemName: "eye.slash.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .foregroundStyle(palette.privateStatusForeground)
                } else {
                    ClipboardPanelIcon(reference: icon(for: entry))
                        .padding(4)
                        .foregroundStyle(selected ? palette.accent : palette.textSecondary)
                }
            }
            .frame(width: 32, height: 32)
            .background(
                selected ? iconSurface : palette.surfaceSubtle,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(previewHidden ? L10n.text("Sensitive content") : entry.title)
                    .font(.system(size: 13, weight: .semibold))
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
            if selected {
                Text(L10n.text(entry.contentType.displayName).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(iconSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(palette.accent.opacity(0.32), lineWidth: 1)
                    }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .transientPanelSelectionStyle(isSelected: selected, cornerRadius: 14)
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
    }

    private var actionList: some View {
        VStack(spacing: 4) {
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
                .padding(.horizontal, 14)
                .frame(height: 48)
                .transientPanelSelectionStyle(
                    isSelected: index == model.selectedActionIndex,
                    cornerRadius: 9
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
        .background(panelSurface)
    }

    private var filterList: some View {
        VStack(spacing: 4) {
            listHeading(L10n.text("Filter by Type"))
            ForEach(Array(model.filters.enumerated()), id: \.element.id) { index, filter in
                HStack(spacing: 12) {
                    Image(systemName: filter.symbol).frame(width: 24)
                    Text(L10n.text(filter.title))
                    Spacer()
                    if filter == model.filter { Image(systemName: "checkmark") }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .transientPanelSelectionStyle(
                    isSelected: index == model.selectedFilterIndex,
                    cornerRadius: 9
                )
                .contentShape(Rectangle())
                .onTapGesture { model.applyFilter(filter) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == model.selectedFilterIndex ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(panelSurface)
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
        .padding(.vertical, 8)
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
        .background(panelSurface)
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
        .background(panelSurface)
    }

    private func stateIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 28))
            .foregroundStyle(palette.textSecondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerStatus)
                .lineLimit(1)
                .foregroundStyle(palette.textSecondary)
            if model.layer == .results {
                Menu("Clear…") {
                    Button("Clear Current Type…", role: .destructive) { model.requestClearCurrentType() }
                        .disabled(model.filter == .all)
                    Button("Clear All Clipboard History…", role: .destructive) { model.requestClearAll() }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 11))
                .disabled(!model.canClearHistory)
            }
            Spacer()
            switch model.layer {
            case .actions, .filters:
                footerShortcut("↩", label: "Choose")
                footerShortcut("Esc", label: "Back")
            case .results:
                footerShortcut("↩", label: "Copy")
                footerShortcut("⌘↩", label: "Paste")
                footerShortcut("⌘K", label: "Actions")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .frame(height: LauncherPanelLayout.footerHeight)
        .background(panelSurface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Action hint"))
    }

    private var footerStatus: String {
        switch model.layer {
        case .actions:
            L10n.format("%lld actions", Int64(model.visibleActions.count))
        case .filters:
            L10n.format("%lld clipboard types", Int64(model.filters.count))
        case .results:
            L10n.format("%lld items · grouped by date", Int64(model.entries.count))
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
        case .openActions: model.openActions()
        case .openFilters: model.openFilters()
        case .deleteSelection: model.requestDeleteSelected()
        case .escape: model.handleEscape()
        case .selectAll: model.requestQueryFocus(selectAll: true)
        case .openSettings, .executeIndex, .tab: return false
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
        if let thumbnail = entry.thumbnailPNG { return .thumbnailPNG(thumbnail) }
        return .systemSymbol(entry.contentType.symbol)
    }

    private func quickViewMetadata(for entry: ClipboardSearchEntry) -> String {
        let values = [entry.subtitle, relativeDate(for: entry)]
        return values.compactMap { $0 }.joined(separator: " · ")
    }

    private func subtitle(for entry: ClipboardSearchEntry) -> String {
        [sourceName(for: entry), relativeDate(for: entry)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func sourceName(for entry: ClipboardSearchEntry) -> String? {
        entry.sourceBundleIdentifier.map(applicationName) ?? L10n.text("Unknown Source")
    }

    private func relativeDate(for entry: ClipboardSearchEntry) -> String {
        RelativeDateTimeFormatter().localizedString(for: entry.lastCopiedAt, relativeTo: Date())
    }

    private func applicationName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return url.deletingPathExtension().lastPathComponent
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
        case .text: "text.alignleft"
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
