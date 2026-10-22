import ShelloSSH
import ShelloSecurity
import SwiftUI

/// The server's keyboard-interactive questions (README section 4): a password, a one-time code, or
/// whatever else it asks, any number at once, and round after round. Each answer is hidden or shown
/// as the server says: a password stays hidden, a one-time code often shows. Sign In sends the
/// answers and waits for the server, which may ask again; Cancel stops signing in, at any time.
///
/// The text comes from the server, which is why the sheet says so, and why VoiceOver reads each
/// question as the field's label. VoiceOver moves to each new round, and to the wait between rounds,
/// since the sheet stays while its content changes. The answers go to the server only: Shello keeps
/// none of them.
struct SignInSheet: View {
    /// The round to answer, or nil while the server checks the last answers.
    let question: HostTerminalModel.SignInQuestion?
    let hostName: String
    let answer: ([Secret]) -> Void
    let cancel: () -> Void
    @AccessibilityFocusState private var isWaitFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let question {
                    SignInQuestions(question: question, answer: answer)
                        // A new round starts with empty fields.
                        .id(question.id)
                } else {
                    ProgressView {
                        Text("Signing in to \(hostName)…")
                            .font(Typography.body)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.ground)
                    .accessibilityFocused($isWaitFocused)
                    .onAppear { isWaitFocused = true }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
            // Signing in stops only through Cancel, never by a swipe that missed: VoiceOver's escape
            // gesture is Cancel too.
            .accessibilityAction(.escape, cancel)
        }
        .interactiveDismissDisabled()
    }
}

/// One round of questions, each with its field, and Sign In.
private struct SignInQuestions: View {
    let question: HostTerminalModel.SignInQuestion
    let answer: ([Secret]) -> Void
    @State private var answers: [String]
    @FocusState private var focus: Int?
    @AccessibilityFocusState private var accessibilityFocus: Element?

    /// Where VoiceOver goes when a round appears: what the server says about it, or else its first
    /// question.
    private enum Element: Hashable {
        case introduction
        case field(Int)
    }

    init(question: HostTerminalModel.SignInQuestion, answer: @escaping ([Secret]) -> Void) {
        self.question = question
        self.answer = answer
        _answers = State(initialValue: Array(repeating: "", count: question.challenge.prompts.count))
    }

    private var challenge: KeyboardInteractiveChallenge { question.challenge }

    var body: some View {
        List {
            if !challenge.name.isEmpty || !challenge.instruction.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        if !challenge.name.isEmpty {
                            Text(challenge.name)
                                .font(Typography.rowTitle)
                        }
                        if !challenge.instruction.isEmpty {
                            Text(challenge.instruction)
                        }
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($accessibilityFocus, equals: .introduction)
                }
                .listRowBackground(Palette.cell)
            }

            Section {
                ForEach(Array(challenge.prompts.enumerated()), id: \.offset) { index, prompt in
                    field(for: prompt, at: index)
                }
            } footer: {
                FooterText(
                    "\(question.server.description) asks \(challenge.prompts.count == 1 ? "this" : "these") before it "
                        + "lets you in. Shello sends your answers to it, and keeps none of them.")
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sign In", systemImage: "checkmark", role: .confirm, action: send)
                    .prominentToolbarButton()
            }
        }
        .onAppear {
            focus = 0
            let hasIntroduction = !challenge.name.isEmpty || !challenge.instruction.isEmpty
            accessibilityFocus = hasIntroduction ? .introduction : .field(0)
        }
    }

    /// The question above its field, which hides or shows the answer as the server asks.
    private func field(for prompt: KeyboardInteractivePrompt, at index: Int) -> some View {
        let label = prompt.spokenText
        let isLast = index == challenge.prompts.count - 1
        return VStack(alignment: .leading, spacing: 6) {
            // The field carries the question for VoiceOver.
            Text(prompt.text)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityHidden(true)
            // No placeholder: the question is above the field, and a long one in the field would be
            // cut off at large text sizes.
            Group {
                if prompt.showsAnswer {
                    TextField(label, text: $answers[index], prompt: Text(""))
                } else {
                    SecureField(label, text: $answers[index], prompt: Text(""))
                }
            }
            .textContentType(prompt.contentType)
            .accessibilityLabel(label)
            .accessibilityHint(prompt.showsAnswer ? "The answer shows as you type it." : "")
            // Voice Control: a long question is too long to say, so the field answers to its last
            // line and to its number too.
            .accessibilityInputLabels([prompt.shortLabel, "Answer \(index + 1)"])
            .accessibilityAction(named: "Copy Question") {
                UIPasteboard.general.string = prompt.text
                announce("Copied")
            }
            .accessibilityFocused($accessibilityFocus, equals: .field(index))
            .font(Typography.data)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: index)
            .submitLabel(isLast ? .go : .next)
            .onSubmit {
                if isLast {
                    send()
                } else {
                    focus = index + 1
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Hands the answers over as secrets, and forgets them here.
    private func send() {
        let secrets = answers.map { Secret(utf8: $0) }
        answers = answers.map { _ in "" }
        focus = nil
        answer(secrets)
    }
}

extension KeyboardInteractivePrompt {
    /// The question as a field's label: without the colon and space that end most prompts, such as
    /// "Password: ", which VoiceOver would read out. A question that is all punctuation stays.
    var spokenText: String {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "Answer" : trimmed
    }

    /// The last line of the question, for Voice Control: the question itself, after what the
    /// server says before it.
    var shortLabel: String {
        spokenText.split(separator: "\n").last.map(String.init) ?? spokenText
    }

    /// What AutoFill offers for the answer, from the question's words: a one-time code from Messages
    /// for a code, a password, a user name, or nothing for anything else.
    var contentType: UITextContentType? {
        let words = Set(shortLabel.lowercased().split { !$0.isLetter && $0 != "-" }.map(String.init))
        if !words.isDisjoint(with: ["code", "token", "otp", "one-time", "passcode", "pin"]) {
            return .oneTimeCode
        }
        if !words.isDisjoint(with: ["password", "passphrase"]) {
            return .password
        }
        if !words.isDisjoint(with: ["user", "username", "login"]) {
            return .username
        }
        return nil
    }
}
