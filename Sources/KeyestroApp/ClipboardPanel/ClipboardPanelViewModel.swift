import AppKit
import Combine
import Foundation
import KeyestroCore
import KeyestroDomain

enum ClipboardPanelFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case links
    case files
    case images

    var id: String { rawValue }

    var contentType: ClipboardContentType? {
        switch self {
        case .all: nil
        case .text: .text
        case .links: .url
        case .files: .files
        case .images: .image
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .files: "Files"
        case .images: "Images"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .links: "link"
        case .files: "doc.on.doc"
        case .images: "photo"
        }
    }
}

@MainActor
final class ClipboardPanelViewModel: ObservableObject {
    enum Layer: Equatable {
        case results
        case actions
        case filters
    }

    enum PendingConfirmation: Equatable {
        case delete(id: String)
        case clear(type: ClipboardContentType)
        case clearAll
    }

    struct ConfirmationPresentation: Equatable {
        let title: String
        let message: String
        let buttonTitle: String
        let isDestructive: Bool
    }

    @Published var query = ""
    @Published private(set) var entries: [ClipboardSearchEntry] = []
    @Published var selectedItemID: String?
    @Published private(set) var filter: ClipboardPanelFilter = .all
    @Published private(set) var state: ClipboardStoreState = .disabled
    @Published private(set) var layer: Layer = .results
    @Published var selectedActionIndex = 0
    @Published var selectedFilterIndex = 0
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    @Published private(set) var isSearching = false
    @Published private(set) var isExecuting = false
    @Published private(set) var isAutoPasting = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPaused: Bool
    @Published var message: String?
    @Published private(set) var messageDetail: String?
    @Published private(set) var messageOffersPermissions = false
    @Published private(set) var queryFocusRequest = LauncherSearchFocusRequest.initial
    @Published private var revealedSensitiveItemIDs = Set<String>()
    @Published private(set) var launcherAppearance: LauncherAppearancePreference

    var onDismiss: (() -> Void)?
    var onOpenPrivacy: (() -> Void)?
    var onOpenPermissions: (() -> Void)?

    private let store: ClipboardStore?
    private let actions: ClipboardActionService?
    private let settings: SettingsStore
    private var context = QueryContext()
    private var searchTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var isComposing = false
    private var cancellables = Set<AnyCancellable>()

