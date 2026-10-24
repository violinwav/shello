import CryptoKit
import Foundation
import LocalAuthentication
import Security
import ShelloModel
import Testing

@testable import ShelloSecurity

/// Imported keys in the key store (README section 13): kept in the Keychain as Ed25519 keys are,
/// and signing through the same path, as their signing policy says. RSA keys sign with SHA-256 or
/// SHA-512, as the SSH agent's flags ask, and never with SHA-1. The key material is made here, as
/// ShelloSSH hands it over; ShelloSSHTests read it from ssh-keygen's files.
struct ImportedKeyTests {
    let authentication = TestAuthentication()
    let items = RecordingKeyItems()
    let window: UnlockWindow
    let store: SSHKeyStore

    init() {
        window = UnlockWindow(authentication: authentication)
        store = SSHKeyStore(
            items: items, enclave: MemoryEnclave(isAvailable: false), unlockWindow: window,
            authentication: authentication)
    }

    @Test(arguments: SSHKeyAlgorithm.allCases)
    func importedKeySignsWhatItsPublicKeyVerifies(algorithm: SSHKeyAlgorithm) async throws {
        try await window.open(reason: "Unlock Shello")
        let material = try TestKeyMaterial.make(algorithm)

        let key = try await store.importKey(material, comment: "  laptop key \n", signingPolicy: .whileUnlocked)

        #expect(key.kind == .imported(algorithm))
        #expect(key.kind.isImported)
        #expect(key.comment == "laptop key")
        #expect(key.publicKey.algorithm == algorithm)
        #expect(Array(key.publicKey.wireRepresentation) == material.publicKey)
        #expect(try store.keys() == [key])
        let data = Data("session identifier and sign-in request".utf8)
        let signature = try await store.sign(data, with: key.id, flags: .rsaSHA512)
        #expect(try verify(signature, of: data, by: key))
        #expect(try !verify(signature, of: Data("something else".utf8), by: key))
    }

    /// The private key goes into the Keychain behind the user's presence, as an Ed25519 key's does,
    /// and is the material's bytes.
    @Test(arguments: SSHKeyAlgorithm.allCases)
    func privateKeyIsAKeychainItemThatNeedsTheUsersPresence(algorithm: SSHKeyAlgorithm) async throws {
        try await window.open(reason: "Unlock Shello")
        let material = try TestKeyMaterial.make(algorithm)

        let key = try await store.importKey(material, comment: "a", signingPolicy: .whileUnlocked)

        #expect(items.items.requiresUserPresence(key.id) == true)
        let stored = try #require(items.items.keyData(of: key.id, context: LAContext()))
        let storedBytes = unsafe stored.withUnsafeBytes { unsafe Array($0) }
        let privateKey = unsafe material.privateKey.withUnsafeBytes { unsafe Array($0) }
        #expect(storedBytes == privateKey)
    }

    /// The flags of the SSH agent's sign request choose an RSA key's hash (RFC 8332); with neither,
    /// the request asks for SHA-1, which Shello never signs with, before anyone is asked anything.
    @Test func rsaKeySignsWithTheHashTheFlagsAskFor() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.importKey(try TestKeyMaterial.make(.rsa), comment: "a", signingPolicy: .everyUse)
        let data = Data("sign-in request".utf8)
        let prompts = authentication.promptCount

        let sha256 = try ParsedSSHSignature(try await store.sign(data, with: key.id, flags: .rsaSHA256))
        let sha512 = try ParsedSSHSignature(try await store.sign(data, with: key.id, flags: .rsaSHA512))
        // OpenSSH's agent reads SHA-256's flag first.
        let both = try ParsedSSHSignature(try await store.sign(data, with: key.id, flags: [.rsaSHA256, .rsaSHA512]))

        #expect(sha256.algorithm == "rsa-sha2-256")
        #expect(sha512.algorithm == "rsa-sha2-512")
        #expect(both.algorithm == "rsa-sha2-256")
        let publicKey = try ParsedOpenSSHLine(key.openSSHPublicKey).rsaPublicKey()
        #expect(try sha256.isValidRSASignature(for: data, by: publicKey))
        #expect(try sha512.isValidRSASignature(for: data, by: publicKey))
        // As long as the modulus: 2048 bits.
        #expect(sha512.blob.count == 256)
        #expect(authentication.promptCount == prompts + 3)

