import CoreServices
import Foundation
import KeyestroDomain

public struct SpotlightRecord: Equatable, Sendable {
    public enum MatchKind: String, Equatable, Sendable {
        case fileName
        case content
    }

    public let url: URL
    public let displayName: String
    public let contentType: String?
    public let modifiedAt: Date?
    public let matchKind: MatchKind

    public init(
        url: URL,
        displayName: String,
        contentType: String?,
        modifiedAt: Date?,
        matchKind: MatchKind = .fileName
    ) {
        self.url = url
        self.displayName = displayName
        self.contentType = contentType
        self.modifiedAt = modifiedAt
        self.matchKind = matchKind
    }
}

public struct SpotlightSearchOptions: Equatable, Sendable {
    public var searchContents: Bool
    public var includeHiddenFiles: Bool
    public var includeSystemLocations: Bool
    public var includeTrash: Bool

    public init(
        searchContents: Bool = false,
        includeHiddenFiles: Bool = false,
        includeSystemLocations: Bool = false,
        includeTrash: Bool = false
    ) {
        self.searchContents = searchContents
        self.includeHiddenFiles = includeHiddenFiles
        self.includeSystemLocations = includeSystemLocations
        self.includeTrash = includeTrash
    }
}

public struct FileSearchConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var options: SpotlightSearchOptions

    public init(
        isEnabled: Bool = false,
        options: SpotlightSearchOptions = SpotlightSearchOptions()
    ) {
        self.isEnabled = isEnabled
        self.options = options
    }
}

public enum SpotlightSearchPhase: Equatable, Sendable {
    case initial
    case liveUpdate
}

public struct SpotlightSearchBatch: Equatable, Sendable {
    public let records: [SpotlightRecord]
    public let phase: SpotlightSearchPhase

    public init(records: [SpotlightRecord], phase: SpotlightSearchPhase) {
        self.records = records
        self.phase = phase
    }
}

public actor FileSearchPreferences {
    private var value: FileSearchConfiguration

    public init(_ value: FileSearchConfiguration = FileSearchConfiguration()) {
        self.value = value
    }

    public func configuration() -> FileSearchConfiguration { value }
    public func update(_ value: FileSearchConfiguration) { self.value = value }
}

public protocol SpotlightServicing: Sendable {
    func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async throws -> [SpotlightRecord]

    func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async -> AsyncThrowingStream<SpotlightSearchBatch, any Error>
}

extension SpotlightServicing {
    public func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpotlightSearchBatch, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let task = Task {
            do {
                let records = try await searchFiles(containing: query, options: options, limit: limit)
                continuation.yield(SpotlightSearchBatch(records: records, phase: .initial))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }
}

public protocol ApplicationDiscovering: Sendable {
    func discoverApplicationURLs(limit: Int) async throws -> [URL]
    func applicationURLUpdates(limit: Int) async -> AsyncThrowingStream<[URL], any Error>
}

extension ApplicationDiscovering {
    public func applicationURLUpdates(limit: Int) async -> AsyncThrowingStream<[URL], any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

public struct EmptyApplicationDiscoveryService: ApplicationDiscovering {
    public init() {}
    public func discoverApplicationURLs(limit: Int) async throws -> [URL] { [] }
}

/// Defers protected-folder scope resolution until file search has been explicitly enabled
/// and a query actually needs Spotlight.
public actor LazyMDSpotlightService: SpotlightServicing {
    private var service: MDSpotlightService?

    public init() {}

    public func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async throws -> [SpotlightRecord] {
        try await resolvedService().searchFiles(containing: query, options: options, limit: limit)
    }

    public func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        await resolvedService().searchFileUpdates(containing: query, options: options, limit: limit)
    }

    private func resolvedService() -> MDSpotlightService {
        if let service { return service }
        let service = MDSpotlightService()
        self.service = service
        return service
    }
}

public enum SpotlightServiceError: Error, Equatable, Sendable {
    case invalidQuery
    case unavailable
    case executionFailed

