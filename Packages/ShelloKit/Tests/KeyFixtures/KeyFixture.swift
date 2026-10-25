import Foundation

/// SSH keys that `ssh-keygen` made for Shello's tests of importing SSH keys (make-fixtures.sh): test
/// fixtures only, public in this repository, never anyone's own key, never to be used anywhere else.
/// The test servers let their test user in with the keys the tests sign in with
/// (TestServers/keys/import_fixtures.pub).
public enum KeyFixture {
    /// The passphrase of every encrypted fixture.
    public static let passphrase = "shello-fixture-passphrase"

    /// The text of the fixture file `name` in Keys/, such as `ed25519-openssh` or `rsa-3072.pub`.
    public static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Keys"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("There is no key fixture \(name)") }
        return text
    }

    /// The keys the tests import and sign in with, each in every format it comes in.
    public enum Key: String, CaseIterable, Hashable, Sendable {
        case ed25519
        case ecdsaP256 = "ecdsa-p256"
        case ecdsaP384 = "ecdsa-p384"
        case rsa3072 = "rsa-3072"

        /// The public key, as its `.pub` file holds it, without the line break.
        public var publicKeyLine: String {
            KeyFixture.text("\(rawValue).pub").trimmingCharacters(in: .newlines)
        }

        /// The formats the key comes in: all three, except for Ed25519, which has no traditional PEM.
        public var formats: [Variant.Format] {
            self == .ed25519 ? [.openSSH, .pkcs8] : Variant.Format.allCases
        }

        /// The key in each of its formats, plain and encrypted.
        public var variants: [Variant] {
            formats.flatMap { format in
                [false, true].map { Variant(key: self, format: format, isEncrypted: $0) }
            }
        }
    }

    /// One of the keys in one of its formats, plain or encrypted with `KeyFixture.passphrase`.
    public struct Variant: Hashable, Sendable, CustomStringConvertible {
        public enum Format: String, CaseIterable, Hashable, Sendable {
            /// OpenSSH's own format.
            case openSSH = "openssh"
            /// PEM, OpenSSL's traditional format, as `ssh-keygen -m PEM` writes it.
            case pem
            /// PKCS #8, as `ssh-keygen -m PKCS8` writes it.
            case pkcs8
        }

        public let key: Key
        public let format: Format
        public let isEncrypted: Bool

        public init(key: Key, format: Format, isEncrypted: Bool) {
            self.key = key
            self.format = format
            self.isEncrypted = isEncrypted
        }

        /// The fixture's file name, such as `ecdsa-p384-pkcs8-encrypted`.
        public var name: String {
            "\(key.rawValue)-\(format.rawValue)" + (isEncrypted ? "-encrypted" : "")
        }

        public var text: String { KeyFixture.text(name) }

        public var description: String { name }
    }

    /// Every variant of every key the tests sign in with.
    public static var variants: [Variant] {
        Key.allCases.flatMap(\.variants)
    }
}
