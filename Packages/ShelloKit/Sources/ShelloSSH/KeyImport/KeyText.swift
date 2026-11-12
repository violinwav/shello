// What the text of a private key says about the key before it is decrypted (README section 13):
// which format it is in, whether it is encrypted, and, in OpenSSH's format, its public key. The
// user pastes or picks any text, so everything here reads untrusted bytes and must neither trap nor
// grow without bound, whatever it is given. The text is read in place, never copied, and none of a
// private key's secret part is decoded. libssh reads the key itself; Fuzz/KeyText fuzzes this.
//
// This file uses the standard library only, so that the fuzz target builds it with the swift.org
// toolchain on Linux as it is (Fuzz/README.md).

/// What a text holds, as far as it says without its passphrase.
enum KeyText: Hashable, Sendable {
    /// A private key in OpenSSH's own format (`openssh-key-v1`), whose public key is readable
    /// without the passphrase.
    case openSSH(isEncrypted: Bool, publicKey: PublicKeySummary)
    /// A private key in PEM, OpenSSL's traditional format, whose label names its algorithm.
    case pem(PEMAlgorithm, isEncrypted: Bool)
    /// A private key in PKCS #8 (RFC 5958), whose algorithm is inside it, encrypted or not.
    case pkcs8(isEncrypted: Bool)
    /// A public key, not a private one: a line of `authorized_keys`, a `.pub` file, or a public key
    /// in PEM or RFC 4716.
    case publicKey
    /// A key in PuTTY's format, which libssh does not read.
    case putty
    /// Nothing Shello takes for a key, or a text far longer than any key.
    case unknown

    /// The longest text read: a private key in PEM is a few kilobytes at most.
    static let maximumLength = 64 * 1024

    /// Reads what `text` holds, as far as its first key goes.
    init<Text: RandomAccessCollection<UInt8>>(_ text: Text) where Text.Index == Int {
        guard text.count <= Self.maximumLength else {
            self = .unknown
            return
        }
        if let armor = PEMArmor(text) {
            self = Self(armor, body: text[armor.body])
        } else if Self.isOneLinePublicKey(text) || text.firstRange(of: Self.rfc4716PublicKey) != nil {
            self = .publicKey
        } else if text.firstRange(of: Self.puttyHeader) != nil {
            self = .putty
        } else {
            self = .unknown
        }
    }

    /// Whether the key is encrypted, and needs its passphrase to be read.
    var isEncrypted: Bool {
        switch self {
        case .openSSH(let isEncrypted, _), .pem(_, let isEncrypted), .pkcs8(let isEncrypted): isEncrypted
        case .publicKey, .putty, .unknown: false
        }
    }

    private static let rfc4716PublicKey = Array("---- BEGIN SSH2 PUBLIC KEY".utf8)
    private static let puttyHeader = Array("PuTTY-User-Key-File-".utf8)

    private init(_ armor: PEMArmor, body: some Collection<UInt8>) {
        switch armor.label {
        case "OPENSSH PRIVATE KEY":
            guard let header = OpenSSHKeyHeader(base64: body) else {
                self = .unknown
                return
            }
            self = .openSSH(isEncrypted: header.cipher != "none", publicKey: header.publicKey)
        case "RSA PRIVATE KEY":
            self = .pem(.rsa, isEncrypted: Self.hasEncryptedHeader(body))
        case "EC PRIVATE KEY":
            self = .pem(.ec, isEncrypted: Self.hasEncryptedHeader(body))
        case "DSA PRIVATE KEY":
            self = .pem(.dsa, isEncrypted: Self.hasEncryptedHeader(body))
        case "PRIVATE KEY":
            self = .pkcs8(isEncrypted: false)
        case "ENCRYPTED PRIVATE KEY":
            self = .pkcs8(isEncrypted: true)
        case "PUBLIC KEY", "RSA PUBLIC KEY", "OPENSSH PUBLIC KEY", "SSH2 PUBLIC KEY":
            self = .publicKey
        default:
            self = .unknown
        }
    }

