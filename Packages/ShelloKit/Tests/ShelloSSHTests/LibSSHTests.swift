import Testing

@testable import ShelloSSH

@Test func versionIsThePinnedReleaseOnOpenSSL() {
    #expect(LibSSH.version.hasPrefix("0.12.2/openssl"))
}

// The MVP's preferred key exchanges (docs/spec/STACK.md section 7.2).
@Test(arguments: ["mlkem768x25519-sha256", "sntrup761x25519-sha512", "curve25519-sha256"])
func supportsPreferredKeyExchange(_ name: String) {
    #expect(LibSSH.keyExchanges.contains(name))
}