    public var descriptor: ErrorDescriptor {
        switch self {
        case .invalidQuery:
            ErrorDescriptor(code: "spotlight.invalidQuery", message: "The file query is invalid.")
        case .unavailable:
            ErrorDescriptor(
                code: "spotlight.unavailable",
                message: "Spotlight is unavailable or still indexing.",
                recoverySuggestion: "Check Spotlight settings and try again later."
            )
        case .executionFailed:
            ErrorDescriptor(
                code: "spotlight.executionFailed",
                message: "Spotlight could not complete the search.",
                recoverySuggestion: "Try a shorter file name or check Spotlight settings."
            )
        }
    }
}

/// Offers a bounded MDQuery snapshot API and an NSMetadataQuery initial/live-update stream.
public actor MDSpotlightService: SpotlightServicing {
    private let searchScopes: [URL]
    private let systemSearchScopes: [URL]
    private let trashSearchScope: URL?
    private let clock: any ClockServicing
    private let queryStartObserver: (@Sendable (Bool) -> Void)?

    public init(
        searchScopes: [URL] = MDSpotlightService.defaultSearchScopes,
        systemSearchScopes: [URL] = MDSpotlightService.defaultSystemSearchScopes,
        trashSearchScope: URL? = MDSpotlightService.defaultTrashSearchScope,
        clock: any ClockServicing = SystemClockService()
    ) {
        self.clock = clock
        queryStartObserver = nil
        self.searchScopes =
            searchScopes
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        self.systemSearchScopes =
            systemSearchScopes
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let trashSearchScope = trashSearchScope?.standardizedFileURL,
            FileManager.default.fileExists(atPath: trashSearchScope.path)
        {
            self.trashSearchScope = trashSearchScope
        } else {
            self.trashSearchScope = nil
        }
    }

    public init(searchScope: URL, clock: any ClockServicing = SystemClockService()) {
        self.clock = clock
        queryStartObserver = nil
        searchScopes = [searchScope.standardizedFileURL]
        systemSearchScopes = []
        trashSearchScope = nil
    }

    init(
        searchScope: URL,
        clock: any ClockServicing = SystemClockService(),
        queryStartObserver: @escaping @Sendable (Bool) -> Void
    ) {
        self.clock = clock
        self.queryStartObserver = queryStartObserver
        searchScopes = [searchScope.standardizedFileURL]
        systemSearchScopes = []
        trashSearchScope = nil
    }

    public static var defaultSearchScopes: [URL] {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory, .moviesDirectory,
            .musicDirectory, .picturesDirectory, .sharedPublicDirectory,
        ]
        return directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
    }

