import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@MainActor
private final class TestSystemCommandBoundary: SystemCommandServicing, SystemCommandConfirmationServicing {
    var explanationShown = false
    var executeCount = 0

    func shouldConfirmSleep() -> Bool { !explanationShown }
    func markSleepExplanationShown() { explanationShown = true }

    func execute(_ command: SystemCommandID) -> Result<Void, ErrorDescriptor> {
        executeCount += 1
        return .success(())
    }
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

private func systemCommandItems(from provider: SystemCommandProvider) async -> [LauncherItem] {
    let request = QueryRequest(generation: 1, rawText: "", normalizedText: "", mode: .commands)
    do {
        for try await event in provider.search(request: request) {
            if case let .items(items, true) = event { return items }
        }
    } catch {
        return []
    }
    return []
}
