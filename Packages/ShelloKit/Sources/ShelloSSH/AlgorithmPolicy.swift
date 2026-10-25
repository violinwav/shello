import Foundation
import ShelloModel

/// Shello's algorithm policy (README sections 4 and 14, STACK section 7.2): the algorithms a
/// connection offers the server, most preferred first, and what Shello knows about them. It is data,
/// not code, so that an app update can change it without touching the connection, and a host can
/// have lists of its own (`overridden(by:)`).
///
/// The standard policy ships as `Resources/AlgorithmPolicy.json`, an object with:
/// - `version`: the policy's version, raised with every change. Each connection logs it.
/// - `keyExchanges`, `ciphers`, `macs`, `hostKeyAlgorithms` and `sshKeyAlgorithms`: what a connection
///   offers, each most preferred first. libssh takes them as they are (`ssh_options_set`), and the
///   server uses the first one of each that it supports too. None may be empty.
/// - `postQuantumKeyExchanges`: the key exchanges that are post-quantum, offered or not. Any other
///   is classical.
///
/// What the standard policy offers:
/// - Key exchange: the post-quantum hybrids, then `curve25519-sha256`, then the classical ones
///   without SHA-1 that a server without curve25519 may have, such as one in FIPS mode: the NIST
///   curves, then the Diffie-Hellman groups.
/// - Ciphers: chacha20-poly1305, AES-GCM, then AES-CTR. MACs: HMAC-SHA2, encrypt-then-MAC. The MACs
///   matter to AES-CTR only, since the others authenticate themselves.
/// - Host keys and SSH keys: Ed25519, ECDSA, then RSA with SHA-2.
/// - Off: SHA-1, CBC ciphers and DSA. libssh 0.12 has no DSA at all.
///
/// `sntrup761x25519-sha512` is offered under both of its names. OpenSSH before 9.9, such as Ubuntu
/// 24.04's 9.6, knows it only as `sntrup761x25519-sha512@openssh.com`, the vendor name it had before
/// IANA assigned it one; OpenSSH 9.9 and later, and libssh 0.12, know both. libssh reports the name
/// it negotiated.
public struct AlgorithmPolicy: Hashable, Sendable, Decodable {
    /// The policy's version, raised with every change to its lists.
    public let version: Int
    /// The key exchanges to offer, most preferred first.
    public let keyExchanges: [String]
    /// The ciphers to offer, in both directions, most preferred first.
    public let ciphers: [String]
    /// The MACs to offer, in both directions, most preferred first.
    public let macs: [String]
    /// The algorithms of the host keys the server may identify itself with, most preferred first.
    public let hostKeyAlgorithms: [String]
    /// The signature algorithms an SSH key may sign in with, most preferred first. An RSA key signs
    /// with SHA-2 only, as `rsa-sha2-512` or `rsa-sha2-256`.
    public let sshKeyAlgorithms: [String]
    /// The key exchanges that are post-quantum, whether the policy offers them or not.
    public let postQuantumKeyExchanges: Set<String>

    public init(
        version: Int, keyExchanges: [String], ciphers: [String], macs: [String], hostKeyAlgorithms: [String],
        sshKeyAlgorithms: [String], postQuantumKeyExchanges: Set<String>
    ) {
        self.version = version
        self.keyExchanges = keyExchanges
        self.ciphers = ciphers
        self.macs = macs
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.sshKeyAlgorithms = sshKeyAlgorithms
        self.postQuantumKeyExchanges = postQuantumKeyExchanges
    }

    /// The policy that ships with the app.
    public static let standard: AlgorithmPolicy = {
        do {
            return try bundled()
        } catch {
            // The file ships inside the app, and AlgorithmPolicyTests read it on every run.
            preconditionFailure("Resources/AlgorithmPolicy.json can’t be read: \(error)")
        }
    }()

    static func bundled() throws -> AlgorithmPolicy {
        guard let url = Bundle.module.url(forResource: "AlgorithmPolicy", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AlgorithmPolicy.self, from: Data(contentsOf: url))
    }

