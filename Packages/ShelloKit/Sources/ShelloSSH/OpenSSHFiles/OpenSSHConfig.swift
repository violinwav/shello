// OpenSSH's client configuration as Shello imports hosts from it (README section 3, STACK sections 2
// and 11): written in-house, fuzzed (Fuzz/OpenSSHConfig), and with the standard library only, so
// that the fuzz target builds on Linux.

/// An OpenSSH client configuration file, such as `~/.ssh/config`, read as ssh_config(5) reads it, for
/// the import of README section 3: keywords in any case, a value after spaces or an `=`, arguments
/// in single or double quotes, `\` escapes, and comments, which start with `#` where a word could.
///
/// The file is a list of blocks: the lines before the first `Host` apply to every host, and each
/// `Host` starts a block that applies to the names its patterns match. For each name, the first
/// value of a keyword wins, from the blocks that match it, in the file's order, so that a `Host *`
/// block at the end gives defaults (`settings(for:)`). `IdentityFile` and the forwards add up
/// instead, as ssh_config(5) says.
///
/// Only the keywords Shello imports are kept (`Keyword`). Every other line that is not blank or a
/// comment is in `skipped`, with its number and why: a keyword Shello does not use, `Match` and the
/// lines of its block, which Shello does not evaluate, `Include`, which Shello does not follow, since
/// it reads only the files the user picks, and lines it cannot read. Nothing is left out silently.
public struct OpenSSHConfig: Hashable, Sendable {
    /// The keywords Shello imports (README section 3), lowercased, as ssh_config(5) matches them.
    public enum Keyword: String, CaseIterable, Hashable, Sendable {
        case hostName = "hostname"
        case user = "user"
        case port = "port"
        case identityFile = "identityfile"
        case proxyJump = "proxyjump"
        case localForward = "localforward"
        case remoteForward = "remoteforward"
        case dynamicForward = "dynamicforward"

        /// The keyword as ssh_config(5) writes it: `HostName`.
        public var name: String {
            switch self {
            case .hostName: "HostName"
            case .user: "User"
            case .port: "Port"
            case .identityFile: "IdentityFile"
            case .proxyJump: "ProxyJump"
            case .localForward: "LocalForward"
            case .remoteForward: "RemoteForward"
            case .dynamicForward: "DynamicForward"
            }
        }

        /// Whether every value from the matching blocks applies, rather than only the first: a host
        /// tries each of its identity files, and has each of its forwards (ssh_config(5)).
        public var addsUp: Bool {
            switch self {
            case .identityFile, .localForward, .remoteForward, .dynamicForward: true
            case .hostName, .user, .port, .proxyJump: false
            }
        }

        /// The most arguments the keyword takes: a local forward's listening side and destination; a
        /// remote forward's too, or only the listening side for a reverse dynamic forward.
        var maximumArgumentCount: Int {
            switch self {
            case .localForward, .remoteForward: 2
            default: 1
            }
        }
    }

    /// A line with a keyword Shello imports, and its arguments, unquoted.
    public struct Directive: Hashable, Sendable {
        /// The line's number, from 1.
        public let line: Int
        public let keyword: Keyword
        public let arguments: [String]

        public init(line: Int, keyword: Keyword, arguments: [String]) {
            self.line = line
            self.keyword = keyword
            self.arguments = arguments
        }

        /// The first argument: the value of every keyword but the forwards, which may have two.
        public var value: String { arguments.first ?? "" }
    }

    /// One pattern of a `Host` line: a name, or names with `*` for any characters and `?` for one,
    /// or either after `!`, which keeps the block from applying to the names it matches.
    public struct Pattern: Hashable, Sendable {
        /// The pattern without its `!`.
        public let text: String
        public let isNegated: Bool

        public init(_ written: String) {
            isNegated = written.hasPrefix("!")
            text = isNegated ? String(written.dropFirst()) : written
        }