        await #expect(throws: SSHKeyError.rsaSHA1Refused) { try await store.sign(data, with: key.id) }
        #expect(authentication.promptCount == prompts + 3)
    }

    /// ECDSA P-384 signs with SHA-384, as `ecdsa-sha2-nistp384` requires (RFC 5656).
    @Test func p384KeySignsAsECDSASHA2NISTP384() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.importKey(
            try TestKeyMaterial.make(.ecdsaP384), comment: "a", signingPolicy: .whileUnlocked)
        let data = Data("sign-in request".utf8)

        let signature = try ParsedSSHSignature(try await store.sign(data, with: key.id))

        #expect(signature.algorithm == "ecdsa-sha2-nistp384")
        let (r, s) = try signature.ecdsaMPInts()
        #expect(r.drop { $0 == 0 }.count <= 48 && s.drop { $0 == 0 }.count <= 48)
        let publicKey = try ParsedOpenSSHLine(key.openSSHPublicKey).p384PublicKey()
        #expect(publicKey.isValidSignature(try signature.p384Signature(), for: SHA384.hash(data: data)))
    }

    /// The signing policies are an imported key's too: on every use, each signature asks.
    @Test func everyUseImportedKeyAsksForEachSignature() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.importKey(
            try TestKeyMaterial.make(.ed25519), comment: "work", signingPolicy: .everyUse)
        let prompts = authentication.promptCount

        _ = try await store.sign(Data([1]), with: key.id, reason: "Sign in to nas.")
        _ = try await store.sign(Data([2]), with: key.id)

        #expect(authentication.promptCount == prompts + 2)
        #expect(authentication.reasons.suffix(2) == ["Sign in to nas.", "Sign in with the SSH key “work”."])
    }

    /// While app lock is engaged nothing is imported, and a key that signs while Shello is unlocked
    /// waits for the next unlock.
    @Test func importingAndSigningNeedTheUnlockWindow() async throws {
        let material = try TestKeyMaterial.make(.ecdsaP256)
        await #expect(throws: UnlockWindowClosed.self) {
            try await store.importKey(material, comment: "a", signingPolicy: .whileUnlocked)
        }
        try await window.open(reason: "Unlock Shello")
        let key = try await store.importKey(material, comment: "a", signingPolicy: .whileUnlocked)
        window.close()

        await #expect(throws: UnlockWindowClosed.self) { try await store.sign(Data([1]), with: key.id) }
        #expect(throws: UnlockWindowClosed.self) { try store.signingKey(id: key.id) }
    }

    /// A private key that is not the public key's, or that Apple's frameworks cannot read, is not
    /// imported.
    @Test(arguments: SSHKeyAlgorithm.allCases)
    func keyWhosePrivateKeyIsNotItsPublicKeysIsRefused(algorithm: SSHKeyAlgorithm) async throws {
        try await window.open(reason: "Unlock Shello")
        let material = try TestKeyMaterial.make(algorithm)
        let other = try TestKeyMaterial.make(algorithm)
        let mismatched = ImportedKeyMaterial(
            algorithm: algorithm, publicKey: other.publicKey, privateKey: material.privateKey)
        let garbage = ImportedKeyMaterial(
            algorithm: algorithm, publicKey: material.publicKey, privateKey: TestKeyBytes([1, 2, 3]))

        await #expect(throws: SSHKeyError.mismatchedKeyPair) {
            try await store.importKey(mismatched, comment: "a", signingPolicy: .whileUnlocked)
        }
        await #expect(throws: SSHKeyError.mismatchedKeyPair) {
            try await store.importKey(garbage, comment: "a", signingPolicy: .whileUnlocked)
        }
        await #expect(throws: SSHKeyError.invalidComment) {
            try await store.importKey(material, comment: "two\nlines", signingPolicy: .whileUnlocked)
        }
        #expect(try store.keys().isEmpty)
    }

    /// Shello makes no imported keys.
    @Test func importedKindIsNotMade() async throws {
        try await window.open(reason: "Unlock Shello")
        await #expect(throws: SSHKeyError.cannotMake(.imported(.rsa))) {
            try await store.generate(.imported(.rsa), comment: "a", signingPolicy: .whileUnlocked)
        }
    }

    /// An RSA key's public key says how many bits its modulus has.
    @Test func rsaPublicKeyCountsItsBits() throws {
        let material = try TestKeyMaterial.make(.rsa)
        let publicKey = SSHPublicKey(algorithm: .rsa, wireRepresentation: Data(material.publicKey))

        #expect(publicKey.rsaBits == 2048)
        #expect(SSHPublicKey(Curve25519.Signing.PrivateKey().publicKey).rsaBits == nil)
    }

    /// The record of each kind of imported key round-trips through the item's attributes, and an
    /// imported key whose algorithm this version does not know is left out.
    @Test(arguments: SSHKeyAlgorithm.allCases)
    func importedRecordRoundTrips(algorithm: SSHKeyAlgorithm) throws {
        let material = try TestKeyMaterial.make(algorithm)
        let key = SSHKey(
            id: UUID(), comment: "laptop", kind: .imported(algorithm), signingPolicy: .everyUse,
            publicKey: SSHPublicKey(algorithm: algorithm, wireRepresentation: Data(material.publicKey)),
            createdAt: Date(timeIntervalSinceReferenceDate: 814_000_000))
        var record = KeyRecord(key)
        let attributes: [String: Any] = [
            kSecAttrAccount as String: key.id.uuidString,
            kSecAttrGeneric as String: try SystemKeyItems.encoder.encode(record),
        ]

        #expect(SystemKeyItems.record(in: attributes)?.key == key)
        #expect(record.kind == "imported")

        record.algorithm = "ssh-xmss"
        #expect(record.key == nil)
        record.algorithm = nil
        #expect(record.key == nil)
    }

    /// The SSH agent signs with imported keys of each kind, as libssh asks it: an RSA key with the
    /// flags for SHA-512 (4) and SHA-256 (2), and never without either.
    @Test func agentSignsWithImportedKeys() async throws {
        try await window.open(reason: "Unlock Shello")
        let p384 = try await store.importKey(
            try TestKeyMaterial.make(.ecdsaP384), comment: "p384", signingPolicy: .whileUnlocked)
        let rsa = try await store.importKey(
            try TestKeyMaterial.make(.rsa), comment: "rsa", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [p384, rsa])
        let data = Array("sign-in request".utf8)

        let identities = await agent.answer([11])
        #expect(
            identities
                == SSHAgentReply.identities([
                    SSHAgentIdentity(keyBlob: Array(p384.publicKey.wireRepresentation), comment: "p384"),
                    SSHAgentIdentity(keyBlob: Array(rsa.publicKey.wireRepresentation), comment: "rsa"),
                ]).message)
        #expect(
            try signatureAlgorithm(await agent.answer(Self.signRequest(p384, data, flags: 0))) == "ecdsa-sha2-nistp384")
        #expect(try signatureAlgorithm(await agent.answer(Self.signRequest(rsa, data, flags: 4))) == "rsa-sha2-512")
        #expect(try signatureAlgorithm(await agent.answer(Self.signRequest(rsa, data, flags: 2))) == "rsa-sha2-256")
        #expect(await agent.answer(Self.signRequest(rsa, data, flags: 0)) == [5])
        #expect(agent.signingFailure as? SSHKeyError == .rsaSHA1Refused)
    }

    // MARK: - Helpers

    /// Whether `signature`, in SSH's wire format, is `key`'s signature of `data`, as a server checks
    /// it: with the public key as SSH sends it.
    private func verify(_ signature: Data, of data: Data, by key: SSHKey) throws -> Bool {
        let line = try ParsedOpenSSHLine(key.openSSHPublicKey)
        let parsed = try ParsedSSHSignature(signature)
        guard parsed.isMade(by: line) else { return false }
        switch key.kind.algorithm {
        case .ecdsaP256: return try line.p256PublicKey().isValidSignature(try parsed.ecdsaSignature(), for: data)
        case .ecdsaP384: return try line.p384PublicKey().isValidSignature(try parsed.p384Signature(), for: data)
        case .ed25519: return try line.ed25519PublicKey().isValidSignature(parsed.blob, for: data)
        case .rsa: return try parsed.isValidRSASignature(for: data, by: try line.rsaPublicKey())
        }
    }

    /// The algorithm of the signature in a sign response.
    private func signatureAlgorithm(_ reply: [UInt8]) throws -> String {
        guard reply.first == 14 else { return "failure \(reply)" }
        var reader = SSHReader(Data(reply.dropFirst()))
        return try ParsedSSHSignature(try reader.readString()).algorithm
    }

    private static func signRequest(_ key: SSHKey, _ data: [UInt8], flags: UInt32) -> [UInt8] {
        var writer = SSHAgentWriter()
        writer.write(UInt8(13))
        writer.writeString(Array(key.publicKey.wireRepresentation))
        writer.writeString(data)
        writer.write(flags)
        return writer.bytes
    }
}

