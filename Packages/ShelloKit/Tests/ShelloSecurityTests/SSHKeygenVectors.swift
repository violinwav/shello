import CryptoKit
import Foundation
import Testing

/// What `ssh-keygen` (OpenSSH 10.2p1, on macOS) writes for two keys: the vectors that Shello's
/// encoding of public keys, fingerprints and signatures must match byte for byte.
///
/// The keys are published test keys, nobody's real keys: RFC 8032's Ed25519 key (section 7.1,
/// TEST 1) and RFC 6979's P-256 key (appendix A.2.5). Each was written as an unencrypted OpenSSH
/// private key file with the comment below. Then:
/// - `ssh-keygen -y -f <key>` printed `publicKey`, and `ssh-keygen -l -f <key>.pub` the fingerprint.
/// - `ssh-keygen -Y sign -f <key> -n shello-test` signed `message`. The ECDSA key signed it until
///   there was a signature for each length an `mpint` of r and s can take; `ssh-keygen -Y
///   check-novalidate` verified every signature kept.
enum SSHKeygenVectors {
    /// The SSHSIG namespace and message of the signatures (PROTOCOL.sshsig in OpenSSH).
    static let namespace = "shello-test"
    static let message = Data("Shello signs this to test its SSH signatures.\n".utf8)

    enum Ed25519 {
        static let privateKey = Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        /// RFC 8032's public key for `privateKey`.
        static let rawPublicKey = Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        static let comment = "rfc8032-test-1@shello"
        static let publicKey =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea rfc8032-test-1@shello"
        static let fingerprint = "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8"
        /// OpenSSH's Ed25519 signatures are deterministic: every run printed this one.
        static let signature = Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAQPg171wZ7by4dnrrSa6l2ohr+OWGlqd/HgWLL0AsZXGa+y48iu5nh3sHYHYc"
                + "jETzDx1AaS039fSDECDx6P+Tggk=")!
    }

    enum ECDSA {
        static let privateKey = Data(hex: "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")
        static let comment = "rfc6979-a.2.5@shello"
        static let publicKey =
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZp"
            + "Yi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk= rfc6979-a.2.5@shello"
        static let fingerprint = "SHA256:hfuNWmjIYvsBGZ6dpCLTTAEa5LxbZABRHHVoynAxFlo"

        /// A signature, with the lengths in bytes of its r and s as `mpint`s: 33 when the top bit
        /// needs a zero byte in front, 31 when the number has a leading zero byte.
        struct Signature: CustomTestStringConvertible, Sendable {
            let rLength: Int
            let sLength: Int
            let wireRepresentation: Data

            init(r rLength: Int, s sLength: Int, _ base64: String) {
                self.rLength = rLength
                self.sLength = sLength
                wireRepresentation = Data(base64Encoded: base64)!
            }

            var testDescription: String { "r \(rLength) bytes, s \(sLength) bytes" }
        }

        static let signatures = [
            Signature(
                r: 32, s: 32,
                "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABIAAAAID4MCySeuoT2CFJc9hjVSUWKRYlwAp2tpXp7TkmvPs3QAAAAIHz75zQGacixSmAk"
                    + "1P+FTvtfP4AvD+X2PuQUTnW53xkw"),
            Signature(
                r: 33, s: 32,
                "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABJAAAAIQD853in5YB2zIUFq/55BWiLEr6uysXBMCygVjvgv+WnywAAACAp2mbL7ppWqjdb"
                    + "G3IBvvqwjg9xcSa1RBrZI0pVUyJ8Ow=="),
            Signature(
                r: 32, s: 33,
                "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABJAAAAIEaEsA7ziytd0b1Ul1r70wVE9A8RV/p+CFDL9C1RTxOHAAAAIQCoqv+5WGwUqXyo"
                    + "GTEI7WjeOnxI4VdAGHdvNk9jxABjGQ=="),
            Signature(
                r: 31, s: 33,
                "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABIAAAAH09Ob+WjFyWqRcATdNo4b8jBrDgtwv3+3jWCUVvOifYAAAAhAJ6+4SdbsQz4fiAk"
                    + "1I5sPO+4ULq1RHGySVIWSGKOL43y"),
            Signature(
                r: 33, s: 31,
                "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAABIAAAAIQDi2cnsA/YG5mZAfealUzADe7T6vZaVutF+9Rfi8xBIgwAAAB8uahPuAaCgfnsX"
                    + "LxUjXEgzPiMkglipXP75UdMfOZzt"),
        ]
    }

    /// What `ssh-keygen -Y sign` signs for `message` (PROTOCOL.sshsig): the preamble, the namespace,
    /// an empty reserved field, the hash's name and the SHA-512 of the message.
    static var signedData: Data {
        var data = Data("SSHSIG".utf8)
        for field in [Data(namespace.utf8), Data(), Data("sha512".utf8), Data(SHA512.hash(data: message))] {
            data.append(contentsOf: UInt32(field.count).bigEndianBytes)
            data.append(field)
        }
        return data
    }
}

extension Data {
    /// The bytes that `hex` spells, two digits each.
    init(hex: String) {
        let digits = Array(hex.utf8)
        self.init(
            stride(from: 0, to: digits.count, by: 2).map { index in
                UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)!
            })
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: self >> $0) }
    }
}
