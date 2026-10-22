import Foundation
import ShelloCore
import ShelloModel
import ShelloSecurity
import ShelloTerminalUI
import Testing

@testable import ShelloFeatures

/// A host's terminal when it cannot connect: it says why, above the terminal. ConnectionTests in the
/// UI tests take it the whole way, against the test server.
@Suite(.timeLimit(.minutes(1)))
struct HostTerminalModelTests {
    let secrets = TestSecrets()
    let test: TestDatabase

    init() throws {
        test = try TestDatabase()
    }

    @Test func withoutAConnectorTheTerminalSaysItCannotConnect() async {
        let model = HostTerminalModel(host: Self.host, connector: nil, controller: TerminalController())

        model.start()

        await waitUntil { model.phase != .connecting }
        #expect(model.status == .failed("Shello can’t connect without its database."))
    }

    @Test func hostWithoutAPasswordSaysSo() async {
        let connector = HostConnector(hostKeys: test.hostKeys, secrets: secrets.store)
        let model = HostTerminalModel(host: Self.host, connector: connector, controller: TerminalController())

        model.start()

        await waitUntil { model.phase != .connecting }
        #expect(model.status == .failed(ConnectError.noPassword.description))
        #expect(model.trustQuestion == nil)
    }

    @Test func unreachableServerSaysSo() async throws {
        try secrets.store.store(Secret(utf8: "hunter2"), as: .password(of: Self.host.id))
        let connector = HostConnector(hostKeys: test.hostKeys, secrets: secrets.store)
        let model = HostTerminalModel(host: Self.host, connector: connector, controller: TerminalController())

        model.start()

        await waitUntil { model.phase != .connecting }
        #expect(model.status == .failed("The server can’t be reached: connection refused."))
    }

    @Test func closingBeforeTheConnectionWorksLeavesNothingOpen() async {
        let connector = HostConnector(hostKeys: test.hostKeys, secrets: secrets.store)
        let model = HostTerminalModel(host: Self.host, connector: connector, controller: TerminalController())
        model.start()

        model.close()

        #expect(model.controller.streamState == .detached)
        #expect(model.trustQuestion == nil)
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
