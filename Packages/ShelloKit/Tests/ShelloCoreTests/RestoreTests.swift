import Foundation
import ShelloModel
import ShelloSSH
import ShelloStorage
import ShelloTmux
import Testing

@testable import ShelloCore

/// What a window remembers of its tabs for Restore (GLOSSARY), as they change: the host of each tab,
/// in the tabs' order, and the selected tab, whatever changes them. Nothing else is remembered.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RememberedTabsTests {
    let test = TabTest()
    let changes = RememberedChanges()
    let nas = TabTest.host("nas")
    let web = TabTest.host("web")
    let db = TabTest.host("db")

    init() {
        test.tabs.onRememberedTabsChange = { [changes] in changes.values.append($0) }
    }

    /// A tab opens after the selected one, so opening reorders them too; several tabs of one host
    /// are remembered as several.
    @Test func rememberedTabsFollowOpeningAndSelecting() throws {
        let first = test.tabs.open(nas)
        test.tabs.open(web)
        #expect(test.tabs.remembered == RememberedTabs(hostIDs: [nas.id, web.id], selectedIndex: 1))

        test.tabs.select(first)
        test.tabs.open(db)
        test.tabs.open(nas)

        #expect(test.tabs.remembered == RememberedTabs(hostIDs: [nas.id, db.id, nas.id, web.id], selectedIndex: 2))
        test.tabs.selectNext()
        #expect(test.tabs.remembered.selectedIndex == 3)
        test.tabs.selectNext()
        #expect(test.tabs.remembered.selectedIndex == 0)
        test.tabs.selectPrevious()
        #expect(test.tabs.remembered.selectedIndex == 3)
        // Each change is passed on once, as it happens.
        #expect(changes.values.last == test.tabs.remembered)
        #expect(changes.values.count == 8)
    }

    /// Closing a tab takes it off; the tab selected after it is remembered as selected. Once the last
    /// one is closed, the window remembers no tabs, and restores nothing.
    @Test func closingATabTakesItOff() async throws {
        let first = test.tabs.open(nas)
        let second = test.tabs.open(web)
        test.tabs.select(first)

        await test.tabs.close(first).value

        #expect(test.tabs.remembered == RememberedTabs(hostIDs: [web.id], selectedIndex: 0))
        await test.tabs.close(second).value
        #expect(test.tabs.remembered == RememberedTabs(hostIDs: [], selectedIndex: nil))
        #expect(test.tabs.remembered.isEmpty)
        #expect(changes.values.last == test.tabs.remembered)
    }

    /// A tab the user declined to trust closes by itself: it is not remembered either.
    @Test func tabThatClosesByItselfIsTakenOff() async throws {
        test.server.queue(.asksToTrust(TerminalTabsTests.hostKey))
        let tab = test.tabs.open(nas)
        await waitUntil { tab.trustQuestion != nil }

        tab.answerTrust(false)
        await waitUntil { tab.state == .closed }

        #expect(test.tabs.remembered.isEmpty)
        #expect(changes.values.last == test.tabs.remembered)
    }
}

