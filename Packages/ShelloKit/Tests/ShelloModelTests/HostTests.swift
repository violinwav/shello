import Foundation
import Testing

@testable import ShelloModel

@Test func newHostIsAnSSHHostOnPort22WithXterm256color() {
    let host = Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy")

    #expect(host.protocol == .ssh)
    #expect(host.port == 22)
    #expect(host.terminalType == "xterm-256color")
}

@Test func newHostSignsInWithAnSSHKeyAndHasNoGroupTagsOrHistory() {
    let host = Host(name: "nas", address: "nas.lan", username: "admin")

    #expect(host.authMethod == .sshKey)
    #expect(host.sshKeyID == nil)
    #expect(host.groupID == nil)
    #expect(host.tagIDs.isEmpty)
    #expect(host.notes.isEmpty)
    #expect(host.startupCommand.isEmpty)
    #expect(!host.isFavorite)
    #expect(host.lastConnectedAt == nil)
}

@Test func newHostKeepsAliveEvery30SecondsAndGivesUpConnectingAfter15() {
    let host = Host(name: "nas", address: "nas.lan", username: "admin")

    #expect(host.keepaliveInterval == .seconds(30))
    #expect(host.connectTimeout == .seconds(15))
}

// Mosh starts over SSH, so a Mosh host's port is its SSH port.
@Test(arguments: [(HostProtocol.ssh, UInt16(22)), (.mosh, 22), (.vnc, 5900)])
func newHostUsesTheProtocolsDefaultPort(_ hostProtocol: HostProtocol, port: UInt16) {
    let host = Host(name: "media-pc", address: "10.0.0.40", protocol: hostProtocol, username: "florian")

    #expect(host.port == port)
}

@Test func explicitPortWinsOverTheProtocolsDefault() {
    let host = Host(name: "media-pc", address: "10.0.0.40", port: 5901, protocol: .vnc, username: "florian")

    #expect(host.port == 5901)
}
