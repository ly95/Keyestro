import CryptoKit
import Foundation
import KeyestroDomain

public struct ApplicationRecord: Equatable, Sendable {
    public let stableID: String
    public let bundleIdentifier: String?
    public let displayName: String
    public let bundleName: String
    public let aliases: [String]
    public let url: URL

    public init(
        stableID: String,
        bundleIdentifier: String?,
        displayName: String,
        bundleName: String,
        aliases: [String] = [],
        url: URL
    ) {
        self.stableID = stableID
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleName = bundleName
        self.aliases = aliases
        self.url = url
    }
}

public actor ApplicationCatalog {
    private struct RefreshPayload: Sendable {
        let rootRecords: [String: ApplicationRecord]
        let indexedURLs: [URL]
        let indexedUpdateRevision: UInt64
        let loadedAt: Date
    }

    private var cachedRecords: [ApplicationRecord] = []
    private var recordsByID: [String: ApplicationRecord] = [:]
    private var indexedRecordsByPath: [String: ApplicationRecord] = [:]
    private var loadedAt: Date?
    private var observationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshWaiters: [UUID: CheckedContinuation<[ApplicationRecord], Never>] = [:]
    private var indexedUpdateRevision: UInt64 = 0
    private let cacheLifetime: TimeInterval
    private let roots: [URL]
    private let discovery: any ApplicationDiscovering

    public init(
        roots: [URL] = ApplicationCatalog.defaultRoots,
        cacheLifetime: TimeInterval = 300,
        discovery: any ApplicationDiscovering = MDApplicationDiscoveryService()
    ) {
        self.roots = roots
        self.cacheLifetime = cacheLifetime
        self.discovery = discovery
    }

    deinit {
        observationTask?.cancel()
        refreshTask?.cancel()
        for waiter in refreshWaiters.values { waiter.resume(returning: cachedRecords) }
    }

    public static var defaultRoots: [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))
        return roots
    }

    public func records(forceRefresh: Bool = false, now: Date = Date()) async -> [ApplicationRecord] {
        startObservingApplicationChangesIfNeeded()
        if !forceRefresh,
            let loadedAt,
            now.timeIntervalSince(loadedAt) < cacheLifetime,
            !cachedRecords.isEmpty
        {
            return cachedRecords
        }

        startRefreshIfNeeded(loadedAt: now)
        if !forceRefresh, !cachedRecords.isEmpty {
            return cachedRecords
        }
        return await waitForRefresh()
    }

    private func startRefreshIfNeeded(loadedAt: Date) {
        guard refreshTask == nil else { return }
        let id = UUID()
        let roots = roots
        let discovery = discovery
        let updateRevision = indexedUpdateRevision
        refreshID = id
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let indexedURLs = (try? await discovery.discoverApplicationURLs(limit: 2_000)) ?? []
            guard !Task.isCancelled else { return }
            let rootRecords = Self.scanRoots(roots)
            guard !Task.isCancelled else { return }
            await self?.finishRefresh(
                id: id,
                payload: RefreshPayload(
                    rootRecords: rootRecords,
                    indexedURLs: indexedURLs,
                    indexedUpdateRevision: updateRevision,
                    loadedAt: loadedAt
                )
            )
        }
    }

    private func finishRefresh(id: UUID, payload: RefreshPayload) async {
        guard refreshID == id else { return }

        var rootRecords = payload.rootRecords
        if payload.indexedUpdateRevision != indexedUpdateRevision {
            // A live Spotlight update raced the background root scan. Revalidate off
            // the actor so stale bundles captured by that scan cannot be committed
            // after a same-path replacement or removal.
            var foundStableRevision = false
            for _ in 0..<3 {
                let validationRevision = indexedUpdateRevision
                let recordsToValidate = payload.rootRecords
                rootRecords = await Task.detached(priority: .utility) {
                    Self.revalidatedApplicationRecords(recordsToValidate)
                }.value
                guard refreshID == id else { return }
                if validationRevision == indexedUpdateRevision {
                    foundStableRevision = true
                    break
                }
            }
            // Do not let a continuously changing live index starve refresh waiters or
            // turn an unverified root snapshot into an authoritative empty snapshot.
            // Preserve the last coherent catalog and leave it stale so the next request retries.
            guard
                Self.rootRecordsForCommit(
                    rootRecords,
                    foundStableRevision: foundStableRevision
                ) != nil
            else {
                abandonRefresh(id: id)
                return
            }
        }

        if payload.indexedUpdateRevision == indexedUpdateRevision {
            indexedRecordsByPath = Self.indexedRecords(for: payload.indexedURLs)
        }
        var merged = rootRecords
        for record in indexedRecordsByPath.values { Self.merge(record, into: &merged) }
        recordsByID = merged
        rebuildCachedRecords()
        loadedAt = payload.loadedAt
        refreshTask = nil
        refreshID = nil
        let refreshedRecords = cachedRecords
        let waiters = Array(refreshWaiters.values)
        refreshWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: refreshedRecords) }
    }

    private func abandonRefresh(id: UUID) {
        guard refreshID == id else { return }
        loadedAt = nil
        refreshTask = nil
        refreshID = nil
        let preservedRecords = cachedRecords
        let waiters = Array(refreshWaiters.values)
        refreshWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: preservedRecords) }
    }

    private func waitForRefresh() async -> [ApplicationRecord] {
        guard refreshTask != nil else { return cachedRecords }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: cachedRecords)
                } else {
                    refreshWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRefreshWaiter(waiterID) }
        }
    }

    private func cancelRefreshWaiter(_ waiterID: UUID) {
        refreshWaiters.removeValue(forKey: waiterID)?.resume(returning: cachedRecords)
    }

    public func record(stableID: String) -> ApplicationRecord? {
        guard let cached = recordsByID[stableID] else { return nil }
        guard let current = Self.applicationRecord(for: cached.url) else {
            recordsByID.removeValue(forKey: stableID)
            indexedRecordsByPath.removeValue(forKey: cached.url.path)
            rebuildCachedRecords()
            return nil
        }
        guard current.stableID == stableID else {
            recordsByID.removeValue(forKey: stableID)
            if indexedRecordsByPath[cached.url.path] != nil {
                indexedRecordsByPath[cached.url.path] = current
            }
            Self.merge(current, into: &recordsByID)
            rebuildCachedRecords()
            return nil
        }
        if current != cached {
            recordsByID[stableID] = current
            if indexedRecordsByPath[cached.url.path] != nil {
                indexedRecordsByPath[cached.url.path] = current
            }
            rebuildCachedRecords()
        }
        return current
    }

    public func invalidate() {
        loadedAt = nil
    }

    private static func scanRoots(_ roots: [URL]) -> [String: ApplicationRecord] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isExecutableKey]
        var discovered: [String: ApplicationRecord] = [:]

        for root in roots where manager.fileExists(atPath: root.path) {
            guard
                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                )
            else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()
                if let record = Self.applicationRecord(for: url) { Self.merge(record, into: &discovered) }
            }
        }

        return discovered
    }

    private func startObservingApplicationChangesIfNeeded() {
        guard observationTask == nil else { return }
        let discovery = discovery
        observationTask = Task { [weak self] in
            let updates = await discovery.applicationURLUpdates(limit: 2_000)
            do {
                for try await urls in updates {
                    guard !Task.isCancelled else { return }
                    await self?.applyIndexedApplicationUpdate(urls)
                }
            } catch {
                // The time-bounded snapshot cache remains available if live Spotlight updates stop.
            }
        }
    }

    private func applyIndexedApplicationUpdate(_ urls: [URL]) {
        indexedUpdateRevision &+= 1
        let bounded = Array(urls.prefix(5_000)).map(\.standardizedFileURL)
        let newPaths = Set(bounded.map(\.path))
        let oldPaths = Set(indexedRecordsByPath.keys)

        for removedPath in oldPaths.subtracting(newPaths) {
            guard let removed = indexedRecordsByPath.removeValue(forKey: removedPath) else { continue }
            if !FileManager.default.fileExists(atPath: removedPath),
                recordsByID[removed.stableID]?.url.path == removedPath
            {
                recordsByID.removeValue(forKey: removed.stableID)
            }
        }

        for url in bounded {
            let prior = indexedRecordsByPath[url.path]
            guard let record = Self.applicationRecord(for: url) else {
                if let prior, recordsByID[prior.stableID]?.url.path == url.path {
                    recordsByID.removeValue(forKey: prior.stableID)
                }
                indexedRecordsByPath.removeValue(forKey: url.path)
                continue
            }
            if let prior, prior.stableID != record.stableID,
                recordsByID[prior.stableID]?.url.path == url.path
            {
                recordsByID.removeValue(forKey: prior.stableID)
            }
            indexedRecordsByPath[url.path] = record
            Self.merge(record, into: &recordsByID)
        }
        rebuildCachedRecords()
    }

    private func rebuildCachedRecords() {
        cachedRecords = recordsByID.values.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.stableID < $1.stableID
        }
    }

    private static func indexedRecords(for urls: [URL]) -> [String: ApplicationRecord] {
        var output: [String: ApplicationRecord] = [:]
        for url in urls.prefix(5_000) {
            let canonical = url.standardizedFileURL
            if let record = applicationRecord(for: canonical) { output[canonical.path] = record }
        }
        return output
    }

    /// Re-reads root-scan results before committing across a concurrent live-index update.
    /// Internal visibility keeps the race-closing transformation directly testable.
    static func revalidatedApplicationRecords(
        _ records: [String: ApplicationRecord]
    ) -> [String: ApplicationRecord] {
        var output: [String: ApplicationRecord] = [:]
        for record in records.values {
            guard !Task.isCancelled, let current = applicationRecord(for: record.url) else { continue }
            merge(current, into: &output)
        }
        return output
    }

    /// `nil` means the refresh must be abandoned; an empty dictionary is a valid,
    /// authoritative scan only when it was observed against a stable live revision.
    static func rootRecordsForCommit(
        _ records: [String: ApplicationRecord],
        foundStableRevision: Bool
    ) -> [String: ApplicationRecord]? {
        foundStableRevision ? records : nil
    }

    private static func applicationRecord(for url: URL) -> ApplicationRecord? {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let infoURL = canonicalURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: infoURL.path),
            let size = (attributes[.size] as? NSNumber)?.intValue,
            (1...1_048_576).contains(size),
            let infoData = try? Data(contentsOf: infoURL, options: .mappedIfSafe),
            let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
            let executableName = info["CFBundleExecutable"] as? String,
            !executableName.isEmpty,
            executableName.utf8.count <= 255,
            !executableName.contains("/"),
            !executableName.contains("\u{0}")
        else { return nil }
        let executableURL = canonicalURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        guard canonicalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            !canonicalURL.path.contains(".app/Contents/"),
            !canonicalURL.path.contains("/Library/LoginItems/"),
            !canonicalURL.path.contains("/XPCServices/"),
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            (info["CFBundlePackageType"] as? String ?? "APPL") == "APPL",
            (info["LSBackgroundOnly"] as? Bool) != true
        else { return nil }

        let fileName = canonicalURL.deletingPathExtension().lastPathComponent
        let localized = Bundle(url: canonicalURL)?.localizedInfoDictionary
        let displayName =
            ((localized?["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
                ?? (localized?["CFBundleName"] as? String)
                    ?? fileName)
            .limitedToUnicodeScalars(DomainLimits.titleUnicodeScalars)
        let bundleName = ((info["CFBundleName"] as? String) ?? fileName)
            .limitedToUnicodeScalars(DomainLimits.titleUnicodeScalars)
        var aliases = Array(
            ((info["CFBundleAlternateNames"] as? [String]) ?? []).prefix(50)
        )
        aliases.append(fileName)
        aliases = Array(
            Set(
                aliases.filter {
                    !$0.isEmpty && $0.unicodeScalars.count <= 256 && $0 != displayName && $0 != bundleName
                }
            )
        ).sorted()
        let bundleIdentifier = (info["CFBundleIdentifier"] as? String).flatMap {
            $0.isEmpty || $0.utf8.count > 255 || $0.contains("\u{0}") ? nil : $0
        }
        let stableID = bundleIdentifier ?? "url:\(sha256(canonicalURL.path))"
        return ApplicationRecord(
            stableID: stableID,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            bundleName: bundleName,
            aliases: aliases,
            url: canonicalURL
        )
    }

    static func merge(_ record: ApplicationRecord, into discovered: inout [String: ApplicationRecord]) {
        if let existing = discovered[record.stableID] {
            let recordPriority = locationPriority(record.url)
            let existingPriority = locationPriority(existing.url)
            if existing.url.path == record.url.path
                || recordPriority < existingPriority
                || (recordPriority == existingPriority && record.url.path < existing.url.path)
            {
                discovered[record.stableID] = record
            }
        } else {
            discovered[record.stableID] = record
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func locationPriority(_ url: URL) -> Int {
        if url.path.hasPrefix("/Applications/") { return 0 }
        if url.path.hasPrefix("/System/Applications/") { return 1 }
        return 2
    }
}

public struct ApplicationProvider: LauncherProvider, LauncherProviderPrewarming {
    public let descriptor = ProviderDescriptor(
        id: "applications",
        displayName: "Applications",
        supportedModes: [.all],
        supportsEmptyQuery: true
    )
    private let catalog: ApplicationCatalog
    private let workspace: any WorkspaceServicing
    private let rankingStore: (any RankingServicing)?
    private let clock: any ClockServicing

    public init(
        catalog: ApplicationCatalog = ApplicationCatalog(),
        workspace: any WorkspaceServicing = MacWorkspaceService(),
        rankingStore: (any RankingServicing)? = nil,
        clock: any ClockServicing = SystemClockService()
    ) {
        self.catalog = catalog
        self.workspace = workspace
        self.rankingStore = rankingStore
        self.clock = clock
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task {
            continuation.yield(.status(.loading))
            let records = await catalog.records()
            try Task.checkCancellation()

            let candidates = records.compactMap { record -> (ApplicationRecord, MatchEvaluation)? in
                let aliases = Self.searchAliases(for: record)
                let evaluation = FuzzyMatcher.evaluate(
                    query: request.normalizedText,
                    title: record.displayName,
                    aliases: aliases
                )
                guard evaluation.tier != .none else { return nil }
                return (record, evaluation)
            }
            .sorted { lhs, rhs in
                if lhs.1.tier != rhs.1.tier { return lhs.1.tier < rhs.1.tier }
                if abs(lhs.1.textMatch - rhs.1.textMatch) > 0.000_000_1 {
                    return lhs.1.textMatch > rhs.1.textMatch
                }
                return lhs.0.displayName.localizedStandardCompare(rhs.0.displayName) == .orderedAscending
            }
            .prefix(DomainLimits.candidatesPerProvider)

            var items: [LauncherItem] = []
            items.reserveCapacity(candidates.count)
            for (record, _) in candidates {
                try Task.checkCancellation()
                let itemID = ItemID(providerID: descriptor.id, providerStableID: record.stableID)
                let searchAliases = Self.searchAliases(for: record)
                let open = ActionDescriptor(id: "open", title: "Open", icon: .systemSymbol("arrow.up.forward.app"))
                var actions = [
                    open,
                    ActionDescriptor(
                        id: "reveal",
                        title: "Show in Finder",
                        icon: .systemSymbol("folder"),
                        shortcut: KeyEquivalent(key: "return", modifiers: [.command]),
                        behavior: .keepLauncherOpen
                    ),
                ]
                if record.bundleIdentifier != nil {
                    actions.append(
                        ActionDescriptor(
                            id: "copyBundleIdentifier",
                            title: "Copy Bundle Identifier",
                            icon: .systemSymbol("doc.on.doc"),
                            behavior: .keepLauncherOpen
                        )
                    )
                }
                actions.append(
                    ActionDescriptor(
                        id: "togglePin",
                        title: "Pin or Unpin",
                        icon: .systemSymbol("pin"),
                        behavior: .keepLauncherOpen
                    )
                )
                items.append(
                    LauncherItem(
                        id: itemID,
                        providerID: descriptor.id,
                        title: record.displayName,
                        subtitle: record.url.path,
                        icon: .application(record.url),
                        canonicalResource: record.bundleIdentifier.map(CanonicalResource.application)
                            ?? .file(record.url),
                        keywords: [record.bundleName, record.bundleIdentifier].compactMap { $0 } + record.aliases,
                        searchAliases: searchAliases,
                        actions: actions,
                        defaultActionID: open.id,
                        scoreFeatures: ScoreFeatures(
                            context: request.context.frontmostBundleIdentifier == record.bundleIdentifier ? 0.25 : 0,
                            providerPrior: 0.8
                        )
                    )
                )
            }

            if items.isEmpty {
                continuation.yield(.items([], isFinal: true))
            } else {
                for offset in stride(from: 0, to: items.count, by: DomainLimits.itemsPerBatch) {
                    try Task.checkCancellation()
                    let end = min(offset + DomainLimits.itemsPerBatch, items.count)
                    continuation.yield(.items(Array(items[offset..<end]), isFinal: end == items.count))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    static func searchAliases(for record: ApplicationRecord) -> [SearchAlias] {
        // Reserve bounded slots for stable technical identifiers before optional
        // alternate names. The same already-sanitized collection is used for both
        // provider prefiltering and the host's final Ranker pass.
        var candidates = [SearchAlias(value: record.bundleName, role: .name)]
        if let bundleIdentifier = record.bundleIdentifier {
            candidates.append(SearchAlias(value: bundleIdentifier, role: .technical))
        }
        candidates.append(SearchAlias(value: record.url.path, role: .technical))
        candidates.append(contentsOf: record.aliases.map { SearchAlias(value: $0, role: .name) })

        let sanitized = candidates.compactMap { alias -> SearchAlias? in
            let value = alias.value.limitedToUnicodeScalars(DomainLimits.keywordUnicodeScalars)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SearchAlias(value: value, role: alias.role, matchPolicy: alias.matchPolicy)
        }
        return Array(sanitized.prefix(DomainLimits.keywordCount))
    }

    public func prewarm() async {
        _ = await catalog.records()
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id else {
            return .failure(
                ErrorDescriptor(code: "applications.invalidItem", message: "The application item is invalid.")
            )
        }
        var resolvedRecord = await catalog.record(stableID: request.itemID.providerStableID)
        if resolvedRecord == nil {
            let refreshed = await catalog.records(forceRefresh: true)
            resolvedRecord = refreshed.first(where: { $0.stableID == request.itemID.providerStableID })
        }
        guard let record = resolvedRecord else {
            return .failure(
                ErrorDescriptor(
                    code: "applications.notFound",
                    message: "The application is no longer installed.",
                    recoverySuggestion: "Refresh the application results."
                )
            )
        }
        guard FileManager.default.fileExists(atPath: record.url.path) else {
            await catalog.invalidate()
            return .failure(
                ErrorDescriptor(
                    code: "applications.moved",
                    message: "The application has moved or was removed.",
                    recoverySuggestion: "Refresh the application results."
                )
            )
        }

        do {
            switch request.actionID.rawValue {
            case "open":
                try await workspace.openApplication(at: record.url, bundleIdentifier: record.bundleIdentifier)
                return .success()
            case "reveal":
                await workspace.reveal(record.url)
                return .success(message: "Shown in Finder")
            case "copyBundleIdentifier":
                guard let bundleIdentifier = record.bundleIdentifier else {
                    return .failure(
                        ErrorDescriptor(
                            code: "applications.missingBundleIdentifier",
                            message: "This application has no bundle identifier."
                        )
                    )
                }
                await workspace.copyText(bundleIdentifier)
                return .success(message: "Bundle identifier copied")
            case "togglePin":
                guard let rankingStore else {
                    return .failure(
                        ErrorDescriptor(code: "applications.rankingUnavailable", message: "Pinning is unavailable.")
                    )
                }
                do {
                    let pinned = try await rankingStore.togglePin(
                        itemID: request.itemID,
                        providerID: descriptor.id,
                        at: await clock.wallTime()
                    )
                    return .success(message: pinned ? "Application pinned" : "Application unpinned")
                } catch {
                    return .failure(
                        ErrorDescriptor(code: "applications.pinFailed", message: "The pin state could not be saved.")
                    )
                }
            default:
                return .failure(
                    ErrorDescriptor(code: "applications.invalidAction", message: "The application action is invalid.")
                )
            }
        } catch {
            return .failure(
                ErrorDescriptor(
                    code: "applications.openFailed",
                    message: "The application could not be opened.",
                    recoverySuggestion: "Verify the application is valid and try again."
                )
            )
        }
    }
}
