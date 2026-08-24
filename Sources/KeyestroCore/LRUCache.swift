import Foundation

/// A small, bounded least-recently-used cache with constant-time reads and normal writes.
/// Eviction scans the bounded entry set, which keeps the implementation compact while
/// avoiding linked-node allocations on the query hot path.
struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var lastAccess: UInt64
    }

    let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var accessCounter: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        entries.reserveCapacity(self.capacity)
    }

    var count: Int { entries.count }

    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        entries[key] = Entry(value: value, lastAccess: nextAccess())
        guard entries.count > capacity,
            let leastRecentlyUsed = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        else { return }
        entries.removeValue(forKey: leastRecentlyUsed)
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        entries.removeValue(forKey: key)?.value
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        accessCounter = 0
    }

    private mutating func nextAccess() -> UInt64 {
        accessCounter &+= 1
        if accessCounter == 0 {
            // This is practically unreachable, but rebasing preserves LRU ordering on overflow.
            let orderedKeys = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }.map(\.key)
            for (offset, key) in orderedKeys.enumerated() {
                entries[key]?.lastAccess = UInt64(offset + 1)
            }
            accessCounter = UInt64(orderedKeys.count + 1)
        }
        return accessCounter
    }
}