/// Imported keys' material as ShelloSSH hands it over, made here: CryptoKit's raw representations,
/// and a new 2048-bit RSA key from Security, in PKCS #1's DER.
enum TestKeyMaterial {
    static func make(_ algorithm: SSHKeyAlgorithm) throws -> ImportedKeyMaterial {
        switch algorithm {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            return material(algorithm, SSHPublicKey(key.publicKey), key.rawRepresentation)
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            return material(algorithm, SSHPublicKey(key.publicKey), key.rawRepresentation)
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            return material(algorithm, SSHPublicKey(key.publicKey), key.rawRepresentation)
        case .rsa:
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
            ]
            var error: Unmanaged<CFError>?
            guard let key = unsafe SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                let der = unsafe SecKeyCopyExternalRepresentation(key, &error) as Data?
            else { throw unsafe error!.takeRetainedValue() as any Error }
            return material(algorithm, try RSAKey.publicKey(of: key), der)
        }
    }

    private static func material(
        _ algorithm: SSHKeyAlgorithm, _ publicKey: SSHPublicKey, _ privateKey: Data
    ) -> ImportedKeyMaterial {
        ImportedKeyMaterial(
            algorithm: algorithm, publicKey: Array(publicKey.wireRepresentation), privateKey: TestKeyBytes(privateKey))
    }
}

/// A private key's bytes for the tests, followed by a zero byte as `SecretBytes` promises.
final class TestKeyBytes: SecretBytes {
    private let bytes: [UInt8]

    init(_ bytes: some Collection<UInt8>) {
        self.bytes = Array(bytes) + [0]
    }

    func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let result: Swift.Result<Result, Failure> = unsafe bytes.withUnsafeBytes { buffer in
            do throws(Failure) {
                return .success(try unsafe body(UnsafeRawBufferPointer(rebasing: buffer.dropLast())))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}