/// Restore recreates the remembered tabs in their order, with the same tab selected, and connects
/// nothing until they show: the selected tab connects once the tabs are on screen, the others once
/// they are selected, as after the background (README section 4). Each connects as any tab does,
/// along its host's route, attaching the host's tmux session.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TabRestoreTests {
    let test = TabTest()
    let nas = TabTest.host("nas")
    let web = TabTest.host("web")
    let db = TabTest.host("db")

    @Test func restoredTabsWaitWithoutConnecting() async throws {
        test.tabs.restore([nas, web, db], selecting: 1)

        #expect(test.tabs.tabs.map(\.host.name) == ["nas", "web", "db"])
        #expect(test.tabs.selectedTab?.host == web)
        #expect(test.tabs.tabs.allSatisfy { $0.state == .restored })
        #expect(test.tabs.remembered == RememberedTabs(hostIDs: [nas.id, web.id, db.id], selectedIndex: 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(test.server.tries == 0)
    }

    /// The selected tab connects once the tabs show, and attaches the host's tmux session as any
    /// connection does; the others wait until they are selected.
    @Test func selectedTabConnectsOnceOnScreenAndTheOthersOnceSelected() async throws {
        var withTmux = web
        withTmux.tmuxAutoAttach = true
        test.tabs.restore([nas, withTmux, db], selecting: 1)
        let selected = try #require(test.tabs.selectedTab)

        test.tabs.isOnScreen = true
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let shell = try #require(test.server.lastConnection?.shell)
        shell.print("admin@web:~$ ")
        await waitUntil { selected.state == .active }

        #expect(test.server.tries == 1)
        #expect(test.server.routes.map(\.host) == [withTmux])
        #expect(
            selected.tmux == .attaching(try #require(TmuxSessionName("main")), try #require(TmuxVersion(name: "3.4"))))
        await waitUntil { shell.input.contains("new-session") }
        #expect(shell.input == " tmux -u new-session -A -s 'main'\r")
        #expect(test.tabs.tabs.filter { $0.state == .restored }.map(\.host.name) == ["nas", "db"])
        let first = try #require(test.tabs.tabs.first)
        test.tabs.select(first)
        await waitUntil { first.state == .active }
        #expect(test.server.tries == 2)
        #expect(test.tabs.tabs.last?.state == .restored)
    }

    /// Restoring while tabs are open puts the restored ones after them, so that the open tabs keep
    /// their places and their names, and selects the one that was selected.
    @Test func restoredTabsComeAfterTheOpenOnes() throws {
        let open = test.tabs.open(nas)
        test.tabs.open(web)
        test.tabs.select(open)

        test.tabs.restore([web, db], selecting: 1)

        #expect(test.tabs.tabs.map(\.host.name) == ["nas", "web", "web", "db"])
        #expect(test.tabs.selectedTab?.host == db)
        #expect(test.tabs.tabs.prefix(2).allSatisfy { $0.state != .restored })
    }

    /// Without a selected tab among them, the restored tabs leave the selection as it is, or select
    /// the first when none was.
    @Test func withoutASelectedTabTheSelectionStaysOrTheFirstIsSelected() throws {
        test.tabs.restore([nas, web], selecting: nil)
        #expect(test.tabs.selectedTab?.host == nas)

        test.tabs.restore([db], selecting: nil)
        #expect(test.tabs.selectedTab?.host == nas)
    }

    /// A restored tab that has not connected has no connection to close in the background, and
    /// still waits to be on screen once Shello is back.
    @Test func restoredTabWaitsThroughTheBackground() async throws {
        test.tabs.restore([nas], selecting: 0)

        await test.tabs.enterBackground(closingConnectionsAfter: .milliseconds(10))
        test.tabs.enterForeground()
        try await Task.sleep(for: .milliseconds(50))

        #expect(test.tabs.selectedTab?.state == .restored)
        #expect(test.server.tries == 0)
    }

    /// The status bar's Connect connects a restored tab that waits, as when Shello is locked.
    @Test func connectingByHandConnectsARestoredTab() async throws {
        test.tabs.restore([nas], selecting: 0)
        let tab = try #require(test.tabs.selectedTab)

        tab.reconnect()
        await waitUntil { tab.state == .active }

        #expect(tab.connectionCount == 1)
    }
}

