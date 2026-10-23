import Foundation
import ShelloModel
import Testing

@testable import ShelloFeatures

struct HostDraftTests {
    @Test func newDraftHasTheDefaultsOfANewHost() {
        let draft = HostDraft.new

        #expect(draft.protocol == .ssh)
        #expect(draft.port == "22")
        #expect(draft.authMethod == .sshKey)
        #expect(draft.terminalType == "xterm-256color")
        #expect(draft.keepaliveInterval == .seconds(30))
        #expect(draft.connectTimeout == .seconds(15))
        #expect(!draft.isFavorite)
    }

    @Test func draftOfAHostHoldsItsValues() {
        let host = Host(
            name: "nas", address: "nas.lan", port: 2222, username: "admin", notes: "Rack 2", tmuxAutoAttach: true,
            tmuxSessionName: "work")

        let draft = HostDraft(host)

        #expect(draft.name == "nas")
        #expect(draft.address == "nas.lan")
        #expect(draft.port == "2222")
        #expect(draft.username == "admin")
        #expect(draft.notes == "Rack 2")
        #expect(draft.tmuxAutoAttach)
        #expect(draft.tmuxSessionName == "work")
    }

    @Test func newDraftNeedsANameAndAnAddress() {
        let problems = HostDraft.new.problems

        #expect(problems == [.name: "Enter a name.", .address: "Enter an address."])
    }

    @Test func blankTextCountsAsEmpty() {
        var draft = filledDraft()
        draft.name = "  "
        draft.address = "\t"

        #expect(draft.problems == [.name: "Enter a name.", .address: "Enter an address."])
    }

    @Test(arguments: ["1", "22", "65535", " 2222 "])
    func portFrom1To65535IsFine(_ port: String) {
        var draft = filledDraft()
        draft.port = port

        #expect(draft.problems.isEmpty)
    }

    @Test(arguments: ["0", "65536", "-22", "+22", "22a", "2 2", "１２", "99999999999999999999"])
    func portOutsideTheRangeOrNotANumberIsAProblem(_ port: String) {
        var draft = filledDraft()
        draft.port = port

        #expect(draft.problems == [.port: "Enter a port from 1 to 65535."])
    }

    @Test func emptyPortIsAProblem() {
        var draft = filledDraft()
        draft.port = ""

        #expect(draft.problems == [.port: "Enter a port."])
    }

    @Test(arguments: ["nas lan", "10.0.4.256", "nas.lan:22", "ssh://nas.lan"])
    func addressThatIsNoHostnameOrIPAddressIsAProblem(_ address: String) {
        var draft = filledDraft()
        draft.address = address

        #expect(draft.problems == [.address: "Enter a hostname, an IPv4 address or an IPv6 address."])
    }

    @Test func addressWithAUserPointsToTheUserField() {
        var draft = filledDraft()
        draft.address = "deploy@nas.lan"

        #expect(draft.problems == [.address: "Enter the user in the User field."])
    }

    @Test(arguments: [" nas.lan ", "10.0.4.21", "2001:db8::21", "fe80::1%en0"])
    func addressThatIsAHostnameOrIPAddressIsFine(_ address: String) {
        var draft = filledDraft()
        draft.address = address

        #expect(draft.problems.isEmpty)
    }

    @Test func terminalTypeIsRequired() {
        var draft = filledDraft()
        draft.terminalType = " "

        #expect(draft.problems == [.terminalType: "Enter a terminal type, such as xterm-256color."])
    }

    @Test func terminalTypeIsOneWord() {
        var draft = filledDraft()
        draft.terminalType = "xterm 256color"

        #expect(draft.problems == [.terminalType: "Enter the terminal type without spaces."])
    }

    // MARK: - tmux

    @Test func newDraftDoesNotAttachTmuxAndWouldAttachMain() {
        #expect(!HostDraft.new.tmuxAutoAttach)
        #expect(HostDraft.new.tmuxSessionName == "main")
    }

    @Test(arguments: ["main", "work", "deploy-1", "ops_2", " main "])
    func sessionNameOfLettersDigitsHyphensAndUnderscoresIsFine(_ name: String) {
        var draft = filledDraft()
        draft.tmuxAutoAttach = true
        draft.tmuxSessionName = name

        #expect(draft.problems.isEmpty)
    }

    @Test func attachingNeedsASessionName() {
        var draft = filledDraft()
        draft.tmuxAutoAttach = true
        draft.tmuxSessionName = " "

        #expect(draft.problems == [.tmuxSessionName: "Enter the tmux session’s name, such as main."])
    }

