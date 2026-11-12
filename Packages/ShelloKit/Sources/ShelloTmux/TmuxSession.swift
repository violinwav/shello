// tmux's sessions, as `tmux list-sessions -F` lists them in an explicit format (docs/spec/STACK.md
// section 7.6). The output comes from a server that Shello does not control, so the parser reads any
// bytes without trapping, in time proportional to them. Fuzz/TmuxOutput fuzzes it.
//
// This file uses the standard library only, so that the fuzz target builds it with the swift.org
// toolchain on Linux as it is (Fuzz/README.md).

/// A tmux session on the server, as `tmux -u list-sessions -F` lists it in `TmuxSession.listFormat`.
public struct TmuxSession: Hashable, Sendable {
    /// tmux's identifier for the session, such as `$3`, which it keeps while it runs: a session
    /// started anew under the same name has another.
    public let id: String
    /// The session's name, as tmux lists it: before 3.7 it escapes some characters, such as a `$` at
    /// the start as `\$`.
    public let name: String
    /// When the session started, in seconds since 1970-01-01T00:00:00Z.
    public let created: Int
    /// How many clients are attached to the session.
    public let attachedClients: Int
    /// How many windows the session has.
    public let windows: Int

    public init(id: String, name: String, created: Int, attachedClients: Int, windows: Int) {
        self.id = id
        self.name = name
        self.created = created
        self.attachedClients = attachedClients
        self.windows = windows
    }

    /// The format each session is listed in: its fields, then its name, each after a tab.
    ///
    /// A tab cannot be in a session's name: tmux before 3.7 lists one as `\t`, and 3.7 refuses such
    /// a name. With `-u`, tmux passes the tab on as it is, from 3.2a on at least; a client without
    /// `-u` whose locale is not UTF-8 turns it into `_`, and tmux 3.4 turns other control characters,
    /// such as the unit separator, into octal escapes even with it. The name comes last, so that a
    /// line would still read if a version ever let a tab into one.
    public static let listFormat =
        "#{session_id}\t#{session_created}\t#{session_attached}\t#{session_windows}\t#{session_name}"

    /// The sessions in what `list-sessions -F listFormat` printed, in its order. A line that is no
    /// session in that format, such as one the server's shell printed as it started, is left out.
    public static func sessions(inListOutput output: some Collection<UInt8>) -> [TmuxSession] {
        Array(output).split(separator: UInt8(ascii: "\n")).compactMap { session(inLine: $0) }
    }

    /// The session on one line of the list, or nil if the line is none.
    private static func session(inLine line: ArraySlice<UInt8>) -> TmuxSession? {
        // A line printed with \r\n, as a pseudo-terminal would.
        let line = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
        let fields = line.split(separator: UInt8(ascii: "\t"), maxSplits: 4, omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0].first == UInt8(ascii: "$"), let id = number(in: fields[0].dropFirst()),
            let created = number(in: fields[1]), let attachedClients = number(in: fields[2]),
            let windows = number(in: fields[3]), !fields[4].isEmpty
        else { return nil }
        return TmuxSession(
            id: "$\(id)", name: String(decoding: fields[4], as: UTF8.self), created: created,
            attachedClients: attachedClients, windows: windows)
    }

    /// The number `digits` writes in decimal: 1 to 18 ASCII digits, which an `Int` always holds.
    private static func number(in digits: ArraySlice<UInt8>) -> Int? {
        guard (1...18).contains(digits.count) else { return nil }
        var number = 0
        for digit in digits {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return nil }
            number = number * 10 + Int(digit - UInt8(ascii: "0"))
        }
        return number
    }
}
