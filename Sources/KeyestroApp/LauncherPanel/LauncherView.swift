import AppKit
import KeyestroDomain
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherViewModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedArgumentID: String?

    private var visualAccessibility: LauncherVisualAccessibilityPolicy {
        LauncherVisualAccessibilityPolicy(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchHeader
                Divider()
                content
                Divider()
                footer
            }
            .background(background)

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
                    if reduceTransparency {
                        Capsule().fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.8), lineWidth: 1)
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: modeSymbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            LauncherSearchField(
                text: $model.query,
                focusToken: model.queryFocusToken,
                placeholder: L10n.text("launcher.search.placeholder"),
                onChange: { text, composing in
                    model.queryDidChange(text, isComposing: composing)
                },
                onCommand: handle
            )
            .frame(height: 44)
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Searching"))
            }
            Text(modeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, ranked in
                            resultRow(ranked.item, index: index)
                                .id(ranked.id)
                        }
                    }
                    .padding(8)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.text("Results"))
                }
                .onChange(of: model.selectedItemID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
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
                Picker(L10n.text(definition.title), selection: parameterBinding(definition.id, value: value)) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
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
            ForEach(Array(model.visibleActions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 12) {
                    Image(systemName: symbol(for: action.icon) ?? "bolt")
                        .frame(width: 24)
                    Text(L10n.text(action.title))
                    Spacer()
                    if action.risk != .safe {
                        Image(systemName: action.risk == .destructive ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                            .foregroundStyle(action.risk == .destructive ? .red : .orange)
                            .accessibilityLabel(
                                L10n.text(action.risk == .destructive ? "Destructive" : "Confirmation required")
                            )
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(
                    index == model.selectedActionIndex
                        ? Color.accentColor.opacity(visualAccessibility.selectionOpacity) : .clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    if index == model.selectedActionIndex, visualAccessibility.usesStrongSelectionOutline {
                        RoundedRectangle(cornerRadius: 9).stroke(.primary, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.text(action.title))
                .accessibilityAddTraits(.isButton)
                .onTapGesture {
                    model.selectedActionIndex = index
                    model.executeSelectedAction()
                }
                .accessibilityAddTraits(index == model.selectedActionIndex ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: statusSymbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(statusTitle)
                .font(.headline)
            if let detail = statusDetail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            switch firstProblemStatus {
            case .permissionDenied:
                HStack {
                    Button("Open Permissions Settings") { model.onOpenPermissions?() }
                    Button("Retry") { model.retrySearch() }
                }
            case .unavailable, .failed:
                Button("Retry") { model.retrySearch() }
            default:
                EmptyView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func resultRow(_ item: LauncherItem, index: Int) -> some View {
        let selected = model.selectedItemID == item.id
        let previewHidden = hidesPreview(for: item)
        return HStack(spacing: 12) {
            LauncherIcon(reference: item.icon)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(previewHidden ? L10n.text("Sensitive item") : localizedTitle(item))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(previewHidden ? L10n.text("Preview hidden") : localizedSubtitle(subtitle, for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
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
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(selected ? Color.accentColor.opacity(visualAccessibility.selectionOpacity) : .clear)
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 8)
            }
        }
        .overlay {
            if selected, visualAccessibility.usesStrongSelectionOutline {
                RoundedRectangle(cornerRadius: 10).stroke(.primary, lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    private var footer: some View {
        HStack(spacing: 8) {
            Text(
                model.layer == .actions
                    ? L10n.text("Choose action")
                    : (model.layer == .parameters
                        ? L10n.text("Enter parameters")
                        : L10n.text(model.selectedItem?.actions.first?.title ?? "Ready"))
            )
            .lineLimit(1)
            Spacer()
            Text(model.selectedItem.map { $0.providerID.rawValue } ?? "Keyestro")
                .foregroundStyle(.secondary)
            Text(model.layer == .actions || model.layer == .parameters ? "↩ Run" : "⌘K Actions")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("Action hint"))
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
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                }
            }
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
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                }
            }
            .shadow(radius: 18)
            .accessibilityElement(children: .contain)
        }
    }

    private var background: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            }
        }
    }

    private func handle(_ command: LauncherCommand) -> Bool {
        switch command {
        case .moveUp: model.moveSelection(-1)
        case .moveDown: model.moveSelection(1)
        case .submit:
            model.layer == .actions ? model.executeSelectedAction() : model.executeDefault()
        case .submitSecondary: model.executeSecondary()
        case .openActions: model.openActions()
        case .escape: model.handleEscape()
        case .selectAll: model.requestQueryFocus(selectAll: true)
        case .openSettings: model.onOpenSettings?()
        case let .executeIndex(index): model.executeVisibleResult(at: index)
        case .tab: model.enterParameterForm()
        }
        return true
    }

    private var modeSymbol: String {
        switch model.query.first {
        case "/": "doc.text.magnifyingglass"
        case ">": "terminal"
        case "=": "function"
        case "@": "puzzlepiece.extension"
        default: "command"
        }
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

    private var firstProblemStatus: ProviderStatus? {
        model.statuses.values.first {
            switch $0 {
            case .permissionDenied, .unavailable, .failed: true
            default: false
            }
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

struct LauncherVisualAccessibilityPolicy: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let increaseContrast: Bool

    var usesStrongSelectionOutline: Bool {
        differentiateWithoutColor || increaseContrast
    }

    var selectionOpacity: Double {
        increaseContrast ? 0.34 : 0.20
    }
}

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
                Image(systemName: name).resizable().scaledToFit().padding(5)
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

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
