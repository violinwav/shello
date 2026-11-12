import Foundation
import ShelloSecurity
import Testing

@testable import ShelloFeatures

/// The SSH keys in Settings: the list, the new key sheet and a key's details (README section 13).
@Suite(.timeLimit(.minutes(1)))
struct SSHKeyListModelTests {
    let keys = TestKeys()

    @Test func listShowsTheKeysByName() async throws {
        let work = try await keys.make("work", kind: .secureEnclave)
        let homelab = try await keys.make("homelab")
        let model = SSHKeyListModel(store: keys.store)

        model.load()

        #expect(model.keys == [homelab, work])
        #expect(model.hasLoaded)
        #expect(model.loadError == nil)
    }

    @Test func listIsEmptyBeforeTheFirstKey() {
        let model = SSHKeyListModel(store: keys.store)
        #expect(!model.hasLoaded)

        model.load()

        #expect(model.hasLoaded)
        #expect(model.keys.isEmpty)
    }

    @Test func deletingAKeyTakesItOffTheList() async throws {
        let work = try await keys.make("work")
        let homelab = try await keys.make("homelab")
        let model = SSHKeyListModel(store: keys.store)
        model.load()

        #expect(model.delete(work))

        #expect(model.keys == [homelab])
        #expect(try keys.store.keys() == [homelab])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct NewSSHKeyModelTests {
    /// README section 13: the default is ECDSA P-256 inside the Secure Enclave.
    @Test func secureEnclaveKeyIsTheDefaultWhereTheDeviceMakesOne() {
        let model = NewSSHKeyModel(store: TestKeys(secureEnclave: true).store, suggestedName: "Shello on iPhone")

        #expect(model.kind == .secureEnclave)
        #expect(model.kinds == [.secureEnclave, .ed25519])
        #expect(model.offersKinds)
        #expect(model.signingPolicy == .whileUnlocked)
        #expect(model.name == "Shello on iPhone")
    }

    /// As in the iOS Simulator: only Ed25519, and no choice to make.
    @Test func keyIsEd25519WhereTheDeviceMakesNoSecureEnclaveKeys() {
        let model = NewSSHKeyModel(store: TestKeys(secureEnclave: false).store, suggestedName: "Shello on iPhone")

        #expect(model.kind == .ed25519)
        #expect(model.kinds == [.ed25519])
        #expect(!model.offersKinds)
    }

    /// Keys made with the suggested name can still be told apart, in lists and by VoiceOver.
    @Test func suggestedNameIsOneNoKeyHasYet() async throws {
        let keys = TestKeys()
        _ = try await keys.make("Shello on iPhone")
        _ = try await keys.make("Shello on iPhone 2")

        let model = NewSSHKeyModel(store: keys.store, suggestedName: "Shello on iPhone")

        #expect(model.name == "Shello on iPhone 3")
    }

    @Test(arguments: [SSHKey.Kind.secureEnclave, .ed25519])
    func creatingMakesTheKeyAsChosen(kind: SSHKey.Kind) async throws {
        let keys = TestKeys()
        let model = NewSSHKeyModel(store: keys.store, suggestedName: "Shello on iPhone")
        model.name = " deploy@ci "
        model.kind = kind
        model.signingPolicy = .everyUse

        let key = try #require(await model.create())

        #expect(key.comment == "deploy@ci")
        #expect(key.kind == kind)
        #expect(key.signingPolicy == .everyUse)
        #expect(try keys.store.keys() == [key])
        #expect(model.createError == nil)
    }

    @Test(arguments: [("", "Enter a name."), ("  ", "Enter a name."), ("two\nlines", "Enter the name on one line.")])
    func nameWithAProblemMakesNoKeyAndSaysWhy(name: String, problem: String) async throws {
        let keys = TestKeys()
        let model = NewSSHKeyModel(store: keys.store, suggestedName: "Shello on iPhone")
        model.name = name
        // Not before the user tries to make the key.
        #expect(model.visibleNameProblem == nil)

        #expect(await model.create() == nil)

        #expect(model.visibleNameProblem == problem)
        #expect(try keys.store.keys().isEmpty)
    }

    @Test func failureSaysWhy() async throws {
        let keys = TestKeys()
        keys.window.close()
        let model = NewSSHKeyModel(store: keys.store, suggestedName: "Shello on iPhone")

        #expect(await model.create() == nil)

        #expect(model.createError != nil)
        #expect(!model.isCreating)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SSHKeyDetailModelTests {
    let keys = TestKeys()

    /// What `authorized_keys` takes: the public key line, with no line break after it.
    @Test func copyingPutsThePublicKeyLineOnTheClipboard() async throws {
        let key = try await keys.make("deploy@ci")
        var clipboard: [String] = []
        let model = SSHKeyDetailModel(store: keys.store, key: key) { clipboard.append($0) }
        #expect(!model.hasCopied)

        model.copyPublicKey()

        #expect(clipboard == [key.openSSHPublicKey])
        #expect(clipboard[0].hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        #expect(clipboard[0].hasSuffix(" deploy@ci"))
        #expect(model.hasCopied)
    }

    @Test func deletingRemovesTheKey() async throws {
        let key = try await keys.make("deploy@ci")
        let model = SSHKeyDetailModel(store: keys.store, key: key) { _ in }

        #expect(model.delete())

        #expect(try keys.store.keys().isEmpty)
        #expect(model.actionError == nil)
    }
}
