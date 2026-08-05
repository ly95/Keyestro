import Foundation
import OSLog

/// Bounded, payload-free performance measurements used by local diagnostics and release benchmarks.
public enum PerformanceMetric: String, CaseIterable, Codable, Sendable {
    case invokeToFirstFrame = "invoke-to-first-frame"
    case queryToFirstResult = "query-to-first-result"
    case queryComplete = "query-complete"
    case actionComplete = "action-complete"
    case extensionStart = "extension-start"
    case clipboardSearch = "clipboard-search"
    case databaseMigration = "database-migration"
}

/// A percentile summary that contains timings only and never query or result payloads.
public struct PerformanceMetricSummary: Codable, Equatable, Sendable {
    public let metric: PerformanceMetric
    public let sampleCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double

    public init(
        metric: PerformanceMetric,
        sampleCount: Int,
        p50Milliseconds: Double,
        p95Milliseconds: Double,
        maximumMilliseconds: Double
    ) {
        self.metric = metric
        self.sampleCount = sampleCount
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }
}

/// A copyable report suitable for the Advanced settings page or a release artifact.
public struct PerformanceReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let summaries: [PerformanceMetricSummary]

    public init(generatedAt: Date = Date(), summaries: [PerformanceMetricSummary]) {
        self.generatedAt = generatedAt
        self.summaries = summaries
    }
}

/// Records bounded performance samples without retaining user content.
public protocol PerformanceRecording: Sendable {
    func record(_ metric: PerformanceMetric, duration: Duration) async
}

/// Process-local rolling performance storage. Samples disappear when Keyestro exits.
public actor PerformanceRecorder: PerformanceRecording {
    public static let shared = PerformanceRecorder()

    private let maximumSamplesPerMetric: Int
    private var samples: [PerformanceMetric: [Double]] = [:]

    public init(maximumSamplesPerMetric: Int = 512) {
        self.maximumSamplesPerMetric = min(max(1, maximumSamplesPerMetric), 10_000)
    }

    public func record(_ metric: PerformanceMetric, duration: Duration) {
        recordMilliseconds(Self.milliseconds(duration), for: metric)
    }

    public func recordMilliseconds(_ milliseconds: Double, for metric: PerformanceMetric) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        var values = samples[metric] ?? []
        values.append(milliseconds)
        if values.count > maximumSamplesPerMetric {
            values.removeFirst(values.count - maximumSamplesPerMetric)
        }
        samples[metric] = values
    }

    public func report() -> PerformanceReport {
        let summaries = PerformanceMetric.allCases.compactMap { metric -> PerformanceMetricSummary? in
            guard let values = samples[metric], !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return PerformanceMetricSummary(
                metric: metric,
                sampleCount: sorted.count,
                p50Milliseconds: Self.percentile(0.50, sorted: sorted),
                p95Milliseconds: Self.percentile(0.95, sorted: sorted),
                maximumMilliseconds: sorted[sorted.count - 1]
            )
        }
        return PerformanceReport(summaries: summaries)
    }

    public func reset() {
        samples.removeAll(keepingCapacity: false)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(_ fraction: Double, sorted: [Double]) -> Double {
        let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

/// Stable signpost names consumed by Instruments and release performance tooling.
public enum PerformanceSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.keyestro.launcher",
        category: "Performance"
    )

    public static func launcherInvoked() {
        os_signpost(.event, log: log, name: "invoke")
    }

    public static func firstFrame() {
        os_signpost(.event, log: log, name: "first-frame")
    }

    public static func firstResult() {
        os_signpost(.event, log: log, name: "first-result")
    }

    public static func queryCompleted() {
        os_signpost(.event, log: log, name: "query-complete")
    }

    public static func actionCompleted() {
        os_signpost(.event, log: log, name: "action-complete")
    }

    public static func extensionStarted() {
        os_signpost(.event, log: log, name: "extension-start")
    }
}
