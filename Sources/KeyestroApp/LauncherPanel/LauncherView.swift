import AppKit
import KeyestroDomain
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.launcherNativeGlassEnabled) private var nativeGlassEnabled
    @FocusState private var focusedArgumentID: String?

    private var palette: LauncherThemePalette {
        LauncherThemePalette.resolved(
            for: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private var panelSurface: Color {
        palette.surfaceElevated
    }

    private var insetSurface: Color {
        palette.surfaceInset
    }

    private var iconSurface: Color {
        colorScheme == .dark ? palette.surfaceSubtle : palette.surfaceElevated
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *), nativeGlassEnabled {
                GlassEffectContainer(spacing: 0) {
                    panelLayers
                }
            } else {
                panelLayers
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.textPrimary)
        .tint(palette.accent)
        .preferredColorScheme(model.launcherAppearance.preferredColorScheme)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LauncherPanelLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay { darkShellEdge }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var panelLayers: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.040, green: 0.050, blue: 0.105).opacity(0.94),
                        Color(red: 0.050, green: 0.065, blue: 0.092).opacity(0.95),
                        Color(red: 0.035, green: 0.046, blue: 0.072).opacity(0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.16, green: 0.34, blue: 0.52).opacity(0.075),
                        Color.clear,
                        Color(red: 0.08, green: 0.19, blue: 0.32).opacity(0.060),
                        Color.clear,
                    ],
                    startPoint: UnitPoint(x: 0.05, y: 0.95),
                    endPoint: UnitPoint(x: 0.90, y: 0.02)
                )
                .blendMode(.screen)
                .allowsHitTesting(false)

                LinearGradient(
                    stops: [
                        .init(
                            color: Color(red: 0.22, green: 0.25, blue: 0.38).opacity(0.16),
                            location: 0
                        ),
                        .init(color: Color.clear, location: 0.11),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.screen)
                .allowsHitTesting(false)

                LinearGradient(
                    stops: [
                        .init(
                            color: Color(red: 0.35, green: 0.40, blue: 0.48).opacity(0.22),
                            location: 0
                        ),
                        .init(color: Color.clear, location: 0.045),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
            }

            launcherContent

            if let message = model.message {
                VStack(spacing: 3) {
                    Text(message).font(.callout.weight(.medium))
                    if let detail = model.messageDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
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

            if let confirmation = model.pendingConfirmation {
                confirmationOverlay(confirmation)
            }

            if model.isExecuting {
                executingOverlay
            }
        }
    }

    @ViewBuilder
    private var darkShellEdge: some View {
        if colorScheme == .dark {
            let shape = RoundedRectangle(
                cornerRadius: LauncherPanelLayout.panelCornerRadius,
                style: .continuous
            )
            ZStack {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.38),
                            Color(red: 0.42, green: 0.58, blue: 0.78).opacity(0.30),
                            Color.white.opacity(0.12),
                            palette.accent.opacity(0.22),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                shape
                    .inset(by: 1.4)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                Color.clear,
                                Color.black.opacity(0.52),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                shape
                    .inset(by: 2.8)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 0.45
                    )
                if nativeGlassEnabled {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.08),
                                Color.clear,
                                Color(red: 0.58, green: 0.72, blue: 0.90).opacity(0.12),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(height: 0.7)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, LauncherPanelLayout.panelCornerRadius * 0.75)
                    .clipShape(shape)

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [
                                Color(red: 0.62, green: 0.76, blue: 0.92).opacity(0.18),
                                Color.white.opacity(0.08),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 0.7)
                    }
                    .padding(.vertical, LauncherPanelLayout.panelCornerRadius * 0.75)
                    .clipShape(shape)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var launcherContent: some View {
        VStack(spacing: 0) {
            searchHeader
            content
                .frame(height: LauncherPanelLayout.contentHeight)
        }
    }

    private var searchHeader: some View {
        HStack {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                LauncherSearchField(
                    text: $model.query,
                    focusRequest: model.queryFocusRequest,
                    placeholder: L10n.text("launcher.search.placeholder"),
                    isEmbedded: true,
                    fontSize: 23,
                    onChange: { text, composing in
                        model.queryDidChange(text, isComposing: composing)
                    },
                    onCommand: handle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ZStack {
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Searching"))
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 18)
            .frame(height: LauncherPanelLayout.searchFieldHeight)
            .transientPanelGlassSurface(
                cornerRadius: LauncherPanelLayout.searchFieldCornerRadius,
                variant: .clear,
                tint: colorScheme == .dark
                    ? Color(red: 0.008, green: 0.025, blue: 0.055).opacity(0.28)
                    : Color.white.opacity(0.02),
                wash: colorScheme == .dark
                    ? Color(red: 0.022, green: 0.050, blue: 0.105).opacity(0.55)
                    : nil,
                fallback: insetSurface,
                edge: colorScheme == .dark
                    ? Color(red: 0.54, green: 0.64, blue: 0.79).opacity(0.40)
                    : Color.white.opacity(0.62),
                interactive: true
            )
        }
        .padding(.horizontal, LauncherPanelLayout.horizontalInset)
        .frame(height: LauncherPanelLayout.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        if model.layer == .parameters {
            parameterForm
        } else if model.layer == .actions {
            actionList
        } else if model.results.isEmpty {
            emptyState
        } else {
            resultWorkspace
        }
    }

    @ViewBuilder
    private var parameterForm: some View {
        if let form = model.parameterForm {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parameters").font(.headline)
                        Text(model.selectedItem.map(localizedTitle) ?? L10n.text("Action"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Tab Next · Esc Back").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(form.definitions) { definition in
                            parameterField(definition, value: form.values[definition.id] ?? "")
                        }
                    }
                }
                HStack {
                    Button("Back") { model.handleEscape() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Run") { model.submitParameters() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canExecuteSelectedResult)
                }
            }
            .padding(20)
            .onAppear { focusedArgumentID = form.definitions.first?.id }
            .onExitCommand { model.handleEscape() }
        }
    }

    @ViewBuilder
    private func parameterField(_ definition: ArgumentDefinition, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L10n.text(definition.title)).font(.callout.weight(.medium))
                if definition.required { Text(L10n.text("Required")).font(.caption2).foregroundStyle(.secondary) }
            }
            switch definition.kind {
            case .text:
                TextField(
                    definition.placeholder ?? "",
                    text: parameterBinding(definition.id, value: value)
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedArgumentID, equals: definition.id)
            case .password:
                SecureField(
                    definition.placeholder ?? "",
                    text: parameterBinding(definition.id, value: value)
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedArgumentID, equals: definition.id)
            case let .choice(options):
                ViewportConstrainedChoicePicker(
                    title: L10n.text(definition.title),
                    options: options,
                    selection: parameterBinding(definition.id, value: value)
                )
            case .file, .directory:
                HStack {
                    TextField("Path", text: parameterBinding(definition.id, value: value))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedArgumentID, equals: definition.id)
                    Button("Choose…") { choosePath(for: definition) }
                }
            }
        }
    }

    private func parameterBinding(_ id: String, value: String) -> Binding<String> {
        Binding(get: { model.parameterForm?.values[id] ?? value }, set: { model.updateParameter(id: id, value: $0) })
    }

    private func choosePath(for definition: ArgumentDefinition) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = definition.kind == .file
        panel.canChooseDirectories = definition.kind == .directory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.updateParameter(id: definition.id, value: url.path) }
        }
    }

    private var actionList: some View {
        VStack(spacing: 4) {
            HStack {
                Text(model.selectedItem.map(localizedTitle) ?? L10n.text("launcher.actions"))
                    .font(.headline)
                Spacer()
                Text("Esc")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: action.icon) ?? "bolt")
                                    .frame(width: 24)
                                Text(L10n.text(action.title))
                                Spacer()
                                if action.risk != .safe {
                                    Image(
                                        systemName: action.risk == .destructive
                                            ? "exclamationmark.triangle.fill"
                                            : "exclamationmark.circle"
                                    )
                                    .foregroundStyle(action.risk == .destructive ? .red : .orange)
                                    .accessibilityLabel(
                                        L10n.text(action.risk == .destructive ? "Destructive" : "Confirmation required")
                                    )
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .transientPanelSelectionStyle(
                                isSelected: index == model.selectedActionIndex,
                                cornerRadius: 9
                            )
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L10n.text(action.title))
                            .accessibilityAddTraits(.isButton)
                            .onTapGesture {
                                model.selectedActionIndex = index
                                model.executeSelectedAction()
                            }
                            .accessibilityAddTraits(index == model.selectedActionIndex ? [.isSelected] : [])
                            .id(action.id)
                        }
                    }
                }
                .onChange(of: model.selectedActionIndex) { _, index in
                    guard model.visibleActions.indices.contains(index) else { return }
                    proxy.scrollTo(model.visibleActions[index].id, anchor: .center)
                }
            }
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: LauncherPanelLayout.emptyStateVerticalMargins / 2)
            LauncherEmptyStateView(
                symbol: statusSymbol,
                title: statusTitle,
                detail: statusDetail,
                actions: emptyStateActions,
                onOpenPermissions: { model.onOpenPermissions?() },
                onRetry: { model.retrySearch() }
            )
            Spacer(minLength: LauncherPanelLayout.emptyStateVerticalMargins / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var resultWorkspace: some View {
        resultsColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.displayOrderedResults.enumerated()), id: \.element.id) { index, ranked in
                        resultRow(ranked.item, index: index)
                            .id(ranked.id)
                    }
                }
                .padding(.bottom, LauncherPanelLayout.resultBottomInset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("Results"))
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedItemID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var privacyNotice: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.privateStatusForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("Private sources stay hidden"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("Reveal only after explicit selection"))
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

            if let item = model.selectedItem {
                quickViewContent(for: item)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 30))
                    Text(L10n.text("Select a result to preview it"))
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

    private func quickViewContent(for item: LauncherItem) -> some View {
        let previewHidden = hidesPreview(for: item)
        let secondaryAction = LauncherViewModel.secondaryAction(for: item)
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
                        LauncherIcon(reference: item.icon)
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
                    Text(quickViewKind(for: item).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text(previewHidden ? L10n.text("Sensitive item") : quickViewTitle(for: item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .padding(.top, 8)
                    if let metadata = quickViewMetadata(for: item) {
                        Text(previewHidden ? L10n.text("Preview hidden") : metadata)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.top, 8)
                    } else {
                        Text("Local")
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .padding(.top, 8)
                    }
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

            if item.privacy == .sensitive {
                let previewButtonTitle = L10n.text(
                    previewHidden ? "Show sensitive preview" : "Hide sensitive preview"
                )
                Button {
                    model.toggleSensitivePreview(item.id)
                } label: {
                    Text(previewButtonTitle)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .frame(height: 18)
                .help(previewButtonTitle)
                .accessibilityIdentifier("launcher.quickView.sensitivePreview")
            } else {
                Spacer().frame(height: 18)
            }

            Button {
                model.executeDefault()
            } label: {
                HStack {
                    Text(primaryActionTitle(for: item))
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
            .disabled(!model.canExecuteSelectedResult)
            .help(primaryActionTitle(for: item))
            .accessibilityIdentifier("launcher.quickView.primaryAction")

            Spacer().frame(height: 8)

            if let secondaryAction {
                Button {
                    model.executeAction(secondaryAction.id)
                } label: {
                    HStack {
                        Text(L10n.text(secondaryAction.title))
                        Spacer()
                        Text(secondaryAction.shortcut.map { shortcutLabel($0) } ?? "")
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
                .disabled(!model.canExecuteSelectedResult)
                .help(L10n.text(secondaryAction.title))
                .accessibilityIdentifier("launcher.quickView.secondaryAction")
            } else {
                Spacer().frame(height: 42)
            }

            Spacer().frame(height: 26)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.localStatus)
                        .accessibilityHidden(true)
                    Text(L10n.text("Built-in sources stay on this Mac"))
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(L10n.text("Files, apps, and clipboard are searched on device."))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                Text(L10n.text("LOCAL SOURCES · READY"))
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

    private func resultRow(_ item: LauncherItem, index: Int) -> some View {
        let selected = model.selectedItemID == item.id
        let previewHidden = hidesPreview(for: item)
        return HStack(spacing: 12) {
            resultIcon(for: item, selected: selected)
            Text(previewHidden ? L10n.text("Sensitive item") : localizedTitle(item))
                .font(.system(size: 19.5, weight: .regular))
                .lineLimit(1)
            Spacer(minLength: 12)
            if selected, item.privacy == .sensitive {
                Button {
                    model.toggleSensitivePreview(item.id)
                } label: {
                    Image(systemName: previewHidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .help(previewHidden ? L10n.text("Show sensitive preview") : L10n.text("Hide sensitive preview"))
                .accessibilityLabel(previewHidden ? L10n.text("Show sensitive preview") : L10n.text("Hide sensitive preview"))
            }
            if selected {
                selectedAction(for: item)
            }
        }
        .padding(.horizontal, LauncherPanelLayout.resultContentHorizontalInset)
        .frame(height: LauncherPanelLayout.resultRowHeight)
        .transientPanelSelectionStyle(
            isSelected: selected,
            cornerRadius: LauncherPanelLayout.selectionCornerRadius
        )
        .overlay(alignment: .bottom) {
            if !selected, index < model.displayOrderedResults.count - 1 {
                Rectangle()
                    .fill(palette.border.opacity(colorScheme == .dark ? 0.62 : 0.5))
                    .frame(height: 0.5)
                    .padding(.horizontal, LauncherPanelLayout.separatorHorizontalInset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectItem(item.id)
            model.executeDefault()
        }
        .onTapGesture { model.selectItem(item.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LauncherAccessibility.resultLabel(for: item, previewHidden: previewHidden))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(.default) {
            model.selectItem(item.id)
            model.executeDefault()
        }
    }

    @ViewBuilder
    private func selectedAction(for item: LauncherItem) -> some View {
        let label = HStack(spacing: 9) {
            Text(primaryActionTitle(for: item))
            Text("↩")
                .font(.system(size: 19, weight: .regular))
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(palette.accent)
        .accessibilityHidden(true)

        if colorScheme == .light {
            label
                .padding(.horizontal, 7)
                .frame(height: 30)
                .transientPanelGlassSurface(
                    cornerRadius: 15,
                    variant: .clear,
                    tint: Color.white.opacity(0.04),
                    fallback: palette.surfaceElevated,
                    edge: Color.white.opacity(0.52),
                    interactive: true
                )
        } else {
            label
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerStatus)
                .lineLimit(1)
                .foregroundStyle(palette.textSecondary)
            Spacer()
            footerShortcut("↩", label: model.layer == .results ? "Open" : "Run")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .frame(height: LauncherPanelLayout.footerHeight)
        .background(panelSurface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Action hint"))
    }

    private func footerShortcut(_ keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(L10n.text(label))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func confirmationOverlay(_ confirmation: LauncherViewModel.PendingConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label("Confirm action", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(L10n.text(confirmation.resolvedAction.descriptor.title))
                    .font(.title3.weight(.semibold))
                LabeledContent("Target", value: confirmation.targetTitle)
                    .lineLimit(2)
                Text("This action affects something outside Keyestro. Review the target before continuing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { model.cancelPendingAction() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Continue") { model.confirmPendingAction() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 420)
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
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(L10n.text("Executing action"))
                Text("Executing action…")
                    .font(.headline)
                Button("Cancel") { model.cancelExecution() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)
            .frame(width: 260)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(palette.surfaceElevated)
            }
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(palette.border, lineWidth: 1) }
            .shadow(radius: 18)
            .accessibilityElement(children: .contain)
        }
    }

    private var background: some View {
        panelSurface
    }

    private func handle(_ command: LauncherCommand) -> Bool {
        switch command {
        case .moveUp: model.moveSelection(-1)
        case .moveDown: model.moveSelection(1)
        case .submit:
            model.layer == .actions ? model.executeSelectedAction() : model.executeDefault()
        case .submitSecondary: model.executeSecondary()
        case .escape: model.handleEscape()
        case .selectAll: model.requestQueryFocus(selectAll: true)
        case .openSettings: model.onOpenSettings?()
        case .openFilters, .deleteSelection: return false
        case let .executeIndex(index): model.executeVisibleResult(at: index)
        case .tab: model.enterParameterForm()
        }
        return true
    }

    private var modeLabel: String {
        switch model.query.first {
        case "/": L10n.text("Files")
        case ">": L10n.text("Commands")
        case "=": L10n.text("Calculator")
        case "@": L10n.text("Extensions")
        default: L10n.text("All")
        }
    }

    private var scopeLabel: String {
        switch model.query.first {
        case "/", ">", "=", "@": modeLabel
        default: L10n.text("Local")
        }
    }

    private var footerStatus: String {
        if model.isSearching { return L10n.text("Searching…") }
        switch model.layer {
        case .actions:
            return L10n.format("%lld actions", Int64(model.visibleActions.count))
        case .parameters:
            return L10n.text("Enter parameters")
        case .results:
            return L10n.format("%lld results", Int64(model.results.count))
        }
    }

    private func providerTitle(_ providerID: ProviderID) -> String {
        switch providerID.rawValue {
        case "files": "Recent Files"
        case "applications": "Applications"
        case "clipboard": "Clipboard"
        case "calculator": "Calculator"
        case "windows": "Windows"
        case "system": "System Commands"
        case "scripts": "Scripts"
        case "quicklinks": "Quick Links"
        case "builtin.capture": "Capture"
        case "builtin.extensions": "Extensions"
        default:
            providerID.rawValue
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private func quickViewKind(for item: LauncherItem) -> String {
        switch item.canonicalResource {
        case let .file(url):
            switch url.pathExtension.lowercased() {
            case "md", "markdown": return L10n.text("Markdown")
            case "": return L10n.text("File")
            case let pathExtension: return pathExtension.uppercased()
            }
        case .application:
            return L10n.text("Application")
        case .url:
            return L10n.text("Link")
        case .command:
            return L10n.text("Command")
        case nil:
            return L10n.text(providerTitle(item.providerID))
        }
    }

    private func quickViewMetadata(for item: LauncherItem) -> String? {
        for accessory in item.accessories {
            if case let .text(value) = accessory { return value }
        }
        return item.subtitle.map { localizedSubtitle($0, for: item) }
    }

    private func quickViewTitle(for item: LauncherItem) -> String {
        guard case .file = item.canonicalResource else { return localizedTitle(item) }
        return URL(fileURLWithPath: localizedTitle(item)).deletingPathExtension().lastPathComponent
    }

    private func primaryActionTitle(for item: LauncherItem) -> String {
        let action = LauncherViewModel.primaryAction(for: item)
        if case .file = item.canonicalResource, action?.id.rawValue == "open" {
            return L10n.text("Open file")
        }
        return L10n.text(action?.title ?? "Open")
    }

    private func rowAccessory(for item: LauncherItem, selected: Bool) -> Accessory? {
        if let accessory = item.accessories.first { return accessory }
        if selected, case .file = item.canonicalResource { return .badge("FILE") }
        if item.providerID.rawValue == "applications", item.subtitle?.localizedCaseInsensitiveContains("currently open") == true {
            return .text("↩")
        }
        return nil
    }

    private func usesHighContrastGlyph(_ icon: IconReference?) -> Bool {
        if case let .systemSymbol(name) = icon { return name == "f.square.fill" }
        return false
    }

    @ViewBuilder
    private func resultIcon(for item: LauncherItem, selected: Bool) -> some View {
        if usesHighContrastGlyph(item.icon) {
            LauncherIcon(reference: item.icon)
                .frame(width: 48, height: 48)
                .foregroundStyle(palette.textPrimary)
        } else {
            LauncherIcon(reference: item.icon)
                .frame(width: 48, height: 48)
                .foregroundStyle(selected ? palette.accent : palette.textSecondary)
        }
    }

    @ViewBuilder
    private func resultAccessory(_ accessory: Accessory) -> some View {
        switch accessory {
        case let .badge(value):
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(iconSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.accent.opacity(0.32), lineWidth: 1)
                }
        case let .keyboardShortcut(shortcut):
            Text(shortcutLabel(shortcut))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
        case let .text(value):
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func shortcutLabel(_ shortcut: KeyestroDomain.KeyEquivalent) -> String {
        let modifiers: [(KeyModifier, String)] = [
            (.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘"),
        ]
        let prefix = modifiers.compactMap { shortcut.modifiers.contains($0.0) ? $0.1 : nil }.joined()
        let key: String
        switch shortcut.key.lowercased() {
        case "return", "enter": key = "↩"
        case "escape": key = "⎋"
        case "space": key = "Space"
        default: key = shortcut.key.uppercased()
        }
        return prefix + key
    }

    private var firstProblemStatus: ProviderStatus? {
        model.firstProblemStatus
    }

    private var emptyStateActions: LauncherEmptyStateView.Actions {
        switch firstProblemStatus {
        case .permissionDenied: .permissionsAndRetry
        case .unavailable, .failed: .retry
        default: .none
        }
    }

    private var statusTitle: String {
        if model.isSearching { return L10n.text("Searching…") }
        switch firstProblemStatus {
        case let .permissionDenied(error), let .unavailable(error), let .failed(error): return L10n.errorMessage(error)
        default: return L10n.text("launcher.empty")
        }
    }

    private var statusDetail: String? {
        switch firstProblemStatus {
        case let .permissionDenied(error), let .unavailable(error), let .failed(error):
            return L10n.recoverySuggestion(error)
        default: return model.query.isEmpty ? L10n.text("Start typing to search enabled providers.") : nil
        }
    }

    private var statusSymbol: String {
        switch firstProblemStatus {
        case .permissionDenied: "lock.trianglebadge.exclamationmark"
        case .unavailable, .failed: "exclamationmark.triangle"
        default: model.isSearching ? "magnifyingglass" : "tray"
        }
    }

    private func symbol(for icon: IconReference?) -> String? {
        if case let .systemSymbol(name) = icon { return name }
        return nil
    }

    private func localizedTitle(_ item: LauncherItem) -> String {
        localizesBuiltInText(item) ? L10n.text(item.title) : item.title
    }

    private func localizedSubtitle(_ subtitle: String, for item: LauncherItem) -> String {
        if item.providerID.rawValue == "files", subtitle.hasPrefix("Content match · ") {
            return L10n.format("file.content.match", String(subtitle.dropFirst("Content match · ".count)))
        }
        return localizesBuiltInText(item) ? L10n.text(subtitle) : subtitle
    }

    private func localizesBuiltInText(_ item: LauncherItem) -> Bool {
        item.providerID.rawValue == "system" || item.providerID.rawValue == "builtin.capture"
    }

    private func hidesPreview(for item: LauncherItem) -> Bool {
        switch item.privacy {
        case .normal: false
        case .sensitive: !model.isSensitivePreviewRevealed(item.id)
        case .secret: true
        }
    }
}

struct LauncherEmptyStateView: View {
    enum Actions: Equatable {
        case none
        case retry
        case permissionsAndRetry
    }

    let symbol: String
    let title: String
    let detail: String?
    let actions: Actions
    var onOpenPermissions: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButtons
        }
        .padding(.horizontal, 24)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch actions {
        case .none:
            EmptyView()
        case .retry:
            Button("Retry", action: onRetry)
        case .permissionsAndRetry:
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Open Permissions Settings", action: onOpenPermissions)
                    Button("Retry", action: onRetry)
                }
                VStack {
                    Button("Open Permissions Settings", action: onOpenPermissions)
                    Button("Retry", action: onRetry)
                }
            }
        }
    }
}

#if DEBUG
    struct LauncherEmptyStateView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                preview(
                    symbol: "tray",
                    title: L10n.text("launcher.empty"),
                    detail: L10n.text("Start typing to search enabled providers."),
                    actions: .none
                )
                .previewDisplayName("Empty")
                preview(
                    symbol: "lock.trianglebadge.exclamationmark",
                    title: L10n.text("Accessibility permission is required for window management."),
                    detail: L10n.text("Open Settings → Permissions to grant access, then refresh."),
                    actions: .permissionsAndRetry
                )
                .previewDisplayName("Permission denied")
                preview(
                    symbol: "exclamationmark.triangle",
                    title: L10n.text("A search provider could not complete the search."),
                    detail: L10n.text("Try again or disable this provider."),
                    actions: .retry
                )
                .previewDisplayName("Provider failure")
            }
        }

        private static func preview(
            symbol: String,
            title: String,
            detail: String?,
            actions: LauncherEmptyStateView.Actions
        ) -> some View {
            LauncherEmptyStateView(
                symbol: symbol,
                title: title,
                detail: detail,
                actions: actions
            )
            .frame(
                width: LauncherPanelLayout.windowWidth,
                height: LauncherPanelLayout.availableContentHeight(
                    panelHeight: actions == .none
                        ? LauncherPanelLayout.compactHeight
                        : LauncherPanelLayout.recoveryHeight
                )
            )
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
#endif

enum LauncherAccessibility {
    static func resultLabel(for item: LauncherItem, previewHidden: Bool) -> String {
        let title = previewHidden ? L10n.text("Sensitive item") : localizedTitle(item)
        guard !previewHidden, let subtitle = item.subtitle else { return title }
        return "\(title), \(localizedSubtitle(subtitle, for: item))"
    }

    private static func localizedTitle(_ item: LauncherItem) -> String {
        localizesBuiltInText(item) ? L10n.text(item.title) : item.title
    }

    private static func localizedSubtitle(_ subtitle: String, for item: LauncherItem) -> String {
        if item.providerID.rawValue == "files", subtitle.hasPrefix("Content match · ") {
            return L10n.format("file.content.match", String(subtitle.dropFirst("Content match · ".count)))
        }
        return localizesBuiltInText(item) ? L10n.text(subtitle) : subtitle
    }

    private static func localizesBuiltInText(_ item: LauncherItem) -> Bool {
        item.providerID.rawValue == "system" || item.providerID.rawValue == "builtin.capture"
    }
}

private struct LauncherIcon: View {
    let reference: IconReference?

    var body: some View {
        Group {
            switch reference {
            case let .systemSymbol(name):
                if name == "f.square.fill" {
                    Image(systemName: name).resizable().scaledToFit()
                } else {
                    Image(systemName: name).resizable().scaledToFit().padding(5)
                }
            case let .application(url), let .file(url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            case let .thumbnailPNG(data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "photo").resizable().scaledToFit().padding(5)
                }
            case .extensionAsset, .none:
                Image(systemName: "command").resizable().scaledToFit().padding(5)
            }
        }
        .accessibilityHidden(true)
    }
}
