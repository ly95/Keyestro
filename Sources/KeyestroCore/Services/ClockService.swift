import Foundation

/// Supplies monotonic deadlines, wall time, and cancellable sleeps at system boundaries.
public protocol ClockServicing: Sendable {
    func now() async -> ContinuousClock.Instant
    func wallTime() async -> Date
    func sleep(for duration: Duration) async throws
}

/// Production clock backed by Swift's monotonic `ContinuousClock` and the system wall clock.
public struct SystemClockService: ClockServicing {
    private let clock = ContinuousClock()

    public init() {}

    public func now() -> ContinuousClock.Instant {
        clock.now
    }

    public func wallTime() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
