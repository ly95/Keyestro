import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@MainActor
private final class TestSystemCommandBoundary: SystemCommandServicing, SystemCommandConfirmationServicing {
    var explanationShown = false
    var executeCount = 0
    var result: Result<Void, ErrorDescriptor> = .success(())

    func shouldConfirmSleep() -> Bool { !explanationShown }
    func markSleepExplanationShown() { explanationShown = true }

    func execute(_ command: SystemCommandID) -> Result<Void, ErrorDescriptor> {
        executeCount += 1
        return result
    }
}

@Test @MainActor func defaultSystemConfirmationAndInvalidCommandsFailClosed() async {
    let confirmation = AlwaysConfirmSystemCommands()
    #expect(confirmation.shouldConfirmSleep())
    confirmation.markSleepExplanationShown()

    let boundary = TestSystemCommandBoundary()
    let provider = SystemCommandProvider(service: boundary, confirmation: confirmation)
    let invalid = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: "other", providerStableID: "unknown"),
            actionID: "wrong",
            arguments: [:]
        )
    )
    #expect(invalid == .failure(ErrorDescriptor(code: "system.invalidCommand", message: "The system command is invalid.")))

    let noMatches = await systemCommandItems(
        from: provider,
        query: "zzzz-no-system-command-matches"
    )
    #expect(noMatches.isEmpty)

    boundary.result = .failure(ErrorDescriptor(code: "system.denied", message: "Denied"))
    let failed = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: SystemCommandID.openHomeFolder.rawValue),
            actionID: "execute",
            arguments: [:]
        )
    )
    #expect(failed == .failure(ErrorDescriptor(code: "system.denied", message: "Denied")))
}

@Test func sleepExplainsFirstUseAndCanThenFollowTheUserPreference() async {
    let boundary = await MainActor.run { TestSystemCommandBoundary() }
    let provider = SystemCommandProvider(service: boundary, confirmation: boundary)

    let firstItems = await systemCommandItems(from: provider)
    let firstSleep = firstItems.first { $0.id.providerStableID == SystemCommandID.sleepSystem.rawValue }
    #expect(firstSleep?.actions.first?.risk == .externalSideEffect)

    let result = await provider.execute(
        request: ProviderActionRequest(
            executionID: UUID(),
            itemID: ItemID(providerID: provider.descriptor.id, providerStableID: SystemCommandID.sleepSystem.rawValue),
            actionID: "execute",
            arguments: [:]
        )
    )
    #expect(result == .success())
    #expect(await MainActor.run { boundary.executeCount } == 1)

    let laterItems = await systemCommandItems(from: provider)
    let laterSleep = laterItems.first { $0.id.providerStableID == SystemCommandID.sleepSystem.rawValue }
    #expect(laterSleep?.actions.first?.risk == .safe)
}

private func systemCommandItems(from provider: SystemCommandProvider, query: String = "") async -> [LauncherItem] {
    let request = QueryRequest(generation: 1, rawText: query, normalizedText: query, mode: .commands)
    do {
        for try await event in provider.search(request: request) {
            if case let .items(items, true) = event { return items }
        }
    } catch {
        return []
    }
    return []
}
