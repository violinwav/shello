import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// The algorithm policy that ships with the app (README sections 4 and 14): post-quantum key
/// exchanges first, then curve25519-sha256 and the classical ones without SHA-1; chacha20-poly1305,
/// AES-GCM and AES-CTR; HMAC-SHA2 encrypt-then-MAC; no SHA-1, CBC or DSA. As data that libssh can
/// apply whole, with a host's own lists in place of the policy's.
@Suite struct AlgorithmPolicyTests {
    @Test func standardPolicyOffersPostQuantumKeyExchangesFirstThenClassicalOnes() {
        let policy = AlgorithmPolicy.standard

        #expect(policy.version == 2)
        #expect(
            policy.keyExchanges == [
                "mlkem768x25519-sha256", "sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com",
                "curve25519-sha256", "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
                "diffie-hellman-group16-sha512", "diffie-hellman-group18-sha512", "diffie-hellman-group14-sha256",
            ])
    }

    @Test func standardPolicyOffersAEADCiphersFirstAndEncryptThenMACs() {
        let policy = AlgorithmPolicy.standard

        #expect(
            policy.ciphers == [
                "chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr",
                "aes192-ctr", "aes128-ctr",
            ])
        #expect(policy.macs == ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com"])
    }

    /// Ed25519, ECDSA, then RSA with SHA-2, for host keys and SSH keys alike.
    @Test func standardPolicyOffersEd25519ECDSAAndRSAWithSHA2Keys() {
        let keys = [
            "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "rsa-sha2-512",
            "rsa-sha2-256",
        ]

        #expect(AlgorithmPolicy.standard.hostKeyAlgorithms == keys)
        #expect(AlgorithmPolicy.standard.sshKeyAlgorithms == keys)
    }

    /// SHA-1, CBC ciphers and DSA are off (README section 4): no list names one. `ssh-rsa` is an RSA
    /// key signing with SHA-1.
    @Test func standardPolicyOffersNoSHA1CBCOrDSA() {
        let policy = AlgorithmPolicy.standard
        let offered =
            policy.keyExchanges + policy.ciphers + policy.macs + policy.hostKeyAlgorithms + policy.sshKeyAlgorithms

        for name in offered {
            #expect(!name.contains("sha1"), "\(name) uses SHA-1")
            #expect(!name.contains("cbc"), "\(name) is a CBC cipher")
            #expect(!name.contains("dss"), "\(name) is DSA")
            #expect(name != "ssh-rsa", "\(name) signs with SHA-1")
        }
    }

    /// libssh drops the names it does not know without a word (`ssh_options_set`), so a misspelt
    /// name would quietly leave an algorithm out.
    @Test func libsshKnowsEveryAlgorithmThePolicyNames() {
        let policy = AlgorithmPolicy.standard

        #expect(Set(policy.keyExchanges).union(policy.postQuantumKeyExchanges).subtracting(LibSSH.keyExchanges).isEmpty)
        #expect(Set(policy.ciphers).subtracting(LibSSH.ciphers).isEmpty)
        #expect(Set(policy.macs).subtracting(LibSSH.macs).isEmpty)
        #expect(Set(policy.hostKeyAlgorithms).subtracting(LibSSH.publicKeyAlgorithms).isEmpty)
        #expect(Set(policy.sshKeyAlgorithms).subtracting(LibSSH.publicKeyAlgorithms).isEmpty)
    }

    /// Both names of sntrup761x25519-sha512 are post-quantum, and so is every ML-KEM hybrid libssh
    /// has, offered or not.
    @Test(arguments: [
        "mlkem768x25519-sha256", "sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com",
        "mlkem768nistp256-sha256", "mlkem1024nistp384-sha384",
    ])
    func postQuantumKeyExchange(_ name: String) {
        #expect(AlgorithmPolicy.standard.keyExchange(named: name) == KeyExchange(name: name, isPostQuantum: true))
    }

    /// Anything the policy does not call post-quantum is classical, a name it never heard of too.
    @Test(arguments: ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256", "not-a-kex"])
    func classicalKeyExchange(_ name: String) {
        #expect(AlgorithmPolicy.standard.keyExchange(named: name) == KeyExchange(name: name, isPostQuantum: false))
    }

    @Test func policyReadsFromJSON() throws {
        let json = """
            {
              "version": 7,
              "keyExchanges": ["curve25519-sha256", "mlkem768x25519-sha256"],
              "ciphers": ["aes128-ctr"],
              "macs": ["hmac-sha2-512-etm@openssh.com"],
              "hostKeyAlgorithms": ["ecdsa-sha2-nistp256"],
              "sshKeyAlgorithms": ["ssh-ed25519"],
              "postQuantumKeyExchanges": ["mlkem768x25519-sha256"]
            }
            """

        let policy = try JSONDecoder().decode(AlgorithmPolicy.self, from: Data(json.utf8))

        #expect(
            policy
                == AlgorithmPolicy(
                    version: 7, keyExchanges: ["curve25519-sha256", "mlkem768x25519-sha256"], ciphers: ["aes128-ctr"],
                    macs: ["hmac-sha2-512-etm@openssh.com"], hostKeyAlgorithms: ["ecdsa-sha2-nistp256"],
                    sshKeyAlgorithms: ["ssh-ed25519"], postQuantumKeyExchanges: ["mlkem768x25519-sha256"]))
    }

    /// A connection with no key exchange, cipher, MAC or host key algorithm to offer could not
    /// connect anywhere, nor sign in without an SSH key algorithm.
    @Test(arguments: ["keyExchanges", "ciphers", "macs", "hostKeyAlgorithms", "sshKeyAlgorithms"])
    func policyWithAnEmptyListIsRefused(_ emptyList: String) {
        var lists = [
            "keyExchanges": #"["curve25519-sha256"]"#, "ciphers": #"["aes128-ctr"]"#,
            "macs": #"["hmac-sha2-256-etm@openssh.com"]"#, "hostKeyAlgorithms": #"["ssh-ed25519"]"#,
            "sshKeyAlgorithms": #"["ssh-ed25519"]"#,
        ]
        lists[emptyList] = "[]"
        let fields = lists.map { #""\#($0.key)": \#($0.value)"# }.joined(separator: ", ")
        let json = #"{"version": 1, \#(fields), "postQuantumKeyExchanges": []}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AlgorithmPolicy.self, from: Data(json.utf8))
        }
    }

    // MARK: - A host's own lists

    @Test func overridesReplaceTheListsTheyHave() {
        let standard = AlgorithmPolicy.standard
        let overrides = AlgorithmOverrides(keyExchanges: ["curve25519-sha256"], macs: ["hmac-sha2-512-etm@openssh.com"])

        let policy = standard.overridden(by: overrides)

        #expect(policy.keyExchanges == ["curve25519-sha256"])
        #expect(policy.macs == ["hmac-sha2-512-etm@openssh.com"])
        #expect(policy.ciphers == standard.ciphers)
        #expect(policy.hostKeyAlgorithms == standard.hostKeyAlgorithms)
        #expect(policy.sshKeyAlgorithms == standard.sshKeyAlgorithms)
        #expect(policy.postQuantumKeyExchanges == standard.postQuantumKeyExchanges)
        #expect(policy.version == standard.version)
    }

    /// An empty list would leave libssh nothing to offer: it keeps the policy's.
    @Test func emptyOverridesKeepThePolicy() {
        let overrides = AlgorithmOverrides(
            keyExchanges: [], ciphers: [], macs: [], hostKeyAlgorithms: [], sshKeyAlgorithms: [])

        #expect(AlgorithmPolicy.standard.overridden(by: overrides) == .standard)
        #expect(AlgorithmPolicy.standard.overridden(by: .none) == .standard)
    }

    // MARK: - The trusted host key's type first

    /// A server trusted with its ECDSA key is asked for that key first, ahead of Ed25519.
    @Test func trustedECDSAKeyGoesFirst() {
        let policy = AlgorithmPolicy.standard.preferringAlgorithms(of: Self.hostKey("ecdsa-sha2-nistp384"))

        #expect(
            policy.hostKeyAlgorithms == [
                "ecdsa-sha2-nistp384", "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521", "rsa-sha2-512",
                "rsa-sha2-256",
            ])
    }

    /// An RSA key (`ssh-rsa`) signs with SHA-2: both of its algorithms go first, in the policy's
    /// order, and SHA-1 stays off.
    @Test func trustedRSAKeyGoesFirstWithSHA2() {
        let policy = AlgorithmPolicy.standard.preferringAlgorithms(of: Self.hostKey("ssh-rsa"))

        #expect(
            policy.hostKeyAlgorithms == [
                "rsa-sha2-512", "rsa-sha2-256", "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                "ecdsa-sha2-nistp521",
            ])
    }

    /// Ed25519 is first already, and a type the policy does not offer changes nothing.
    @Test(arguments: ["ssh-ed25519", "ssh-dss"])
    func otherTrustedKeysLeaveTheOrder(_ type: String) {
        #expect(AlgorithmPolicy.standard.preferringAlgorithms(of: Self.hostKey(type)) == .standard)
    }

    /// Only the host key algorithms move.
    @Test func preferringATrustedKeyKeepsTheOtherLists() {
        let standard = AlgorithmPolicy.standard

        let policy = standard.preferringAlgorithms(of: Self.hostKey("ssh-rsa"))

        #expect(policy.keyExchanges == standard.keyExchanges)
        #expect(policy.ciphers == standard.ciphers)
        #expect(policy.macs == standard.macs)
        #expect(policy.sshKeyAlgorithms == standard.sshKeyAlgorithms)
        #expect(policy.version == standard.version)
    }

    private static func hostKey(_ algorithm: String) -> HostKey {
        HostKey(algorithm: algorithm, wireRepresentation: Data(), fingerprint: "SHA256:")
    }
}
