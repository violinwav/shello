import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTmux

/// Installing an SSH key on a host (GLOSSARY, README section 13), as `ssh-copy-id` does: its public
/// key goes into `~/.ssh/authorized_keys` of the user the connection signed in as, over a hidden
/// channel of a connection that is open, such as a tab's. `~/.ssh` and the file are made if they are
/// missing, readable by that user only (700 and 600); what is there already keeps its modes. A key
/// that the file has already, whatever its options or comment, is not added again.
///
/// The server's login shell is unknown, and may be fish or csh, which read a command otherwise than
/// sh does. So the command is the one `ssh-copy-id` sends, `exec sh -c '…'`, on one line, which every
/// shell passes on to sh as it is: nothing in it is a single quote, a backslash before a quote, an
/// exclamation mark or a line break. The script in it is POSIX sh, and the key's line reaches the file
/// through `printf`, every byte of it that is not plainly safe written as an octal escape, so that no
/// shell reads anything of the key's comment, whatever the user named the key.
public enum AuthorizedKeys {
    /// Installs `key` on the server `channels` reach, and says whether it added it or found it there.
    /// - Throws: `KeyInstallationError` when the command fails on the server, as when its home
    ///   directory cannot be written; the `SSHError` of the connection; or `CancellationError`.
    public static func install(_ key: SSHKey, on channels: some HiddenChannels) async throws -> KeyInstallation {
        let blob = key.publicKey.wireRepresentation.base64EncodedString()
        let result = try await channels.run(command(installing: key.openSSHPublicKey, blob: blob))
        return try installation(from: result)
    }

    /// What `exec sh -c` runs, on the server, for the line `line` of `authorized_keys`, whose key in
    /// base64 is `blob`:
    /// 1. In the home directory, with a umask that leaves new files to their owner, `.ssh` and
    ///    `authorized_keys` in it are made if they are missing.
    /// 2. If a line that is not a comment has the key already, nothing changes.
    /// 3. Otherwise the line is added, after a line break if the file does not end with one.
    /// 4. Where SELinux is, `restorecon` gives both their label, as `ssh-copy-id` does, and its failure
    ///    changes nothing.
    /// 5. The last line of output says which: `addedMarker`, or `presentMarker`.
    ///
    /// The script holds no single quote, and is one line.
    static func script(installing line: String, blob: String) -> String {
        precondition(blob.allSatisfy(isBase64), "The key's base64 is base64")
        return [
            "cd && umask 077 && mkdir -p .ssh && cd .ssh && touch authorized_keys",
            #"if grep -v -e "^[[:space:]]*#" authorized_keys | grep -q -F -e "\#(blob)"; then r=\#(presentMarker); "#
                + #"else { if [ -s authorized_keys ] && [ -n "$(tail -c 1 authorized_keys)" ]; then echo; fi; "#
                + #"printf "\#(printfFormat(line))\n"; } >> authorized_keys && r=\#(addedMarker); fi"#,
            "{ command -v restorecon >/dev/null 2>&1 && restorecon -F . authorized_keys; :; }",
            #"echo "$r""#,
        ].joined(separator: " && ")
    }

    /// The command for a hidden channel: `script` in single quotes for `exec sh -c`.
    static func command(installing line: String, blob: String) -> String {
        "exec sh -c '\(script(installing: line, blob: blob))'"
    }

    /// The last line of output when the key was added.
    static let addedMarker = "shello-key-added"
    /// The last line of output when the file had the key already.
    static let presentMarker = "shello-key-present"

    /// What the command did, as its output says. The login shell may print something of its own
    /// first, so the marker is looked for in the last line.
    static func installation(from result: SSHCommandResult) throws(KeyInstallationError) -> KeyInstallation {
        let output = String(decoding: result.output, as: UTF8.self)
        let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init)
        if result.exitStatus == 0 {
            switch lastLine {
            case addedMarker: return .added
            case presentMarker: return .alreadyInstalled
            default: break
            }
        }
        throw .commandFailed(exitStatus: result.exitStatus, detail(of: result))
    }

    /// `text` as the format of `printf`: the bytes that no shell and no `printf` reads anything into
    /// stay as they are, `%` doubles, and every other byte becomes an octal escape (POSIX `printf`,
    /// `\ddd`), so that what reaches the file is `text`'s UTF-8 exactly.
    static func printfFormat(_ text: String) -> String {
        var format = ""
        for byte in text.utf8 {
            if byte == UInt8(ascii: "%") {
                format += "%%"
            } else if isPlainlySafe(byte) {
                format.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                let octal = String(byte, radix: 8)
                format += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        return format
    }

    /// Letters, digits, the space, and the punctuation that base64 and a key's type and comment
    /// usually have, none of which a shell or `printf` reads anything into.
    private static func isPlainlySafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        default:
            " +/=@._-:,".utf8.contains(byte)
        }
    }

    private static func isBase64(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "+/=".contains(character))
    }

    /// The longest detail kept, in characters.
    static let maximumDetailLength = 200

    /// What a failed command said: the first line it wrote to standard error, or else to its output,
    /// as the screen can show it, without control characters and bidirectional overrides, which the
    /// server's text could have, and at most `maximumDetailLength` characters long.
    static func detail(of result: SSHCommandResult) -> String {
        for stream in [result.errorOutput, result.output] {
            let text = String(decoding: stream, as: UTF8.self)
            let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
                switch scalar.properties.generalCategory {
                case .lineSeparator, .paragraphSeparator: "\n"
                case .control where scalar != "\n": " "
                case .format where (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value):
                    " "
                default: scalar
                }
            }
            let line = String(String.UnicodeScalarView(scalars)).split(separator: "\n").lazy
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .first { !$0.isEmpty }
            if let line { return String(line.prefix(maximumDetailLength)) }
        }
        return result.exitStatus.map { "The command exited with status \($0)." }
            ?? "The command ended without a status."
    }
}

/// What installing an SSH key on a host did.
public enum KeyInstallation: Hashable, Sendable {
    /// The key was added to `~/.ssh/authorized_keys`.
    case added
    /// `~/.ssh/authorized_keys` had the key already, and nothing changed.
    case alreadyInstalled
}

/// Why installing an SSH key on a host failed.
public enum KeyInstallationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The command exited with this status, or none, saying what is given, on one line.
    case commandFailed(exitStatus: Int?, String)
    /// The tab has no connection that works, to install the key over.
    case notConnected

    public var description: String {
        switch self {
        case .commandFailed(_, let detail): "The server couldn’t add the key: \(detail)"
        case .notConnected: "The connection isn’t open anymore. Connect to the host again, then install the key."
        }
    }
}