    /// The key exchange that SSH calls `name`, post-quantum if the policy says it is.
    public func keyExchange(named name: String) -> KeyExchange {
        KeyExchange(name: name, isPostQuantum: postQuantumKeyExchanges.contains(name))
    }

    /// The policy with a host's own lists in place of its own (README section 14). A list that the
    /// overrides leave out, or leave empty, stays the policy's. The version stays too: it names the
    /// policy the host's lists depart from.
    public func overridden(by overrides: AlgorithmOverrides) -> AlgorithmPolicy {
        func list(_ override: [String]?, else standard: [String]) -> [String] {
            guard let override, !override.isEmpty else { return standard }
            return override
        }
        return AlgorithmPolicy(
            version: version, keyExchanges: list(overrides.keyExchanges, else: keyExchanges),
            ciphers: list(overrides.ciphers, else: ciphers), macs: list(overrides.macs, else: macs),
            hostKeyAlgorithms: list(overrides.hostKeyAlgorithms, else: hostKeyAlgorithms),
            sshKeyAlgorithms: list(overrides.sshKeyAlgorithms, else: sshKeyAlgorithms),
            postQuantumKeyExchanges: postQuantumKeyExchanges)
    }

    /// The policy with the host key algorithms of `trusted`, the host key trusted for the server, ahead
    /// of the others, as OpenSSH orders them for a server in `known_hosts`. A server with several host
    /// keys then identifies itself with the trusted one, rather than with another one that would look
    /// like a changed host key. Algorithms the policy does not offer stay out.
    public func preferringAlgorithms(of trusted: HostKey) -> AlgorithmPolicy {
        let preferred = Self.signatureAlgorithms(ofKeyType: trusted.algorithm)
        let first = hostKeyAlgorithms.filter(preferred.contains)
        guard !first.isEmpty else { return self }
        return AlgorithmPolicy(
            version: version, keyExchanges: keyExchanges, ciphers: ciphers, macs: macs,
            hostKeyAlgorithms: first + hostKeyAlgorithms.filter { !preferred.contains($0) },
            sshKeyAlgorithms: sshKeyAlgorithms, postQuantumKeyExchanges: postQuantumKeyExchanges)
    }

    /// The host key algorithms that a key of `keyType` signs with: an RSA key (`ssh-rsa`) with SHA-512
    /// or SHA-256, and with SHA-1 under its own name; any other key under its own name.
    static func signatureAlgorithms(ofKeyType keyType: String) -> [String] {
        keyType == "ssh-rsa" ? ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"] : [keyType]
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case keyExchanges
        case ciphers
        case macs
        case hostKeyAlgorithms
        case sshKeyAlgorithms
        case postQuantumKeyExchanges
    }

    /// Reads a policy. None of its lists may be empty: without a key exchange, or a cipher, no
    /// connection could be made.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] {
            let list = try container.decode([String].self, forKey: key)
            guard !list.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "The policy’s \(key.rawValue) are empty.")
            }
            return list
        }
        self.init(
            version: try container.decode(Int.self, forKey: .version), keyExchanges: try list(.keyExchanges),
            ciphers: try list(.ciphers), macs: try list(.macs), hostKeyAlgorithms: try list(.hostKeyAlgorithms),
            sshKeyAlgorithms: try list(.sshKeyAlgorithms),
            postQuantumKeyExchanges: try container.decode(Set<String>.self, forKey: .postQuantumKeyExchanges))
    }
}

/// A key exchange (GLOSSARY), by the name SSH gives it, such as `mlkem768x25519-sha256`, and whether
/// it is post-quantum.
public struct KeyExchange: Hashable, Sendable {
    /// The name SSH and libssh give it.
    public let name: String
    /// Whether it is post-quantum: traffic recorded today stays private even from a future quantum
    /// computer. Otherwise it is classical.
    public let isPostQuantum: Bool

    public init(name: String, isPostQuantum: Bool) {
        self.name = name
        self.isPostQuantum = isPostQuantum
    }
}
