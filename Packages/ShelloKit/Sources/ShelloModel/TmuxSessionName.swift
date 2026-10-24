/// The name of the tmux session a host attaches (README section 8): 1 to 64 ASCII letters, digits,
/// hyphens and underscores, not starting with a hyphen, such as `main`.
///
/// Shello types the name into the login shell and hands it to tmux, so it keeps to characters that
/// mean nothing more to either. A shell reads quotes, spaces, `$`, `;` and much else, and fish reads
/// backslashes even between single quotes. tmux reads a leading `$` as a session's identifier, a
/// leading `=` as an exact match and `*`, `?` and `[` as a pattern, escapes other characters in the
/// names it lists, and its older versions turn `.` and `:` into `_`. tmux takes more than this, but a
/// name it changes would never be attached again.
public struct TmuxSessionName: Hashable, Sendable, CustomStringConvertible {
    /// The longest name: more than any name a person types.
    public static let maximumLength = 64

    public let rawValue: String

    /// The name, or nil if it is empty, longer than `maximumLength`, starts with a hyphen, which tmux
    /// would read as an option, or has a character other than an ASCII letter, digit, hyphen or
    /// underscore.
    public init?(_ name: String) {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, first != "-", scalars.count <= Self.maximumLength,
            scalars.allSatisfy(Self.isAllowed)
        else { return nil }
        rawValue = name
    }

    public var description: String { rawValue }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
        default: false
        }
    }
}
