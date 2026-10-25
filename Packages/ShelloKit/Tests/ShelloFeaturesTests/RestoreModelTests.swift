import Foundation
import ShelloCore
import ShelloModel
import ShelloSecurity
import Testing

@testable import ShelloFeatures

/// Restore in a window (GLOSSARY: Restore), as its host list offers it: once the window appears, the
/// tabs it remembers are offered, named as their tabs would be, without those whose host was deleted,
/// which are counted; nothing connects until the user taps. Restore recreates them all and shows the
/// selected one, a tab can be restored alone, and Don't Restore forgets them. RestoreTests in the UI
/// tests take the whole way, through a termination of the app, against the test server.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RestoreModelTests {
    let secrets = TestSecrets()
    let test: TestDatabase
    let nas = Host(name: "nas", address: "127.0.0.1", port: 9, username: "admin", authMethod: .password)
    let web = Host(name: "web", address: "127.0.0.1", port: 9, username: "deploy", authMethod: .password)
    let deleted = UUID()

    init() async throws {
        test = try TestDatabase()
        try await test.repository.create(nas)
        try await test.repository.create(web)
    }

    private var file: URL { test.root.appending(path: "RememberedTabs.json") }

    /// The remembered tabs as a launch before this one left them: two of nas, one of a host deleted
    /// since, and web, with the second of nas selected.
    private func rememberTabs() {
        let store = RememberedTabsStore(file: file, openWindows: { ["window"] })
        _ = store.windowAppeared("window")
        store.remember(
            RememberedTabs(hostIDs: [nas.id, deleted, nas.id, web.id], selectedIndex: 2), ofWindow: "window")
    }

    /// The window's tabs in this launch, once the window appeared, with the offer shown.
    private func launch() async -> TerminalTabsModel {
        let model = TerminalTabsModel(
            connector: HostConnector(hostKeys: test.hostKeys, secrets: secrets.store), hosts: test.repository,
            settings: nil, rememberedTabs: RememberedTabsStore(file: file, openWindows: { ["window"] }))
        model.windowAppeared("window")
        await waitUntil { model.restoreOffer != nil }
        return model
    }

    /// What the next launch would offer.
    private func nextLaunchRemembers() -> RememberedTabs {
        RememberedTabsStore(file: file, openWindows: { ["window"] }).windowAppeared("window")
    }

    @Test func windowOffersItsTabsWithoutConnecting() async throws {
        rememberTabs()

        let model = await launch()

        let offer = try #require(model.restoreOffer)
        #expect(offer.hosts == [nas, nas, web])
        #expect(model.offeredTabNames == ["nas", "nas (2)", "web"])
        #expect(offer.deletedHostCount == 1)
        #expect(model.tabs.tabs.isEmpty)
        #expect(!model.isShowingTerminals)
    }

    /// Restore recreates the tabs in their order, shows them with the same tab selected, which
    /// connects, while the others wait to be selected. What they are is remembered at once.
    @Test func restoreRecreatesTheTabsAndShowsTheSelectedOne() async throws {
        rememberTabs()
        let model = await launch()

        model.restoreAll()

        #expect(model.restoreOffer == nil)
        #expect(model.tabs.tabs.map(\.host.name) == ["nas", "nas", "web"])
        #expect(model.selectedTab?.id == model.tabs.tabs[1].id)
        #expect(model.isShowingTerminals)
        let selected = try #require(model.selectedTab)
        await waitUntil { selected.state != .restored }
        #expect(model.tabs.tabs.filter { $0.state == .restored }.count == 2)
        #expect(nextLaunchRemembers() == RememberedTabs(hostIDs: [nas.id, nas.id, web.id], selectedIndex: 1))
    }

    /// A tab restored alone opens, connects and shows; the others stay offered, without it.
    @Test func tabRestoredAloneOpensAndTheOthersStayOffered() async throws {
        rememberTabs()
        let model = await launch()

        model.restoreTab(try #require(model.restoreOffer).tabs[2].id)

        #expect(model.tabs.tabs.map(\.host.name) == ["web"])
        #expect(model.isShowingTerminals)
        #expect(model.selectedTab?.state.isConnecting == true)
        #expect(model.restoreOffer?.hosts == [nas, nas])
        #expect(model.offeredTabNames == ["nas", "nas (2)"])
        #expect(nextLaunchRemembers() == RememberedTabs(hostIDs: [web.id], selectedIndex: 0))
    }

    /// Which offered tab connects at once if all are restored: the selected one; once that one was
    /// restored alone and stays selected, none of the others.
    @Test func selectedTabConnectsAtOnceUnlessItWasRestoredAlready() async throws {
        rememberTabs()
        let model = await launch()
        #expect(model.offeredTabConnectingAtOnce == 1)

        model.restoreTab(try #require(model.restoreOffer).tabs[1].id)

        #expect(model.offeredTabConnectingAtOnce == nil)
        model.restoreAll()
        #expect(model.tabs.tabs.map(\.host.name) == ["nas", "nas", "web"])
        #expect(model.selectedTab?.id == model.tabs.tabs.first?.id)
        #expect(model.tabs.tabs.dropFirst().allSatisfy { $0.state == .restored })
    }

    /// Restored tabs come after the open ones, and are named after them: no open tab's name changes.
    @Test func openTabsKeepTheirNames() async throws {
        rememberTabs()
        let model = await launch()
        model.connect(to: web)

        #expect(model.offeredTabNames == ["nas", "nas (2)", "web (2)"])
        model.restoreAll()

        #expect(model.tabs.tabs.map { model.name(of: $0) } == ["web", "nas", "nas (2)", "web (2)"])
    }

    /// Don't Restore forgets the tabs: the next launch offers none.
    @Test func dontRestoreForgetsTheTabs() async throws {
        rememberTabs()
        let model = await launch()

        model.dismissRestoreOffer()

        #expect(model.restoreOffer == nil)
        #expect(model.tabs.tabs.isEmpty)
        #expect(nextLaunchRemembers() == .empty)
    }

    /// A host deleted while the offer shows leaves it, and is counted with the others; once no host
    /// is left, there is nothing to offer.
    @Test func hostDeletedWhileOfferedLeavesTheOffer() async throws {
        rememberTabs()
        let model = await launch()

        try await test.repository.deleteHost(id: web.id)
        await waitUntil { model.restoreOffer?.hosts.count == 2 }

        #expect(model.restoreOffer?.hosts == [nas, nas])
        #expect(model.restoreOffer?.deletedHostCount == 2)
        try await test.repository.deleteHost(id: nas.id)
        await waitUntil { model.restoreOffer == nil }
        #expect(nextLaunchRemembers() == .empty)
    }

    /// Tabs opened while the offer shows are what the window has open: what is remembered.
    @Test func tabsOpenedMeanwhileAreRemembered() async throws {
        rememberTabs()
        let model = await launch()

        model.connect(to: web)

        #expect(model.restoreOffer != nil)
        #expect(nextLaunchRemembers() == RememberedTabs(hostIDs: [web.id], selectedIndex: 0))
    }

    /// The window is the same while its tabs live: appearing again offers nothing, as when Shello
    /// comes back to the foreground with its tabs.
    @Test func windowThatAppearsAgainOffersNothingMore() async throws {
        rememberTabs()
        let model = await launch()
        model.restoreAll()

        model.windowAppeared("window")
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.restoreOffer == nil)
        #expect(model.tabs.tabs.count == 3)
    }

    /// A window without remembered tabs offers nothing.
    @Test func windowWithoutRememberedTabsOffersNothing() async throws {
        let model = TerminalTabsModel(
            connector: HostConnector(hostKeys: test.hostKeys, secrets: secrets.store), hosts: test.repository,
            settings: nil, rememberedTabs: RememberedTabsStore(file: file, openWindows: { ["window"] }))

        model.windowAppeared("window")
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.restoreOffer == nil)
    }
}

/// The offer's texts count the tabs, in the singular and the plural.
@Test(arguments: [
    (1, "Restore 1 Tab", "One tab can’t be restored: its host was deleted.", "Won’t restore the tab"),
    (3, "Restore 3 Tabs", "3 tabs can’t be restored: their hosts were deleted.", "Won’t restore the 3 tabs"),
])
func restoreTextsCountTheTabs(count: Int, title: String, leftOut: String, dismissed: String) {
    #expect(RestoreDisplay.restoreAll(count: count) == title)
    #expect(RestoreDisplay.leftOut(count: count) == leftOut)
    #expect(RestoreDisplay.dismissed(count: count) == dismissed)
}

/// VoiceOver hears which tab Restore connects at once, and that the others wait; for one tab, the
/// title says it all.
@Test func restoreHintSaysWhichTabConnectsAtOnce() {
    #expect(
        RestoreDisplay.restoreAllHint(names: ["web", "db"], connecting: 1)
            == "Connects db now, and the others once you select them.")
    #expect(
        RestoreDisplay.restoreAllHint(names: ["web", "db"], connecting: nil)
            == "Opens them. Each connects once you select it.")
    #expect(RestoreDisplay.restoreAllHint(names: ["web"], connecting: 0) == "")
}