        /// Whether the pattern names one host: no wildcard and no `!`. Each such name on a `Host`
        /// line becomes a host on import.
        public var isConcrete: Bool {
            !isNegated && !text.isEmpty && !text.utf8.contains(where: { $0 == .asterisk || $0 == .questionMark })
        }

        /// Whether `name` matches the pattern, `!` aside. Case does not matter: ssh lowercases the
        /// host name it is given, and host names ignore case.
        public func matches(_ name: String) -> Bool {
            Self.glob(Array(text.lowercased().utf8), matches: Array(name.lowercased().utf8))
        }

        /// Whether `pattern`, with `*` for any bytes and `?` for one, matches all of `text`. Each `*`
        /// is tried at one place after the other, going back only to the last one, so the time stays
        /// proportional to the product of the lengths.
        static func glob(_ pattern: [UInt8], matches text: [UInt8]) -> Bool {
            var patternIndex = 0
            var textIndex = 0
            var star: (pattern: Int, text: Int)?
            while textIndex < text.count {
                if patternIndex < pattern.count,
                    pattern[patternIndex] == .questionMark || pattern[patternIndex] == text[textIndex]
                {
                    patternIndex += 1
                    textIndex += 1
                } else if patternIndex < pattern.count, pattern[patternIndex] == .asterisk {
                    star = (patternIndex, textIndex)
                    patternIndex += 1
                } else if let last = star {
                    patternIndex = last.pattern + 1
                    textIndex = last.text + 1
                    star = (last.pattern, last.text + 1)
                } else {
                    return false
                }
            }
            while patternIndex < pattern.count, pattern[patternIndex] == .asterisk {
                patternIndex += 1
            }
            return patternIndex == pattern.count
        }
    }

    /// The lines before the first `Host`, which apply to every host, or a `Host` line and the lines
    /// after it, up to the next `Host` or `Match`.
    public struct Block: Hashable, Sendable {
        /// The number of its `Host` line; nil for the lines before the first one.
        public let line: Int?
        public let patterns: [Pattern]
        public fileprivate(set) var directives: [Directive]

        /// Whether the block applies to the host `name`: the lines before the first `Host` always
        /// do; a `Host` block does if one of its patterns matches and none of its negated ones does.
        public func matches(_ name: String) -> Bool {
            guard line != nil else { return true }
            var matched = false
            for pattern in patterns where pattern.matches(name) {
                if pattern.isNegated { return false }
                matched = true
            }
            return matched
        }
    }

    /// A line that is not blank or a comment, and that Shello does not import.
    public struct SkippedLine: Hashable, Sendable {
        /// The line's number, from 1.
        public let line: Int
        /// The line as written, without the spaces around it.
        public let text: String
        public let reason: Reason

        public enum Reason: Hashable, Sendable {
            /// A keyword Shello does not import, as written.
            case unsupported(keyword: String)
            /// `Include`: Shello reads only the files the user picks.
            case include
            /// `Match`, whose conditions Shello does not evaluate.
            case match
            /// A line of the `Match` block on line `matchLine`, which applies only where the `Match`
            /// does.
            case inMatchBlock(matchLine: Int)
            /// A keyword without a value.
            case missingValue(Keyword?)
            /// A keyword Shello imports, with more values than it takes.
            case extraValues(Keyword)
            /// A quote that is not closed on the line.
            case unclosedQuote
            /// A null character, which ends a line in OpenSSH.
            case nullCharacter
        }
    }

    /// A concrete name on a `Host` line, which becomes a host on import.
    public struct Alias: Hashable, Sendable {
        public let name: String
        /// The `Host` line it is first on.
        public let line: Int
    }

    /// What the file says for one host: the first value of each keyword, and every identity file and
    /// forward, each with its line.
    public struct Settings: Hashable, Sendable {
        public var hostName: Directive?
        public var user: Directive?
        public var port: Directive?
        public var proxyJump: Directive?
        public var identityFiles: [Directive] = []
        /// The local, remote and dynamic forwards, in the file's order.
        public var forwards: [Directive] = []

