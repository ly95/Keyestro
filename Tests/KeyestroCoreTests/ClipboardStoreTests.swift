import Foundation
import CoreGraphics
import ImageIO
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func clipboardStoreEncryptsDeduplicatesAndDetectsMissingKey() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let keychain = InMemoryKeychainService()
    let keys = InstallationKeyManager(keychain: keychain, service: "com.keyestro.clipboard-tests")
    let store = ClipboardStore(database: database, keyManager: keys)
    await store.initialize(enabled: true)
    let secret = "clipboard super-secret-value\nprivate body"
    let first = await store.capture(.text(secret), sourceBundleIdentifier: "com.example.source", at: Date(timeIntervalSince1970: 100))
    let firstID = try #require(first.successValue)
    let duplicate = await store.capture(.text(secret), sourceBundleIdentifier: nil, at: Date(timeIntervalSince1970: 200))
    #expect(duplicate.successValue == firstID)
    #expect(try await database.clipboardItemCount() == 1)

    let matches = try #require(await store.search("super-secret").successValue)
    #expect(matches.count == 1)
    #expect(matches[0].id == firstID)
    #expect(matches[0].title == "clipboard super-secret-value")
    #expect(await store.content(id: firstID).successValue == .text(secret))

    let databaseBytes = try Data(contentsOf: paths.database)
    let walBytes = (try? Data(contentsOf: URL(fileURLWithPath: paths.database.path + "-wal"))) ?? Data()
    #expect(!String(decoding: databaseBytes + walBytes, as: UTF8.self).contains(secret))

    await keychain.delete(
        service: "com.keyestro.clipboard-tests",
        account: InstallationKeyManager.clipboardMasterAccount
    )
    let reloaded = ClipboardStore(database: database, keyManager: keys)
    await reloaded.initialize(enabled: true)
    #expect(await reloaded.currentState() == .keyMissing(encryptedItemCount: 1))
    #expect(try await database.clipboardItemCount() == 1)
    #expect(await reloaded.clear(type: .image).successValue != nil)
    #expect(await reloaded.currentState() == .keyMissing(encryptedItemCount: 1))

    #expect(await reloaded.clear().successValue != nil)
    #expect(await reloaded.currentState() == .ready(itemCount: 0))
    #expect(try await database.clipboardItemCount() == 0)
    #expect(await reloaded.capture(.text("new key works"), sourceBundleIdentifier: nil).successValue != nil)
}

@Test func concurrentIdenticalClipboardCapturesConvergeOnOneEncryptedItem() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-concurrent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-concurrent-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let store = ClipboardStore(
        database: database,
        keyManager: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.clipboard-concurrent-tests"
        )
    )
    await store.initialize(enabled: true)

    let results = await withTaskGroup(of: Result<String, ErrorDescriptor>.self) { group in
        for index in 0..<32 {
            group.addTask {
                await store.capture(
                    .text("one concurrent secret"),
                    sourceBundleIdentifier: "com.example.source",
                    at: Date(timeIntervalSince1970: TimeInterval(index + 1))
                )
            }
        }
        var values: [Result<String, ErrorDescriptor>] = []
        for await result in group { values.append(result) }
        return values
    }

    let identifiers = results.compactMap(\.successValue)
    #expect(identifiers.count == 32)
    #expect(Set(identifiers).count == 1)
    #expect(try await database.clipboardItemCount() == 1)
    #expect(await store.currentState() == .ready(itemCount: 1))

    await store.initialize(enabled: false)
    #expect(await store.clear().successValue != nil)
    #expect(await store.currentState() == .disabled)
    #expect(try await database.clipboardItemCount() == 0)
}

