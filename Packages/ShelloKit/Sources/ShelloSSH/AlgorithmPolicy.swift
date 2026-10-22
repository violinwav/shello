import Foundation

/// Shello's algorithm policy (README section 14, STACK section 7.2): the algorithms a connection
/// offers the server, most preferred first, and what Shello knows about them. It is data, not code,
/// so that an app update can change it without touching the connection.
///
/// The standard policy ships as `Resources/AlgorithmPolicy.json`, an object with:
/// - `version`: the policy's version, raised with every change. Each connection logs it.
/// - `keyExchanges`: the key exchanges a connection offers, most preferred first. libssh takes them
///   as they are (`SSH_OPTIONS_KEY_EXCHANGE`), and the server uses the first one it supports too.
/// - `postQuantumKeyExchanges`: the key exchanges that are post-quantum, offered or not. Any other
///   is classical.
///
/// Ciphers, MACs and host key algorithms (#27) become lists of their own beside these, and a host's
/// own order (#27) a policy that replaces some of the lists.
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
    /// The key exchanges that are post-quantum, whether the policy offers them or not.
    public let postQuantumKeyExchanges: Set<String>

    public init(version: Int, keyExchanges: [String], postQuantumKeyExchanges: Set<String>) {
        self.version = version
        self.keyExchanges = keyExchanges
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

    private enum CodingKeys: String, CodingKey {
        case version
        case keyExchanges
        case postQuantumKeyExchanges
    }

    /// Reads a policy, which must offer a key exchange: without one, no connection could be made.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyExchanges = try container.decode([String].self, forKey: .keyExchanges)
        guard !keyExchanges.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyExchanges, in: container, debugDescription: "The policy offers no key exchange.")
        }
        self.init(
            version: try container.decode(Int.self, forKey: .version), keyExchanges: keyExchanges,
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
