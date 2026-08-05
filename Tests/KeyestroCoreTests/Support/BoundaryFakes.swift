import CoreGraphics
import Foundation
@testable import KeyestroCore

@MainActor
final class FakeWorkspaceService: WorkspaceServicing {
    private(set) var openedApplications: [(URL, String?)] = []
    private(set) var revealedURLs: [URL] = []
    private(set) var copiedText: [String] = []
    var openError: (any Error)?

    func openApplication(at url: URL, bundleIdentifier: String?) async throws {
        if let openError { throw openError }
        openedApplications.append((url, bundleIdentifier))
    }

    func reveal(_ url: URL) {
        revealedURLs.append(url)
    }

    func copyText(_ value: String) {
        copiedText.append(value)
    }
}

actor FakeSpotlightService: SpotlightServicing {
    var batches: [SpotlightSearchBatch]
    var failure: SpotlightServiceError?
    private(set) var requests: [(String, SpotlightSearchOptions, Int)] = []

    init(batches: [SpotlightSearchBatch] = []) {
        self.batches = batches
    }

    func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) throws -> [SpotlightRecord] {
        requests.append((query, options, limit))
        if let failure { throw failure }
        return Array((batches.first?.records ?? []).prefix(limit))
    }

    func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        requests.append((query, options, limit))
        let batches = self.batches
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                for batch in batches { continuation.yield(batch) }
                continuation.finish()
            }
        }
    }
}

@MainActor
final class FakePasteboardService: PasteboardServicing {
    var changeCount = 0
    var content: ClipboardContent?
    var acceptsWrites = true

    func readSupportedContent() -> ClipboardContent? { content }

    func write(_ content: ClipboardContent) -> Bool {
        guard acceptsWrites else { return false }
        self.content = content
        changeCount += 1
        return true
    }
}

actor FakeAccessibilityService: AccessibilityServicing {
    var trusted: Bool
    var records: [AccessibleWindowRecord]
    var failure: AccessibilityServiceError?
    private(set) var performedActions: [(WindowLayoutAction, String)] = []

    init(trusted: Bool = false, records: [AccessibleWindowRecord] = []) {
        self.trusted = trusted
        self.records = records
    }

    func isTrusted() -> Bool { trusted }

    func windows() throws -> [AccessibleWindowRecord] {
        if let failure { throw failure }
        return records
    }

    func perform(_ action: WindowLayoutAction, windowID: String) throws {
        if let failure { throw failure }
        performedActions.append((action, windowID))
    }
}

actor FakeCaptureService: CaptureServicing {
    var permission: ScreenCapturePermission
    var requestResult: Bool
    var image: CapturedImage?
    private(set) var capturedPlans: [CaptureRegionPlan] = []
    private(set) var excludedBundleIdentifiers: [String?] = []

    init(
        permission: ScreenCapturePermission = .notDeterminedOrDenied,
        requestResult: Bool = false,
        image: CapturedImage? = nil
    ) {
        self.permission = permission
        self.requestResult = requestResult
        self.image = image
    }

    func permissionStatus() -> ScreenCapturePermission { permission }

    func requestPermission() -> Bool {
        if requestResult { permission = .allowed }
        return requestResult
    }

    func capture(
        plan: CaptureRegionPlan,
        excludingApplicationBundleIdentifier: String?
    ) throws -> CapturedImage {
        capturedPlans.append(plan)
        excludedBundleIdentifiers.append(excludingApplicationBundleIdentifier)
        guard let image else { throw CaptureError.captureFailed }
        return image
    }
}

actor FakeProcessService: ProcessServicing {
    var result: Result<ProcessExecutionResult, ProcessServiceError>
    private(set) var requests: [ProcessExecutionRequest] = []

    init(
        result: Result<ProcessExecutionResult, ProcessServiceError> = .success(
            ProcessExecutionResult(
                termination: .exited(0),
                standardOutput: Data(),
                standardError: Data(),
                standardOutputTruncated: false,
                standardErrorTruncated: false,
                duration: .zero
            )
        )
    ) {
        self.result = result
    }

    func run(_ request: ProcessExecutionRequest) throws -> ProcessExecutionResult {
        requests.append(request)
        return try result.get()
    }
}

@MainActor
final class FakeUpdateService: UpdateServicing {
    var isConfigured = true
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var channel = "stable"
    var lastErrorMessage: String?
    private(set) var checkCount = 0

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        automaticallyDownloadsUpdates = enabled
    }

    func setChannel(_ channel: String) {
        self.channel = channel
    }

    func checkForUpdates() {
        checkCount += 1
    }
}
