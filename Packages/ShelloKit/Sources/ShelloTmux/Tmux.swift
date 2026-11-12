// tmux on a server, which Shello asks over hidden channels (docs/spec/STACK.md section 7.6): its
// version, which decides whether a connection attaches a tmux session (README section 8), and its
// sessions. No UIKit, so that it stays buildable on Linux (STACK section 4).
import ShelloModel
import ShelloSSH

/// Where Shello runs tmux's commands: the hidden channels (GLOSSARY) of a connection, which never
/// show in a tab. `SSHConnection` has them; tests stand in for it.
public protocol HiddenChannels: Sendable {
    /// Runs `command` on a hidden channel, and returns what it printed and how it exited.
    func run(_ command: String) async throws -> SSHCommandResult
}

extension SSHConnection: HiddenChannels {}

/// tmux on a server, as Shello asks it over hidden channels.
public enum Tmux {
    /// The oldest tmux that Shello attaches a tmux session with: 1.8, which added `new-session -A`,
    /// the one command auto-attach runs, which attaches the session, or starts it if it is not
    /// running. The distributions whose OpenSSH is 8.8 or later, the oldest Shello supports (README
    /// section 4), ship tmux 3.2a or later, as Alpine 3.15 and Ubuntu 22.04 do; the test servers
    /// have 3.4 and 3.7c.
    public static let minimumRelease = TmuxVersion.Release(major: 1, minor: 8)

    /// The command that prints tmux's version.
    static let versionCommand = "tmux -V"

    /// The command that lists the tmux sessions, in `TmuxSession.listFormat`. With `-u`, tmux passes
    /// the format's tabs and the names' UTF-8 on as they are, whatever the server's locale.
    static let listSessionsCommand = "tmux -u list-sessions -F \(shellQuoted(TmuxSession.listFormat))"

    /// Checks tmux on the server on a hidden channel: `tmux -V`, with the `PATH` the server gives a
    /// command, as `ssh host tmux -V` runs it. A tmux that only the login shell's profile puts on the
    /// `PATH`, as Homebrew's on a Mac, counts as missing.
    /// - Throws: `CancellationError`, or the `SSHError` of a connection that is gone. A command that
    ///   failed otherwise is a result: Shello cannot tell what tmux there is.
    public static func check(on channels: some HiddenChannels) async throws -> TmuxCheck {
        let result: SSHCommandResult
        do {
            result = try await channels.run(versionCommand)
        } catch let error as SSHError where error.endsTheConnection {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown(TmuxCheck.detail(String(describing: error)))
        }
        switch result.exitStatus {
        case 0?:
            guard let version = TmuxVersion(versionOutput: result.output) else {
                return .unknown(TmuxCheck.detail(of: result))
            }
            return version.isAtLeast(minimumRelease) ? .available(version) : .tooOld(version)
        case 127?:
            // The shell's status for a command it did not find.
            return .missing
        default:
            return .unknown(TmuxCheck.detail(of: result))
        }
    }

    /// How a connection of a host with auto-attach on starts (README section 8): it attaches the tmux
    /// session `sessionName`, if the server's tmux can, which a hidden channel checks first; else it
    /// runs a plain shell, for the reason given.
    /// - Throws: As `check(on:)`.
    public static func attachment(sessionName: String, on channels: some HiddenChannels) async throws
        -> TmuxAttachment
    {
        guard let name = TmuxSessionName(sessionName) else {
            return .plainShell(.invalidSessionName(TmuxCheck.detail(sessionName)))
        }
        switch try await check(on: channels) {
        case .available(let version): return .attaching(name, version)
        case .missing: return .plainShell(.missing)
        case .tooOld(let version): return .plainShell(.tooOld(version))
        case .unknown(let detail): return .plainShell(.unknown(detail))
        }
    }

    /// The command that attaches the tmux session `session`, or starts it if it is not running, as
    /// `tmux new -A -s main` does. `-u` tells tmux that the terminal takes UTF-8, which Shello's
    /// always does: without it, tmux draws other characters than ASCII as `_` when the server's shell
    /// has no UTF-8 locale, and libssh sends none. The name is quoted for the shell, although a
    /// `TmuxSessionName` has nothing a shell would read in it.
    public static func attachCommand(for session: TmuxSessionName) -> String {
        "tmux -u new-session -A -s \(shellQuoted(session.rawValue))"
    }

