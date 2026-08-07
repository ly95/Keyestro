import AppKit
import Combine
import Foundation
import KeyestroCore
import KeyestroDomain

@MainActor
final class LauncherViewModel: ObservableObject {
    enum Layer: Equatable {
        case results
        case actions
        case parameters
    }

    struct PendingConfirmation: Equatable {
        let request: ActionExecutionRequest
        let resolvedAction: ResolvedAction
        let targetTitle: String
    }

    struct ParameterFormState: Equatable {
        let itemID: ItemID
        let actionID: ActionID
        let definitions: [ArgumentDefinition]
        var values: [String: String]
    }

    @Published var query = ""
    @Published private(set) var results: [RankedItem] = []
    @Published private(set) var statuses: [ProviderID: ProviderStatus] = [:]
    @Published var selectedItemID: ItemID?
    @Published var selectedActionIndex = 0
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var isSearching = false
    @Published private(set) var isExecuting = false
    @Published private(set) var layer: Layer = .results
    @Published var message: String?
    @Published private(set) var messageDetail: String?
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var parameterForm: ParameterFormState?
    @Published private(set) var queryFocusToken = 0
    @Published private var revealedSensitiveItemIDs = Set<ItemID>()
    @Published private(set) var launcherAppearance: LauncherAppearancePreference

    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenPermissions: (() -> Void)?

    private let coordinator: QueryCoordinator
    private let actionRunner: ActionRunner
    private let settings: SettingsStore
    private var searchTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var activeExecutionID: UUID?
    private var messageTask: Task<Void, Never>?
    private var settingsCancellables = Set<AnyCancellable>()
    private var context = QueryContext()
    private var isComposing = false
    private var lastAnnouncedGeneration: UInt64?

