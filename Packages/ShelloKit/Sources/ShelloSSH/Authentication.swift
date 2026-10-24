import CLibSSH
import Foundation

/// The ways of signing in that a server takes (RFC 4252 section 5.1), as it lists them when it
/// refuses a sign-in or accepts it only partly.
public struct SSHAuthenticationMethods: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let password = SSHAuthenticationMethods(rawValue: SSH_AUTH_METHOD_PASSWORD)
    public static let publicKey = SSHAuthenticationMethods(rawValue: SSH_AUTH_METHOD_PUBLICKEY)
    public static let keyboardInteractive = SSHAuthenticationMethods(rawValue: SSH_AUTH_METHOD_INTERACTIVE)
    public static let hostBased = SSHAuthenticationMethods(rawValue: SSH_AUTH_METHOD_HOSTBASED)
    public static let gssapi = SSHAuthenticationMethods(rawValue: SSH_AUTH_METHOD_GSSAPI_MIC)

    /// The methods as SSH names them, such as `publickey` and `keyboard-interactive`.
    public var names: [String] {
        let all: [(SSHAuthenticationMethods, String)] = [
            (.publicKey, "publickey"), (.password, "password"), (.keyboardInteractive, "keyboard-interactive"),
            (.hostBased, "hostbased"), (.gssapi, "gssapi-with-mic"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

/// One round of keyboard-interactive sign-in (RFC 4256): the server's questions, such as a password
/// or a one-time code, which the user answers all at once. A server can ask any number of rounds,
/// and any number of questions in each.
///
/// The text comes from the server, so it is untrusted: control characters other than line breaks
/// and tabs are removed, and each text is cut at `maximumTextLength` characters.
public struct KeyboardInteractiveChallenge: Hashable, Sendable {
    /// What the server calls the round, such as "Two-factor sign-in", or empty.
    public let name: String
    /// What the server says about the questions, or empty.
    public let instruction: String
    /// The questions, in the server's order, to be answered in the same order.
    public let prompts: [KeyboardInteractivePrompt]

    public init(name: String, instruction: String, prompts: [KeyboardInteractivePrompt]) {
        self.name = Self.displayable(name)
        self.instruction = Self.displayable(instruction)
        self.prompts = prompts
    }

    /// How long a text from the server may be: longer ones are cut.
    public static let maximumTextLength = 1000

    /// `text` without the control characters that could move or hide what is shown around it,
    /// with line breaks as `\n`, without surrounding whitespace, and at most `maximumTextLength`
    /// characters long.
    static func displayable(_ text: String) -> String {
        let normalized = text.replacing("\r\n", with: "\n")
        let scalars = normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !Self.isControl(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(maximumTextLength))
    }

    /// C0 and C1 controls, and the format characters that reorder text (bidirectional overrides and
    /// isolates), which could make a prompt read as something else.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: true
        case .format: (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        default: false
        }
    }
}

/// One question of keyboard-interactive sign-in.
public struct KeyboardInteractivePrompt: Hashable, Sendable {
    /// The question as the server words it, such as "Password:" or "Verification code:".
    public let text: String
    /// Whether the answer is shown as it is typed. Servers hide passwords, and often show one-time
    /// codes.
    public let showsAnswer: Bool

    public init(text: String, showsAnswer: Bool) {
        self.text = KeyboardInteractiveChallenge.displayable(text)
        self.showsAnswer = showsAnswer
    }
}