/// Restored tabs of hosts behind jump hosts (README section 3) connect along their host's route as
/// it is stored now, the same way as every tab. One whose route no longer works says so in its tab,
/// and the other restored tabs connect all the same.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct JumpHostRestoreTests {
    let hosts: TestHosts
    let test: TabTest
    let bastion: Host
    let inner: Host
    let web: Host

    init() async throws {
        hosts = try TestHosts()
        test = TabTest(hosts: hosts.repository)
        bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump", authMethod: .password)
        inner = Host(name: "inner", address: "10.0.0.5", username: "jump", authMethod: .password)
        web = Host(
            name: "web-01", address: "10.0.1.21", username: "deploy", authMethod: .password,
            jumpHostIDs: [bastion.id, inner.id], keepaliveInterval: .seconds(3600))
        for host in [bastion, inner, web] {
            try await hosts.repository.create(host)
        }
    }

    @Test func restoredTabKeepsItsHostAndConnectsAlongItsRoute() async throws {
        test.tabs.restore([web], selecting: 0)
        let tab = try #require(test.tabs.selectedTab)

        test.tabs.isOnScreen = true
        await waitUntil { tab.state == .active }

        #expect(tab.host.id == web.id)
        #expect(tab.route?.hops.map(\.name) == ["bastion", "inner", "web-01"])
        #expect(test.server.routes.map { $0.hops.map(\.name) } == [["bastion", "inner", "web-01"]])
    }

    /// A jump host deleted since the tab was remembered: the tab says why, without trying, and the
    /// next restored tab connects once selected.
    @Test func routeThatNoLongerWorksShowsItsErrorAndTheOtherTabsConnect() async throws {
        try await hosts.repository.deleteHost(id: inner.id)
        test.tabs.restore([web, bastion], selecting: 0)
        let broken = try #require(test.tabs.selectedTab)

        test.tabs.isOnScreen = true
        await waitUntil { !broken.state.isConnecting && broken.state != .restored }

        #expect(broken.state == .disconnected(RouteError.missingJumpHost(of: "web-01").description))
        #expect(test.server.tries == 0)
        let other = try #require(test.tabs.tabs.last)
        test.tabs.select(other)
        await waitUntil { other.state == .active }
        #expect(test.server.routes.map { $0.hops.map(\.name) } == [["bastion"]])
    }
}

/// What a window offers to restore: its remembered tabs whose hosts Shello still has, as they are
/// now, in their order. A tab whose host was deleted since is left out, and counted, so that the
/// offer can say so; the selection moves on from a tab left out, as closing a tab moves it.
@MainActor
struct RestoreOfferTests {
    let nas = TabTest.host("nas")
    let web = TabTest.host("web")
    let db = TabTest.host("db")
    let deleted = UUID()

    private func saved(_ hosts: Host...) -> [Host.ID: Host] {
        Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
    }

