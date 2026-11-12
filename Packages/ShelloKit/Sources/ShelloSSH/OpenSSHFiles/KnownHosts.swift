// OpenSSH's known_hosts file as Shello imports trusted host keys from it (README section 3, STACK
// sections 2 and 11): written in-house, fuzzed (Fuzz/KnownHosts), and with the standard library
// only, so that the fuzz target builds on Linux. Hashed names are matched with an HMAC that the
// caller passes in (`KnownHosts.Name.matches(host:port:hmacSHA1:)`); ShelloSSH's
// `KnownHostKeys.hmacSHA1` computes it with libssh.

/// An OpenSSH `known_hosts` file, read as sshd(8) describes it, for the import of README section 3:
/// one host key a line, after the names of its servers, `host` or `[host]:port`, comma-separated, or
/// one hashed name, `|1|salt|hash`. Blank lines and comments are left alone.
///
/// Each line Shello can import is in `entries`, with the key in SSH's wire format, checked. Every
/// other line, and every name of an entry that Shello cannot import, is in `skipped`, with its line
/// number and why: `@cert-authority` and `@revoked` lines, names with wildcards or `!`, key types
/// Shello does not take, and lines it cannot read. Nothing is left out silently.
public struct KnownHosts: Hashable, Sendable {
    /// The host key types Shello trusts: those of its algorithm policy (README section 4), most
    /// preferred first.
    public static let supportedKeyTypes = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    /// The default SSH port, which a name without brackets has.
    public static let defaultPort: UInt16 = 22

    /// A line with a host key of a type Shello trusts, and the names of its servers that Shello can
    /// import.
    public struct Entry: Hashable, Sendable {
        /// The line's number, from 1.
        public let line: Int
        /// The names Shello can import, in the line's order; never empty.
        public let names: [Name]
        /// The key's type, one of `supportedKeyTypes`.
        public let keyType: String
        /// The key in SSH's wire format (RFC 4253 section 6.6), which starts with its type.
        public let key: [UInt8]
        /// The key in base64, as written.
        public let keyBase64: String
    }

    /// A name of the servers a key is for.
    public enum Name: Hashable, Sendable {
        /// A host name or address, lowercased, and its port: 22, unless written `[host]:port`.
        case plain(host: String, port: UInt16)
        /// A hashed name, `|1|salt|hash`: the HMAC-SHA1 of the name, keyed with the salt, which
        /// hides the name. It is matched against the names of servers Shello knows.
        case hashed(salt: [UInt8], hash: [UInt8])
    }

    /// A line, or one name on a line, that Shello does not import.
    public struct SkippedLine: Hashable, Sendable {
        /// The line's number, from 1.
        public let line: Int
        /// The line as written, without the spaces around it, or the name, for a name.
        public let text: String
        public let reason: Reason

        public enum Reason: Error, Hashable, Sendable {
            /// A line with a marker: `@cert-authority`, a certificate authority's key, or `@revoked`,
            /// a key never to trust, as written; or another marker.
            case marker(String)
            /// A name with `*` or `?`, which stands for many servers.
            case wildcard
            /// A name with `!`, which keeps a pattern from matching.
            case negated
            /// A name that is not `host`, `[host]:port` or `|1|salt|hash`.
            case malformedName
            /// A key type Shello does not trust, such as `ssh-dss`, a security key's, or a
            /// certificate's.
            case unsupportedKeyType(String)
            /// A key that is not valid base64, or not a key of its type.
            case malformedKey
            /// A line without a name, a type and a key.
            case malformed
            /// A null character.
            case nullCharacter
        }
    }

    /// The lines with keys Shello can import, in order.
    public let entries: [Entry]
    /// The lines and names Shello does not import, in order.
    public let skipped: [SkippedLine]

