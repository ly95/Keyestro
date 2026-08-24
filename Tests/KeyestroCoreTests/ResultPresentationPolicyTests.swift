import Foundation
import KeyestroDomain
import Testing
@testable import KeyestroCore

@Test func stableAppendKeepsExistingRowsInPlaceAndAppendsNewRows() {
    let first = ranked("first", title: "First")
    let second = ranked("second", title: "Second")
    let updatedFirst = ranked("first", title: "First Updated", score: 1)
    let third = ranked("third", title: "Third")

    let output = ResultPresentationPolicy.stableAppend(
        current: [first, second],
        incoming: [third, updatedFirst, second],
        removeMissing: false
    )

    #expect(output.map(\.id) == [first.id, second.id, third.id])
    #expect(output.first?.item.title == "First Updated")
}

@Test func stableAppendReplacesEquivalentResourcesWithoutMovingTheRow() {
    let resource = CanonicalResource.application(bundleIdentifier: "com.example.app")
    let old = ranked("old", title: "Old", resource: resource)
    let replacement = ranked("replacement", title: "Replacement", resource: resource)

    let output = ResultPresentationPolicy.stableAppend(
        current: [old],
        incoming: [replacement],
        removeMissing: false
    )

    #expect(output.map(\.id) == [replacement.id])
}

@Test func stableAppendOnlyRemovesMissingRowsFromASettledSnapshot() {
    let retained = ranked("retained", title: "Retained")
    let missing = ranked("missing", title: "Missing")

    let streaming = ResultPresentationPolicy.stableAppend(
        current: [retained, missing],
        incoming: [retained],
        removeMissing: false
    )
    let settled = ResultPresentationPolicy.stableAppend(
        current: streaming,
        incoming: [retained],
        removeMissing: true
    )

    #expect(streaming.map(\.id) == [retained.id, missing.id])
    #expect(settled.map(\.id) == [retained.id])
}

private func ranked(
    _ stableID: String,
    title: String,
    resource: CanonicalResource? = nil,
    score: Double = 0
) -> RankedItem {
    let providerID = ProviderID("presentation-test")
    let action = ActionDescriptor(id: "open", title: "Open")
    return RankedItem(
        item: LauncherItem(
            id: ItemID(providerID: providerID, providerStableID: stableID),
            providerID: providerID,
            title: title,
            canonicalResource: resource,
            actions: [action],
            defaultActionID: action.id
        ),
        score: score,
        matchTier: .fuzzy
    )
}
