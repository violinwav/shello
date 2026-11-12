import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// OpenSSH's known_hosts as Shello imports trusted host keys from it (README section 3): plain names
/// and `[host]:port`, comma-separated lists, hashed names matched with libssh's HMAC-SHA1, markers
/// and wildcard names listed, key types Shello does not trust listed, and the keys read by libssh as
/// a connection reads them. `randomTextNeverTraps` is a short, seeded version of the fuzz target
/// Fuzz/KnownHosts.
///
/// The keys are test keys that `ssh-keygen` made for this file, and the hashed names are what
/// `ssh-keygen -H` wrote for `example.com` and `[code.example.com]:2222`.
struct KnownHostsTests {
    static let ed25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIJFtpzQWVpf+aJ97q0dxz0/UukN2CIziag3hJj7pN6xi"
    static let ed25519Fingerprint = "SHA256:cc4geCL78RRRMyLVr1qFiqetJOX6l3o6FcSFrPmirk8"
    static let p256 =
        "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJcVD/qqXVD8k/bD6p3DsW9/gEYXmgGiRVYo8Wny0WptZE5hFW0VAH4tDU"
        + "mab+IEPduH+gOLeo1UYdM2RRGvJzw="
    static let p256Fingerprint = "SHA256:+h2e0Ku0++D+Xxvx9kXQvoIc/gOnP+dupz7NuPPE04A"
    static let p384 =
        "AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBLSl8dl6f+M/T/Ou81D651xONlb3l3HRR8MrQeZWDvyG2yiqswEhLYUT0B"
        + "b/JHLlZDORGwVP0PMQ55tDDuMRFULjWm/kRYuUX7EENVzSKH9rzgwmJANNdZg4BXvO94rjAQ=="
    static let p384Fingerprint = "SHA256:u73UGoRg9Mbn5RJE5/2KVFNkPVCzBoy0HtYDXA+xVUU"
    static let rsa =
        "AAAAB3NzaC1yc2EAAAADAQABAAABAQC6yDIvlo3Hs4Q4lzeCfEm30cTTPUimNyYarmF3gmiRphYyTQhtjiPydYz73XpMTyPgAL6attJbcF6P"
        + "GUy7D9wvbI5Pk/5ABrhMyTCilCo89QzAzzVGJZDXImObVLYQsoiLvnyh90elbZbw1cgkTr0faMNIPxY1VdW1P68SEStI7AdlYNDqzfMgyzEp"
        + "DsppuuuHrGo0fdovoVNDTzUhQ/TBjC94axu0FoOR8gKqWwCTKUX8daaEXo5vzH1rGxXyale4XUsTWMnGr3iGO0KymSA0DuSbno1v9dF9Vpad9"
        + "u0VNPwIVoC/JgDZnPq+o1SSQmlwhSWKx+EINub0j/L9U3QV"
    static let rsaFingerprint = "SHA256:EJCZA7oxEksflbMG+XNNUWzzRE8w16GL94sgwFedmvQ"

    /// A known_hosts file as OpenSSH leaves it after a while: plain names, a comma list with an
    /// address, a non-default port, hashed names, a certificate authority, a revoked key, a wildcard,
    /// an old DSA key, a security key, a certificate's type, and comments.
    static let realWorld = """
        # Written by ssh.
        github.com,140.82.121.4 ssh-ed25519 \(ed25519)
        [nas.lan]:2222 ecdsa-sha2-nistp256 \(p256) the NAS
        |1|3UxmGYwopYVkXqT5fEFyxnSsMJI=|xQfSeaC8J+UDDeMPpuZ58ZzyVPs= ssh-ed25519 \(ed25519)
        |1|p+Ud5V73OBUq0pjA6rr9+PhWYsA=|L6EayKxRXPuifdzAAkKdB4Sz2yg= ecdsa-sha2-nistp256 \(p256)
        @cert-authority *.example.com ssh-ed25519 \(ed25519)
        @revoked old.example.com ssh-rsa \(rsa)
        *.internal,db.internal,!skip.internal ecdsa-sha2-nistp384 \(p384)

        legacy.example.com ssh-dss AAAAB3NzaC1kc3MAAACBAP1/U4EddRIpUt9KnC7s5Of2EbdSPO9EAMMeP4C2USZpRV1AIlH7WT2NWPq
        yubi.example.com sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIA==
        cert.example.com ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29t
        rsa.example.com ssh-rsa \(rsa)
        """

