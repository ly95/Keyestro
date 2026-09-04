import Testing
@testable import KeyestroApp

@Test
func settingsSearchCatalogHasUniqueTargetsAndCoversEverySection() {
    let entries = SettingsSearchCatalog.entries

    #expect(Set(entries.map(\.id)).count == entries.count)
    #expect(Set(entries.map(\.anchor)) == Set(SettingsAnchor.allCases))
    #expect(Set(entries.map(\.section)) == Set(SettingsSection.allCases))
    #expect(entries.allSatisfy { !$0.title.isEmpty && !$0.keywords.isEmpty })
}

@Test
func settingsSearchPrefersAnExactSettingTitle() {
    let results = SettingsSearchCatalog.search("Quick Paste")

    #expect(results.first?.id == "features.quick-paste")
}

@Test
func settingsSearchMatchesKeywordsAcrossCaseWidthAndDiacritics() {
    #expect(SettingsSearchCatalog.search("ＳＰＯＴＬＩＧＨＴ").first?.id == "features.files")
    #expect(SettingsSearchCatalog.search("frecency").first?.id == "privacy.ranking")
    #expect(SettingsSearchCatalog.search("cachés").first?.id == "advanced.caches")
    #expect(SettingsSearchCatalog.search("factory defaults").first?.id == "advanced.defaults")
}

@Test
func settingsSearchMatchesTheLocalizedSectionTitleAndIgnoresEmptyQueries() {
    let results = SettingsSearchCatalog.search(SettingsSection.shortcuts.title)

    #expect(Set(results.map(\.section)) == [.shortcuts])
    #expect(SettingsSearchCatalog.search(" \n\t ").isEmpty)
}

@Test
func settingsSearchRequiresEveryQueryTokenAndRejectsUnknownText() {
    let results = SettingsSearchCatalog.search("clipboard sensitive")

    #expect(results.contains { $0.id == "features.quick-paste" })
    #expect(SettingsSearchCatalog.search("definitely-not-a-keyestro-setting").isEmpty)
}

@Test @MainActor
func settingsSearchNavigationSelectsTheSectionAndPublishesItsScrollTarget() throws {
    let navigation = SettingsNavigationModel()
    let entry = try #require(SettingsSearchCatalog.entries.first { $0.id == "features.ocr" })

    navigation.navigate(to: entry)
    #expect(navigation.selection == .features)
    let request = try #require(navigation.pendingScrollRequest)
    #expect(request.anchor == .featuresOCR)

    navigation.consumePendingScrollRequest(request)
    #expect(navigation.pendingScrollRequest == nil)
}

@Test @MainActor
func settingsSearchNavigationRejectsAStaleScrollCompletion() throws {
    let navigation = SettingsNavigationModel()
    let files = try #require(SettingsSearchCatalog.entries.first { $0.anchor == .featuresFiles })
    let updates = try #require(SettingsSearchCatalog.entries.first { $0.anchor == .updatesCheck })

    navigation.navigate(to: files)
    let staleRequest = try #require(navigation.pendingScrollRequest)
    navigation.navigate(to: updates)
    let currentRequest = try #require(navigation.pendingScrollRequest)

    #expect(currentRequest.id > staleRequest.id)
    #expect(currentRequest.anchor == .updatesCheck)
    #expect(navigation.selection == .updates)

    navigation.consumePendingScrollRequest(staleRequest)
    #expect(navigation.pendingScrollRequest == currentRequest)

    navigation.consumePendingScrollRequest(currentRequest)
    #expect(navigation.pendingScrollRequest == nil)
}

@Test @MainActor
func settingsSidebarKeyboardNavigationMovesContinuouslyAndStopsAtTheEdges() {
    let navigation = SettingsNavigationModel()

    navigation.moveSectionSelection(.previous)
    #expect(navigation.selection == .general)

    navigation.moveSectionSelection(.next)
    #expect(navigation.selection == .shortcuts)
    navigation.moveSectionSelection(.next)
    #expect(navigation.selection == .features)
    navigation.moveSectionSelection(.previous)
    #expect(navigation.selection == .shortcuts)

    navigation.selection = .about
    navigation.moveSectionSelection(.next)
    #expect(navigation.selection == .about)

    navigation.selection = nil
    navigation.moveSectionSelection(.next)
    #expect(navigation.selection == .general)
}

@Test @MainActor
func settingsSearchKeyboardSelectionTracksResultsAndActivatesTheHighlightedEntry() throws {
    let navigation = SettingsNavigationModel()
    navigation.searchQuery = "clipboard"
    let results = SettingsSearchCatalog.search(navigation.searchQuery)
    #expect(results.count > 1)
    #expect(navigation.searchResultSelection == results.first?.anchor)

    navigation.moveSearchSelection(.next, in: results)
    let second = try #require(results.dropFirst().first)
    #expect(navigation.searchResultSelection == second.anchor)

    navigation.activateSearchSelection(in: results)
    #expect(navigation.selection == second.section)
    #expect(navigation.pendingScrollRequest?.anchor == second.anchor)

    navigation.searchQuery = "update channel"
    let narrowedResults = SettingsSearchCatalog.search(navigation.searchQuery)
    #expect(navigation.searchResultSelection == narrowedResults.first?.anchor)

    navigation.searchQuery = ""
    #expect(navigation.searchResultSelection == nil)
}
