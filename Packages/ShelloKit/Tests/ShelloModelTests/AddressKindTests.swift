import Testing

@testable import ShelloModel

// A host's address is a hostname, an IPv4 address or an IPv6 address (README section 3).

@Test(arguments: [
    "nas",
    "nas.lan",
    "prod-api-01",
    "staging.internal",
    "Florians-MacBook.local",
    "localhost",
    "1password.com",
    "xn--bcher-kva.example",
    // Not a valid DNS name, but used for internal hosts, and the system resolver accepts it.
    "build_server.corp",
    // A fully qualified name with its root dot.
    "forge.lan.",
    String(repeating: "a", count: 63) + ".lan",
    nameOfLength(253),
    nameOfLength(253) + ".",
])
func hostnameIsAHostname(_ address: String) {
    #expect(AddressKind(of: address) == .hostname)
}

@Test(arguments: [
    "",
    " nas",
    "nas ",
    "nas lan",
    "deploy@nas.lan",
    "nas.lan:22",
    "-nas",
    "nas-",
    "nas..lan",
    ".nas",
    "nas/",
    "ssh://nas.lan",
    // Shello does not convert names to punycode, so a name must already be ASCII.
    "zürich.lan",
    String(repeating: "a", count: 64) + ".lan",
    nameOfLength(254),
])
func malformedHostnameIsNoAddress(_ address: String) {
    #expect(AddressKind(of: address) == nil)
}

/// A name of 63-character labels with `length` characters in all. DNS allows 253, not counting a
/// trailing dot.
private func nameOfLength(_ length: Int) -> String {
    let labels = Array(repeating: String(repeating: "a", count: 63), count: 3)
    return String(repeating: "b", count: length - 3 * 64) + "." + labels.joined(separator: ".")
}

@Test(arguments: ["10.0.4.21", "192.168.1.1", "0.0.0.0", "255.255.255.255"])
func dottedQuadIsAnIPv4Address(_ address: String) {
    #expect(AddressKind(of: address) == .ipv4)
}

/// Digits and dots are always read as an IPv4 address. Shorthands such as `10.1` and leading
/// zeros, which some resolvers read as octal, are refused rather than guessed.
@Test(arguments: ["256.1.1.1", "10.0.4", "10.0.4.21.5", "010.0.4.21", "10..4.21", "10.0.4.", "1234", "1.2.3.-4"])
func malformedIPv4AddressIsNoAddress(_ address: String) {
    #expect(AddressKind(of: address) == nil)
}

@Test(arguments: [
    "::",
    "::1",
    "1::",
    "2001:db8::21",
    "2001:DB8::A",
    "1:2:3:4:5:6:7:8",
    "1:2:3:4:5:6:7::",
    "::2:3:4:5:6:7:8",
    "::ffff:192.168.1.1",
    "1:2:3:4:5:6:10.0.4.21",
    // A link-local address with its zone, the interface to reach it through.
    "fe80::1%en0",
    "fe80::1%pdp_ip0",
])
func ipv6AddressIsAnIPv6Address(_ address: String) {
    #expect(AddressKind(of: address) == .ipv6)
}

@Test(arguments: [
    ":::",
    "1::2::3",
    "12345::",
    "g::1",
    ":1",
    "1:",
    "1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7:8:9",
    "1:2:3:4:5:6:7:8::",
    "1:2:3:4:5:6:7:10.0.4.21",
    "::10.0.4",
    "::ffff:256.1.1.1",
    "10.0.4.21::",
    "fe80::1%",
    "fe80::1%en 0",
    // Brackets belong around an address in a URL, not in the address field.
    "[2001:db8::21]",
])
func malformedIPv6AddressIsNoAddress(_ address: String) {
    #expect(AddressKind(of: address) == nil)
}