        public init() {}

        /// Every directive whose value counts for the host.
        public var directives: [Directive] {
            [hostName, user, port, proxyJump].compactMap { $0 } + identityFiles + forwards
        }
    }

    /// The blocks, in the file's order, with the directives Shello imports. The first has no `Host`
    /// line, and may have no directives.
    public let blocks: [Block]
    /// Every line that is not blank or a comment and that Shello does not import, in order.
    public let skipped: [SkippedLine]

    /// Reads `text`. Invalid UTF-8 should be repaired before, as `init(bytes:)` does.
    public init(_ text: String) {
        var blocks = [Block(line: nil, patterns: [], directives: [])]
        var skipped: [SkippedLine] = []
        /// The line of the `Match` whose block the lines are in, until the next `Host` or `Match`.
        var matchLine: Int?
        for (index, rawLine) in Self.lines(of: text).enumerated() {
            let number = index + 1
            guard let line = Line(rawLine) else { continue }
            let text = Self.trimmed(rawLine)
            func skip(_ reason: SkippedLine.Reason) {
                skipped.append(SkippedLine(line: number, text: text, reason: reason))
            }
            switch line {
            case .malformed(let reason):
                skip(reason)
            case .keyword(let keyword, let written, let arguments):
                switch keyword {
                case "host":
                    matchLine = nil
                    let patterns = arguments.map(Pattern.init).filter { !$0.text.isEmpty }
                    blocks.append(Block(line: number, patterns: patterns, directives: []))
                    if patterns.isEmpty {
                        skip(.missingValue(nil))
                    }
                case "match":
                    matchLine = number
                    skip(.match)
                case "include":
                    skip(.include)
                case _ where matchLine != nil:
                    skip(.inMatchBlock(matchLine: matchLine ?? number))
                default:
                    guard let known = Keyword(rawValue: keyword) else {
                        skip(.unsupported(keyword: written))
                        continue
                    }
                    if arguments.isEmpty || arguments.allSatisfy(\.isEmpty) {
                        skip(.missingValue(known))
                    } else if arguments.count > known.maximumArgumentCount {
                        skip(.extraValues(known))
                    } else {
                        blocks[blocks.count - 1].directives.append(
                            Directive(line: number, keyword: known, arguments: arguments))
                    }
                }
            }
        }
        self.blocks = blocks
        self.skipped = skipped
    }

    /// Reads the file's `bytes` as UTF-8, with invalid bytes replaced.
    public init(bytes: some Collection<UInt8>) {
        self.init(String(decoding: bytes, as: UTF8.self))
    }

    /// The concrete names on the `Host` lines, each once, in the order they first appear: names
    /// that differ only in case are one name, as ssh sees them.
    public var aliases: [Alias] {
        var seen: Set<String> = []
        var aliases: [Alias] = []
        for block in blocks {
            guard let line = block.line else { continue }
            for pattern in block.patterns where pattern.isConcrete && seen.insert(pattern.text.lowercased()).inserted {
                aliases.append(Alias(name: pattern.text, line: line))
            }
        }
        return aliases
    }

    /// What the file says for the host `name`, as ssh reads it for `ssh name`: from each block that
    /// matches the name, in order, the first value of each keyword, and every identity file and
    /// forward.
    public func settings(for name: String) -> Settings {
        var settings = Settings()
        for block in blocks where block.matches(name) {
            for directive in block.directives {
                switch directive.keyword {
                case .hostName: settings.hostName = settings.hostName ?? directive
                case .user: settings.user = settings.user ?? directive
                case .port: settings.port = settings.port ?? directive
                case .proxyJump: settings.proxyJump = settings.proxyJump ?? directive
                case .identityFile: settings.identityFiles.append(directive)
                case .localForward, .remoteForward, .dynamicForward: settings.forwards.append(directive)
                }
            }
        }
        return settings
    }

