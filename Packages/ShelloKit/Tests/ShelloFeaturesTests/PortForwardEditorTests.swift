import Foundation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// The host editor's port forwards (README section 4): a forward's draft and its problems, a remote
/// forward's too, the host's problem when two forwards that are on share a port on the same side or
/// one is not complete, and saving them with the host; how the editor and the Connection sheet name a
/// forward and its state; and the Local Network explanation that a remote forward's destination on
/// the local network brings (README section 3).
@Suite(.timeLimit(.minutes(1)))
struct PortForwardEditorTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    // MARK: - A forward's draft

    @Test func newForwardIsALocalOneThatIsOnWithItsFieldsEmpty() {
        let draft = PortForwardDraft.new

        #expect(draft.kind == .local)
        #expect(draft.isEnabled)
        #expect(
            draft.problems == [
                .port: "Enter the port to listen on.",
                .destinationAddress: "Enter the address the server connects to, such as localhost.",
                .destinationPort: "Enter the port the server connects to.",
            ])
        #expect(draft.forward == nil)
    }

    @Test func completeLocalForwardIsTheForwardWithoutSurroundingWhitespace() {
        var draft = PortForwardDraft.new
        draft.port = " 8080 "
        draft.destinationAddress = " db.internal "
        draft.destinationPort = "5432"
        draft.name = " Database "

        #expect(draft.problems.isEmpty)
        #expect(
            draft.forward
                == PortForward(
                    id: draft.id, name: "Database", port: 8080,
                    kind: .local(destination: ForwardDestination(address: "db.internal", port: 5432))))
    }

    /// An IPv6 address may be written in brackets, as beside a port; the brackets go.
    @Test func ipv6DestinationMayBeWrittenInBrackets() {
        var draft = PortForwardDraft.new
        draft.port = "8080"
        draft.destinationAddress = "[fd00::5]"
        draft.destinationPort = "80"

        #expect(draft.forward?.destination == ForwardDestination(address: "fd00::5", port: 80))
    }

    @Test(arguments: ["0", "65536", "-1", "80a", "１２"])
    func portOutsideTheRangeOrNotANumberIsAProblem(_ port: String) {
        var draft = Self.localDraft()
        draft.port = port
        draft.destinationPort = port

        #expect(draft.problems[.port] == "Enter a port from 1 to 65535.")
        #expect(draft.problems[.destinationPort] == "Enter a port from 1 to 65535.")
    }

    @Test(arguments: ["db internal", "10.0.0.256", "db.internal:5432", "user@db"])
    func destinationThatIsNoAddressIsAProblem(_ address: String) {
        var draft = Self.localDraft()
        draft.destinationAddress = address

        #expect(draft.problems == [.destinationAddress: "Enter a hostname, an IPv4 address or an IPv6 address."])
    }

    /// A dynamic forward has no destination: what was typed for one stays, for a switch back, and
    /// counts for nothing.
    @Test func dynamicForwardNeedsOnlyItsPort() {
        var draft = PortForwardDraft.new
        draft.kind = .dynamic
        draft.port = "1080"

        #expect(draft.problems.isEmpty)
        #expect(draft.forward?.kind == .dynamic)
        draft.kind = .local
        #expect(draft.forward == nil)
    }

    /// A remote forward has the server listen on its port, on its loopback unless the bind address
    /// says otherwise, and goes to a destination as this device reaches it.
    @Test func completeRemoteForwardIsTheForward() {
        var draft = PortForwardDraft.new
        draft.kind = .remote

        #expect(
            draft.problems == [
                .port: "Enter the port the server listens on.",
                .destinationAddress: "Enter the address this device connects to, such as localhost.",
                .destinationPort: "Enter the port this device connects to.",
            ])
        draft.port = "8080"
        draft.destinationAddress = " 192.168.1.20 "
        draft.destinationPort = "3000"
        #expect(draft.problems.isEmpty)
        #expect(
            draft.forward
                == PortForward(
                    id: draft.id, port: 8080,
                    kind: .remote(bindAddress: "", destination: ForwardDestination(address: "192.168.1.20", port: 3000))
                ))
    }

    /// The bind address may be empty, for the server's loopback, `*` for all of its addresses, or
    /// an address, an IPv6 one also in brackets.
    @Test(arguments: [("", ""), ("*", "*"), (" 0.0.0.0 ", "0.0.0.0"), ("[::1]", "::1"), ("gateway.lan", "gateway.lan")])
    func bindAddressIsEmptyAStarOrAnAddress(_ typed: String, _ address: String) {
        var draft = Self.remoteDraft()
        draft.bindAddress = typed

        #expect(draft.problems.isEmpty)
        #expect(draft.forward?.bindAddress == address)
    }

    @Test(arguments: ["0.0.0.0 1", "**", "host:8080", "user@host"])
    func bindAddressThatIsNoAddressIsAProblem(_ typed: String) {
        var draft = Self.remoteDraft()
        draft.bindAddress = typed

        #expect(
            draft.problems == [
                .bindAddress:
                    "Enter a hostname, an IPv4 address, an IPv6 address or *, or leave it empty for the server’s loopback."
            ])
    }

    /// The bind address and the destination stay for a switch back, and count only for a remote
    /// forward.
    @Test func bindAddressCountsForARemoteForwardOnly() {
        var draft = Self.remoteDraft()
        draft.bindAddress = "not an address"
        draft.kind = .local

        #expect(draft.problems.isEmpty)
        #expect(draft.forward?.kind == .local(destination: ForwardDestination(address: "localhost", port: 3000)))
        draft.kind = .remote
        #expect(draft.forward == nil)
    }

    @Test func draftOfARemoteForwardHoldsItsValues() {
        let forward = PortForward(
            name: "Preview", port: 8080,
            kind: .remote(bindAddress: "*", destination: ForwardDestination(address: "localhost", port: 3000)))

        let draft = PortForwardDraft(forward)

        #expect(draft.kind == .remote)
        #expect(draft.bindAddress == "*")
        #expect(draft.destinationPort == "3000")
        #expect(draft.forward == forward)
    }

    @Test func draftOfAForwardHoldsItsValues() {
        let forward = PortForward(
            name: "Web", port: 8080, kind: .local(destination: ForwardDestination(address: "localhost", port: 80)),
            isEnabled: false)

        let draft = PortForwardDraft(forward)

        #expect(draft.forward == forward)
        #expect(draft.port == "8080")
        #expect(draft.destinationAddress == "localhost")
        #expect(!draft.isEnabled)
    }

    // MARK: - The host's forwards

    /// Two forwards that are on and listen on the same port keep the host from being saved; one of
    /// them turned off, they don't.
    @Test func twoForwardsThatAreOnOnOnePortAreAProblem() {
        var draft = Self.hostDraft()
        draft.portForwards = [Self.localDraft(port: "8080"), Self.localDraft(port: "8080")]

        #expect(
            draft.problems[.portForwards]
                == "Two port forwards that are on listen on port 8080. Turn one off, or change its port.")
        draft.portForwards[1].isEnabled = false
        #expect(draft.problems[.portForwards] == nil)
    }

    /// A local forward and a remote one on the same number listen on different machines; two remote
    /// ones that are on have the server listen on it twice, which only one of them could.
    @Test func remoteForwardsShareAPortWithEachOtherOnly() {
        var draft = Self.hostDraft()
        draft.portForwards = [Self.localDraft(port: "8080"), Self.remoteDraft(port: "8080")]

        #expect(draft.problems[.portForwards] == nil)
        draft.portForwards.append(Self.remoteDraft(port: "8080"))
        #expect(
            draft.problems[.portForwards]
                == "Two remote forwards that are on have the server listen on port 8080. Turn one off, or change its "
                + "port.")
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft = draft
        #expect(model.sharesPort(draft.portForwards[1]))
        #expect(!model.sharesPort(draft.portForwards[0]))
    }

    @Test func forwardThatIsNotCompleteIsAProblem() {
        var draft = Self.hostDraft()
        var incomplete = Self.localDraft()
        incomplete.destinationAddress = ""
        draft.portForwards = [incomplete]

        #expect(draft.problems[.portForwards] == "A port forward isn’t complete. Open it to finish it, or delete it.")
    }

    /// A VNC host shows no forwards, so they never keep it from being saved.
    @Test func forwardsOfAVNCHostAreNoProblem() {
        var draft = Self.hostDraft()
        draft.portForwards = [Self.localDraft(port: "8080"), Self.localDraft(port: "8080")]

        draft.protocol = .vnc

        #expect(draft.problems[.portForwards] == nil)
    }

    @Test func savedHostHasTheForwardsInTheirOrder() async throws {
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft = Self.hostDraft()
        let local = Self.localDraft(port: "15432")
        var dynamic = PortForwardDraft.new
        dynamic.kind = .dynamic
        dynamic.port = "1080"
        dynamic.isEnabled = false
        model.addPortForward(local)
        model.addPortForward(dynamic)

        #expect(await model.save())

        let saved = try #require(try await repository.hosts().first)
        #expect(saved.portForwards == [local.forward, dynamic.forward].compactMap(\.self))
        #expect(saved.portForwards.map(\.isEnabled) == [true, false])
    }

    /// Deleting a forward sends VoiceOver on to the next one, or else to Add Port Forward.
    @Test func deletingAForwardMovesVoiceOverToTheNextOne() {
        let model = HostEditorModel(repository: repository, host: nil)
        let (first, second) = (Self.localDraft(port: "1"), Self.localDraft(port: "2"))
        model.addPortForward(first)
        model.addPortForward(second)

        model.removePortForward(first.id)
        #expect(model.deletedPortForwardFocus == .row(second.id))
        model.removePortForward(second.id)
        #expect(model.deletedPortForwardFocus == .add)
        #expect(model.draft.portForwards.isEmpty)
    }

    @Test func forwardSharesAPortOnlyWithAnotherThatIsOn() {
        let model = HostEditorModel(repository: repository, host: nil)
        var other = Self.localDraft(port: "8080")
        model.addPortForward(other)
        let new = Self.localDraft(port: "8080")

        #expect(model.sharesPort(new))
        other.isEnabled = false
        model.updatePortForward(other)
        #expect(!model.sharesPort(new))
    }

    // MARK: - Names and states

    @Test func forwardIsNamedByItsNameOrElseWhereItGoes() {
        let local = PortForward(
            port: 8080, kind: .local(destination: ForwardDestination(address: "fd00::5", port: 80)))
        let dynamic = PortForward(port: 1080, kind: .dynamic)

        #expect(PortForwardDisplay.title(local) == "[fd00::5]:80")
        #expect(PortForwardDisplay.spokenTitle(local) == "fd00::5, port 80")
        #expect(PortForwardDisplay.summary(local) == "8080 → [fd00::5]:80")
        #expect(PortForwardDisplay.spokenSummary(local) == "Local forward, port 8080 to fd00::5, port 80")
        #expect(PortForwardDisplay.title(dynamic) == "SOCKS Proxy")
        #expect(PortForwardDisplay.summary(dynamic) == "SOCKS5 on 1080")
        var named = dynamic
        named.name = "Office"
        #expect(PortForwardDisplay.title(named) == "Office")
        #expect(PortForwardDisplay.spokenTitle(named) == "Office")
    }

    @Test func remoteForwardIsNamedByWhereItGoesAndSaysTheServersPort() {
        let remote = PortForward(
            port: 8080,
            kind: .remote(bindAddress: "", destination: ForwardDestination(address: "localhost", port: 3000)))
        var everywhere = remote
        everywhere.kind = .remote(bindAddress: "*", destination: ForwardDestination(address: "localhost", port: 3000))
        var onAddress = remote
        onAddress.kind = .remote(
            bindAddress: "fd00::1", destination: ForwardDestination(address: "localhost", port: 3000))

        #expect(PortForwardDisplay.title(remote) == "localhost:3000")
        #expect(PortForwardDisplay.summary(remote) == "Server port 8080 → localhost:3000")
        #expect(
            PortForwardDisplay.spokenSummary(remote) == "Remote forward, the server’s port 8080 to localhost, port 3000"
        )
        #expect(PortForwardDisplay.summary(everywhere) == "Server *:8080 → localhost:3000")
        #expect(
            PortForwardDisplay.spokenSummary(everywhere)
                == "Remote forward, the server’s port 8080 on all of the server’s addresses, to localhost, port 3000")
        #expect(PortForwardDisplay.summary(onAddress) == "Server [fd00::1]:8080 → localhost:3000")
    }

    @Test func eachStateIsSaid() {
        let local = PortForward(port: 8080, kind: .dynamic)
        let remote = PortForward(
            port: 8080,
            kind: .remote(bindAddress: "", destination: ForwardDestination(address: "localhost", port: 3000)))
        #expect(
            PortForwardDisplay.state(.listening(port: 8080, problem: nil), of: local) == "Listening on 127.0.0.1:8080")
        #expect(
            PortForwardDisplay.spokenState(.listening(port: 8080, problem: nil), of: local)
                == "Listening on 127.0.0.1, port 8080")
        #expect(
            PortForwardDisplay.state(.listening(port: 8080, problem: nil), of: remote)
                == "Listening on the server’s port 8080")
        #expect(
            PortForwardDisplay.spokenState(.listening(port: 8080, problem: nil), of: remote)
                == "Listening on the server’s port 8080")
        #expect(
            PortForwardDisplay.state(.failed("Port 8080 is in use by another tab or app."), of: local)
                == "Not listening. Port 8080 is in use by another tab or app.")
        #expect(
            PortForwardDisplay.state(.failed(ForwardListenError.serverRefused(8080).description), of: remote)
                == "Not listening. The server refused to listen on its port 8080. It may not allow remote forwards, "
                + "or the port may be in use or reserved.")
        #expect(PortForwardDisplay.state(.off, of: local) == "Off")
        #expect(PortForwardDisplay.state(.waiting, of: remote) == "Listens once the tab is connected")
        #expect(PortForwardDisplay.state(.starting, of: remote) == "Starting…")
    }

    /// The note under the forwards says where each kind listens, and for how long (README section 4).
    @Test func lifetimeNoteSaysWhereEachKindListens() {
        #expect(
            PortForwardDisplay.lifetimeNote(hasRemote: false, hasOnDevice: false).hasPrefix("Forwards listen on 127"))
        #expect(PortForwardDisplay.lifetimeNote(hasRemote: true, hasOnDevice: false).hasPrefix("Remote forwards"))
        let both = PortForwardDisplay.lifetimeNote(hasRemote: true, hasOnDevice: true)
        #expect(both.hasPrefix("Local and dynamic forwards listen on 127.0.0.1"))
        #expect(both.contains("GatewayPorts"))
    }

    // MARK: - Local Network

    /// A remote forward goes to its destination from this device, so one on the local network gets
    /// the Local Network explanation before the tab connects, also behind a jump host, where the
    /// host's own address never counts (README section 3). One that is off, or goes to the loopback
    /// or the internet, does not; nor does any once the user continued past the explanation.
    @Test @MainActor func remoteForwardToTheLocalNetworkIsExplainedFirst() throws {
        let suite = "PortForwardEditorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = LocalNetworkNotice(defaults: defaults)
        let toNAS = PortForward(
            port: 8080,
            kind: .remote(bindAddress: "", destination: ForwardDestination(address: "192.168.1.20", port: 80)))
        let toDevice = PortForward(
            port: 8081,
            kind: .remote(bindAddress: "", destination: ForwardDestination(address: "localhost", port: 3000)))
        let localToNAS = PortForward(
            port: 8082, kind: .local(destination: ForwardDestination(address: "192.168.1.20", port: 80)))
        var off = toNAS
        off.isEnabled = false
        let cloud = Host(name: "cloud", address: "203.0.113.10", username: "deploy")
        let bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump")

        func reason(_ forwards: [PortForward], jumpHosts: [Host] = []) throws -> LocalNetworkReason? {
            var host = cloud
            host.portForwards = forwards
            host.jumpHostIDs = jumpHosts.map(\.id)
            let route = try Route(to: host, hosts: Dictionary(uniqueKeysWithValues: jumpHosts.map { ($0.id, $0) }))
            #expect(notice.explainsBeforeConnecting(to: host) == (notice.reason(connectingAlong: route) != nil))
            return notice.reason(connectingAlong: route)
        }

        #expect(try reason([toDevice, toNAS]) == .remoteForward(toNAS))
        #expect(try reason([toNAS], jumpHosts: [bastion]) == .remoteForward(toNAS))
        #expect(try reason([toDevice, localToNAS, off]) == nil)
        #expect(try reason([]) == nil)
        // The route's first host comes first: Shello connects to it before any forward.
        var nas = Host(name: "nas", address: "nas.lan", username: "admin")
        nas.portForwards = [toNAS]
        #expect(notice.reason(connectingAlong: try Route(to: nas, hosts: [:])) == .server(nas))

        notice.markExplained()

        #expect(try reason([toNAS]) == nil)
    }

    // MARK: - Helpers

    private static func hostDraft() -> HostDraft {
        var draft = HostDraft.new
        draft.name = "db-proxy"
        draft.address = "db.example.com"
        return draft
    }

    private static func remoteDraft(port: String = "8080") -> PortForwardDraft {
        var draft = PortForwardDraft.new
        draft.kind = .remote
        draft.port = port
        draft.destinationAddress = "localhost"
        draft.destinationPort = "3000"
        return draft
    }

    private static func localDraft(port: String = "8080") -> PortForwardDraft {
        var draft = PortForwardDraft.new
        draft.port = port
        draft.destinationAddress = "localhost"
        draft.destinationPort = "5432"
        return draft
    }
}