    init(coordinator: QueryCoordinator, actionRunner: ActionRunner, settings: SettingsStore) {
        self.coordinator = coordinator
        self.actionRunner = actionRunner
        self.settings = settings
        launcherAppearance = settings.launcherAppearance
        settings.$launcherAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in self?.launcherAppearance = appearance }
            .store(in: &settingsCancellables)
    }

    var selectedItem: LauncherItem? {
        guard let selectedItemID else { return results.first?.item }
        return results.first(where: { $0.id == selectedItemID })?.item
    }

    var visibleActions: [ActionDescriptor] {
        selectedItem?.actions ?? []
    }

    var selectedPrimaryAction: ActionDescriptor? {
        selectedItem.flatMap(Self.primaryAction)
    }

    var selectedSecondaryAction: ActionDescriptor? {
        selectedItem.flatMap(Self.secondaryAction)
    }

    var canExecuteSelectedResult: Bool {
        selectedItem != nil && !isSearching && !isExecuting
    }

    var displayOrderedResults: [RankedItem] {
        var providerOrder: [ProviderID] = []
        var resultsByProvider: [ProviderID: [RankedItem]] = [:]
        for result in results {
            let providerID = result.item.providerID
            if resultsByProvider[providerID] == nil { providerOrder.append(providerID) }
            resultsByProvider[providerID, default: []].append(result)
        }
        return providerOrder.flatMap { resultsByProvider[$0] ?? [] }
    }

    var firstProblemStatus: ProviderStatus? {
        statuses.sorted { $0.key < $1.key }.lazy.compactMap { _, status in
            switch status {
            case .permissionDenied, .unavailable, .failed: status
            default: nil
            }
        }.first
    }

    var requiresExpandedEmptyState: Bool {
        results.isEmpty && firstProblemStatus != nil
    }

    func invoke(context: QueryContext) {
        self.context = context
        layer = .results
        pendingConfirmation = nil
        parameterForm = nil
        message = nil
        messageDetail = nil
        requestQueryFocus(selectAll: !query.isEmpty)
        performSearch(preservingCurrentResults: true)
    }

    func didDismiss() {
        searchTask?.cancel()
        searchTask = nil
        Task { await coordinator.cancelCurrentSearch() }
        isSearching = false
        layer = .results
        pendingConfirmation = nil
        parameterForm = nil
        revealedSensitiveItemIDs.removeAll()
    }

    func queryDidChange(_ value: String, isComposing: Bool) {
        query = value.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        self.isComposing = isComposing
        performSearch(preservingCurrentResults: false)
    }

    func isSensitivePreviewRevealed(_ itemID: ItemID) -> Bool {
        revealedSensitiveItemIDs.contains(itemID)
    }

    func toggleSensitivePreview(_ itemID: ItemID) {
        guard results.first(where: { $0.id == itemID })?.item.privacy == .sensitive else { return }
        if revealedSensitiveItemIDs.remove(itemID) == nil { revealedSensitiveItemIDs.insert(itemID) }
    }

    func moveSelection(_ delta: Int) {
        guard layer != .parameters else { return }
        guard layer == .results else {
            moveActionSelection(delta)
            return
        }
        let displayedResults = displayOrderedResults
        guard !displayedResults.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { id in displayedResults.firstIndex(where: { $0.id == id }) } ?? 0
        let newIndex = min(displayedResults.count - 1, max(0, currentIndex + delta))
        selectedItemID = displayedResults[newIndex].id
    }

    func selectItem(_ id: ItemID) {
        selectedItemID = id
    }

    func openActions() {
        guard canExecuteSelectedResult else { return }
        layer = .actions
        selectedActionIndex = 0
    }

    func closeActions() {
        layer = .results
        selectedActionIndex = 0
        requestQueryFocus(selectAll: false)
    }

    func handleEscape() {
        if isExecuting {
            cancelExecution()
        } else if pendingConfirmation != nil {
            pendingConfirmation = nil
        } else if layer == .parameters {
            parameterForm = nil
            layer = .results
            requestQueryFocus(selectAll: false)
        } else if layer == .actions {
            closeActions()
        } else if !query.isEmpty {
            queryDidChange("", isComposing: false)
            requestQueryFocus(selectAll: false)
        } else {
            onDismiss?()
        }
    }

    func executeDefault() {
        guard canExecuteSelectedResult, let item = selectedItem else { return }
        execute(itemID: item.id, actionID: item.defaultActionID)
    }

    func executeSecondary() {
        guard canExecuteSelectedResult, let item = selectedItem else { return }
        execute(itemID: item.id, actionID: selectedSecondaryAction?.id ?? item.defaultActionID)
    }

    func executeAction(_ actionID: ActionID) {
        guard canExecuteSelectedResult,
            let item = selectedItem,
            item.actions.contains(where: { $0.id == actionID })
        else { return }
        execute(itemID: item.id, actionID: actionID)
    }

    func executeVisibleResult(at index: Int) {
        let displayedResults = displayOrderedResults
        guard !isSearching,
            !isExecuting,
            settings.numberShortcutsEnabled,
            displayedResults.indices.contains(index)
        else { return }
        let item = displayedResults[index].item
        selectedItemID = item.id
        execute(itemID: item.id, actionID: item.defaultActionID)
    }

    func executeSelectedAction() {
        guard canExecuteSelectedResult,
            let item = selectedItem,
            item.actions.indices.contains(selectedActionIndex)
        else { return }
        execute(itemID: item.id, actionID: item.actions[selectedActionIndex].id)
    }

    func enterParameterForm() {
        guard canExecuteSelectedResult, let item = selectedItem else { return }
        let action: ActionDescriptor?
        if layer == .actions, item.actions.indices.contains(selectedActionIndex) {
            action = item.actions[selectedActionIndex]
        } else {
            action = item.actions.first(where: { $0.id == item.defaultActionID })
        }
        guard let action, !action.arguments.isEmpty else { return }
        presentParameterForm(itemID: item.id, action: action)
    }

    func requestQueryFocus(selectAll: Bool) {
        queryFocusToken += selectAll ? 2 : 1
    }

    func retrySearch() {
        performSearch(preservingCurrentResults: true)
    }

    func confirmPendingAction() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        beginExecution(pending.request.executionID)
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await coordinator.resolve(pending.request) {
            case let .failure(error):
                guard finishExecution(pending.request.executionID) else { return }
                showMessage(L10n.errorMessage(error), detail: L10n.recoverySuggestion(error))
            case let .success(resolved) where resolved != pending.resolvedAction:
                guard finishExecution(pending.request.executionID) else { return }
                pendingConfirmation = PendingConfirmation(
                    request: pending.request,
                    resolvedAction: resolved,
                    targetTitle: confirmationTarget(for: resolved)
                )
            case let .success(resolved):
                await run(
                    request: pending.request,
                    resolvedAction: resolved,
                    targetTitle: pending.targetTitle,
                    riskConfirmed: true
                )
            }
        }
    }

    func cancelPendingAction() {
        pendingConfirmation = nil
        requestQueryFocus(selectAll: false)
    }

    func cancelExecution() {
        guard isExecuting else { return }
        activeExecutionID = nil
        isExecuting = false
        let task = executionTask
        executionTask = nil
        task?.cancel()
        showMessage("Cancelled")
        requestQueryFocus(selectAll: false)
    }

    func updateParameter(id: String, value: String) {
        guard var form = parameterForm, form.definitions.contains(where: { $0.id == id }) else { return }
        form.values[id] = value
        parameterForm = form
    }

    func submitParameters() {
        guard canExecuteSelectedResult, let form = parameterForm else { return }
        var arguments: [String: ArgumentValue] = [:]
        for definition in form.definitions {
            let value = form.values[definition.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if definition.required && value.isEmpty {
                showMessage(L10n.format("launcher.parameter.required", definition.title))
                return
            }
            guard !value.isEmpty else { continue }
            switch definition.kind {
            case .file, .directory:
                arguments[definition.id] = .file(URL(fileURLWithPath: value).standardizedFileURL)
            case .text, .password, .choice:
                arguments[definition.id] = .text(value)
            }
        }
        parameterForm = nil
        layer = .results
        execute(itemID: form.itemID, actionID: form.actionID, suppliedArguments: arguments)
    }

    private func performSearch(preservingCurrentResults: Bool) {
        searchTask?.cancel()
        revealedSensitiveItemIDs.removeAll()
        let rawText = query
        let composing = isComposing
        let prefixesEnabled = settings.prefixesEnabled
        isSearching = true

        searchTask = Task { [weak self] in
            guard let self else { return }
            let stream = await coordinator.search(
                rawText: rawText,
                isComposing: composing,
                prefixesEnabled: prefixesEnabled,
                context: context
            )
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                apply(snapshot, preservingCurrentResults: preservingCurrentResults)
            }
        }
    }

    private func apply(_ snapshot: QuerySnapshot, preservingCurrentResults: Bool) {
        guard snapshot.generation >= generation else { return }
        let oldResults = results
        let oldIndex = selectedItemID.flatMap { id in oldResults.firstIndex(where: { $0.id == id }) } ?? 0

        generation = snapshot.generation
        statuses = snapshot.statuses
        isSearching = !snapshot.isComplete

        if preservingCurrentResults,
            !snapshot.isComplete,
            snapshot.items.isEmpty,
            !results.isEmpty
        {
            return
        }

        results = snapshot.items

        if snapshot.isComplete, lastAnnouncedGeneration != snapshot.generation {
            lastAnnouncedGeneration = snapshot.generation
            announceResultCount(snapshot.items.count)
        }

        if let selectedItemID, results.contains(where: { $0.id == selectedItemID }) {
            return
        }
        guard !results.isEmpty else {
            selectedItemID = nil
            return
        }
        selectedItemID = results[min(oldIndex, results.count - 1)].id
    }

    private func moveActionSelection(_ delta: Int) {
        guard !visibleActions.isEmpty else { return }
        selectedActionIndex = min(visibleActions.count - 1, max(0, selectedActionIndex + delta))
    }

    private func execute(
        itemID: ItemID,
        actionID: ActionID,
        suppliedArguments: [String: ArgumentValue]? = nil
    ) {
        guard !isSearching, !isExecuting else { return }
        guard let item = results.first(where: { $0.id == itemID })?.item,
            let descriptor = item.actions.first(where: { $0.id == actionID })
        else {
            showMessage("The selected action is no longer available")
            return
        }
        if suppliedArguments == nil, !descriptor.arguments.isEmpty {
            presentParameterForm(itemID: itemID, action: descriptor)
            return
        }
        let executionID = UUID()
        let request = ActionExecutionRequest(
            executionID: executionID,
            generation: generation,
            itemID: itemID,
            actionID: actionID,
            arguments: suppliedArguments ?? [:]
        )
        beginExecution(executionID)
        executionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await coordinator.resolve(request)
            switch resolution {
            case let .failure(error):
                guard finishExecution(executionID) else { return }
                showMessage(L10n.errorMessage(error), detail: L10n.recoverySuggestion(error))
            case let .success(resolved):
                await run(
                    request: request,
                    resolvedAction: resolved,
                    targetTitle: confirmationTarget(for: resolved),
                    riskConfirmed: false
                )
            }
        }
    }

    private func run(
        request: ActionExecutionRequest,
        resolvedAction: ResolvedAction,
        targetTitle: String,
        riskConfirmed: Bool
    ) async {
        let outcome = await actionRunner.run(
            executionID: request.executionID,
            resolvedAction: resolvedAction,
            arguments: request.arguments,
            riskConfirmed: riskConfirmed
        )
        guard finishExecution(request.executionID) else { return }
        switch outcome {
        case let .confirmationRequired(action):
            pendingConfirmation = PendingConfirmation(
                request: request,
                resolvedAction: action,
                targetTitle: targetTitle
            )
        case let .completed(result):
            handle(result, behavior: resolvedAction.descriptor.behavior)
        }
    }

    private func beginExecution(_ executionID: UUID) {
        executionTask?.cancel()
        activeExecutionID = executionID
        isExecuting = true
    }

    @discardableResult
    private func finishExecution(_ executionID: UUID) -> Bool {
        guard activeExecutionID == executionID else { return false }
        activeExecutionID = nil
        executionTask = nil
        isExecuting = false
        return true
    }

    private func presentParameterForm(itemID: ItemID, action: ActionDescriptor) {
        var defaults: [String: String] = [:]
        for definition in action.arguments {
            if case let .choice(options) = definition.kind, let first = options.first {
                defaults[definition.id] = first
            }
        }
        parameterForm = ParameterFormState(
            itemID: itemID,
            actionID: action.id,
            definitions: action.arguments,
            values: defaults
        )
        layer = .parameters
    }

    private func handle(_ result: ActionResult, behavior: ActionBehavior) {
        switch result {
        case let .success(message):
            if behavior == .replaceContent, let message {
                queryDidChange(message, isComposing: false)
                requestQueryFocus(selectAll: false)
            } else if behavior == .closeLauncher {
                onDismiss?()
            } else if let message {
                showMessage(L10n.text(message))
            }
        case .cancelled:
            showMessage("Cancelled")
        case let .failure(error):
            showMessage(L10n.errorMessage(error), detail: L10n.recoverySuggestion(error))
        }
    }

    private func confirmationTarget(for action: ResolvedAction) -> String {
        if let explicitTarget = action.descriptor.confirmationTarget {
            return L10n.text(explicitTarget)
        }
        guard action.privacy == .normal else { return L10n.text("Sensitive item") }
        guard let subtitle = action.displayedSubtitle, !subtitle.isEmpty else { return action.displayedTitle }
        return "\(action.displayedTitle) — \(subtitle)".limitedToUnicodeScalars(DomainLimits.subtitleUnicodeScalars)
    }

    private func showMessage(_ value: String, detail: String? = nil) {
        messageTask?.cancel()
        message = L10n.text(value)
        messageDetail = detail
        let visibility: Duration = detail == nil ? .seconds(2) : .seconds(6)
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: visibility)
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.messageDetail = nil
        }
    }

    private func announceResultCount(_ count: Int) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: L10n.format("accessibility.results.count", Int64(count)),
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue),
            ]
        )
    }

    static func primaryAction(for item: LauncherItem) -> ActionDescriptor? {
        item.actions.first { $0.id == item.defaultActionID }
    }

    static func secondaryAction(for item: LauncherItem) -> ActionDescriptor? {
        let alternateActions = item.actions.filter { $0.id != item.defaultActionID }
        return alternateActions.first(where: isCommandReturnAction)
            ?? alternateActions.first { $0.id.rawValue == "reveal" }
            ?? alternateActions.first
    }

    private static func isCommandReturnAction(_ action: ActionDescriptor) -> Bool {
        guard let shortcut = action.shortcut else { return false }
        return ["return", "enter"].contains(shortcut.key.lowercased())
            && shortcut.modifiers.contains(.command)
    }
}