    /// The directives of every block, in the file's order.
    public var directives: [Directive] {
        blocks.flatMap(\.directives)
    }

    // MARK: - Lines

    /// The file's lines, split at line feeds, each without its line feed.
    static func lines(of text: String) -> [Substring.UTF8View] {
        text.utf8.split(separator: .lineFeed, omittingEmptySubsequences: false)
    }

    /// The line without the spaces, tabs, carriage returns and form feeds around it.
    static func trimmed(_ line: Substring.UTF8View) -> String {
        guard let start = line.firstIndex(where: { !$0.isLineSpace }),
            let end = line.lastIndex(where: { !$0.isLineSpace })
        else { return "" }
        return String(Substring(line[start...end]))
    }

    /// A line as ssh_config(5) reads it: nothing, for a blank line or a comment; a keyword with its
    /// arguments; or a line that cannot be read.
    enum Line: Hashable {
        /// The keyword lowercased and as written, and its arguments.
        case keyword(String, written: String, arguments: [String])
        case malformed(SkippedLine.Reason)

        /// Reads `bytes`, or returns nil for a blank line or a comment.
        init?(_ bytes: Substring.UTF8View) {
            var bytes = Array(bytes)
            // Trailing white space, carriage returns and form feeds go first, as in ssh.
            while let last = bytes.last, last.isLineSpace {
                bytes.removeLast()
            }
            var index = bytes.firstIndex(where: { !$0.isBlank }) ?? bytes.endIndex
            guard index < bytes.endIndex, bytes[index] != .hash else { return nil }
            guard !bytes.contains(0) else {
                self = .malformed(.nullCharacter)
                return
            }
            // The keyword ends at a space, a tab or an `=`.
            let keywordStart = index
            while index < bytes.endIndex, !bytes[index].isBlank, bytes[index] != .equals {
                index += 1
            }
            let written = String(decoding: bytes[keywordStart..<index], as: UTF8.self)
            // Then spaces, at most one `=`, and spaces again.
            while index < bytes.endIndex, bytes[index].isBlank { index += 1 }
            if index < bytes.endIndex, bytes[index] == .equals { index += 1 }
            while index < bytes.endIndex, bytes[index].isBlank { index += 1 }
            guard !written.isEmpty else {
                self = .malformed(.missingValue(nil))
                return
            }
            guard let arguments = Self.arguments(bytes[index...]) else {
                self = .malformed(.unclosedQuote)
                return
            }
            let keyword = written.lowercased()
            guard !arguments.isEmpty else {
                self = .malformed(.missingValue(Keyword(rawValue: keyword)))
                return
            }
            self = .keyword(keyword, written: written, arguments: arguments)
        }

        /// The arguments in `bytes`, split as OpenSSH's `argv_split` splits them: at spaces and tabs
        /// outside quotes; a quote, single or double, runs to the next one of the same kind; `\`
        /// escapes a quote, a `\` and, outside quotes, a space; a `#` that starts an argument starts a
        /// comment. Nil when a quote is not closed.
        static func arguments(_ bytes: ArraySlice<UInt8>) -> [String]? {
            var arguments: [String] = []
            var index = bytes.startIndex
            while index < bytes.endIndex {
                if bytes[index].isBlank {
                    index += 1
                    continue
                }
                if bytes[index] == .hash { break }
                var argument: [UInt8] = []
                var quote: UInt8?
                while index < bytes.endIndex {
                    let byte = bytes[index]
                    if byte == .backslash, index + 1 < bytes.endIndex {
                        let next = bytes[index + 1]
                        if next == .singleQuote || next == .doubleQuote || next == .backslash
                            || (quote == nil && next == .space)
                        {
                            argument.append(next)
                            index += 2
                            continue
                        }
                        argument.append(byte)
                    } else if quote == nil, byte.isBlank {
                        break
                    } else if quote == nil, byte == .singleQuote || byte == .doubleQuote {
                        quote = byte
                    } else if let open = quote, byte == open {
                        quote = nil
                    } else {
                        argument.append(byte)
                    }
                    index += 1
                }
                guard quote == nil else { return nil }
                arguments.append(String(decoding: argument, as: UTF8.self))
            }
            return arguments
        }
    }
}

