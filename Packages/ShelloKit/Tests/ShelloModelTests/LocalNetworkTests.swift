import Testing

@testable import ShelloModel

/// Which servers Shello takes to be on the local network, and explains iOS's Local Network question
/// for before connecting to one (README section 3, TN3179). A guess from the address alone, which
/// errs towards local.
struct LocalNetworkTests {
    @Test(arguments: [
        "10.0.4.21", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.12.7", "224.0.0.251",
        "255.255.255.255", "fe80::1", "FE80::1%en0", "fd12:3456:789a::1", "fc00::5", "ff02::fb",
        "::ffff:192.168.1.20", "nas.local", "printer.local.", "nas.lan", "router.home", "nas.home.arpa",
        "build.internal", "pi.localdomain", "nas",
    ])
    func localAddress(_ address: String) {
        #expect(Server(address: address, port: 22).isOnLocalNetwork)
    }

    /// Public addresses, the loopback, which is no network at all, and what is not an address.
    @Test(arguments: [
        "8.8.8.8", "172.32.0.1", "172.15.255.255", "100.64.0.1", "192.169.0.1", "2001:db8::1", "::1",
        "127.0.0.1", "localhost", "my.localhost", "::ffff:8.8.8.8", "example.com", "prod-api-01.example.com",
        "server.local.example.com", "not an address",
    ])
    func addressThatIsNotLocal(_ address: String) {
        #expect(!Server(address: address, port: 22).isOnLocalNetwork)
    }
}