    @Test(arguments: ["my work", "-main", "web.1", "it's", "zürich", String(repeating: "a", count: 65)])
    func sessionNameThatAShellOrTmuxWouldReadMoreIntoIsAProblem(_ name: String) {
        var draft = filledDraft()
        draft.tmuxAutoAttach = true
        draft.tmuxSessionName = name

        #expect(
            draft.problems == [
                .tmuxSessionName: "Use up to 64 letters, digits, hyphens and underscores, not starting with a hyphen."
            ])
    }

    /// With auto-attach off the name is hidden and unused: it is no problem, and a name that would be
    /// one is not saved.
    @Test func sessionNameDoesNotMatterWithAutoAttachOff() {
        let base = Host(name: "nas", address: "nas.lan", username: "admin")
        var draft = HostDraft(base)
        draft.tmuxSessionName = "my work"

        #expect(draft.problems.isEmpty)
        #expect(draft.applied(to: base, comparedTo: HostDraft(base)).tmuxSessionName == "main")
    }

    @Test func savedHostAttachesTheSessionTheDraftNames() {
        let base = Host(name: "nas", address: "nas.lan", username: "admin")
        var draft = HostDraft(base)
        draft.tmuxAutoAttach = true
        draft.tmuxSessionName = " work "

        let host = draft.applied(to: base, comparedTo: HostDraft(base))

        #expect(host.tmuxAutoAttach)
        #expect(host.tmuxSessionName == "work")
    }

    @Test(arguments: [
        (HostProtocol.ssh, HostProtocol.vnc, "5900"),
        (.vnc, .mosh, "22"),
        (.ssh, .mosh, "22"),
    ])
    func switchingProtocolMovesADefaultPortToTheNewDefault(from old: HostProtocol, to new: HostProtocol, port: String) {
        var draft = HostDraft(Host(name: "media-pc", address: "10.0.0.40", protocol: old, username: "florian"))

        draft.protocol = new

        #expect(draft.port == port)
    }

    @Test func switchingProtocolKeepsAPortTheUserChose() {
        var draft = HostDraft(Host(name: "media-pc", address: "10.0.0.40", port: 2222, username: "florian"))

        draft.protocol = .vnc

        #expect(draft.port == "2222")
    }

    @Test func savedHostHasTheDraftsValuesWithoutSurroundingWhitespace() {
        var draft = HostDraft.new
        draft.name = " prod-api-02 "
        draft.address = " 10.0.4.22\n"
        draft.port = " 2222"
        draft.username = "deploy "
        draft.startupCommand = " tmux new -A -s main "
        draft.terminalType = "xterm "
        draft.notes = "Second API server.\n"
        let base = Host(name: "", address: "", username: "")

        let host = draft.applied(to: base, comparedTo: HostDraft(base))

        #expect(host.name == "prod-api-02")
        #expect(host.address == "10.0.4.22")
        #expect(host.port == 2222)
        #expect(host.username == "deploy")
        #expect(host.startupCommand == "tmux new -A -s main")
        #expect(host.terminalType == "xterm")
        #expect(host.notes == "Second API server.\n")
    }

    @Test func savedHostHasEveryFieldTheDraftChanged() {
        let group = HostGroup(name: "Homelab")
        let tag = Tag(name: "Staging", color: .purple)
        let base = Host(name: "nas", address: "nas.lan", username: "admin")
        var draft = HostDraft(base)
        draft.protocol = .mosh
        draft.authMethod = .keyboardInteractive
        draft.groupID = group.id
        draft.tagIDs = [tag.id]
        draft.keepaliveInterval = .seconds(45)
        draft.connectTimeout = .seconds(20)
        draft.isFavorite = true

        let host = draft.applied(to: base, comparedTo: HostDraft(base))

        #expect(host.protocol == .mosh)
        #expect(host.authMethod == .keyboardInteractive)
        #expect(host.groupID == group.id)
        #expect(host.tagIDs == [tag.id])
        #expect(host.keepaliveInterval == .seconds(45))
        #expect(host.connectTimeout == .seconds(20))
        #expect(host.isFavorite)
    }

    /// The editor writes what the user changed onto the host as it is stored now, so that saving
    /// never undoes a change made since the editor opened.
    @Test func savedHostKeepsChangesMadeSinceTheDraftWasTaken() {
        let opened = Host(name: "nas", address: "nas.lan", username: "admin")
        var draft = HostDraft(opened)
        draft.name = "nas-2"
        var latest = opened
        latest.isFavorite = true
        latest.lastConnectedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        latest.sshKeyID = UUID()

        let host = draft.applied(to: latest, comparedTo: HostDraft(opened))

        #expect(host.name == "nas-2")
        #expect(host.isFavorite)
        #expect(host.lastConnectedAt == latest.lastConnectedAt)
        #expect(host.sshKeyID == latest.sshKeyID)
    }

    /// A draft with every required field filled in and nothing wrong.
    private func filledDraft() -> HostDraft {
        var draft = HostDraft.new
        draft.name = "nas"
        draft.address = "nas.lan"
        return draft
    }
}