// MARK: - Values

extension OpenSSHConfig {
    /// `text` as a port: a decimal number from 1 to 65535, as `Port` takes it, or nil.
    public static func port(_ text: some StringProtocol) -> UInt16? {
        guard !text.isEmpty, text.utf8.count <= 5, text.utf8.allSatisfy(\.isDigit), let number = Int(text),
            (1...65535).contains(number)
        else { return nil }
        return UInt16(number)
    }

    /// One hop of a `ProxyJump`: `[user@]host[:port]`, or the same as `ssh://` URI, with an IPv6
    /// address in brackets.
    public struct Hop: Hashable, Sendable {
        /// The hop as written, without `ssh://`.
        public let text: String
        public let user: String?
        /// The host's name or address, without brackets.
        public let host: String
        public let port: UInt16?

        public init(text: String, user: String?, host: String, port: UInt16?) {
            self.text = text
            self.user = user
            self.host = host
            self.port = port
        }

        /// Reads one hop as OpenSSH's `parse_user_host_port` and `parse_ssh_uri` do, or returns nil.
        public init?(_ written: some StringProtocol) {
            var text = Substring(written)
            if text.lowercased().hasPrefix("ssh://") {
                text = text.dropFirst("ssh://".count)
                // A URI may end with a slash, and nothing after it.
                if text.hasSuffix("/") { text = text.dropLast() }
                guard !text.contains("/") else { return nil }
            }
            self.text = String(text)
            var rest = text
            if let at = text.lastIndex(of: "@") {
                let user = text[..<at]
                guard !user.isEmpty else { return nil }
                self.user = String(user)
                rest = text[text.index(after: at)...]
            } else {
                user = nil
            }
            guard let (host, port) = Self.hostAndPort(rest) else { return nil }
            self.host = host
            self.port = port
        }

        /// `host[:port]`, with an IPv6 address in brackets, as OpenSSH's `hpdelim` splits it.
        static func hostAndPort(_ text: Substring) -> (String, UInt16?)? {
            let host: Substring
            let rest: Substring
            if text.hasPrefix("[") {
                guard let close = text.firstIndex(of: "]") else { return nil }
                host = text[text.index(after: text.startIndex)..<close]
                rest = text[text.index(after: close)...]
                guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            } else if let colon = text.firstIndex(of: ":") {
                host = text[..<colon]
                rest = text[colon...]
            } else {
                host = text
                rest = ""
            }
            guard !host.isEmpty else { return nil }
            guard rest.count > 1 else { return rest.isEmpty ? (String(host), nil) : nil }
            guard let port = OpenSSHConfig.port(rest.dropFirst()) else { return nil }
            return (String(host), port)
        }
    }

    /// What `ProxyJump` says: no jump host, or the hops in the order the connection goes through
    /// them, as OpenSSH reads a comma-separated list; nil if one hop cannot be read.
    public enum ProxyJump: Hashable, Sendable {
        case none
        case hops([Hop])

        public init?(_ text: String) {
            if text.lowercased() == "none" {
                self = .none
                return
            }
            var hops: [Hop] = []
            for written in text.split(separator: ",", omittingEmptySubsequences: false) {
                guard let hop = Hop(written) else { return nil }
                hops.append(hop)
            }
            self = .hops(hops)
        }
    }