    /// Reads `text`. Invalid UTF-8 should be repaired before, as `init(bytes:)` does.
    public init(_ text: String) {
        var entries: [Entry] = []
        var skipped: [SkippedLine] = []
        for (index, rawLine) in text.utf8.split(separator: .lineFeed, omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let fields = Self.fields(of: rawLine)
            guard let first = fields.first, first.first != .hash else { continue }
            let lineText = Self.trimmed(rawLine)
            func skip(_ reason: SkippedLine.Reason, _ text: String? = nil) {
                skipped.append(SkippedLine(line: number, text: text ?? lineText, reason: reason))
            }
            guard !rawLine.contains(0) else {
                skip(.nullCharacter)
                continue
            }
            if first.first == .at {
                skip(.marker(String(decoding: first, as: UTF8.self)))
                continue
            }
            guard fields.count >= 3 else {
                skip(.malformed)
                continue
            }
            let keyType = String(decoding: fields[1], as: UTF8.self)
            guard Self.supportedKeyTypes.contains(keyType) else {
                skip(.unsupportedKeyType(keyType))
                continue
            }
            guard let key = Self.base64Decoded(fields[2]), Self.isKey(key, ofType: keyType) else {
                skip(.malformedKey)
                continue
            }
            var names: [Name] = []
            for written in Self.names(fields[0]) {
                let text = String(decoding: written, as: UTF8.self)
                switch Self.name(written) {
                case .success(let name): names.append(name)
                case .failure(let reason): skip(reason, text)
                }
            }
            guard !names.isEmpty else { continue }
            entries.append(
                Entry(
                    line: number, names: names, keyType: keyType, key: key,
                    keyBase64: String(decoding: fields[2], as: UTF8.self)))
        }
        self.entries = entries
        self.skipped = skipped
    }

    /// Reads the file's `bytes` as UTF-8, with invalid bytes replaced.
    public init(bytes: some Collection<UInt8>) {
        self.init(String(decoding: bytes, as: UTF8.self))
    }

    // MARK: - Fields

    /// The line's fields, at spaces and tabs; a carriage return at the end is left out.
    static func fields(of line: Substring.UTF8View) -> [ArraySlice<UInt8>] {
        Array(line).split(whereSeparator: { $0.isSpace })
    }

    static func trimmed(_ line: Substring.UTF8View) -> String {
        guard let start = line.firstIndex(where: { !$0.isSpace }), let end = line.lastIndex(where: { !$0.isSpace })
        else { return "" }
        return String(Substring(line[start...end]))
    }

    /// The names of the first field: one hashed name, as OpenSSH reads a field that starts with
    /// `|`, or names separated by commas.
    static func names(_ field: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        field.first == .bar ? [field] : field.split(separator: .comma)
    }

    /// The name `written`, or why Shello does not import it.
    static func name(_ written: ArraySlice<UInt8>) -> Result<Name, SkippedLine.Reason> {
        if written.first == .bar {
            // |1|salt|hash, both in base64, each as long as a SHA-1 hash.
            let parts = written.split(separator: .bar, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0].isEmpty, Array(parts[1]) == [UInt8(ascii: "1")],
                let salt = base64Decoded(parts[2]), let hash = base64Decoded(parts[3]),
                salt.count == 20, hash.count == 20
            else { return .failure(.malformedName) }
            return .success(.hashed(salt: salt, hash: hash))
        }
        if written.first == .exclamationMark { return .failure(.negated) }
        if written.contains(.asterisk) || written.contains(.questionMark) { return .failure(.wildcard) }
        var host = written
        var port = defaultPort
        if written.first == .openingBracket {
            // [host]:port
            guard let close = written.firstIndex(of: .closingBracket), close + 1 < written.endIndex,
                written[close + 1] == .colon,
                let number = Self.port(written[(close + 2)...])
            else { return .failure(.malformedName) }
            host = written[(written.startIndex + 1)..<close]
            port = number
        }
        guard !host.isEmpty, !host.contains(.openingBracket), !host.contains(.closingBracket) else {
            return .failure(.malformedName)
        }
        return .success(.plain(host: String(decoding: host, as: UTF8.self).lowercased(), port: port))
    }

    /// A port from 1 to 65535, in decimal.
    static func port(_ digits: ArraySlice<UInt8>) -> UInt16? {
        guard (1...5).contains(digits.count),
            digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        let number = digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        return (1...65535).contains(number) ? UInt16(number) : nil
    }

    // MARK: - Keys