    /// The tmux sessions running on the server, listed on a hidden channel: none when no tmux server
    /// runs.
    /// - Throws: `TmuxError` when tmux fails otherwise, as when it is missing; the `SSHError` of the
    ///   connection; or `CancellationError`.
    public static func sessions(on channels: some HiddenChannels) async throws -> [TmuxSession] {
        let result = try await channels.run(listSessionsCommand)
        guard result.exitStatus == 0 else {
            let message = String(decoding: result.errorOutput, as: UTF8.self)
            // tmux 3.x says "no server running on /tmp/tmux-1000/default", older versions that they
            // failed to connect.
            let noServerMessages = ["no server running", "error connecting to", "failed to connect to server"]
            if result.exitStatus == 1, noServerMessages.contains(where: { message.contains($0) }) {
                return []
            }
            throw TmuxError.commandFailed(exitStatus: result.exitStatus, TmuxCheck.detail(of: result))
        }
        return TmuxSession.sessions(inListOutput: result.output)
    }

    /// `text` between single quotes, which every shell takes as it is, with each single quote in it
    /// written as `'\''`: the quoting ends, an escaped quote, and the quoting starts again.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: #"'\''"#) + "'"
    }
}

/// What `Tmux.check(on:)` found on the server.
public enum TmuxCheck: Hashable, Sendable {
    /// tmux of this version, `Tmux.minimumRelease` or later.
    case available(TmuxVersion)
    /// No tmux: the server's shell did not find the command.
    case missing
    /// tmux of this version, older than `Tmux.minimumRelease`.
    case tooOld(TmuxVersion)
    /// Something else, such as tmux printing no version Shello reads, or the command failing, with
    /// what was said about it, on one line.
    case unknown(String)

    /// The longest detail kept, in characters.
    static let maximumDetailLength = 120

    /// What the result says about itself: the first line it wrote to standard error, or else to
    /// its output, or else its exit status.
    static func detail(of result: SSHCommandResult) -> String {
        for stream in [result.errorOutput, result.output] {
            let line = detail(String(decoding: stream, as: UTF8.self))
            if !line.isEmpty { return line }
        }
        return result.exitStatus.map { "tmux -V exited with status \($0)" } ?? "tmux -V ended without a status"
    }

    /// The first line of `text` that has anything in it, as the terminal can show it: without
    /// control characters and bidirectional overrides, which the server's text could have, and at
    /// most `maximumDetailLength` characters long.
    static func detail(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: "\n"
            case .control where scalar != "\n": " "
            case .format where (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value):
                " "
            default: scalar
            }
        }
        let lines = String(String.UnicodeScalarView(scalars)).split(separator: "\n")
        let line = lines.lazy.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        return String((line ?? "").prefix(maximumDetailLength))
    }
}

/// How a connection of a host with auto-attach on starts (README section 8).
public enum TmuxAttachment: Hashable, Sendable {
    /// The connection attaches the tmux session, or starts it, with tmux of this version: it types
    /// `Tmux.attachCommand(for:)` once the startup command is typed.
    case attaching(TmuxSessionName, TmuxVersion)
    /// The connection runs a plain shell (GLOSSARY), for this reason, which a note in the terminal
    /// says.
    case plainShell(TmuxFallback)
}

/// Why a connection of a host with auto-attach on runs a plain shell instead of its tmux session.
public enum TmuxFallback: Hashable, Sendable {
    /// The server has no tmux.
    case missing
    /// The server's tmux is older than `Tmux.minimumRelease`.
    case tooOld(TmuxVersion)
    /// Shello could not tell which tmux the server has, for the reason given.
    case unknown(String)
    /// The host's tmux session name is not a `TmuxSessionName`; the name, as the terminal can show
    /// it. The host editor and import refuse such a name, so only a damaged database has one.
    case invalidSessionName(String)

    /// The note the terminal shows, one sentence: what the tab does instead, and why.
    public var note: String {
        switch self {
        case .missing:
            "tmux isn’t installed on this server, so this tab runs a plain shell."
        case .tooOld(let version):
            "tmux \(version) on this server is older than \(Tmux.minimumRelease), so this tab runs a plain shell."
        case .unknown(let detail):
            "Shello couldn’t tell which tmux this server has, so this tab runs a plain shell: \(detail)"
        case .invalidSessionName(let name):
            "“\(name)” can’t be a tmux session name, so this tab runs a plain shell."
        }
    }
}

/// A tmux command that failed.
public enum TmuxError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The command exited with this status, or none, saying what is given.
    case commandFailed(exitStatus: Int?, String)

    public var description: String {
        switch self {
        case .commandFailed(let status?, let detail): "tmux failed with status \(status): \(detail)"
        case .commandFailed(nil, let detail): "tmux failed: \(detail)"
        }
    }
}

extension SSHError {
    /// Whether the connection is gone, rather than the command failing on it.
    fileprivate var endsTheConnection: Bool {
        switch self {
        case .connectionLost, .closed: true
        default: false
        }
    }
}
