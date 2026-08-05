import Foundation
import KeyestroCore
import Testing

@Test
func performanceRecorderCalculatesNearestRankPercentilesAndBoundsStorage() async {
    let recorder = PerformanceRecorder(maximumSamplesPerMetric: 4)
    for value in [1.0, 2.0, 3.0, 4.0, 100.0] {
        await recorder.recordMilliseconds(value, for: .queryComplete)
    }

    let report = await recorder.report()
    let summary = report.summaries.first { $0.metric == .queryComplete }

    #expect(summary?.sampleCount == 4)
    #expect(summary?.p50Milliseconds == 3)
    #expect(summary?.p95Milliseconds == 100)
    #expect(summary?.maximumMilliseconds == 100)
}

@Test
func performanceRecorderRejectsInvalidSamplesAndCanReset() async {
    let recorder = PerformanceRecorder()
    await recorder.recordMilliseconds(-1, for: .actionComplete)
    await recorder.recordMilliseconds(.infinity, for: .actionComplete)
    await recorder.record(.actionComplete, duration: .milliseconds(12))
    #expect((await recorder.report()).summaries.count == 1)

    await recorder.reset()
    #expect((await recorder.report()).summaries.isEmpty)
}
