import Foundation
import Security

/// An imported RSA key (README section 13) as Security takes it: its private key in PKCS #1's DER,
/// which signs with SHA-256 or SHA-512 (RFC 8332), never with SHA-1. CryptoKit has no RSA.
enum RSAKey {
    /// The private key in `der`, PKCS #1's `RSAPrivateKey`, read in place.
    /// - Throws: `SSHKeyError.mismatchedKeyPair` if Security cannot read it.
    static func privateKey(der: UnsafeRawBufferPointer) throws -> SecKey {
        // The data is the secret's own buffer, not a copy that nothing would overwrite.
        let data =
            if let base = der.baseAddress {
                unsafe Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: der.count, deallocator: .none)
            } else {
                Data()
            }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = unsafe SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            unsafe error?.release()
            throw SSHKeyError.mismatchedKeyPair
        }
        return key
    }

    /// The public key of `privateKey`, as SSH writes it.
    /// - Throws: `SSHKeyError.mismatchedKeyPair` if Security gives out no public key Shello reads.
    static func publicKey(of privateKey: SecKey) throws -> SSHPublicKey {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
            let der = unsafe SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
            let (modulus, exponent) = Self.integers(inRSAPublicKey: der)
        else {
            unsafe error?.release()
            throw SSHKeyError.mismatchedKeyPair
        }
        return SSHPublicKey(rsaModulus: modulus, exponent: exponent)
    }

    /// Signs `data` with `key`, hashed with `hash`, and returns the signature in SSH's wire format.
    /// - Throws: What Security reported.
    static func signature(for data: Data, by key: SecKey, hash: RSAHash) throws -> Data {
        let algorithm: SecKeyAlgorithm =
            switch hash {
            case .sha256: .rsaSignatureMessagePKCS1v15SHA256
            case .sha512: .rsaSignatureMessagePKCS1v15SHA512
            }
        var error: Unmanaged<CFError>?
        guard let signature = unsafe SecKeyCreateSignature(key, algorithm, data as CFData, &error) as Data? else {
            throw unsafe error.map { unsafe $0.takeRetainedValue() as any Error } ?? SSHKeyError.mismatchedKeyPair
        }
        return SSHSignature.rsa(hash, signature)
    }

    /// The modulus and the public exponent in PKCS #1's `RSAPublicKey`, as Security exports a public
    /// key: `SEQUENCE { modulus INTEGER, publicExponent INTEGER }` in DER. Nil for anything else.
    static func integers(inRSAPublicKey der: Data) -> (modulus: Data, exponent: Data)? {
        var outer = DERScanner(der[...])
        guard var sequence = outer.contents(ofTag: 0x30), outer.isAtEnd,
            let modulus = sequence.contents(ofTag: 0x02), let exponent = sequence.contents(ofTag: 0x02),
            sequence.isAtEnd
        else { return nil }
        return (modulus.bytes, exponent.bytes)
    }
}

/// Reads the DER elements Security writes for an RSA public key, one after the other: a tag, then a
/// length of one to four bytes, then the contents.
private struct DERScanner {
    private(set) var bytes: Data.SubSequence

    init(_ bytes: Data.SubSequence) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { bytes.isEmpty }

    /// The contents of the next element, if it has `tag`, as a scanner of their own.
    mutating func contents(ofTag tag: UInt8) -> DERScanner? {
        guard bytes.first == tag, bytes.count >= 2 else { return nil }
        var index = bytes.startIndex + 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...4).contains(count), bytes.endIndex - index >= count else { return nil }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard bytes.endIndex - index >= length else { return nil }
        let contents = bytes[index..<index + length]
        bytes = bytes[(index + length)...]
        return DERScanner(contents)
    }
}
