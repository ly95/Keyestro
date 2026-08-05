import Foundation
@testable import KeyestroCore

actor ManualClockService: ClockServicing {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var instant: ContinuousClock.Instant
    private var date: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepRequestCount = 0

    init(
        instant: ContinuousClock.Instant = ContinuousClock.now,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) {
        self.instant = instant
        self.date = date
    }

    func now() -> ContinuousClock.Instant { instant }

    func wallTime() -> Date { date }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        sleepRequestCount += 1
        let token = UUID()
        let deadline = instant.advanced(by: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if deadline <= instant {
                    continuation.resume()
                } else {
                    sleepers[token] = Sleeper(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        date = date.addingTimeInterval(Self.seconds(duration))
        let ready = sleepers.filter { $0.value.deadline <= instant }
        for (token, sleeper) in ready {
            sleepers[token] = nil
            sleeper.continuation.resume()
        }
    }

    func pendingSleepCount() -> Int { sleepers.count }

    func totalSleepRequestCount() -> Int { sleepRequestCount }

    private func cancel(_ token: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: token) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

func waitForSleepRequests(_ clock: ManualClockService, atLeast count: Int) async {
    for _ in 0..<1_000 {
        if await clock.totalSleepRequestCount() >= count { return }
        await Task.yield()
    }
}