    public static var defaultSystemSearchScopes: [URL] {
        let manager = FileManager.default
        return [
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: "/System", isDirectory: true),
            URL(fileURLWithPath: "/usr/local", isDirectory: true),
            manager.urls(for: .libraryDirectory, in: .userDomainMask).first,
        ].compactMap { $0 }
    }

    public static var defaultTrashSearchScope: URL? {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    public func searchFiles(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async throws -> [SpotlightRecord] {
        try Task.checkCancellation()
        let bounded = query.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        guard !bounded.isEmpty else { return [] }
        let literal = Self.escapeMetadataLiteral(bounded)
        guard !literal.isEmpty else { throw SpotlightServiceError.invalidQuery }

        let queryString = Self.metadataQueryString(escapedLiteral: literal, searchContents: options.searchContents)
        guard let metadataQuery = MDQueryCreate(nil, queryString as CFString, nil, nil) else {
            throw SpotlightServiceError.unavailable
        }
        let maximum = min(max(1, limit), DomainLimits.candidatesPerProvider)
        var activeScopes = searchScopes
        if options.includeSystemLocations { activeScopes.append(contentsOf: systemSearchScopes) }
        if options.includeTrash, let trashSearchScope { activeScopes.append(trashSearchScope) }
        activeScopes = Self.uniqued(activeScopes)
        guard !activeScopes.isEmpty else { throw SpotlightServiceError.unavailable }
        MDQuerySetSearchScope(metadataQuery, activeScopes.map(\.path) as CFArray, 0)
        MDQuerySetMaxCount(metadataQuery, CFIndex(maximum))
        guard MDQueryExecute(metadataQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw SpotlightServiceError.executionFailed
        }
        try Task.checkCancellation()

        let resultCount = min(MDQueryGetResultCount(metadataQuery), CFIndex(maximum))
        var records: [SpotlightRecord] = []
        records.reserveCapacity(Int(resultCount))
        for index in 0..<resultCount {
            if index.isMultiple(of: 100) { try Task.checkCancellation() }
            guard let pointer = MDQueryGetResultAtIndex(metadataQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isVisibleUserFile(url, roots: activeScopes, options: options) else { continue }
            let displayName =
                (MDItemCopyAttribute(item, kMDItemDisplayName) as? String)
                ?? (MDItemCopyAttribute(item, kMDItemFSName) as? String)
                ?? url.lastPathComponent
            let contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String
            let modifiedAt = MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date
            let normalizedName = TextNormalizer.normalize(displayName)
            let matchKind: SpotlightRecord.MatchKind = normalizedName.contains(TextNormalizer.normalize(bounded)) ? .fileName : .content
            records.append(
                SpotlightRecord(
                    url: url,
                    displayName: displayName,
                    contentType: contentType,
                    modifiedAt: modifiedAt,
                    matchKind: matchKind
                )
            )
        }
        return records
    }

    public func searchFileUpdates(
        containing query: String,
        options: SpotlightSearchOptions,
        limit: Int
    ) async -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        let bounded = query.limitedToUnicodeScalars(DomainLimits.queryUnicodeScalars)
        guard !bounded.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.yield(SpotlightSearchBatch(records: [], phase: .initial))
                continuation.finish()
            }
        }
        var activeScopes = searchScopes
        if options.includeSystemLocations { activeScopes.append(contentsOf: systemSearchScopes) }
        if options.includeTrash, let trashSearchScope { activeScopes.append(trashSearchScope) }
        activeScopes = Self.uniqued(activeScopes)
        guard !activeScopes.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: SpotlightServiceError.unavailable)
            }
        }
        let maximum = min(max(1, limit), DomainLimits.candidatesPerProvider)
        return MetadataQuerySession.makeStream(
            queryText: bounded,
            options: options,
            scopes: activeScopes,
            maximum: maximum,
            clock: clock,
            queryStartObserver: queryStartObserver
        )
    }

    /// Escapes all Metadata query metacharacters. The host contributes the only two wildcards.
    public static func escapeMetadataLiteral(_ query: String) -> String {
        var result = ""
        result.reserveCapacity(query.count)
        for scalar in query.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            switch scalar {
            case "\\", "\"", "*", "?", "'": result.append("\\")
            default: break
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func metadataQueryString(escapedLiteral: String, searchContents: Bool) -> String {
        let name = "kMDItemFSName == \"*\(escapedLiteral)*\"cdw"
        guard searchContents else { return name }
        return "(\(name) || kMDItemTextContent == \"*\(escapedLiteral)*\"cdw)"
    }

    static func isVisibleUserFile(
        _ url: URL,
        roots: [URL],
        options: SpotlightSearchOptions
    ) -> Bool {
        guard let root = roots.first(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else {
            return false
        }
        let relativeComponents = url.pathComponents.dropFirst(root.pathComponents.count)
        if !options.includeHiddenFiles, relativeComponents.contains(where: { $0.hasPrefix(".") }) { return false }
        if !options.includeTrash, url.pathComponents.contains(".Trash") { return false }
        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame { return false }
        return true
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var paths = Set<String>()
        return urls.filter { paths.insert($0.standardizedFileURL.path).inserted }
    }
}

/// NSMetadataQuery can block while it resolves search scopes. Apple requires a run loop when
/// starting it away from the app's main thread, so all query lifecycle work is confined here.
private final class MetadataQueryRunLoop: @unchecked Sendable {
    static let shared = MetadataQueryRunLoop()

    private final class StartupState: @unchecked Sendable {
        private let condition = NSCondition()
        private var value: CFRunLoop?

        func publish(_ runLoop: CFRunLoop) {
            condition.lock()
            value = runLoop
            condition.broadcast()
            condition.unlock()
        }

        func waitForRunLoop() -> CFRunLoop {
            condition.lock()
            defer { condition.unlock() }
            while value == nil { condition.wait() }
            return value!
        }
    }

    private let thread: Thread
    private let runLoop: CFRunLoop

    private init() {
        let startup = StartupState()
        let worker = Thread {
            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            startup.publish(CFRunLoopGetCurrent())
            CFRunLoopRun()
            withExtendedLifetime(keepAlivePort) {}
        }
        worker.name = "com.keyestro.metadata-query"
        worker.qualityOfService = .userInitiated
        thread = worker
        worker.start()
        runLoop = startup.waitForRunLoop()
    }

    func perform(_ operation: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode?.rawValue, operation)
        CFRunLoopWakeUp(runLoop)
    }
}

private final class MetadataQuerySession: NSObject, @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queryText: String
    private let options: SpotlightSearchOptions
    private let scopes: [URL]
    private let maximum: Int
    private let clock: any ClockServicing
    private let queryStartObserver: (@Sendable (Bool) -> Void)?
    private let lifecycleLock = NSLock()
    private var continuation: AsyncThrowingStream<SpotlightSearchBatch, any Error>.Continuation?
    private var initialDelivered = false
    private var cancellationRequested = false
    private var startTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var stopped = false

    private init(
        queryText: String,
        options: SpotlightSearchOptions,
        scopes: [URL],
        maximum: Int,
        clock: any ClockServicing,
        queryStartObserver: (@Sendable (Bool) -> Void)?,
        continuation: AsyncThrowingStream<SpotlightSearchBatch, any Error>.Continuation
    ) {
        self.queryText = queryText
        self.options = options
        self.scopes = scopes
        self.maximum = maximum
        self.clock = clock
        self.queryStartObserver = queryStartObserver
        self.continuation = continuation
    }

    static func makeStream(
        queryText: String,
        options: SpotlightSearchOptions,
        scopes: [URL],
        maximum: Int,
        clock: any ClockServicing,
        queryStartObserver: (@Sendable (Bool) -> Void)?
    ) -> AsyncThrowingStream<SpotlightSearchBatch, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpotlightSearchBatch, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let session = MetadataQuerySession(
            queryText: queryText,
            options: options,
            scopes: scopes,
            maximum: maximum,
            clock: clock,
            queryStartObserver: queryStartObserver,
            continuation: continuation
        )
        continuation.onTermination = { @Sendable _ in
            session.requestStop()
        }
        session.scheduleStart()
        return stream
    }

    private func scheduleStart() {
        let task = Task { [weak self] in
            do {
                // Avoid starting one expensive metadata session per intermediate keystroke.
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self, !isCancellationRequested else { return }
            MetadataQueryRunLoop.shared.perform { [weak self] in self?.start() }
        }
        lifecycleLock.lock()
        if cancellationRequested {
            lifecycleLock.unlock()
            task.cancel()
        } else {
            startTask = task
            lifecycleLock.unlock()
        }
    }

    private func requestStop() {
        lifecycleLock.lock()
        cancellationRequested = true
        let pendingStart = startTask
        startTask = nil
        lifecycleLock.unlock()
        pendingStart?.cancel()
        // Keep the session alive until stopQuery runs on the same run loop as startQuery.
        // A weak capture can release NSMetadataQuery before this block is serviced.
        MetadataQueryRunLoop.shared.perform { self.stop() }
    }

    private var isCancellationRequested: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return cancellationRequested
    }

    private func start() {
        guard !isCancellationRequested else {
            stop()
            return
        }
        queryStartObserver?(Thread.isMainThread)
        let namePredicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, queryText)
        if options.searchContents {
            let contentPredicate = NSPredicate(
                format: "%K CONTAINS[cd] %@",
                NSMetadataItemTextContentKey,
                queryText
            )
            query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [namePredicate, contentPredicate])
        } else {
            query.predicate = namePredicate
        }
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.25
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(finishedGathering),
            name: Notification.Name.NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resultsChanged),
            name: Notification.Name.NSMetadataQueryDidUpdate,
            object: query
        )
        guard query.start() else {
            continuation?.finish(throwing: SpotlightServiceError.executionFailed)
            stop()
            return
        }
        timeoutTask = Task { [weak self, clock] in
            guard let self else { return }
            try? await clock.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            MetadataQueryRunLoop.shared.perform { [weak self] in
                self?.initialGatheringTimedOut()
            }
        }
    }

    @objc private func finishedGathering(_ notification: Notification) {
        guard notification.object as? NSMetadataQuery === query else { return }
        timeoutTask?.cancel()
        initialDelivered = true
        continuation?.yield(SpotlightSearchBatch(records: currentRecords(), phase: .initial))
    }

    @objc private func resultsChanged(_ notification: Notification) {
        guard initialDelivered, notification.object as? NSMetadataQuery === query else { return }
        continuation?.yield(SpotlightSearchBatch(records: currentRecords(), phase: .liveUpdate))
    }

    private func currentRecords() -> [SpotlightRecord] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = min(query.resultCount, maximum)
        var records: [SpotlightRecord] = []
        records.reserveCapacity(count)
        var seen = Set<String>()
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard seen.insert(url.path).inserted,
                MDSpotlightService.isVisibleUserFile(url, roots: scopes, options: options)
            else { continue }
            let displayName =
                (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? url.lastPathComponent
            let normalizedName = TextNormalizer.normalize(displayName)
            records.append(
                SpotlightRecord(
                    url: url,
                    displayName: displayName,
                    contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
                    modifiedAt: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                    matchKind: normalizedName.contains(TextNormalizer.normalize(queryText)) ? .fileName : .content
                )
            )
        }
        return records
    }

    private func initialGatheringTimedOut() {
        guard !stopped, !initialDelivered else { return }
        continuation?.finish(throwing: SpotlightServiceError.unavailable)
        stop()
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        timeoutTask?.cancel()
        timeoutTask = nil
        query.stop()
        NotificationCenter.default.removeObserver(self)
        continuation = nil
    }
}

