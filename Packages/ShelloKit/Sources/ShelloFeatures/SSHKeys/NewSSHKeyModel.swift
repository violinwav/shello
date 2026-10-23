import Foundation
import Observation
import ShelloSecurity

/// The new SSH key sheet: the key's name, its kind and its signing policy (README section 13). A
/// Secure Enclave key is the default where the device can make one; elsewhere, as in the iOS
/// Simulator, the key is Ed25519.
@Observable
final class NewSSHKeyModel {
    let store: SSHKeyStore
    /// The key's name, which ends its public key as the comment.
    var name: String
    var kind: SSHKey.Kind
    var signingPolicy = SigningPolicy.standard
    /// Set when making the key fails; the sheet shows it and clears it.
    var createError: String?
    private(set) var isCreating = false
    private var attemptedCreate = false

    /// A new key named `suggestedName`, or "\(suggestedName) 2" and so on if a key has that name,
    /// until the user names it otherwise.
    init(store: SSHKeyStore, suggestedName: String) {
        self.store = store
        let taken = Set((try? store.keys())?.map(\.comment) ?? [])
        name = Self.unused(suggestedName, taken: taken)
        kind = store.kinds.first ?? .ed25519
    }

    /// `name`, or the first of "name 2", "name 3" and so on that is not in `taken`, so that keys
    /// made with the suggested name can still be told apart.
    static func unused(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    /// The kinds the device can make, the default first.
    var kinds: [SSHKey.Kind] { store.kinds }

    /// Whether the user can choose the kind: only where the Secure Enclave can make keys too.
    var offersKinds: Bool { kinds.count > 1 }

    /// What is wrong with the name, as a sentence that says how to fix it.
    var nameProblem: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Enter a name."
        }
        if SSHKeyName.holdsPrivateKey(name) {
            return SSHKeyName.privateKeyProblem
        }
        if !SSHKey.isValidComment(name) {
            return "Enter the name on one line."
        }
        return nil
    }

    /// The problem with the name, once the user has tried to make the key.
    var visibleNameProblem: String? {
        attemptedCreate ? nameProblem : nil
    }

    /// Makes the key, and returns it; nil if the name has a problem, which is then shown, or if
    /// making it fails, which `createError` says.
    func create() async -> SSHKey? {
        attemptedCreate = true
        guard nameProblem == nil, !isCreating else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            return try await store.generate(kind, comment: name, signingPolicy: signingPolicy)
        } catch {
            SSHKeyListModel.logger.error("Could not make an SSH key: \(error)")
            createError = String(describing: error)
            return nil
        }
    }
}