    /// Whether a traditional PEM key's headers say it is encrypted (RFC 1421): `Proc-Type:
    /// 4,ENCRYPTED`. Base64 has no colon, so the headers are the only place for one.
    private static func hasEncryptedHeader(_ body: some Collection<UInt8>) -> Bool {
        guard let procType = body.firstRange(of: Array("Proc-Type:".utf8)) else { return false }
        let line = body[procType.upperBound...].prefix { $0 != UInt8(ascii: "\n") }
        return line.firstRange(of: Array("ENCRYPTED".utf8)) != nil
    }

    /// Whether `text` starts like a line of `authorized_keys` or a `.pub` file: a key type that SSH
    /// names, such as `ssh-ed25519`, then a space and base64 that starts as a public key's does.
    private static func isOneLinePublicKey(_ text: some Collection<UInt8>) -> Bool {
        let start = text.drop { isWhitespace($0) }
        let type = start.prefix { !isWhitespace($0) }
        let isKeyType = ["ssh-", "ecdsa-sha2-", "sk-"].contains { type.starts(with: Array($0.utf8)) }
        let rest = start[type.endIndex...].drop { isWhitespace($0) }
        return isKeyType && rest.starts(with: Array("AAAA".utf8))
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
    }
}

/// The algorithm a traditional PEM private key's label names.
enum PEMAlgorithm: Hashable, Sendable {
    /// `RSA PRIVATE KEY`.
    case rsa
    /// `EC PRIVATE KEY`, of any curve.
    case ec
    /// `DSA PRIVATE KEY`, which Shello does not import.
    case dsa
}

/// The public key of an SSH key, as far as Shello tells keys apart before it imports them.
struct PublicKeySummary: Hashable, Sendable {
    /// The key type's name, such as `ssh-ed25519`, `ssh-rsa` or `ssh-dss`.
    let type: String
    /// An RSA key's modulus, in bits; nil for every other key.
    let rsaBits: Int?

    /// The summary of the public key `wireRepresentation`, in SSH's wire format (RFC 4253 section
    /// 6.6); nil if it is not one.
    init?(wireRepresentation: some Collection<UInt8>) {
        var reader = SSHWireReader(wireRepresentation.makeIterator())
        guard let type = reader.readString(maximumLength: 64), let name = String(validating: type, as: UTF8.self)
        else { return nil }
        self.type = name
        guard name == "ssh-rsa" else {
            rsaBits = nil
            return
        }
        // The public exponent, then the modulus.
        guard reader.readString(maximumLength: 2048) != nil, let modulus = reader.readString(maximumLength: 2048)
        else { return nil }
        rsaBits = Self.bits(ofMPInt: modulus)
    }

    /// How many bits the number in the `mpint` `bytes` has, leading zeros left out.
    static func bits(ofMPInt bytes: [UInt8]) -> Int {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return 0 }
        return (bytes.count - first - 1) * 8 + (8 - bytes[first].leadingZeroBitCount)
    }
}

/// The first `-----BEGIN label-----` … `-----END label-----` in a text (RFC 7468): the label, and
/// where the body between the two lines lies. Text around it is left alone, as OpenSSL and libssh
/// leave it.
struct PEMArmor: Hashable, Sendable {
    let label: String
    let body: Range<Int>

    private static let begin = Array("-----BEGIN ".utf8)
    private static let dashes = Array("-----".utf8)

    init?<Text: RandomAccessCollection<UInt8>>(_ text: Text) where Text.Index == Int {
        guard let begin = text.firstRange(of: Self.begin) else { return nil }
        // A label is short, and of capital letters, digits and spaces.
        let label = text[begin.upperBound...].prefix(64).prefix { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: " ")
        }
        guard !label.isEmpty, text[label.endIndex...].starts(with: Self.dashes) else { return nil }
        let bodyStart = label.endIndex + Self.dashes.count
        let end = Array("-----END ".utf8) + label + Self.dashes
        guard let endRange = text[bodyStart...].firstRange(of: end) else { return nil }
        self.label = String(decoding: label, as: UTF8.self)
        body = bodyStart..<endRange.lowerBound
    }
}