    init(
        store: ClipboardStore?,
        actions: ClipboardActionService?,
        settings: SettingsStore
    ) {
        self.store = store
        self.actions = actions
        self.settings = settings
        isEnabled = settings.clipboardEnabled
        isPaused = settings.clipboardPaused
        launcherAppearance = settings.launcherAppearance

        settings.$clipboardEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.clipboardEnabledDidChange(enabled) }
            .store(in: &cancellables)
        settings.$clipboardPaused
            .removeDuplicates()
            .sink { [weak self] paused in self?.isPaused = paused }
            .store(in: &cancellables)
        settings.$launcherAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in self?.launcherAppearance = appearance }
            .store(in: &cancellables)
    }

    var selectedEntry: ClipboardSearchEntry? {
        guard let selectedItemID else { return entries.first }
        return entries.first(where: { $0.id == selectedItemID })
    }

    var visibleActions: [ActionDescriptor] {
        guard let selectedEntry else { return [] }
        return ClipboardActionCatalog.descriptors(
            itemID: selectedEntry.id,
            pasteConfirmationTarget: pasteConfirmationTarget
        )
    }

    var canExecuteSelectedEntry: Bool {
        selectedEntry != nil
            && canBrowse
            && actions != nil
            && !isSearching
            && !isExecuting
            && pendingConfirmation == nil
    }

    func actionDescriptor(for action: ClipboardActionKind) -> ActionDescriptor? {
        visibleActions.first { $0.id == action.id }
    }

    var filters: [ClipboardPanelFilter] { ClipboardPanelFilter.allCases }

    var canBrowse: Bool {
        if case .ready = state { true } else { false }
    }

    var canClearHistory: Bool { canBrowse }

    var pendingConfirmationPresentation: ConfirmationPresentation? {
        guard let pendingConfirmation else { return nil }
        switch pendingConfirmation {
        case let .delete(id):
            return ConfirmationPresentation(
                title: L10n.text("Delete clipboard item?"),
                message: L10n.format("This permanently deletes encrypted clipboard item ID %@.", id),
                buttonTitle: L10n.text("Delete"),
                isDestructive: true
            )
        case let .clear(type):
            return ConfirmationPresentation(
                title: L10n.text("Clear clipboard history by type?"),
                message: L10n.format("This permanently deletes all encrypted %@ clipboard items from this Mac.", typeLabel(type)),
                buttonTitle: L10n.text("Clear"),
                isDestructive: true
            )
        case .clearAll:
            return ConfirmationPresentation(
                title: L10n.text("Clear all clipboard history?"),
                message: L10n.text("This permanently deletes all encrypted clipboard items from this Mac."),
                buttonTitle: L10n.text("Clear All"),
                isDestructive: true
            )
        }
    }

    func invoke(context: QueryContext) {
        self.context = context
        query = ""
        filter = .all
        selectedItemID = nil
        selectedActionIndex = 0
        selectedFilterIndex = 0
        layer = .results
        pendingConfirmation = nil
        message = nil
        messageDetail = nil
        messageOffersPermissions = false
        revealedSensitiveItemIDs.removeAll()
        isComposing = false
        isEnabled = settings.clipboardEnabled
        isPaused = settings.clipboardPaused
        requestQueryFocus(selectAll: false)
        observeStore()
    }

    func didDismiss() {
        searchTask?.cancel()
        searchTask = nil
        stateTask?.cancel()
        stateTask = nil
        executionTask?.cancel()
        executionTask = nil
        messageTask?.cancel()
        messageTask = nil
        isSearching = false
        isExecuting = false
        isAutoPasting = false
        layer = .results
        pendingConfirmation = nil
        revealedSensitiveItemIDs.removeAll()
    }

    func queryDidChange(_ value: String, isComposing: Bool) {
        query = value.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        self.isComposing = isComposing
        revealedSensitiveItemIDs.removeAll()
        guard !isComposing else {
            searchTask?.cancel()
            searchTask = nil
            searchGeneration &+= 1
            isSearching = false
            return
        }
        performSearch()
    }

    func moveSelection(_ delta: Int) {
        switch layer {
        case .results:
            guard !entries.isEmpty else { return }
            let current = selectedItemID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } ?? 0
            let next = min(entries.count - 1, max(0, current + delta))
            selectedItemID = entries[next].id
        case .actions:
            guard !visibleActions.isEmpty else { return }
            selectedActionIndex = min(visibleActions.count - 1, max(0, selectedActionIndex + delta))
        case .filters:
            selectedFilterIndex = min(filters.count - 1, max(0, selectedFilterIndex + delta))
        }
    }

    func selectItem(_ id: String) {
        selectedItemID = id
    }

    func openActions() {
        guard canExecuteSelectedEntry else { return }
        layer = .actions
        selectedActionIndex = 0
    }

    func openFilters() {
        guard canBrowse else { return }
        layer = .filters
        selectedFilterIndex = filters.firstIndex(of: filter) ?? 0
    }

    func applyFilter(_ newFilter: ClipboardPanelFilter) {
        filter = newFilter
        layer = .results
        revealedSensitiveItemIDs.removeAll()
        performSearch()
        requestQueryFocus(selectAll: false)
    }

    func applySelectedFilter() {
        guard filters.indices.contains(selectedFilterIndex) else { return }
        applyFilter(filters[selectedFilterIndex])
    }

    func executeDefault() {
        requestAction(.autoPaste)
    }

    func executeSecondary() {
        requestAction(.copy)
    }

    func executeSelectedAction() {
        guard canExecuteSelectedEntry,
            visibleActions.indices.contains(selectedActionIndex),
            let action = ClipboardActionKind(rawValue: visibleActions[selectedActionIndex].id.rawValue)
        else { return }
        requestAction(action)
    }

    func requestDeleteSelected() {
        requestAction(.delete)
    }

    func requestClearCurrentType() {
        guard let type = filter.contentType else { return }
        pendingConfirmation = .clear(type: type)
    }

    func requestClearAll() {
        pendingConfirmation = .clearAll
    }

    func confirmPendingAction() {
        guard let pendingConfirmation else { return }
        self.pendingConfirmation = nil
        switch pendingConfirmation {
        case let .delete(id):
            performAction(.delete, itemID: id)
        case let .clear(type):
            clear(type: type)
        case .clearAll:
            clear(type: nil)
        }
    }

    func cancelPendingAction() {
        pendingConfirmation = nil
        requestQueryFocus(selectAll: false)
    }

    func handleEscape() {
        if pendingConfirmation != nil {
            cancelPendingAction()
        } else if layer != .results {
            layer = .results
            requestQueryFocus(selectAll: false)
        } else if !query.isEmpty {
            queryDidChange("", isComposing: false)
            requestQueryFocus(selectAll: false)
        } else {
            onDismiss?()
        }
    }

    func toggleSensitivePreview(_ id: String) {
        guard entries.first(where: { $0.id == id })?.isSensitive == true else { return }
        if revealedSensitiveItemIDs.remove(id) == nil { revealedSensitiveItemIDs.insert(id) }
    }

    func isSensitivePreviewRevealed(_ id: String) -> Bool {
        revealedSensitiveItemIDs.contains(id)
    }

    func enableHistory() {
        settings.clipboardEnabled = true
        settings.clipboardPaused = false
    }

    func resumeMonitoring() {
        settings.clipboardPaused = false
    }

    func retry() {
        guard let store else {
            applyStoreState(storageUnavailableState)
            return
        }
        state = .loading
        Task {
            await store.initialize(enabled: settings.clipboardEnabled)
        }
    }

    func requestQueryFocus(selectAll: Bool) {
        queryFocusRequest = queryFocusRequest.next(selectAll: selectAll)
    }

    private func clipboardEnabledDidChange(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            if case .disabled = state { state = .loading }
        } else {
            applyStoreState(.disabled)
        }
    }

    private func observeStore() {
        stateTask?.cancel()
        guard let store else {
            applyStoreState(storageUnavailableState)
            return
        }
        stateTask = Task { [weak self] in
            let updates = await store.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.applyStoreState(state)
            }
        }
    }

    private func applyStoreState(_ newState: ClipboardStoreState) {
        if !settings.clipboardEnabled {
            state = .disabled
        } else if case .disabled = newState {
            state = .loading
        } else {
            state = newState
        }
        guard case .ready = state else {
            searchTask?.cancel()
            isSearching = false
            entries = []
            selectedItemID = nil
            return
        }
        performSearch()
    }

    private func performSearch() {
        searchTask?.cancel()
        guard !isComposing, case .ready = state, let store else {
            isSearching = false
            return
        }
        searchGeneration &+= 1
        let generation = searchGeneration
        let rawQuery = query
        let contentType = filter.contentType
        isSearching = true
        searchTask = Task { [weak self] in
            let result = await store.search(
                rawQuery,
                contentType: contentType,
                limit: ClipboardStore.maximumSearchResults
            )
            guard !Task.isCancelled, let self, generation == searchGeneration else { return }
            isSearching = false
            switch result {
            case let .success(newEntries):
                applyEntries(newEntries)
            case let .failure(error):
                state = .failed(error)
                entries = []
                selectedItemID = nil
            }
        }
    }

    private func applyEntries(_ newEntries: [ClipboardSearchEntry]) {
        let oldIndex = selectedItemID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } ?? 0
        entries = newEntries
        if let selectedItemID, entries.contains(where: { $0.id == selectedItemID }) { return }
        selectedItemID = entries.isEmpty ? nil : entries[min(oldIndex, entries.count - 1)].id
    }

    private func requestAction(_ action: ClipboardActionKind) {
        guard canExecuteSelectedEntry, let id = selectedEntry?.id else { return }
        switch action {
        case .copy, .autoPaste:
            performAction(action, itemID: id)
        case .delete:
            pendingConfirmation = .delete(id: id)
        }
    }

    private func performAction(_ action: ClipboardActionKind, itemID: String) {
        guard !isExecuting, let actions else {
            if actions == nil { showMessage(L10n.text("Clipboard actions are unavailable.")) }
            return
        }
        isExecuting = true
        isAutoPasting = action == .autoPaste
        executionTask?.cancel()
        executionTask = Task { [weak self] in
            guard let self else { return }
            let target = context.frontmostBundleIdentifier.map {
                AutoPasteTarget(
                    bundleIdentifier: $0,
                    processIdentifier: context.frontmostProcessIdentifier,
                    activationPolicy: .activateIfNeeded
                )
            }
            let result = await actions.execute(
                action,
                itemID: itemID,
                target: target
            )
            guard !Task.isCancelled else { return }
            isExecuting = false
            isAutoPasting = false
            executionTask = nil
            layer = .results
            switch result {
            case let .success(message):
                if action == .copy || action == .autoPaste {
                    onDismiss?()
                } else if let message {
                    showMessage(L10n.text(message))
                }
            case .cancelled:
                showMessage(L10n.text("Cancelled"))
            case let .failure(error):
                showMessage(
                    L10n.errorMessage(error),
                    detail: L10n.recoverySuggestion(error),
                    offersPermissions: error.code == "clipboard.autoPaste.permissionDenied"
                )
                requestQueryFocus(selectAll: false)
            }
        }
    }

    private func clear(type: ClipboardContentType?) {
        guard !isExecuting, let store else { return }
        isExecuting = true
        executionTask?.cancel()
        executionTask = Task { [weak self] in
            guard let self else { return }
            let result =
                if let type {
                    await store.clear(type: type)
                } else {
                    await store.clear()
                }
            guard !Task.isCancelled else { return }
            isExecuting = false
            executionTask = nil
            switch result {
            case .success:
                showMessage(L10n.text(type == nil ? "Clipboard history cleared." : "Selected clipboard history cleared."))
            case let .failure(error):
                showMessage(L10n.errorMessage(error), detail: L10n.recoverySuggestion(error))
            }
        }
    }

    private var pasteConfirmationTarget: String {
        Self.pasteConfirmationTarget(
            applicationName: context.frontmostApplicationName,
            bundleIdentifier: context.frontmostBundleIdentifier,
            localizeFallback: L10n.text
        )
    }

    static func pasteConfirmationTarget(
        applicationName: String?,
        bundleIdentifier: String?,
        localizeFallback: (String) -> String
    ) -> String {
        let target = ClipboardActionCatalog.pasteConfirmationTarget(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        guard applicationName == nil, bundleIdentifier == nil else { return target }
        return localizeFallback(target)
    }

    private var storageUnavailableState: ClipboardStoreState {
        .failed(
            ErrorDescriptor(
                code: "clipboard.storageUnavailable",
                message: "Clipboard history storage is unavailable.",
                recoverySuggestion: "Restart Keyestro, then review Privacy settings if the problem continues."
            )
        )
    }

    private func typeLabel(_ type: ClipboardContentType) -> String {
        switch type {
        case .text: L10n.text("text")
        case .url: L10n.text("link")
        case .files: L10n.text("file")
        case .image: L10n.text("image")
        }
    }

    private func showMessage(
        _ value: String,
        detail: String? = nil,
        offersPermissions: Bool = false
    ) {
        messageTask?.cancel()
        message = value
        messageDetail = detail
        messageOffersPermissions = offersPermissions
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: detail == nil ? .seconds(2) : .seconds(6))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.messageDetail = nil
            self?.messageOffersPermissions = false
        }
    }
}
