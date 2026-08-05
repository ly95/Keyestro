import Foundation
import Testing
@testable import KeyestroCore

@Test(arguments: WindowLayoutAction.allCases.filter { ![.focus, .restore, .nextDisplay].contains($0) })
func windowLayoutsStayInsideVisibleFrame(action: WindowLayoutAction) throws {
    let visible = CGRect(x: -1_920, y: 24, width: 1_920, height: 1_056)
    let current = CGRect(x: -1_600, y: 100, width: 900, height: 700)
    let frame = try #require(WindowFrameCalculator.frame(for: action, current: current, visibleFrame: visible))
    #expect(frame.minX >= visible.minX)
    #expect(frame.minY >= visible.minY)
    #expect(frame.maxX <= visible.maxX)
    #expect(frame.maxY <= visible.maxY)
}

@Test func accessibilityCircuitBreakerIsPerApplicationBoundedAndRecoversAfterCooldown() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var breaker = AccessibilityCircuitBreaker(failureThreshold: 2, cooldown: 30, maximumProcesses: 2)

    var isAllowed = breaker.allows(101, at: start)
    #expect(isAllowed)
    breaker.recordFailure(101, at: start)
    isAllowed = breaker.allows(101, at: start)
    #expect(isAllowed)
    breaker.recordFailure(101, at: start)
    isAllowed = breaker.allows(101, at: start.addingTimeInterval(29))
    #expect(!isAllowed)
    isAllowed = breaker.allows(202, at: start)
    #expect(isAllowed)
    isAllowed = breaker.allows(101, at: start.addingTimeInterval(30))
    #expect(isAllowed)

    breaker.recordFailure(101, at: start.addingTimeInterval(31))
    breaker.recordSuccess(101)
    isAllowed = breaker.allows(101, at: start.addingTimeInterval(31))
    #expect(isAllowed)

    breaker.recordFailure(202, at: start)
    breaker.recordFailure(303, at: start.addingTimeInterval(1))
    breaker.recordFailure(404, at: start.addingTimeInterval(2))
    breaker.removeMissingProcesses([303, 404])
    isAllowed = breaker.allows(202, at: start)
    #expect(isAllowed)
}