/// Discovers application bundles from the local machine's existing Spotlight index.
public actor MDApplicationDiscoveryService: ApplicationDiscovering {
    private let searchScopes: [URL]

    public init(searchScopes: [URL] = MDApplicationDiscoveryService.defaultSearchScopes) {
        self.searchScopes = searchScopes.map(\.standardizedFileURL)
    }

    public static var defaultSearchScopes: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications",
                isDirectory: true
            ),
        ]
    }

    public func discoverApplicationURLs(limit: Int = 2_000) async throws -> [URL] {
        try Task.checkCancellation()
        guard !searchScopes.isEmpty else { return [] }
        let queryString = "kMDItemContentTypeTree == 'com.apple.application-bundle'"
        guard let metadataQuery = MDQueryCreate(nil, queryString as CFString, nil, nil) else {
            throw SpotlightServiceError.unavailable
        }
        let maximum = min(max(1, limit), 5_000)
        MDQuerySetSearchScope(metadataQuery, searchScopes.map(\.path) as CFArray, 0)
        MDQuerySetMaxCount(metadataQuery, CFIndex(maximum))
        guard MDQueryExecute(metadataQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw SpotlightServiceError.executionFailed
        }
        try Task.checkCancellation()

        let count = min(MDQueryGetResultCount(metadataQuery), CFIndex(maximum))
        var seen = Set<String>()
        var urls: [URL] = []
        urls.reserveCapacity(Int(count))
        for index in 0..<count {
            if index.isMultiple(of: 100) { try Task.checkCancellation() }
            guard let pointer = MDQueryGetResultAtIndex(metadataQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                seen.insert(url.path).inserted
            else { continue }
            urls.append(url)
        }
        return urls
    }

    public func applicationURLUpdates(limit: Int = 2_000) async -> AsyncThrowingStream<[URL], any Error> {
        guard !searchScopes.isEmpty else {
            return AsyncThrowingStream { continuation in continuation.finish() }
        }
        let maximum = min(max(1, limit), 5_000)
        return ApplicationMetadataQuerySession.makeStream(scopes: searchScopes, maximum: maximum)
    }
}