    @Test func deletedHostsAreLeftOutAndCounted() {
        let offer = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, deleted, web.id, deleted], selectedIndex: 2), hosts: saved(nas, web, db))

        #expect(offer.hosts == [nas, web])
        #expect(offer.selectedIndex == 1)
        #expect(offer.deletedHostCount == 2)
    }

    @Test func hostsAreTakenAsTheyAreNow() {
        var renamed = web
        renamed.name = "web-01"

        let offer = RestoreOffer(RememberedTabs(hostIDs: [web.id, web.id], selectedIndex: 0), hosts: saved(renamed))

        #expect(offer.hosts.map(\.name) == ["web-01", "web-01"])
    }

    /// The selected tab's host was deleted: the tab after it is selected, or the one before it when
    /// it was the last.
    @Test func selectionMovesOnFromATabLeftOut() {
        let middle = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, deleted, web.id], selectedIndex: 1), hosts: saved(nas, web))
        let last = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, web.id, deleted], selectedIndex: 2), hosts: saved(nas, web))
        let none = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, deleted, web.id], selectedIndex: nil), hosts: saved(nas, web))

        // web, after nas.
        #expect(middle.selectedIndex == 1)
        #expect(last.selectedIndex == 1)
        #expect(none.selectedIndex == nil)
    }

    @Test func offerWithoutHostsIsEmpty() {
        let offer = RestoreOffer(RememberedTabs(hostIDs: [deleted], selectedIndex: 0), hosts: saved(nas))

        #expect(offer.isEmpty)
        #expect(offer.selectedIndex == nil)
        #expect(offer.deletedHostCount == 1)
    }

    /// While the offer shows, its hosts follow the saved ones: a host deleted meanwhile leaves it and
    /// is counted with the others, and a renamed one shows its new name.
    @Test func offerFollowsTheSavedHosts() {
        let offer = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, deleted, web.id, db.id], selectedIndex: 2), hosts: saved(nas, web, db))
        var renamed = db
        renamed.name = "db-01"

        let updated = offer.updated(with: saved(nas, renamed))

        #expect(updated.hosts == [nas, renamed])
        #expect(updated.deletedHostCount == 2)
        // web was selected: the tab after it.
        #expect(updated.selectedIndex == 1)
        // Each tab stays the same tab.
        #expect(updated.tabs.map(\.id) == [offer.tabs[0].id, offer.tabs[2].id])
    }

    /// A tab restored alone leaves the offer. The others keep their order; once the selected one has
    /// gone, restoring the others selects none of them.
    @Test func tabRestoredAloneLeavesTheOffer() {
        let offer = RestoreOffer(
            RememberedTabs(hostIDs: [nas.id, web.id, db.id], selectedIndex: 2), hosts: saved(nas, web, db))

        let rest = offer.removingTab(offer.tabs[0].id)

        #expect(rest.hosts == [web, db])
        #expect(rest.tabs.map(\.id) == offer.tabs.dropFirst().map(\.id))
        #expect(rest.selectedIndex == 1)
        let last = rest.removingTab(offer.tabs[2].id)
        #expect(last.selectedIndex == nil)
        #expect(last.hosts == [web])
        #expect(last.deletedHostCount == 0)
    }
}

/// Where each window's tabs are remembered: in a file, under the window's scene session, read again
/// by the next launch. A window that iOS discards takes its tabs with it, except that the first
/// window of a launch, if new, takes over the tabs of the window that changed last among those iOS
/// discarded while Shello was not running, as it does when it installs a new build.
@MainActor
struct RememberedTabsStoreTests {
    let directory = TemporaryDirectory()
    var file: URL { directory.url.appending(path: "RememberedTabs.json") }
    let clock = TestClock()
    let tabsA = RememberedTabs(hostIDs: [UUID(), UUID()], selectedIndex: 1)
    let tabsB = RememberedTabs(hostIDs: [UUID()], selectedIndex: 0)

    /// The store as a launch of Shello opens it, with the windows iOS keeps.
    private func launch(keeping windows: Set<String>) -> RememberedTabsStore {
        RememberedTabsStore(file: file, openWindows: { windows }, now: { [clock] in clock.next() })
    }

    @Test func eachWindowFindsItsOwnTabsAfterALaunch() {
        let first = launch(keeping: ["A", "B"])
        #expect(first.windowAppeared("A") == .empty)
        first.remember(tabsA, ofWindow: "A")
        #expect(first.windowAppeared("B") == .empty)
        first.remember(tabsB, ofWindow: "B")

        let next = launch(keeping: ["A", "B"])

        #expect(next.windowAppeared("B") == tabsB)
        #expect(next.windowAppeared("A") == tabsA)
    }

    /// The last change is what counts: a window whose last tab was closed restores nothing.
    @Test func windowWhoseLastTabClosedRestoresNothing() {
        let first = launch(keeping: ["A"])
        _ = first.windowAppeared("A")
        first.remember(tabsA, ofWindow: "A")
        first.remember(.empty, ofWindow: "A")

        #expect(launch(keeping: ["A"]).windowAppeared("A") == .empty)
    }

