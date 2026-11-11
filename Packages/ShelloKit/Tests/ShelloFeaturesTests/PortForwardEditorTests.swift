import Foundation
import ShelloCore
import ShelloModel
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// The host editor's port forwards (README section 4): a forward's draft and its problems, the
/// host's problem when two forwards that are on share a port or one is not complete, and saving
/// them with the host; and how the editor and the Connection sheet name a forward and its state.
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
                .localPort: "Enter the port to listen on.",
                .destinationAddress: "Enter the address the server connects to, such as localhost.",
                .destinationPort: "Enter the port the server connects to.",
            ])
        #expect(draft.forward == nil)
    }

    @Test func completeLocalForwardIsTheForwardWithoutSurroundingWhitespace() {
        var draft = PortForwardDraft.new
        draft.localPort = " 8080 "
        draft.destinationAddress = " db.internal "
        draft.destinationPort = "5432"
        draft.name = " Database "

        #expect(draft.problems.isEmpty)
        #expect(
            draft.forward
                == PortForward(
                    id: draft.id, name: "Database", localPort: 8080,
                    kind: .local(destination: ForwardDestination(address: "db.internal", port: 5432))))
    }

    /// An IPv6 address may be written in brackets, as beside a port; the brackets go.
    @Test func ipv6DestinationMayBeWrittenInBrackets() {
        var draft = PortForwardDraft.new
        draft.localPort = "8080"
        draft.destinationAddress = "[fd00::5]"
        draft.destinationPort = "80"

        #expect(draft.forward?.destination == ForwardDestination(address: "fd00::5", port: 80))
    }

    @Test(arguments: ["0", "65536", "-1", "80a", "１２"])
    func portOutsideTheRangeOrNotANumberIsAProblem(_ port: String) {
        var draft = Self.localDraft()
        draft.localPort = port
        draft.destinationPort = port

        #expect(draft.problems[.localPort] == "Enter a port from 1 to 65535.")
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
        draft.localPort = "1080"

        #expect(draft.problems.isEmpty)
        #expect(draft.forward?.kind == .dynamic)
        draft.kind = .local
        #expect(draft.forward == nil)
    }

    @Test func draftOfAForwardHoldsItsValues() {
        let forward = PortForward(
            name: "Web", localPort: 8080, kind: .local(destination: ForwardDestination(address: "localhost", port: 80)),
            isEnabled: false)

        let draft = PortForwardDraft(forward)

        #expect(draft.forward == forward)
        #expect(draft.localPort == "8080")
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
        dynamic.localPort = "1080"
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
            localPort: 8080, kind: .local(destination: ForwardDestination(address: "fd00::5", port: 80)))
        let dynamic = PortForward(localPort: 1080, kind: .dynamic)

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

    @Test func eachStateIsSaid() {
        #expect(PortForwardDisplay.state(.listening(port: 8080, problem: nil)) == "Listening on 127.0.0.1:8080")
        #expect(
            PortForwardDisplay.spokenState(.listening(port: 8080, problem: nil)) == "Listening on 127.0.0.1, port 8080")
        #expect(
            PortForwardDisplay.state(.failed("Port 8080 is in use by another tab or app."))
                == "Not listening. Port 8080 is in use by another tab or app.")
        #expect(PortForwardDisplay.state(.off) == "Off")
        #expect(PortForwardDisplay.state(.waiting) == "Listens once the tab is connected")
        #expect(PortForwardDisplay.state(.starting) == "Starting…")
    }

    // MARK: - Helpers

    private static func hostDraft() -> HostDraft {
        var draft = HostDraft.new
        draft.name = "db-proxy"
        draft.address = "db.example.com"
        return draft
    }

    private static func localDraft(port: String = "8080") -> PortForwardDraft {
        var draft = PortForwardDraft.new
        draft.localPort = port
        draft.destinationAddress = "localhost"
        draft.destinationPort = "5432"
        return draft
    }
}