    /// Whether `key` is a public key of `type` in SSH's wire format, every field there and nothing
    /// after them: its type, then an Ed25519 key's 32 bytes; an ECDSA key's curve, which the type
    /// names, and its point, uncompressed; or an RSA key's exponent and modulus.
    static func isKey(_ key: [UInt8], ofType type: String) -> Bool {
        var reader = WireReader(key)
        guard let name = reader.string(), name.elementsEqual(type.utf8) else { return false }
        switch type {
        case "ssh-ed25519":
            guard reader.string()?.count == 32 else { return false }
        case "ssh-rsa":
            guard let exponent = reader.string(), !exponent.isEmpty, let modulus = reader.string(), !modulus.isEmpty
            else { return false }
        default:
            // ecdsa-sha2-nistp256 and the others: the curve's name, then the point, 04 x y.
            let curve = type.dropFirst("ecdsa-sha2-".count)
            guard let curveName = reader.string(), curveName.elementsEqual(curve.utf8), let point = reader.string(),
                point.first == 0x04, point.count > 1, point.count % 2 == 1
            else { return false }
        }
        return reader.isAtEnd
    }

    /// Reads SSH's wire format: strings, each a 32-bit length and that many bytes.
    struct WireReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index == bytes.count }

        /// The next string, or nil if the bytes end before it does.
        mutating func string() -> ArraySlice<UInt8>? {
            guard bytes.count - index >= 4 else { return nil }
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            index += 4
            guard bytes.count - index >= length else { return nil }
            defer { index += length }
            return bytes[index..<index + length]
        }
    }

    /// `text` decoded from base64 (RFC 4648): characters of its alphabet, in groups of four, the
    /// last padded with `=`; nil for anything else.
    static func base64Decoded(_ text: ArraySlice<UInt8>) -> [UInt8]? {
        guard !text.isEmpty, text.count % 4 == 0 else { return nil }
        let padding = text.reversed().prefix(while: { $0 == .equals }).count
        guard padding <= 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 4 * 3)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for character in text.dropLast(padding) {
            guard let value = base64Value(character) else { return nil }
            accumulator = (accumulator << 6 | UInt32(value)) & 0xFFFF
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bitCount)))
            }
        }
        return bytes
    }

    private static func base64Value(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): 62
        case UInt8(ascii: "/"): 63
        default: nil
        }
    }
}

extension KnownHosts.Name {
    /// The name OpenSSH writes in `known_hosts` for the server at `host` and `port`, and hashes:
    /// the host for port 22, `[host]:port` for any other.
    public static func written(host: String, port: UInt16) -> String {
        port == KnownHosts.defaultPort ? host : "[\(host)]:\(port)"
    }

    /// Whether the name is that of the server at `host`, lowercased, and `port`. A hashed name is
    /// compared with `hmacSHA1(salt, name)`, the HMAC-SHA1 of the server's name as OpenSSH writes
    /// it, keyed with the name's salt, which the caller computes: this parser uses the standard
    /// library only, and has no HMAC.
    public func matches(
        host: String, port: UInt16, hmacSHA1: (_ key: [UInt8], _ message: [UInt8]) -> [UInt8]?
    ) -> Bool {
        switch self {
        case .plain(let name, let namePort):
            return name == host && namePort == port
        case .hashed(let salt, let hash):
            let name = Array(Self.written(host: host, port: port).utf8)
            return hmacSHA1(salt, name) == hash
        }
    }
}

extension UInt8 {
    fileprivate static let lineFeed = UInt8(ascii: "\n")
    fileprivate static let hash = UInt8(ascii: "#")
    fileprivate static let at = UInt8(ascii: "@")
    fileprivate static let bar = UInt8(ascii: "|")
    fileprivate static let comma = UInt8(ascii: ",")
    fileprivate static let colon = UInt8(ascii: ":")
    fileprivate static let equals = UInt8(ascii: "=")
    fileprivate static let asterisk = UInt8(ascii: "*")
    fileprivate static let questionMark = UInt8(ascii: "?")
    fileprivate static let exclamationMark = UInt8(ascii: "!")
    fileprivate static let openingBracket = UInt8(ascii: "[")
    fileprivate static let closingBracket = UInt8(ascii: "]")

    /// A space, a tab, or a carriage return, which ends a line written on Windows.
    fileprivate var isSpace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\t") || self == UInt8(ascii: "\r")
    }
}
