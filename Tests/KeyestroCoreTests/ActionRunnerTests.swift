import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func actionRunnerRequiresHostConfirmationAndSuppressesConcurrentDuplicateSubmissions() async throws {
    let provider = BlockingActionProvider()
    let action = ActionDescriptor(
        id: "mutate",
        title: "Mutate Target",
        risk: .externalSideEffect
    )
    let itemID = ItemID(providerID: provider.descriptor.id, providerStableID: "target")
    let resolved = ResolvedAction(
        providerID: provider.descriptor.id,
        itemID: itemID,
        actionID: action.id,
        descriptor: action,
        displayedTitle: "Concrete Target",
        displayedSubtitle: "/current/target",
        privacy: .normal
    )
    let runner = ActionRunner(providers: [provider])

    #expect(
        await runner.run(
            executionID: UUID(),
            resolvedAction: resolved,
            arguments: [:],
            riskConfirmed: false
        ) == .confirmationRequired(resolved)
    )
    #expect(await provider.executionCount == 0)

    let executionID = UUID()
    let first = Task {
        await runner.run(
            executionID: executionID,
            resolvedAction: resolved,
            arguments: [:],
            riskConfirmed: true
        )
    }
    await provider.waitUntilExecutionStarts()
    let duplicate = await runner.run(
        executionID: executionID,
        resolvedAction: resolved,
        arguments: [:],
        riskConfirmed: true
    )
    guard case let .completed(.failure(error)) = duplicate else {
        Issue.record("The concurrent duplicate submission was not rejected.")
        await provider.finishExecution()
        _ = await first.value
        return
    }
    #expect(error.code == "action.duplicateExecution")
    await provider.finishExecution()
    #expect(await first.value == .completed(.success()))
    #expect(await provider.executionCount == 1)

    let repeated = await runner.run(
        executionID: executionID,
        resolvedAction: resolved,
        arguments: [:],
        riskConfirmed: true
    )
    guard case let .completed(.failure(error)) = repeated else {
        Issue.record("The recently completed duplicate submission was not rejected.")
        return
    }
    #expect(error.code == "action.duplicateExecution")
    #expect(await provider.executionCount == 1)
}

private actor BlockingActionProvider: LauncherProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "action-runner-test",
        displayName: "Action Runner Test",
        supportedModes: [.all],
        supportsEmptyQuery: false
    )
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var executionCount = 0

    nonisolated func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.items([], isFinal: true))
            continuation.finish()
        }
    }

    func execute(request: ProviderActionRequest) async -> ActionResult {
        executionCount += 1
        await withCheckedContinuation { continuation = $0 }
        return .success()
    }

    func waitUntilExecutionStarts() async {
        while executionCount == 0 { await Task.yield() }
    }

    func finishExecution() {
        continuation?.resume()
        continuation = nil
    }
}