/// The start of a private key in OpenSSH's format, `openssh-key-v1` (OpenSSH's PROTOCOL.key), up to
/// its public key: everything before the private part, which is never decoded. Read from the base64
/// between the armor's lines.
struct OpenSSHKeyHeader: Hashable, Sendable {
    /// The cipher that encrypts the private part: `none` for a key without a passphrase.
    let cipher: String
    /// The function that makes the cipher's key from the passphrase: `none`, or `bcrypt`.
    let kdf: String
    let publicKey: PublicKeySummary

    /// The magic bytes that start the format, its terminating zero included.
    static let magic = Array("openssh-key-v1\0".utf8)

    init?(base64 text: some Collection<UInt8>) {
        var reader = SSHWireReader(Base64Decoder(text.makeIterator()))
        guard let magic = reader.readBytes(Self.magic.count), magic == Self.magic,
            let cipher = reader.readString(maximumLength: 64).flatMap({ String(validating: $0, as: UTF8.self) }),
            let kdf = reader.readString(maximumLength: 64).flatMap({ String(validating: $0, as: UTF8.self) }),
            reader.readString(maximumLength: 1024) != nil,
            // OpenSSH writes one key a file, and libssh reads no other.
            reader.readUInt32() == 1,
            let blob = reader.readString(maximumLength: 16 * 1024),
            let publicKey = PublicKeySummary(wireRepresentation: blob)
        else { return nil }
        self.cipher = cipher
        self.kdf = kdf
        self.publicKey = publicKey
    }
}

/// Decodes base64 (RFC 4648) a byte at a time, as far as it is read, so that the bytes after those
/// read stay encoded. Line breaks and spaces are skipped; decoding ends at the padding, the end of
/// the text, or a byte that is not base64, which `isInvalid` then reports.
struct Base64Decoder<Characters: IteratorProtocol<UInt8>>: IteratorProtocol {
    private var characters: Characters
    /// The bits decoded and not handed out yet are the lowest `bitCount` of these.
    private var accumulator: UInt32 = 0
    private var bitCount = 0
    private var hasEnded = false
    private(set) var isInvalid = false

    init(_ characters: Characters) {
        self.characters = characters
    }

    mutating func next() -> UInt8? {
        while !hasEnded {
            if bitCount >= 8 {
                bitCount -= 8
                return UInt8(truncatingIfNeeded: accumulator >> UInt32(bitCount))
            }
            guard let character = characters.next() else {
                hasEnded = true
                break
            }
            if KeyText.isWhitespace(character) { continue }
            guard let value = Self.value(of: character) else {
                isInvalid = character != UInt8(ascii: "=")
                hasEnded = true
                break
            }
            // Six bits more. At most 13 are held, so 14 bits keep them all.
            accumulator = (accumulator << 6 | UInt32(value)) & 0x3FFF
            bitCount += 6
        }
        return nil
    }

    /// The six bits `character` stands for, or nil if it is not one of base64's characters.
    static func value(of character: UInt8) -> UInt8? {
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

/// Reads SSH's wire format (RFC 4251 section 5) from bytes as they come, checking each length
/// against a maximum before reading that many.
struct SSHWireReader<Bytes: IteratorProtocol<UInt8>> {
    private var bytes: Bytes

    init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard let byte = bytes.next() else { return nil }
            result.append(byte)
        }
        return result
    }

    /// A `uint32`: four bytes, the most significant first.
    mutating func readUInt32() -> UInt32? {
        readBytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    /// A `string`: a `uint32` length, then that many bytes; nil for one longer than `maximumLength`.
    mutating func readString(maximumLength: Int) -> [UInt8]? {
        guard let length = readUInt32(), length <= maximumLength else { return nil }
        return readBytes(Int(length))
    }
}
