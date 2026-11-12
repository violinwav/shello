// The private key inside PKCS #8 (RFC 5958), the form libssh hands an imported key over in once it
// has read and decrypted it (README section 13), found in place: the bytes Apple's frameworks take,
// without a copy of the rest. OpenSSL writes it, but it reads like any input, checking every length
// against what is left, and must neither trap nor read past its bytes. Fuzz/KeyText fuzzes it.
//
// This file uses the standard library only, so that the fuzz target builds it with the swift.org
// toolchain on Linux as it is (Fuzz/README.md).

/// What is in a PKCS #8 `PrivateKeyInfo`: the key's algorithm, and where its private key lies in the
/// bytes, in the form Apple's frameworks take it.
struct PKCS8PrivateKey: Hashable, Sendable {
    enum Algorithm: Hashable, Sendable {
        /// `rsaEncryption`: the private key is PKCS #1's `RSAPrivateKey`, whole.
        case rsa
        /// `id-ecPublicKey`, of any curve: the private key is the private scalar of SEC 1's
        /// `ECPrivateKey`.
        case ec
        /// `id-Ed25519` (RFC 8410): the private key is the 32-byte seed.
        case ed25519
    }

    let algorithm: Algorithm
    let privateKey: Range<Int>

    /// The private key in `der`, a `PrivateKeyInfo` in DER:
    /// `SEQUENCE { version INTEGER, algorithm AlgorithmIdentifier, privateKey OCTET STRING, … }`.
    /// - Throws: `DERError` for bytes that are not one, or one of another algorithm.
    init<Bytes: RandomAccessCollection<UInt8>>(der: Bytes) throws(DERError) where Bytes.Index == Int {
        var outer = DERReader(der)
        var info = try outer.reader(ofTag: DERTag.sequence)
        guard outer.isAtEnd else { throw .malformed }
        let version = try info.read(DERTag.integer)
        // Version 1, RFC 5208's, or 2, RFC 5958's, which may add the public key.
        guard version.count == 1, [0, 1].contains(der[version.lowerBound]) else { throw .malformed }
        var algorithmIdentifier = try info.reader(ofTag: DERTag.sequence)
        let oid = der[try algorithmIdentifier.read(DERTag.objectIdentifier)]
        let privateKey = try info.read(DERTag.octetString)
        // The attributes and the public key that may follow are not needed.
        if oid.elementsEqual(Self.rsaEncryption) {
            algorithm = .rsa
            self.privateKey = try Self.rsaPrivateKey(in: der, privateKey)
        } else if oid.elementsEqual(Self.ecPublicKey) {
            algorithm = .ec
            self.privateKey = try Self.ecPrivateScalar(in: der, privateKey)
        } else if oid.elementsEqual(Self.ed25519) {
            algorithm = .ed25519
            // `CurvePrivateKey ::= OCTET STRING`, inside the private key's.
            var curvePrivateKey = DERReader(der, range: privateKey)
            let seed = try curvePrivateKey.read(DERTag.octetString)
            guard curvePrivateKey.isAtEnd, seed.count == 32 else { throw .malformed }
            self.privateKey = seed
        } else {
            throw .unsupportedAlgorithm
        }
    }

    /// 1.2.840.113549.1.1.1, `rsaEncryption`.
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    /// 1.2.840.10045.2.1, `id-ecPublicKey`.
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    /// 1.3.101.112, `id-Ed25519`.
    static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]

    /// The whole of PKCS #1's `RSAPrivateKey` in `range`, once it reads as one: version 0, then the
    /// eight numbers of a key with two primes, from the modulus to the CRT coefficient.
    private static func rsaPrivateKey<Bytes: RandomAccessCollection<UInt8>>(
        in der: Bytes, _ range: Range<Int>
    ) throws(DERError) -> Range<Int> where Bytes.Index == Int {
        var octets = DERReader(der, range: range)
        var key = try octets.reader(ofTag: DERTag.sequence)
        guard octets.isAtEnd else { throw .malformed }
        let version = try key.read(DERTag.integer)
        guard version.count == 1, der[version.lowerBound] == 0 else { throw .malformed }
        for _ in 0..<8 {
            guard try !key.read(DERTag.integer).isEmpty else { throw .malformed }
        }
        guard key.isAtEnd else { throw .malformed }
        return range
    }

    /// The private scalar of SEC 1's `ECPrivateKey` in `range`:
    /// `SEQUENCE { version INTEGER (1), privateKey OCTET STRING, [0] parameters, [1] publicKey }`.
    private static func ecPrivateScalar<Bytes: RandomAccessCollection<UInt8>>(
        in der: Bytes, _ range: Range<Int>
    ) throws(DERError) -> Range<Int> where Bytes.Index == Int {
        var octets = DERReader(der, range: range)
        var key = try octets.reader(ofTag: DERTag.sequence)
        guard octets.isAtEnd else { throw .malformed }
        let version = try key.read(DERTag.integer)
        guard version.count == 1, der[version.lowerBound] == 1 else { throw .malformed }
        let scalar = try key.read(DERTag.octetString)
        guard !scalar.isEmpty else { throw .malformed }
        return scalar
    }
}

/// Why DER could not be read.
enum DERError: Error, Hashable, Sendable {
    /// The bytes are not the DER expected: a tag is missing, or a length runs past the end.
    case malformed
    /// A private key of an algorithm other than RSA, ECDSA and Ed25519.
    case unsupportedAlgorithm
}

/// The tags of the DER elements a private key is made of.
enum DERTag {
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let objectIdentifier: UInt8 = 0x06
    static let sequence: UInt8 = 0x30
}

/// Reads DER (ITU-T X.690) elements one after the other within a range of bytes: a tag of one byte,
/// then a length, short or of one to four bytes, then that many bytes of contents. An indefinite
/// length, which DER never has, is malformed.
struct DERReader<Bytes: RandomAccessCollection<UInt8>> where Bytes.Index == Int {
    private let bytes: Bytes
    private var position: Int
    private let end: Int

    init(_ bytes: Bytes) {
        self.init(bytes, range: bytes.startIndex..<bytes.endIndex)
    }

    init(_ bytes: Bytes, range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    var isAtEnd: Bool { position >= end }

    /// Where the contents of the next element lie, which must have `tag`; the reader moves past it.
    mutating func read(_ tag: UInt8) throws(DERError) -> Range<Int> {
        guard position < end, bytes[position] == tag else { throw .malformed }
        var index = position + 1
        guard index < end else { throw .malformed }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), end - index >= count else { throw .malformed }
            length = 0
            for byte in bytes[index..<index + count] {
                length = length << 8 | Int(byte)
            }
            index += count
        }
        guard end - index >= length else { throw .malformed }
        position = index + length
        return index..<index + length
    }

    /// A reader of the contents of the next element, which must have `tag`.
    mutating func reader(ofTag tag: UInt8) throws(DERError) -> DERReader {
        DERReader(bytes, range: try read(tag))
    }
}