    /// A window the user closed while Shello ran takes its tabs with it: a window opened later does
    /// not get them.
    @Test func windowClosedWhileShelloRunsTakesItsTabsWithIt() {
        let windows = OpenWindows(["A", "B"])
        let store = RememberedTabsStore(
            file: file, openWindows: { windows.identifiers }, now: { [clock] in clock.next() })
        _ = store.windowAppeared("A")
        _ = store.windowAppeared("B")
        store.remember(tabsA, ofWindow: "A")
        store.remember(tabsB, ofWindow: "B")

        windows.identifiers = ["B", "C"]
        store.remember(tabsB, ofWindow: "B")

        #expect(store.windowAppeared("C") == .empty)
        #expect(launch(keeping: []).windowAppeared("D") == tabsB)
    }

    /// iOS discarded every window while Shello was not running, as when it installs a new build:
    /// the first window of the launch takes over the tabs that changed last, and the others go.
    @Test func newFirstWindowTakesOverTheTabsThatChangedLast() {
        let first = launch(keeping: ["A", "B"])
        _ = first.windowAppeared("A")
        _ = first.windowAppeared("B")
        first.remember(tabsB, ofWindow: "B")
        first.remember(tabsA, ofWindow: "A")

        let next = launch(keeping: ["C", "D"])

        #expect(next.windowAppeared("C") == tabsA)
        #expect(next.windowAppeared("D") == .empty)
        #expect(launch(keeping: ["C", "D"]).windowAppeared("C") == tabsA)
    }

    /// A window that iOS kept has tabs of its own, even none: it never takes over a discarded one's.
    @Test func windowThatIOSKeptKeepsItsOwnTabs() {
        let first = launch(keeping: ["A", "B"])
        _ = first.windowAppeared("A")
        _ = first.windowAppeared("B")
        first.remember(tabsA, ofWindow: "A")

        let next = launch(keeping: ["B"])

        #expect(next.windowAppeared("B") == .empty)
        #expect(next.windowAppeared("C") == .empty)
    }

    /// A file that cannot be read, as one a crash cut short, or a newer Shello's, holds no tabs, and
    /// is written anew.
    @Test(arguments: ["{", #"{"version": 2, "windows": {}}"#, #"{"version": 1}"#])
    func unreadableFileHoldsNoTabs(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)

        let store = launch(keeping: ["A"])

        #expect(store.windowAppeared("A") == .empty)
        store.remember(tabsA, ofWindow: "A")
        #expect(launch(keeping: ["A"]).windowAppeared("A") == tabsA)
    }

    /// The file holds the tabs' hosts by identifier and the selected tab's place, nothing more: no
    /// name, address, user or secret, and nothing the terminals showed.
    @Test func fileHoldsHostIdentifiersAndPlacesOnly() throws {
        let store = launch(keeping: ["A"])
        _ = store.windowAppeared("A")
        store.remember(tabsA, ofWindow: "A")

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let windows = try #require(json["windows"] as? [String: [String: Any]])
        let tabs = try #require(windows["A"]?["tabs"] as? [String: Any])
        #expect(Set(json.keys) == ["version", "windows"])
        #expect(Set(try #require(windows["A"]).keys) == ["tabs", "changedAt"])
        #expect(Set(tabs.keys) == ["hostIDs", "selectedIndex"])
        #expect(tabs["hostIDs"] as? [String] == tabsA.hostIDs.map(\.uuidString))
        #expect(tabs["selectedIndex"] as? Int == 1)
    }
}

/// A directory of its own in the temporary directory, deleted when the test ends.
final class TemporaryDirectory: Sendable {
    let url = URL.temporaryDirectory.appending(
        path: "ShelloCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The windows iOS keeps, as a test changes them: the user closing one, for example.
@MainActor
final class OpenWindows {
    var identifiers: Set<String>

    init(_ identifiers: Set<String>) {
        self.identifiers = identifiers
    }
}

/// A clock for the store's changes that moves a second at each reading, so that every change is
/// later than the one before.
@MainActor
final class TestClock {
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func next() -> Date {
        current += 1
        return current
    }
}

/// The values a window's tabs passed on to be remembered, in order.
@MainActor
final class RememberedChanges {
    var values: [RememberedTabs] = []
}
