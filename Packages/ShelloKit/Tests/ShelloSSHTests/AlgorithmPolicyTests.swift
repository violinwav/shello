import Foundation
import Testing

@testable import ShelloSSH

/// The algorithm policy that ships with the app (README section 14): post-quantum key exchanges
/// first, then curve25519-sha256, as data that libssh can apply whole.
@Suite struct AlgorithmPolicyTests {
    @Test func standardPolicyOffersPostQuantumKeyExchangesFirst() {
        let policy = AlgorithmPolicy.standard

        #expect(policy.version == 1)
        #expect(
            policy.keyExchanges == [
                "mlkem768x25519-sha256", "sntrup761x25519-sha512", "sntrup761x25519-sha512@openssh.com",
                "curve25519-sha256",
            ])
    }

    /// libssh drops the names it does not know without a word (`ssh_options_set`), so a misspelt
    /// name would quietly leave an algorithm out.
    @Test func libsshKnowsEveryKeyExchangeThePolicyNames() {
        let policy = AlgorithmPolicy.standard
        let named = Set(policy.keyExchanges).union(policy.postQuantumKeyExchanges)

        #expect(named.subtracting(LibSSH.keyExchanges).isEmpty)
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
              "postQuantumKeyExchanges": ["mlkem768x25519-sha256"]
            }
            """

        let policy = try JSONDecoder().decode(AlgorithmPolicy.self, from: Data(json.utf8))

        #expect(
            policy
                == AlgorithmPolicy(
                    version: 7, keyExchanges: ["curve25519-sha256", "mlkem768x25519-sha256"],
                    postQuantumKeyExchanges: ["mlkem768x25519-sha256"]))
    }

    /// A connection with no key exchange to offer could not connect anywhere.
    @Test func policyWithoutKeyExchangesIsRefused() {
        let json = #"{"version": 1, "keyExchanges": [], "postQuantumKeyExchanges": []}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AlgorithmPolicy.self, from: Data(json.utf8))
        }
    }
}
