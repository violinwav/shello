import Foundation
import KeyFixtures
import Testing

@testable import ShelloSSH

/// What a private key's text says before libssh reads it (KeyText.swift), and the private key in
/// libssh's PKCS #8 (PKCS8.swift): the formats of the fixtures, and that neither traps on anything
/// it is given. Fuzz/KeyText runs the same robustness checks with libFuzzer.
struct KeyTextTests {
    @Test(arguments: KeyFixture.variants)
    func tellsEachFixturesFormat(_ variant: KeyFixture.Variant) {
        let text = KeyText(Array(variant.text.utf8))

        #expect(text.isEncrypted == variant.isEncrypted)
        switch (variant.format, text) {
        case (.openSSH, .openSSH(_, let publicKey)):
            #expect(publicKey.type == variant.key.publicKeyLine.split(separator: " ")[0])
            #expect(publicKey.rsaBits == (variant.key == .rsa3072 ? 3072 : nil))
        case (.pem, .pem(let algorithm, _)):
            #expect(algorithm == (variant.key == .rsa3072 ? .rsa : .ec))
        case (.pkcs8, .pkcs8):
            break
        default:
            Issue.record("\(variant) reads as \(text)")
        }
    }

    @Test func tellsTheKeysShelloRefuses() {
        #expect(KeyText(Array(KeyFixture.text("dsa-pem").utf8)) == .pem(.dsa, isEncrypted: false))
        guard case .openSSH(false, let dsa) = KeyText(Array(KeyFixture.text("dsa-openssh").utf8)) else {
            Issue.record("The DSA key is not in OpenSSH's format")
            return
        }
        #expect(dsa.type == "ssh-dss")
        guard case .openSSH(false, let rsa) = KeyText(Array(KeyFixture.text("rsa-1024-openssh").utf8)) else {
            Issue.record("The RSA key is not in OpenSSH's format")
            return
        }
        #expect(rsa.rsaBits == 1024)
        #expect(KeyText(Array(KeyFixture.text("ed25519.pub").utf8)) == .publicKey)
        #expect(KeyText(Array("PuTTY-User-Key-File-2: ssh-rsa\n".utf8)) == .putty)
        #expect(KeyText(Array("ssh-ed25519 is a key type".utf8)) == .unknown)
        #expect(KeyText([UInt8]()) == .unknown)
    }

    /// The header of an encrypted OpenSSH key names its cipher and the bcrypt that makes the key.
    @Test func readsTheOpenSSHHeader() throws {
        let text = Array(KeyFixture.text("ed25519-openssh-encrypted").utf8)
        let armor = try #require(PEMArmor(text))
        let header = try #require(OpenSSHKeyHeader(base64: text[armor.body]))

        #expect(armor.label == "OPENSSH PRIVATE KEY")
        #expect(header.cipher == "aes256-ctr")
        #expect(header.kdf == "bcrypt")
        #expect(header.publicKey == PublicKeySummary(wireRepresentation: Self.publicKey(.ed25519)))
    }

    @Test func base64DecodesAsFarAsItIsRead() {
        var decoder = Base64Decoder(Array("aGVs\nbG8g d29y bGQ=".utf8).makeIterator())
        let decoded = Array(AnyIterator { decoder.next() })
        #expect(String(decoding: decoded, as: UTF8.self) == "hello world")
        #expect(!decoder.isInvalid)

        var invalid = Base64Decoder(Array("aGVs*bG8=".utf8).makeIterator())
        #expect(Array(AnyIterator { invalid.next() }) == Array("hel".utf8))
        #expect(invalid.isInvalid)

        // Only what is read is decoded: two of the twelve characters' nine bytes.
        var partial = Base64Decoder(Array("aGVsbG8gd29y".utf8).makeIterator())
        #expect([partial.next(), partial.next()] == [104, 101])
    }

    /// The private key of each PKCS #8 fixture, found where it lies.
    @Test(arguments: KeyFixture.Key.allCases)
    func findsThePrivateKeyInPKCS8(_ key: KeyFixture.Key) throws {
        let text = Array(KeyFixture.text("\(key.rawValue)-pkcs8").utf8)
        let armor = try #require(PEMArmor(text))
        var decoder = Base64Decoder(text[armor.body].makeIterator())
        let der = Array(AnyIterator { decoder.next() })

        let pkcs8 = try PKCS8PrivateKey(der: der)

        switch key {
        case .ed25519:
            #expect(pkcs8.algorithm == .ed25519)
            #expect(pkcs8.privateKey.count == 32)
        case .ecdsaP256, .ecdsaP384:
            #expect(pkcs8.algorithm == .ec)
            #expect(pkcs8.privateKey.count == (key == .ecdsaP256 ? 32 : 48))
        case .rsa3072:
            #expect(pkcs8.algorithm == .rsa)
            #expect(der[pkcs8.privateKey.lowerBound] == 0x30)
        }
        #expect(pkcs8.privateKey.upperBound <= der.count)
    }

    @Test(
        arguments: [
            [], [0x30], [0x30, 0x80], [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF], [0x30, 0x03, 0x02, 0x01, 0x00],
            [0x30, 0x05, 0x02, 0x01, 0x07, 0x30, 0x00], [0x04, 0x00],
        ] as [[UInt8]])
    func malformedDERIsRefused(_ der: [UInt8]) {
        #expect(throws: DERError.self) { try PKCS8PrivateKey(der: der) }
    }

    /// Random bytes, and the fixtures with bytes changed, cut short or repeated, never trap any of
    /// the readers, and whatever they find lies within what they were given. Seeded, so that a
    /// failure repeats.
    @Test func randomTextNeverTraps() {
        var random = SeededRandom(seed: 30)
        let fixtures =
            KeyFixture.variants.map { Array($0.text.utf8) }
            + ["dsa-openssh", "rsa-1024-pem", "ed25519.pub"].map { Array(KeyFixture.text($0).utf8) }
        for round in 0..<3000 {
            var bytes: [UInt8]
            if round % 3 == 0 {
                bytes = (0..<Int.random(in: 0..<300, using: &random)).map { _ in
                    UInt8.random(in: 0...255, using: &random)
                }
            } else {
                bytes = fixtures[Int.random(in: 0..<fixtures.count, using: &random)]
                for _ in 0..<Int.random(in: 1...8, using: &random) where !bytes.isEmpty {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<3, using: &random) {
                    case 0: bytes[index] = UInt8.random(in: 0...255, using: &random)
                    case 1: bytes.removeSubrange(index...)
                    default:
                        let repeated = Array(bytes[index...].prefix(16))
                        bytes.insert(contentsOf: repeated, at: index)
                    }
                }
            }
            _ = KeyText(bytes)
            if let armor = PEMArmor(bytes) {
                #expect(armor.body.upperBound <= bytes.count)
                _ = OpenSSHKeyHeader(base64: bytes[armor.body])
            }
            if let pkcs8 = try? PKCS8PrivateKey(der: bytes) {
                #expect(pkcs8.privateKey.upperBound <= bytes.count)
            }
        }
    }

    private static func publicKey(_ key: KeyFixture.Key) -> [UInt8] {
        Array(Data(base64Encoded: String(key.publicKeyLine.split(separator: " ")[1])) ?? Data())
    }
}

/// A generator of numbers that start from a seed, SplitMix64's, so that a test of random input runs
/// the same each time.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