private final class ApplicationMetadataQuerySession: NSObject, @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let scopes: [URL]
    private let maximum: Int
    private var continuation: AsyncThrowingStream<[URL], any Error>.Continuation?
    private var stopped = false

    private init(
        scopes: [URL],
        maximum: Int,
        continuation: AsyncThrowingStream<[URL], any Error>.Continuation
    ) {
        self.scopes = scopes
        self.maximum = maximum
        self.continuation = continuation
    }

    static func makeStream(scopes: [URL], maximum: Int) -> AsyncThrowingStream<[URL], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[URL], any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let session = ApplicationMetadataQuerySession(
            scopes: scopes,
            maximum: maximum,
            continuation: continuation
        )
        continuation.onTermination = { @Sendable _ in
            MetadataQueryRunLoop.shared.perform { session.stop() }
        }
        MetadataQueryRunLoop.shared.perform { session.start() }
        return stream
    }

    private func start() {
        query.predicate = NSPredicate(
            format: "%K == %@",
            NSMetadataItemContentTypeTreeKey,
            "com.apple.application-bundle"
        )
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.5
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resultsChanged),
            name: Notification.Name.NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resultsChanged),
            name: Notification.Name.NSMetadataQueryDidUpdate,
            object: query
        )
        guard query.start() else {
            continuation?.finish(throwing: SpotlightServiceError.executionFailed)
            stop()
            return
        }
    }

    @objc private func resultsChanged(_ notification: Notification) {
        guard notification.object as? NSMetadataQuery === query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let count = min(query.resultCount, maximum)
        var seen = Set<String>()
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                seen.insert(url.path).inserted
            else { continue }
            urls.append(url)
        }
        continuation?.yield(urls)
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        query.stop()
        NotificationCenter.default.removeObserver(self)
        continuation = nil
    }
}