    /// A `LocalForward`, `RemoteForward` or `DynamicForward` as OpenSSH's `parse_forward` reads it:
    /// `[bind_address:]port`, then for a local or remote forward `host:hostport`, with IPv6 addresses
    /// in brackets.
    public struct Forward: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case local
            case remote
            case dynamic
        }

        public let kind: Kind
        /// The address it listens on, as written, without brackets: nil when the line names none, and
        /// empty for one written empty, as in `:8080`, which means all of them.
        public let bindAddress: String?
        /// The port it listens on: on this device for a local or dynamic forward, on the server for a
        /// remote one. Never 0.
        public let port: UInt16
        /// Where each connection goes; nil for a dynamic forward.
        public let destination: Destination?

        public struct Destination: Hashable, Sendable {
            public let host: String
            public let port: UInt16
        }

        /// Why a forward cannot be imported.
        public enum Problem: Error, Hashable, Sendable {
            /// A Unix domain socket on either side, which Shello does not forward.
            case unixSocket
            /// `RemoteForward 0`: the server would choose the port, which libssh does not report
            /// reliably.
            case serverChosenPort
            /// A `RemoteForward` without a destination: OpenSSH's reverse dynamic (SOCKS) forward,
            /// which Shello does not have.
            case reverseDynamic
            /// `${…}`, an environment variable of the Mac's, which Shello cannot know.
            case environmentVariable
            /// Not a forward OpenSSH would read: a missing destination, a port that is not from 1 to
            /// 65535, or fields that do not add up.
            case malformed
        }

        /// Reads the forward on `directive`, a `LocalForward`, `RemoteForward` or `DynamicForward`.
        public static func parse(_ directive: Directive) -> Result<Forward, Problem> {
            let kind: Kind
            switch directive.keyword {
            case .localForward: kind = .local
            case .remoteForward: kind = .remote
            case .dynamicForward: kind = .dynamic
            default: return .failure(.malformed)
            }
            let arguments = directive.arguments
            guard let first = arguments.first, arguments.count <= kind.maximumArguments else {
                return .failure(.malformed)
            }
            // OpenSSH joins the two arguments with a colon and reads them as one. A remote forward
            // with one argument is a reverse dynamic forward, read as a dynamic one; a local forward
            // needs both.
            if kind == .local, arguments.count == 1 { return .failure(.malformed) }
            let isDynamic = kind == .dynamic || arguments.count == 1
            let specification = arguments.count == 2 ? first + ":" + arguments[1] : first
            guard !specification.contains("${") else { return .failure(.environmentVariable) }
            guard let fields = Self.fields(of: specification) else { return .failure(.malformed) }
            if fields.contains(where: \.isPath) { return .failure(.unixSocket) }
            let texts = fields.map(\.text)
            let listening: (bind: String?, port: String)
            var destination: (host: String, port: String)?
            switch (isDynamic, texts.count) {
            case (true, 1):
                listening = (nil, texts[0])
            case (true, 2):
                listening = (texts[0], texts[1])
            case (false, 3):
                listening = (nil, texts[0])
                destination = (texts[1], texts[2])
            case (false, 4):
                listening = (texts[0], texts[1])
                destination = (texts[2], texts[3])
            default:
                return .failure(.malformed)
            }
            if kind == .remote, !listening.port.isEmpty, listening.port.utf8.allSatisfy({ $0 == .zero }) {
                return .failure(isDynamic ? .reverseDynamic : .serverChosenPort)
            }
            guard let port = OpenSSHConfig.port(listening.port) else { return .failure(.malformed) }
            if kind == .remote, isDynamic { return .failure(.reverseDynamic) }
            var target: Destination?
            if let destination {
                guard !destination.host.isEmpty, let destinationPort = OpenSSHConfig.port(destination.port) else {
                    return .failure(.malformed)
                }
                target = Destination(host: destination.host, port: destinationPort)
            }
            return .success(Forward(kind: kind, bindAddress: listening.bind, port: port, destination: target))
        }

        /// The colon-separated fields of a forward's specification, as OpenSSH's `parse_fwd_field`
        /// splits them: a field in brackets is taken as it is, which is how an IPv6 address is
        /// written; `\` escapes the next character; a field with a `/` is a path. Nil for more than
        /// four fields, or a bracket that does not close a field.
        static func fields(of specification: String) -> [(text: String, isPath: Bool)]? {
            var bytes = Array(specification.utf8)[...]
            // Leading spaces are skipped, as in OpenSSH.
            while let first = bytes.first, first.isBlank { bytes.removeFirst() }
            var fields: [(text: String, isPath: Bool)] = []
            while !bytes.isEmpty {
                guard fields.count < 4 else { return nil }
                var field: [UInt8] = []
                var isPath = false
                if bytes.first == .openingBracket {
                    bytes.removeFirst()
                    guard let close = bytes.firstIndex(of: .closingBracket) else { return nil }
                    field = Array(bytes[..<close])
                    isPath = field.contains(.slash)
                    bytes = bytes[(close + 1)...]
                    if let next = bytes.first {
                        guard next == .colon else { return nil }
                        bytes.removeFirst()
                    }
                } else {
                    while let byte = bytes.first {
                        bytes.removeFirst()
                        if byte == .backslash {
                            // The next character is taken as it is, a colon or a slash too.
                            guard let escaped = bytes.first else { return nil }
                            bytes.removeFirst()
                            field.append(escaped)
                            continue
                        }
                        if byte == .colon { break }
                        if byte == .slash { isPath = true }
                        field.append(byte)
                    }
                }
                fields.append((String(decoding: field, as: UTF8.self), isPath))
            }
            return fields
        }
    }

    /// The `%` tokens ssh_config(5) expands in a value: `%%` for `%`, and those in `tokens`, such as
    /// `h` for the host. Nil when the value has another token, which Shello cannot know, such as
    /// `%d`, the local home directory, or ends with a lone `%`.
    public static func expandingTokens(in text: String, _ tokens: [Character: String]) -> String? {
        guard text.contains("%") else { return text }
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            guard let token = characters.next() else { return nil }
            if token == "%" {
                result.append("%")
            } else if let value = tokens[token] {
                result += value
            } else {
                return nil
            }
        }
        return result
    }
}

