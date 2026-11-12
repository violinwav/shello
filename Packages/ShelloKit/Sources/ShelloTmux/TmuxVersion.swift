// tmux's version, as `tmux -V` prints it (docs/spec/STACK.md section 7.6). The output comes from a
// server that Shello does not control, so the parser reads any bytes without trapping, in time
// proportional to them. Fuzz/TmuxOutput fuzzes it.
//
// This file uses the standard library only, so that the fuzz target builds it with the swift.org
// toolchain on Linux as it is (Fuzz/README.md).

/// The version of tmux on a server, as `tmux -V` names it: `tmux 3.4`, `tmux 3.3a`; `tmux next-3.6`
/// for a build of tmux's development branch, `tmux master` for an older one, and `tmux openbsd-7.6`
/// for the tmux of OpenBSD's base system, which goes by OpenBSD's version.
public struct TmuxVersion: Hashable, Sendable, CustomStringConvertible {
    /// A tmux release by its major and minor number, such as 3.4 for tmux 3.4 and 3.4a.
    public struct Release: Hashable, Sendable, Comparable, CustomStringConvertible {
        public let major: Int
        public let minor: Int

        public init(major: Int, minor: Int) {
            self.major = major
            self.minor = minor
        }

        public static func < (lhs: Release, rhs: Release) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }

        public var description: String { "\(major).\(minor)" }
    }

    /// The version as tmux names it, such as `3.4`, `3.3a` or `next-3.6`: ASCII letters, digits and
    /// `.`, `-`, `+`, `_` and `~` only, so that it can be shown as it is.
    public let name: String
    /// The release the version is, or leads to for a build of the development branch; nil for
    /// `master`, and for OpenBSD's tmux.
    public let release: Release?

    /// The longest name read: tmux's are a few characters long.
    static let maximumNameLength = 32

    public var description: String { name }

    /// Whether this tmux is `release` or later. A version without a release, a build of the
    /// development branch or OpenBSD's, counts as later: both follow tmux's newest code.
    public func isAtLeast(_ release: Release) -> Bool {
        self.release.map { $0 >= release } ?? true
    }

    /// The version named `name`, such as `3.4`, `3.3a`, `3.2-rc3`, `next-3.6`, `master` or
    /// `openbsd-7.6`, or nil for a name that is none of these. A release's number may be followed by
    /// anything a packager adds, such as `3.5a+git`.
    public init?(name: some StringProtocol) {
        let name = String(name)
        guard !name.isEmpty, name.utf8.count <= Self.maximumNameLength,
            name.unicodeScalars.allSatisfy(Self.isAllowedInName)
        else { return nil }
        if name == "master" || name.hasPrefix("openbsd-") {
            release = nil
        } else {
            let number = name.hasPrefix("next-") ? name.dropFirst("next-".count) : Substring(name)
            guard let release = Self.release(atStartOf: number) else { return nil }
            self.release = release
        }
        self.name = name
    }

    /// Reads the version in what `tmux -V` printed: the name after `tmux` on the last line that
    /// starts with it, after anything the server's shell printed as it started. Nil when there is
    /// no such line, or its name is no version (`init(name:)`).
    public init?(versionOutput output: some Collection<UInt8>) {
        var found: TmuxVersion??
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let words = line.split(whereSeparator: Self.isASCIISpace)
            guard words.count >= 2, words[0].elementsEqual("tmux".utf8) else { continue }
            found = .some(TmuxVersion(name: String(decoding: words[1], as: UTF8.self)))
        }
        guard let version = found ?? nil else { return nil }
        self = version
    }

    /// The release that `text` starts with: digits, a dot and digits, at most four of each.
    private static func release(atStartOf text: Substring) -> Release? {
        let major = text.prefix(while: \.isASCIIDigit)
        let rest = text.dropFirst(major.count)
        guard (1...4).contains(major.count), rest.first == "." else { return nil }
        let minor = rest.dropFirst().prefix(while: \.isASCIIDigit)
        guard (1...4).contains(minor.count), let majorNumber = Int(major), let minorNumber = Int(minor) else {
            return nil
        }
        return Release(major: majorNumber, minor: minorNumber)
    }

    private static func isAllowedInName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "+", "_", "~": true
        default: false
        }
    }

    /// A space, a tab or a carriage return, which ends a line printed with `\r\n`.
    private static func isASCIISpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }
}

extension Character {
    /// Whether the character is one of the digits 0 to 9: `isNumber` takes other scripts' digits too.
    fileprivate var isASCIIDigit: Bool {
        asciiValue.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? false
    }
}