@Test func clipboardImagesUseEncryptedBoundedThumbnailsAndLazyOriginalDecryption() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-image-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-image-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let keys = InstallationKeyManager(
        keychain: InMemoryKeychainService(),
        service: "com.keyestro.clipboard-image-tests"
    )
    let image = try testPNG(width: 640, height: 320)
    let store = ClipboardStore(database: database, keyManager: keys)
    await store.initialize(enabled: true)
    let result = await store.capture(.imagePNG(image), sourceBundleIdentifier: nil)
    let itemID = try #require(result.successValue)
    let stored = try #require(try await database.clipboardItem(id: itemID))
    #expect(stored.thumbnailCiphertext != nil)
    #expect(stored.thumbnailNonce?.count == 12)
    #expect(stored.thumbnailTag?.count == 16)

    let firstMatches = try #require(await store.search("image").successValue)
    let firstEntry = try #require(firstMatches.first)
    let thumbnail = try #require(firstEntry.thumbnailPNG)
    #expect(thumbnail.count <= 256 * 1_024)
    #expect(thumbnail != image)

    let reloaded = ClipboardStore(database: database, keyManager: keys)
    await reloaded.initialize(enabled: true)
    let reloadedMatches = try #require(await reloaded.search("image").successValue)
    let reloadedEntry = try #require(reloadedMatches.first)
    #expect(reloadedEntry.thumbnailPNG == thumbnail)
    #expect(await reloaded.content(id: itemID).successValue == .imagePNG(image))

    let databaseBytes = try Data(contentsOf: paths.database)
    let walBytes = (try? Data(contentsOf: URL(fileURLWithPath: paths.database.path + "-wal"))) ?? Data()
    let diskBytes = databaseBytes + walBytes
    #expect(diskBytes.range(of: thumbnail) == nil)
    #expect(diskBytes.range(of: Data(image.base64EncodedString().utf8)) == nil)
}

@Test func clipboardStoreAppliesRetentionAndClearsOneContentType() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-retention-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-retention-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let keys = InstallationKeyManager(
        keychain: InMemoryKeychainService(),
        service: "com.keyestro.clipboard-retention-tests"
    )
    let store = ClipboardStore(
        database: database,
        keyManager: keys,
        policy: ClipboardRetentionPolicy(maximumAge: nil, maximumItemCount: 2)
    )
    await store.initialize(enabled: true)
    let now = Date()
    let exampleURL = try #require(URL(string: "https://example.com"))
    _ = await store.capture(.text("oldest"), sourceBundleIdentifier: nil, at: now.addingTimeInterval(-2))
    _ = await store.capture(.url(exampleURL), sourceBundleIdentifier: nil, at: now.addingTimeInterval(-1))
    _ = await store.capture(.files([URL(fileURLWithPath: "/tmp/example")]), sourceBundleIdentifier: nil, at: now)
    #expect(try await database.clipboardItemCount() == 2)
    #expect((await store.search("oldest").successValue ?? []).isEmpty)

    _ = await store.clear(type: .url)
    #expect(try await database.clipboardItemCount() == 1)
    #expect((await store.search("example").successValue ?? []).count == 1)
}

@Test func clipboardSearchFiltersBeforeLimitAndOrdersTheCompleteTimeline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyestro-clipboard-filter-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try AppPaths(
        bundleIdentifier: "com.keyestro.clipboard-filter-tests",
        applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
        cachesRoot: root.appendingPathComponent("cache", isDirectory: true)
    )
    let database = LauncherDatabase(paths: paths)
    let store = ClipboardStore(
        database: database,
        keyManager: InstallationKeyManager(
            keychain: InMemoryKeychainService(),
            service: "com.keyestro.clipboard-filter-tests"
        )
    )
    await store.initialize(enabled: true)
    let textID = try #require(
        (await store.capture(.text("synthetic text"), sourceBundleIdentifier: nil, at: Date(timeIntervalSince1970: 100)))
            .successValue
    )
    let imageID = try #require(
        (await store.capture(.imagePNG(testPNG(width: 4, height: 4)), sourceBundleIdentifier: nil, at: Date(timeIntervalSince1970: 200)))
            .successValue
    )
    let fileID = try #require(
        (await store.capture(
            .files([URL(fileURLWithPath: "/tmp/synthetic-needle.txt")]),
            sourceBundleIdentifier: nil,
            at: Date(timeIntervalSince1970: 300)
        )).successValue
    )
    let syntheticURL = try #require(URL(string: "https://example.invalid/synthetic-needle"))
    let urlID = try #require(
        (await store.capture(
            .url(syntheticURL),
            sourceBundleIdentifier: nil,
            at: Date(timeIntervalSince1970: 400)
        )).successValue
    )

    let timeline = try #require(await store.search("", limit: 1_000).successValue)
    #expect(timeline.map(\.id) == [urlID, fileID, imageID, textID])
    let latest = try #require((await store.latestEntry()).successValue ?? nil)
    #expect(latest.id == urlID)
    #expect(latest.contentType == .url)

    let olderText = try #require(await store.search("", contentType: .text, limit: 1).successValue)
    #expect(olderText.map(\.id) == [textID])

    let fileIntersection = try #require(
        await store.search("ＳＹＮＴＨＥＴＩＣ－ＮＥＥＤＬＥ", contentType: .files, limit: 1).successValue
    )
    #expect(fileIntersection.map(\.id) == [fileID])
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self { return value }
        return nil
    }
}

private func testPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