extension OpenSSHConfig.Forward.Kind {
    /// How many arguments the keyword takes at most.
    fileprivate var maximumArguments: Int {
        self == .dynamic ? 1 : 2
    }
}

extension UInt8 {
    fileprivate static let lineFeed = UInt8(ascii: "\n")
    fileprivate static let space = UInt8(ascii: " ")
    fileprivate static let tab = UInt8(ascii: "\t")
    fileprivate static let hash = UInt8(ascii: "#")
    fileprivate static let equals = UInt8(ascii: "=")
    fileprivate static let backslash = UInt8(ascii: "\\")
    fileprivate static let singleQuote = UInt8(ascii: "'")
    fileprivate static let doubleQuote = UInt8(ascii: "\"")
    fileprivate static let asterisk = UInt8(ascii: "*")
    fileprivate static let questionMark = UInt8(ascii: "?")
    fileprivate static let colon = UInt8(ascii: ":")
    fileprivate static let slash = UInt8(ascii: "/")
    fileprivate static let openingBracket = UInt8(ascii: "[")
    fileprivate static let closingBracket = UInt8(ascii: "]")
    fileprivate static let zero = UInt8(ascii: "0")

    /// A space or a tab, which separate words on a line.
    fileprivate var isBlank: Bool { self == .space || self == .tab }

    /// What ssh strips from the end of a line: spaces, tabs, carriage returns, line feeds and form
    /// feeds.
    fileprivate var isLineSpace: Bool {
        isBlank || self == UInt8(ascii: "\r") || self == .lineFeed || self == 0x0C
    }

    fileprivate var isDigit: Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) }
}
