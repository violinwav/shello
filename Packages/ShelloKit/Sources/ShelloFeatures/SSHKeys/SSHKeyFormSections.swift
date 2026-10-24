import ShelloSecurity
import SwiftUI

// The sections the new SSH key sheet and the import sheet share.

/// A key's name, as the new key sheet and the import sheet check it.
enum SSHKeyName {
    /// Why a private key is not taken as the name, and what to do instead.
    static let privateKeyProblem = "That’s a private key. Enter a name instead."

    /// Whether `text` holds a private key, pasted in the wrong field. The name goes at the end of the
    /// public key, which is copied, shared and installed on servers, so it must never hold one.
    static func holdsPrivateKey(_ text: String) -> Bool {
        text.contains("PRIVATE KEY-----") || text.contains("PuTTY-User-Key-File-")
    }
}

/// The key's name, which goes at the end of its public key. The field wraps, so that a long name stays
/// readable at large text sizes, but the name stays on one line: Return puts the keyboard away instead
/// of starting a new line, and a pasted line break goes. A pasted private key does not go in at all.
struct SSHKeyNameSection: View {
    @Binding var name: String
    /// What is wrong with the name, once the user has tried to make or import the key.
    let problem: String?
    let isFocused: FocusState<Bool>.Binding
    /// How many times a private key was pasted into the field and left out; each time redraws the
    /// field with the name it had.
    @State private var refusedKeys = 0
    /// Whether the last change to the field was a private key, which it left out.
    @State private var refusedKey = false

    var body: some View {
        let problem = refusedKey ? SSHKeyName.privateKeyProblem : self.problem
        Section {
            VStack(alignment: .leading, spacing: 6) {
                // Names such as "deploy@ci" are identifiers, which autocorrection would change.
                TextField("Name", text: oneLine, prompt: Text("required"), axis: .vertical)
                    .id(refusedKeys)
                    .accessibilityLabel("Name")
                    .accessibilityHint(problem ?? "")
                    .font(Typography.data)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(isFocused)
                    .submitLabel(.done)
                    .onSubmit { isFocused.wrappedValue = false }
                if let problem {
                    ProblemText(problem: problem)
                }
            }
        } header: {
            SectionHeader("Name")
        } footer: {
            FooterText(
                "The name goes at the end of the public key, so that a server’s authorized_keys shows whose key it is.")
        }
        .listRowBackground(Palette.cell)
    }

    private var oneLine: Binding<String> {
        Binding {
            name
        } set: { newName in
            // The field is made anew, without the key's text or its undo.
            guard !SSHKeyName.holdsPrivateKey(newName) else {
                refusedKey = true
                refusedKeys += 1
                isFocused.wrappedValue = false
                announce(SSHKeyName.privateKeyProblem)
                return
            }
            refusedKey = false
            guard newName.contains(where: \.isNewline) else {
                name = newName
                return
            }
            name = newName.filter { !$0.isNewline }
            isFocused.wrappedValue = false
        }
    }
}

/// When the key may sign (README section 13). "Every use" comes with a warning that every reconnect
/// asks, which VoiceOver hears as the choice changes.
struct SigningPolicySection: View {
    @Binding var policy: SigningPolicy
    @Environment(\.appLock) private var appLock

    var body: some View {
        Section {
            Picker("Signing", selection: $policy) {
                ForEach(SigningPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            SectionHeader("Signing")
        } footer: {
            switch policy {
            case .whileUnlocked:
                FooterText("The key signs without asking again once you’ve unlocked Shello with \(biometry).")
            case .everyUse:
                // An icon and a sentence, not only a colour.
                Label(everyUseWarning, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.row)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .listRowBackground(Palette.cell)
        // The warning replaces the footer while VoiceOver is still on the choice.
        .onChange(of: policy) { _, policy in
            if policy == .everyUse { announce(everyUseWarning, priority: .low) }
        }
    }

    /// README section 13: the UI warns that "every use" makes every reconnect prompt.
    private var everyUseWarning: String {
        "Every connection and every reconnect with this key asks for \(biometry)."
    }

    /// What the device asks for, as app lock knows it.
    private var biometry: String {
        appLock?.biometry.inSentence ?? "Face ID or Touch ID"
    }
}
