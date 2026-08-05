import CryptoKit
import Foundation
import KeyestroDomain

private actor FileResultCache {
    private var records: [String: SpotlightRecord] = [:]

    func replace(with newRecords: [String: SpotlightRecord]) {
        records = newRecords
    }

    func record(for stableID: String) -> SpotlightRecord? {
        records[stableID]
    }
}

private actor RecentFileCache {
    private struct Entry {
        let record: SpotlightRecord
        let expiresAt: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: Duration
    private let maximumRecords = 200

    init(lifetime: Duration) {
        self.lifetime = min(max(lifetime, .seconds(1)), .seconds(600))
    }

    func merge(_ records: [SpotlightRecord], now: ContinuousClock.Instant) {
        removeExpired(now: now)
        for record in records.prefix(DomainLimits.candidatesPerProvider) {
            entries[record.url.standardizedFileURL.path] = Entry(
                record: record,
                expiresAt: now.advanced(by: lifetime)
            )
        }
        if entries.count > maximumRecords {
            let keep = entries.sorted {
                if $0.value.expiresAt != $1.value.expiresAt { return $0.value.expiresAt > $1.value.expiresAt }
                return $0.key < $1.key
            }.prefix(maximumRecords)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    func matching(_ query: String, now: ContinuousClock.Instant) -> [SpotlightRecord] {
        removeExpired(now: now)
        let normalizedQuery = TextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        return entries.values
            .map(\.record)
            .filter {
                TextNormalizer.normalize($0.displayName).contains(normalizedQuery)
                    || TextNormalizer.normalize($0.url.path).contains(normalizedQuery)
            }
            .sorted {
                let left = $0.modifiedAt ?? .distantPast
                let right = $1.modifiedAt ?? .distantPast
                if left != right { return left > right }
                return $0.url.path < $1.url.path
            }
            .prefix(DomainLimits.itemsPerBatch)
            .map { $0 }
    }

    private func removeExpired(now: ContinuousClock.Instant) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

public struct FileProvider: LauncherProvider {
    public let descriptor = ProviderDescriptor(
        id: "files",
        displayName: "Files",
        supportedModes: [.all, .files],
        supportsEmptyQuery: false
    )
    private let spotlight: any SpotlightServicing
    private let actions: any FileActionServicing
    private let preferences: FileSearchPreferences
    private let cache = FileResultCache()
    private let recentCache: RecentFileCache
    private let clock: any ClockServicing

    public init(
        spotlight: any SpotlightServicing = MDSpotlightService(),
        actions: any FileActionServicing,
        preferences: FileSearchPreferences = FileSearchPreferences(),
        recentCacheLifetime: Duration = .seconds(300),
        clock: any ClockServicing = SystemClockService()
    ) {
        self.spotlight = spotlight
        self.actions = actions
        self.preferences = preferences
        recentCache = RecentFileCache(lifetime: recentCacheLifetime)
        self.clock = clock
    }

    public func search(request: QueryRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task {
            guard !request.normalizedText.isEmpty else {
                continuation.yield(.items([], isFinal: true))
                continuation.finish()
                return
            }
            continuation.yield(.status(.loading))
            let cachedRecords = await recentCache.matching(request.normalizedText, now: await clock.now())
            if !cachedRecords.isEmpty {
                let (resolved, items) = makeItems(records: cachedRecords, request: request)
                await cache.replace(with: resolved)
                continuation.yield(.replacement(items, isFinal: false))
            }
            do {
                let options = await preferences.options()
                let updates = await spotlight.searchFileUpdates(
                    containing: request.normalizedText,
                    options: options,
                    limit: DomainLimits.candidatesPerProvider
                )
                for try await batch in updates {
                    try Task.checkCancellation()
                    await recentCache.merge(batch.records, now: await clock.now())
                    let (cached, items) = makeItems(records: batch.records, request: request)
                    await cache.replace(with: cached)
                    continuation.yield(.replacement(items, isFinal: true))
                }
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
                return
            } catch let error as SpotlightServiceError {
                continuation.yield(.status(.unavailable(error.descriptor)))
                continuation.yield(.items([], isFinal: true))
            } catch {
                continuation.yield(
                    .status(
                        .failed(
                            ErrorDescriptor(
                                code: "files.searchFailed",
                                message: "File search failed.",
                                recoverySuggestion: "Check Spotlight status and try again."
                            )
                        )
                    )
                )
                continuation.yield(.items([], isFinal: true))
            }
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func makeItems(
        records: [SpotlightRecord],
        request: QueryRequest
    ) -> ([String: SpotlightRecord], [LauncherItem]) {
        var cached: [String: SpotlightRecord] = [:]
        var items: [LauncherItem] = []
        items.reserveCapacity(records.count)
        for record in records {
            let stableID = Self.stableID(for: record.url)
            cached[stableID] = record
            let itemID = ItemID(providerID: descriptor.id, providerStableID: stableID)
            let open = ActionDescriptor(id: "open", title: "Open", icon: .systemSymbol("arrow.up.forward.app"))
            let fileActions = [
                open,
                ActionDescriptor(
                    id: "quickLook",
                    title: "Quick Look",
                    icon: .systemSymbol("eye"),
                    shortcut: KeyEquivalent(key: "y", modifiers: [.command]),
                    behavior: .keepLauncherOpen
                ),
                ActionDescriptor(
                    id: "reveal",
                    title: "Show in Finder",
                    icon: .systemSymbol("folder"),
                    shortcut: KeyEquivalent(key: "return", modifiers: [.command]),
                    behavior: .keepLauncherOpen
                ),
                ActionDescriptor(
                    id: "copyPath",
                    title: "Copy Path",
                    icon: .systemSymbol("doc.on.doc"),
                    behavior: .keepLauncherOpen
                ),
                ActionDescriptor(
                    id: "copyURL",
                    title: "Copy File URL",
                    icon: .systemSymbol("link"),
                    behavior: .keepLauncherOpen
                ),
            ]
            items.append(
                LauncherItem(
                    id: itemID,
                    providerID: descriptor.id,
                    title: record.displayName,
                    subtitle: record.matchKind == .content ? "Content match · \(record.url.path)" : record.url.path,
                    icon: .file(record.url),
                    canonicalResource: .file(record.url),
                    keywords: [
                        record.url.pathExtension,
                        record.contentType,
                        record.matchKind == .content ? request.normalizedText : nil,
                    ].compactMap { $0 },
                    actions: fileActions,
                    defaultActionID: open.id,
                    scoreFeatures: ScoreFeatures(
                        lastUsedAt: record.modifiedAt,
                        providerPrior: record.matchKind == .content ? 0.15 : 0.45
                    )
                )
            )
        }
        return (cached, items)
    }

    public func execute(request: ProviderActionRequest) async -> ActionResult {
        guard request.itemID.providerID == descriptor.id,
            let record = await cache.record(for: request.itemID.providerStableID)
        else {
            return .failure(
                ErrorDescriptor(
                    code: "files.staleResult",
                    message: "The file result is no longer current.",
                    recoverySuggestion: "Search for the file again."
                )
            )
        }
        guard FileManager.default.fileExists(atPath: record.url.path) else {
            return .failure(
                ErrorDescriptor(
                    code: "files.notFound",
                    message: "The file was moved or deleted.",
                    recoverySuggestion: "Refresh the file results."
                )
            )
        }

        switch request.actionID.rawValue {
        case "open":
            return await actions.open(record.url)
                ? .success()
                : .failure(ErrorDescriptor(code: "files.openFailed", message: "The file could not be opened."))
        case "quickLook":
            return await actions.preview(record.url)
                ? .success()
                : .failure(ErrorDescriptor(code: "files.previewFailed", message: "Quick Look could not preview this file."))
        case "reveal":
            await actions.reveal(record.url)
            return .success(message: "Shown in Finder")
        case "copyPath":
            await actions.copy(record.url.path)
            return .success(message: "Path copied")
        case "copyURL":
            await actions.copy(record.url.absoluteString)
            return .success(message: "File URL copied")
        default:
            return .failure(ErrorDescriptor(code: "files.invalidAction", message: "The file action is invalid."))
        }
    }

    private static func stableID(for url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
