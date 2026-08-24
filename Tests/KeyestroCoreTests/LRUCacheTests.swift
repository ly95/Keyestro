import Testing
@testable import KeyestroCore

@Test func lruCacheEvictsTheLeastRecentlyUsedEntry() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.insert(1, forKey: "first")
    cache.insert(2, forKey: "second")
    #expect(cache.value(forKey: "first") == 1)

    cache.insert(3, forKey: "third")

    #expect(cache.value(forKey: "first") == 1)
    #expect(cache.value(forKey: "second") == nil)
    #expect(cache.value(forKey: "third") == 3)
    #expect(cache.count == 2)
}

@Test func lruCacheUpdatingAValueRefreshesItsRecency() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.insert(1, forKey: "first")
    cache.insert(2, forKey: "second")
    cache.insert(10, forKey: "first")
    cache.insert(3, forKey: "third")

    #expect(cache.value(forKey: "first") == 10)
    #expect(cache.value(forKey: "second") == nil)
    #expect(cache.value(forKey: "third") == 3)
}
