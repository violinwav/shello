import Foundation
import ShelloCore
import ShelloModel
import ShelloSecurity
import ShelloTerminalUI
import SwiftUI
import Testing

@testable import ShelloFeatures

/// The terminal screen's tabs when they cannot connect, and what the screen does with them: it says
/// why above the terminal, tells tabs of one host apart, closes what is in front first, and follows
/// the app's foreground, background and lock. TabTests in the UI tests take them the whole way,
/// against the test server.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalTabsModelTests {
    let secrets = TestSecrets()
    let test: TestDatabase

    init() throws {
        test = try TestDatabase()
    }

    @Test func hostWithoutAPasswordSaysSo() async throws {
        let model = model()

        model.connect(to: Self.host)

        let tab = try #require(model.selectedTab)
        await waitUntil { !tab.state.isConnecting }
        #expect(tab.state == .disconnected(ConnectError.noPassword.description))
        #expect(tab.trustQuestion == nil)
        #expect(model.isShowingTerminals)
    }

    @Test func unreachableServerSaysSo() async throws {
        try secrets.store.store(Secret(utf8: "hunter2"), as: .password(of: Self.host.id))
        let model = model()

        model.connect(to: Self.host)

        let tab = try #require(model.selectedTab)
        await waitUntil { !tab.state.isConnecting }
        #expect(tab.state == .disconnected("The server can’t be reached: connection refused."))
    }

    /// Closing the last tab goes back to the host list, and leaves nothing open.
    @Test func closingTheLastTabGoesBackToTheHosts() async throws {
        let model = model()
        model.connect(to: Self.host)
        let tab = try #require(model.selectedTab)

        model.close(tab)

        #expect(!model.isShowingTerminals)
        await waitUntil { model.tabs.tabs.isEmpty }
        #expect(tab.state == .closed)
        #expect(tab.terminal.streamState == .detached)
    }

    /// Several tabs of one host are told apart by a number, in their order; New Tab opens another
    /// one of the selected tab's host.
    @Test func tabsOfOneHostAreNumbered() throws {
        let model = model()
        model.connect(to: Self.host)
        model.connect(to: Host(name: "web", address: "127.0.0.1", port: 9, username: "deploy"))
        let nas = try #require(model.tabs.tabs.first)
        model.select(nas)

        model.newTab()

        #expect(model.tabs.tabs.map { model.name(of: $0) } == ["nas", "nas (2)", "web"])
        #expect(model.hasSeveralTabs)
    }

    /// Command-W closes what is in front: the connection sheet first, then the tab.
    @Test func commandWClosesTheConnectionSheetBeforeTheTab() async throws {
        let model = model()
        model.connect(to: Self.host)
        model.isShowingConnection = true

        model.closeFrontmost()

        #expect(!model.isShowingConnection)
        #expect(model.tabs.tabs.count == 1)
        model.closeFrontmost()
        await waitUntil { model.tabs.tabs.isEmpty }
        #expect(model.tabs.tabs.isEmpty)
    }

    /// The tabs connect only while the window is active and Shello unlocked, so that a return costs
    /// at most one Face ID prompt (README section 13).
    @Test func tabsConnectOnlyWhileActiveAndUnlocked() {
        let model = model()

        model.scenePhaseChanged(.active)
        #expect(model.tabs.canConnect)
        model.lockChanged(isLocked: true)
        #expect(!model.tabs.canConnect)
        model.lockChanged(isLocked: false)
        model.scenePhaseChanged(.inactive)
        #expect(!model.tabs.canConnect)
        model.scenePhaseChanged(.active)
        #expect(model.tabs.canConnect)
    }

    /// The connections stay for the background time iOS grants, less five seconds for their clean
    /// close, and at most 25 seconds.
    @Test(arguments: [(30.0, 25.0), (20.0, 15.0), (3.0, 0.0), (Double.greatestFiniteMagnitude, 25.0), (.infinity, 25)])
    func connectionsCloseBeforeTheBackgroundTimeRunsOut(remaining: Double, closesAfter seconds: Double) {
        #expect(TerminalTabsModel.closeDelay(remaining: remaining) == .seconds(seconds))
    }

    @Test(arguments: [
        (Duration.milliseconds(24), "24 ms"), (.microseconds(1_400), "1 ms"), (.microseconds(100), "1 ms"),
    ])
    func latencyIsShownInMilliseconds(latency: Duration, shown: String) {
        #expect(latency.latencyText == shown)
    }

    private func model() -> TerminalTabsModel {
        TerminalTabsModel(
            connector: HostConnector(hostKeys: test.hostKeys, secrets: secrets.store), hosts: test.repository,
            settings: nil)
    }

    /// A password host on a port of this device that nothing listens on.
    static let host = Host(name: "nas", address: "127.0.0.1", port: 9, username: "admin", authMethod: .password)
}

/// VoiceOver reads a fingerprint in groups of four characters, each spelled out with its
/// punctuation, to compare with what the server's administrator reads out.
@Test func fingerprintIsSpokenFourCharactersAtATime() {
    let key = HostKey(
        algorithm: "ssh-ed25519", wireRepresentation: Data([1]),
        fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")

    let spoken = key.spokenFingerprint

    #expect(
        String(spoken.characters)
            == "SHA-256, lgFe, mmff, oQcp, nsIr, UqaS, gDH/, p2JS, kANq, Ab3Q, m8/a, vRY")
    let spelled = spoken.runs.filter { $0.accessibilitySpeechSpellsOutCharacters == true }
    #expect(
        spelled.map { String(spoken[$0.range].characters) }.joined() == "lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")
}
