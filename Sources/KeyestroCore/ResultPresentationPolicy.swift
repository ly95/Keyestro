import KeyestroDomain

/// Keeps already-presented rows stable while providers stream fresher results.
public enum ResultPresentationPolicy {
    public static func stableAppend(
        current: [RankedItem],
        incoming: [RankedItem],
        removeMissing: Bool
    ) -> [RankedItem] {
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let incomingByResource = Dictionary(
            incoming.compactMap { result in
                result.item.canonicalResource.map { ($0, result) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var consumed = Set<ItemID>()
        var merged: [RankedItem] = []

        for existing in current {
            if let updated = incomingByID[existing.id] {
                merged.append(updated)
                consumed.insert(updated.id)
            } else if let resource = existing.item.canonicalResource,
                let replacement = incomingByResource[resource],
                !consumed.contains(replacement.id)
            {
                merged.append(replacement)
                consumed.insert(replacement.id)
            } else if !removeMissing {
                merged.append(existing)
            }
        }

        for result in incoming where consumed.insert(result.id).inserted {
            merged.append(result)
        }
        return merged
    }
}
