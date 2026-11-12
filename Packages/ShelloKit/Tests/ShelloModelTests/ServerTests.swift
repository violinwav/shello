import Foundation
import Testing

@testable import ShelloModel

// Host names and IPv6 addresses ignore case, so a server is the same whichever case a host uses.
@Test func serverIgnoresTheCaseOfItsAddress() {
    let first = Host(name: "nas", address: "NAS.lan", port: 2222, username: "admin")
    let second = Host(name: "nas as root", address: "nas.LAN", port: 2222, username: "root")

    #expect(first.server == second.server)
    #expect(first.server.address == "nas.lan")
}

@Test func serversOnOtherPortsAreOtherServers() {
    #expect(Server(address: "nas.lan", port: 22) != Server(address: "nas.lan", port: 2222))
}

@Test func serverIsWrittenWithItsPortAndAnIPv6AddressInBrackets() {
    #expect(Server(address: "nas.lan", port: 22).description == "nas.lan:22")
    #expect(Server(address: "10.0.4.21", port: 2222).description == "10.0.4.21:2222")
    #expect(Server(address: "FE80::1", port: 22).description == "[fe80::1]:22")
}

@Test(arguments: [
    ("ssh-ed25519", "ED25519"), ("ecdsa-sha2-nistp256", "ECDSA"), ("ecdsa-sha2-nistp521", "ECDSA"),
    ("ssh-rsa", "RSA"), ("sk-ssh-ed25519@openssh.com", "ED25519-SK"), ("ssh-new", "SSH-NEW"),
])
func hostKeyTypeIsNamedAsSSHKeygenNamesIt(_ algorithm: String, typeName: String) {
    let key = HostKey(algorithm: algorithm, wireRepresentation: Data([1, 2, 3]), fingerprint: "SHA256:AQID")

    #expect(key.typeName == typeName)
}