    // MARK: - The real-world file

    @Test func realWorldFileHasTheEntriesShelloCanImport() throws {
        let file = KnownHosts(Self.realWorld)

        #expect(file.entries.map(\.line) == [2, 3, 4, 5, 8, 13])
        #expect(
            file.entries[0].names == [.plain(host: "github.com", port: 22), .plain(host: "140.82.121.4", port: 22)])
        #expect(file.entries[0].keyType == "ssh-ed25519")
        #expect(file.entries[1].names == [.plain(host: "nas.lan", port: 2222)])
        #expect(file.entries[1].keyType == "ecdsa-sha2-nistp256")
        #expect(file.entries[1].keyBase64 == Self.p256)
        // The plain name of a line with a wildcard and a negation.
        #expect(file.entries[4].names == [.plain(host: "db.internal", port: 22)])
        #expect(file.entries[5].keyType == "ssh-rsa")
        guard case .hashed(let salt, let hash) = file.entries[2].names[0] else {
            Issue.record("Line 4's name is not hashed")
            return
        }
        #expect(salt == Array(try #require(Data(base64Encoded: "3UxmGYwopYVkXqT5fEFyxnSsMJI="))))
        #expect(hash == Array(try #require(Data(base64Encoded: "xQfSeaC8J+UDDeMPpuZ58ZzyVPs="))))
    }

    @Test func realWorldFileListsWhatShelloDoesNotImport() {
        let file = KnownHosts(Self.realWorld)

        #expect(
            file.skipped.map(\.line) == [6, 7, 8, 8, 10, 11, 12])
        #expect(
            file.skipped.map(\.reason) == [
                .marker("@cert-authority"), .marker("@revoked"), .wildcard, .negated,
                .unsupportedKeyType("ssh-dss"), .unsupportedKeyType("sk-ssh-ed25519@openssh.com"),
                .unsupportedKeyType("ssh-ed25519-cert-v01@openssh.com"),
            ])
        // A name is listed as itself; a line as itself.
        #expect(file.skipped[2].text == "*.internal")
        #expect(file.skipped[3].text == "!skip.internal")
        #expect(file.skipped[0].text.hasPrefix("@cert-authority *.example.com ssh-ed25519 "))
    }

    @Test func hashedNamesMatchTheirServersOnly() {
        let file = KnownHosts(Self.realWorld)
        let exampleCom = file.entries[2].names[0]
        let codeExample = file.entries[3].names[0]

        #expect(exampleCom.matches(host: "example.com", port: 22, hmacSHA1: KnownHostKeys.hmacSHA1))
        #expect(!exampleCom.matches(host: "example.org", port: 22, hmacSHA1: KnownHostKeys.hmacSHA1))
        #expect(!exampleCom.matches(host: "example.com", port: 2222, hmacSHA1: KnownHostKeys.hmacSHA1))
        #expect(codeExample.matches(host: "code.example.com", port: 2222, hmacSHA1: KnownHostKeys.hmacSHA1))
        #expect(!codeExample.matches(host: "code.example.com", port: 22, hmacSHA1: KnownHostKeys.hmacSHA1))
    }

    @Test func plainNamesMatchTheirServer() {
        let name = KnownHosts.Name.plain(host: "nas.lan", port: 2222)

        #expect(name.matches(host: "nas.lan", port: 2222) { _, _ in nil })
        #expect(!name.matches(host: "nas.lan", port: 22) { _, _ in nil })
        #expect(KnownHosts.Name.written(host: "nas.lan", port: 2222) == "[nas.lan]:2222")
        #expect(KnownHosts.Name.written(host: "nas.lan", port: 22) == "nas.lan")
    }

    // MARK: - Names

    @Test(arguments: [
        ("host", KnownHosts.Name.plain(host: "host", port: 22)),
        ("Host.Example.COM", .plain(host: "host.example.com", port: 22)),
        ("[host]:2222", .plain(host: "host", port: 2222)),
        ("[host]:22", .plain(host: "host", port: 22)),
        ("[fd00::1]:2222", .plain(host: "fd00::1", port: 2222)),
        ("fd00::1", .plain(host: "fd00::1", port: 22)),
        ("192.168.1.2", .plain(host: "192.168.1.2", port: 22)),
    ])
    func plainNamesAndPorts(_ written: String, _ name: KnownHosts.Name) {
        let file = KnownHosts("\(written) ssh-ed25519 \(Self.ed25519)")

        #expect(file.skipped.isEmpty)
        #expect(file.entries.first?.names == [name])
    }

    @Test(arguments: [
        ("*.example.com", KnownHosts.SkippedLine.Reason.wildcard), ("host?", .wildcard), ("[*.lan]:22", .wildcard),
        ("!host", .negated), ("[host]", .malformedName), ("[host]:0", .malformedName),
        ("[host]:65536", .malformedName), ("[host]2222", .malformedName), ("[]:22", .malformedName),
        ("|1|abc|def", .malformedName),
        ("|2|3UxmGYwopYVkXqT5fEFyxnSsMJI=|xQfSeaC8J+UDDeMPpuZ58ZzyVPs=", .malformedName),
        ("|1|3UxmGYwopYVkXqT5fEFyxnSsMJI=", .malformedName),
    ])
    func namesShelloDoesNotImportAreListed(_ written: String, _ reason: KnownHosts.SkippedLine.Reason) {
        let file = KnownHosts("\(written) ssh-ed25519 \(Self.ed25519)")

        #expect(file.entries.isEmpty)
        #expect(file.skipped == [.init(line: 1, text: written, reason: reason)])
    }

    @Test func commaListsKeepTheirImportableNames() {
        let file = KnownHosts("a,*.b,[c]:2200,!d,e ssh-ed25519 \(Self.ed25519)")

        #expect(
            file.entries.first?.names == [
                .plain(host: "a", port: 22), .plain(host: "c", port: 2200), .plain(host: "e", port: 22),
            ])
        #expect(file.skipped.map(\.text) == ["*.b", "!d"])
    }

    // MARK: - Lines and keys

    @Test(arguments: [
        ("host ssh-ed25519", KnownHosts.SkippedLine.Reason.malformed), ("host", .malformed),
        ("host ssh-ed25519 notbase64!", .malformedKey), ("host ssh-ed25519 AAAA", .malformedKey),
        // An ECDSA key under the Ed25519 type.
        ("host ssh-ed25519 \(p256)", .malformedKey),
        // The Ed25519 key cut short, and with a byte more.
        ("host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFtpzQWVpf+aJ97q0dxz0/UukN2CIziag3hJj7pN6x=", .malformedKey),
        ("host ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFtpzQWVpf+aJ97q0dxz0/UukN2CIziag3hJj7pN6xiAA==", .malformedKey),
        ("host ssh-ed448 AAAACXNzaC1lZDQ0OA==", .unsupportedKeyType("ssh-ed448")),
        ("@marker host ssh-ed25519 \(ed25519)", .marker("@marker")),
        ("host ssh-ed25519 \(ed25519)\u{0}", .nullCharacter),
    ])
    func linesShelloDoesNotImportAreListed(_ line: String, _ reason: KnownHosts.SkippedLine.Reason) {
        let file = KnownHosts("# comment\n" + line)

        #expect(file.entries.isEmpty)
        #expect(file.skipped.map(\.reason) == [reason])
        #expect(file.skipped.map(\.line) == [2])
    }

    @Test func blankLinesCommentsAndWindowsLineEndsAreFine() {
        let file = KnownHosts("\n   \n# comment\n\thost ssh-ed25519 \(Self.ed25519) comment with spaces\r\n")

        #expect(file.skipped.isEmpty)
        #expect(file.entries.map(\.line) == [4])
        #expect(file.entries.first?.keyBase64 == Self.ed25519)
    }

    @Test func supportedKeyTypesAreTheAlgorithmPolicysHostKeyTypes() {
        let types = AlgorithmPolicy.standard.hostKeyAlgorithms.map { $0.hasPrefix("rsa-sha2-") ? "ssh-rsa" : $0 }
        var unique: [String] = []
        for type in types where !unique.contains(type) {
            unique.append(type)
        }
        #expect(KnownHosts.supportedKeyTypes == unique)
    }

    /// libssh reads each type's key as a connection reads the server's: its fingerprint is the one
    /// `ssh-keygen -l` showed for it.
    @Test(arguments: [
        ("ssh-ed25519", ed25519, ed25519Fingerprint), ("ecdsa-sha2-nistp256", p256, p256Fingerprint),
        ("ecdsa-sha2-nistp384", p384, p384Fingerprint), ("ssh-rsa", rsa, rsaFingerprint),
    ])
    func libsshReadsEachKeyWithItsFingerprint(_ type: String, _ key: String, _ fingerprint: String) throws {
        let entry = try #require(KnownHosts("host \(type) \(key)").entries.first)

        let hostKey = try KnownHostKeys.hostKey(of: entry)

        #expect(hostKey.algorithm == type)
        #expect(hostKey.fingerprint == fingerprint)
        #expect(Array(hostKey.wireRepresentation) == entry.key)
    }

    /// RFC 2202's first two test cases for HMAC-SHA1.
    @Test func hmacSHA1IsRFC2202s() {
        let first = KnownHostKeys.hmacSHA1(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))
        #expect(first.map(Self.hex) == "b617318655057264e28bc0b6fb378c8ef146be00")
        let second = KnownHostKeys.hmacSHA1(
            key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))
        #expect(second.map(Self.hex) == "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    // MARK: - Robustness

    /// Random text, and the real-world file with characters changed, cut short or repeated, never
    /// traps; every entry has names and a key of its type, every line number is in the file, and no
    /// line is both an entry and a skipped line. Seeded, so that a failure repeats. The fuzz target
    /// Fuzz/KnownHosts checks the same.
    @Test func randomTextNeverTraps() {
        var random = SeededRandom(seed: 4022)
        let alphabet = Array(" \t\n\r,|[]:*?!@#=+/AQWaz019".utf8) + [0, 0xFF]
        let valid = Array(Self.realWorld.utf8)
        for round in 0..<2000 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                bytes = (0..<Int.random(in: 0..<400, using: &random)).map { _ in
                    alphabet[Int.random(in: 0..<alphabet.count, using: &random)]
                }
            } else {
                bytes = valid
                for _ in 0..<Int.random(in: 1...6, using: &random) where !bytes.isEmpty {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<3, using: &random) {
                    case 0: bytes[index] = alphabet[Int.random(in: 0..<alphabet.count, using: &random)]
                    case 1:
                        bytes.removeSubrange(index..<min(bytes.count, index + Int.random(in: 1...40, using: &random)))
                    default: bytes.insert(contentsOf: Array(bytes[index...].prefix(30)), at: index)
                    }
                }
            }
            let file = KnownHosts(bytes: bytes)
            let lineCount = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).count
            for entry in file.entries {
                #expect(!entry.names.isEmpty)
                #expect(KnownHosts.isKey(entry.key, ofType: entry.keyType))
                #expect((1...lineCount).contains(entry.line))
                for name in entry.names {
                    _ = name.matches(host: "example.com", port: 22, hmacSHA1: KnownHostKeys.hmacSHA1)
                }
            }
            #expect(file.skipped.allSatisfy { (1...lineCount).contains($0.line) })
            let skippedLines = Set(file.skipped.filter { !$0.reason.isAboutAName }.map(\.line))
            #expect(skippedLines.isDisjoint(with: file.entries.map(\.line)))
        }
    }
}

extension KnownHosts.SkippedLine.Reason {
    /// Whether the reason is about one name of a line, whose other names may still be imported.
    fileprivate var isAboutAName: Bool {
        switch self {
        case .wildcard, .negated, .malformedName: true
        default: false
        }
    }
}
