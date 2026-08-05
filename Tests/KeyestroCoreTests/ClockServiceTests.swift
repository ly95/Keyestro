import Foundation
import Testing
@testable import KeyestroCore

@Test func manualClockAdvancesSleepAndWallTimeWithoutRealDelay() async throws {
    let initialDate = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = ManualClockService(date: initialDate)
    let sleeper = Task {
        try await clock.sleep(for: .seconds(5))
    }
    await waitForPendingSleep(clock)

    await clock.advance(by: .seconds(4))
    #expect(await clock.pendingSleepCount() == 1)
    await clock.advance(by: .seconds(1))
    try await sleeper.value

    #expect(await clock.pendingSleepCount() == 0)
    #expect(await clock.wallTime() == initialDate.addingTimeInterval(5))
}

@Test func manualClockSleepRespondsToCancellation() async {
    let clock = ManualClockService()
    let sleeper = Task {
        try await clock.sleep(for: .seconds(60))
    }
    await waitForPendingSleep(clock)
    sleeper.cancel()
    await #expect(throws: CancellationError.self) {
        try await sleeper.value
    }
    #expect(await clock.pendingSleepCount() == 0)
}

func waitForPendingSleep(_ clock: ManualClockService) async {
    for _ in 0..<100 where await clock.pendingSleepCount() == 0 {
        await Task.yield()
    }
}
