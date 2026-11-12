import Testing

@testable import ShelloSSH

/// OpenSSH's client configuration as Shello imports hosts from it (README section 3), read as
/// ssh_config(5) reads it: keywords in any case, `=` or spaces, quotes and escapes, comments, `Host`
/// patterns with `*`, `?` and `!`, the first value winning, a `Host *` block of defaults, every
/// directive Shello imports with the forms of `ProxyJump` and the forwards, and every other line
/// listed with its number. `randomTextNeverTraps` is a short, seeded version of the fuzz target
/// Fuzz/OpenSSHConfig.
struct OpenSSHConfigTests {
    /// A config as people write them: an Include, a jump host, pattern blocks with a negation, forwards,
    /// a Match block, and defaults at the end.
    static let realWorld = """
        # ~/.ssh/config
        Include ~/.ssh/config.d/*

        Host bastion bastion.example.com
            HostName bastion.example.com
            User jump
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host web-* !web-legacy
            User deploy
            ProxyJump bastion

        Host web-01
            HostName 10.0.1.21

        Host web-legacy
            HostName 10.0.1.9
            User root

        Host db
            HostName=db.internal
            LocalForward 5432 localhost:5432
            LocalForward [::1]:8080 [fd00::5]:80
            RemoteForward 9000 localhost:3000
            DynamicForward 1080

        Match host *.corp exec "test -f ~/.vpn"
            ProxyJump vpn-gw

        Host *
            ServerAliveInterval 30
            User me
            IdentityFile "~/.ssh/My Key"
        """

    // MARK: - The real-world file

    @Test func realWorldFileHasItsAliasesInOrder() {
        let config = OpenSSHConfig(Self.realWorld)

        #expect(
            config.aliases == [
                .init(name: "bastion", line: 4), .init(name: "bastion.example.com", line: 4),
                .init(name: "web-01", line: 14), .init(name: "web-legacy", line: 17), .init(name: "db", line: 21),
            ])
    }

    @Test func realWorldFileGivesEachHostItsSettings() {
        let config = OpenSSHConfig(Self.realWorld)

        let bastion = config.settings(for: "bastion")
        #expect(bastion.hostName?.value == "bastion.example.com")
        #expect(bastion.user?.value == "jump")
        #expect(bastion.port?.value == "2222")
        #expect(bastion.proxyJump == nil)
        // Identity files add up: the host's own, then the default's, in quotes for its space.
        #expect(bastion.identityFiles.map(\.value) == ["~/.ssh/id_ed25519", "~/.ssh/My Key"])

        // The pattern block comes first, so its user wins over the default.
        let web = config.settings(for: "web-01")
        #expect(web.hostName?.value == "10.0.1.21")
        #expect(web.user?.value == "deploy")
        #expect(web.proxyJump?.value == "bastion")
        #expect(web.user?.line == 11)

        // The negation keeps the pattern block out.
        let legacy = config.settings(for: "web-legacy")
        #expect(legacy.user?.value == "root")
        #expect(legacy.proxyJump == nil)

        // `=` without spaces, and the forwards in order.
        let db = config.settings(for: "db")
        #expect(db.hostName?.value == "db.internal")
        #expect(db.user?.value == "me")
        #expect(db.forwards.map(\.keyword) == [.localForward, .localForward, .remoteForward, .dynamicForward])
        #expect(db.forwards.map(\.line) == [23, 24, 25, 26])
        #expect(db.forwards[1].arguments == ["[::1]:8080", "[fd00::5]:80"])
    }

    @Test func realWorldFileListsTheLinesShelloDoesNotImport() {
        let config = OpenSSHConfig(Self.realWorld)

        #expect(
            config.skipped == [
                .init(line: 2, text: "Include ~/.ssh/config.d/*", reason: .include),
                .init(line: 28, text: "Match host *.corp exec \"test -f ~/.vpn\"", reason: .match),
                .init(line: 29, text: "ProxyJump vpn-gw", reason: .inMatchBlock(matchLine: 28)),
                .init(line: 32, text: "ServerAliveInterval 30", reason: .unsupported(keyword: "ServerAliveInterval")),
            ])
    }

    // MARK: - Lines

    @Test(arguments: [
        "HostName example.com", "hostname example.com", "HOSTNAME example.com", "HostName=example.com",
        "HostName = example.com", "HostName\texample.com", "  HostName   example.com   ", "HostName example.com\r",
        "HostName \"example.com\"", "HostName 'example.com'", "HostName example.com # the server",
        "HostName example.com\u{0C}",
    ])
    func keywordInAnyCaseWithEqualsSpacesQuotesOrComment(_ line: String) {
        let config = OpenSSHConfig("Host a\n" + line)

        #expect(config.skipped.isEmpty)
        #expect(config.settings(for: "a").hostName?.arguments == ["example.com"])
    }

    @Test(arguments: [
        (#"IdentityFile "~/.ssh/My Key""#, "~/.ssh/My Key"),
        (#"IdentityFile '~/.ssh/My Key'"#, "~/.ssh/My Key"),
        (#"IdentityFile ~/.ssh/My\ Key"#, "~/.ssh/My Key"),
        (#"IdentityFile ~/.ssh/a"b c"d"#, "~/.ssh/ab cd"),
        (#"IdentityFile "it's""#, "it's"),
        (#"IdentityFile 'say "hi"'"#, #"say "hi""#),
        (#"IdentityFile a\"b"#, #"a"b"#),
        (#"IdentityFile a\\b"#, #"a\b"#),
        (#"IdentityFile a\xb"#, #"a\xb"#),
        (#"IdentityFile key#1"#, "key#1"),
        (##"IdentityFile "# not a comment""##, "# not a comment"),
    ])
    func argumentsAreUnquotedAsOpenSSHSplitsThem(_ line: String, _ argument: String) {
        let config = OpenSSHConfig("Host a\n" + line)

        #expect(config.settings(for: "a").identityFiles.map(\.arguments) == [[argument]])
    }

    @Test func commentsAndBlankLinesAreNothing() {
        let config = OpenSSHConfig("# comment\n\n   # indented\n\t\nHost a # an alias\n  # in the block\n")

        #expect(config.skipped.isEmpty)
        #expect(config.aliases == [.init(name: "a", line: 5)])
        #expect(config.directives.isEmpty)
    }

    @Test func unclosedQuoteIsListed() {
        let config = OpenSSHConfig("Host a\nUser \"deploy\nPort 22")

        #expect(config.skipped == [.init(line: 2, text: "User \"deploy", reason: .unclosedQuote)])
        #expect(config.settings(for: "a").user == nil)
        #expect(config.settings(for: "a").port?.value == "22")
    }

    @Test func keywordsWithoutOrWithTooManyValuesAreListed() {
        let config = OpenSSHConfig(
            "Host\nHost a\nUser\nPort 22 23\nLocalForward 1 a:1 extra\nHostName \"\"\nUser ok\n= value")

        #expect(
            config.skipped == [
                .init(line: 1, text: "Host", reason: .missingValue(nil)),
                .init(line: 3, text: "User", reason: .missingValue(.user)),
                .init(line: 4, text: "Port 22 23", reason: .extraValues(.port)),
                .init(line: 5, text: "LocalForward 1 a:1 extra", reason: .extraValues(.localForward)),
                .init(line: 6, text: "HostName \"\"", reason: .missingValue(.hostName)),
                .init(line: 8, text: "= value", reason: .missingValue(nil)),
            ])
        #expect(config.settings(for: "a").user?.value == "ok")
    }

    @Test func nullCharacterIsListed() {
        let config = OpenSSHConfig("Host a\nUser de\0ploy")

        #expect(config.skipped.map(\.reason) == [.nullCharacter])
        #expect(config.settings(for: "a").user == nil)
    }

    @Test func invalidUTF8IsReadWithReplacements() {
        let bytes = Array("Host a\nUser ".utf8) + [0xFF, 0xFE] + Array("\nPort 2222".utf8)
        let config = OpenSSHConfig(bytes: bytes)

        #expect(config.settings(for: "a").user?.value == "\u{FFFD}\u{FFFD}")
        #expect(config.settings(for: "a").port?.value == "2222")
    }

    // MARK: - Hosts and patterns

    @Test func linesBeforeTheFirstHostApplyToEveryHost() {
        let config = OpenSSHConfig("User early\nHost a\nUser late\nHost b\nPort 2200")

        #expect(config.settings(for: "a").user?.value == "early")
        #expect(config.settings(for: "b").user?.value == "early")
        #expect(config.settings(for: "b").port?.value == "2200")
        #expect(config.settings(for: "unknown").user?.value == "early")
    }

    @Test func firstValueWinsSoDefaultsGoLast() {
        let atEnd = OpenSSHConfig("Host a\nUser own\nPort 1\nHost *\nUser default\nPort 2")
        #expect(atEnd.settings(for: "a").user?.value == "own")
        #expect(atEnd.settings(for: "a").port?.value == "1")
        #expect(atEnd.settings(for: "other").user?.value == "default")

        // A `Host *` first wins over everything after it, as in ssh.
        let atStart = OpenSSHConfig("Host *\nUser default\nHost a\nUser own\nPort 1")
        #expect(atStart.settings(for: "a").user?.value == "default")
        #expect(atStart.settings(for: "a").port?.value == "1")
    }

    @Test func identityFilesAndForwardsAddUpAcrossBlocks() {
        let config = OpenSSHConfig(
            "Host a\nIdentityFile one\nLocalForward 1 x:1\nHost *\nIdentityFile two\nDynamicForward 2\n")

        let settings = config.settings(for: "a")
        #expect(settings.identityFiles.map(\.value) == ["one", "two"])
        #expect(settings.forwards.map(\.line) == [3, 6])
    }

    @Test(arguments: [
        ("web-*", "web-01", true), ("web-*", "db-01", false), ("*", "anything", true), ("web-0?", "web-01", true),
        ("web-0?", "web-012", false), ("*.example.com", "a.example.com", true), ("*.example.com", "example.com", false),
        ("WEB", "web", true), ("web", "WEB", true), ("a*b*c", "aXbYc", true), ("a*b*c", "aXbY", false),
        ("*a*", "banana", true), ("**", "", true), ("?", "", false),
    ])
    func patternMatches(_ pattern: String, _ name: String, _ matches: Bool) {
        #expect(OpenSSHConfig.Pattern(pattern).matches(name) == matches)
    }

    @Test func negatedPatternKeepsTheBlockFromMatching() {
        let config = OpenSSHConfig("Host *.example.com !old.example.com\nUser new\nHost !a\nPort 3")

        #expect(config.settings(for: "web.example.com").user?.value == "new")
        #expect(config.settings(for: "old.example.com").user == nil)
        // A block of negations alone matches nothing.
        #expect(config.settings(for: "b").port == nil)
    }

    @Test func aliasesAreTheConcreteNamesEachOnce() {
        let config = OpenSSHConfig("Host a b* c? !d e\nHost A f\nHost \"g h\"")

        #expect(config.aliases.map(\.name) == ["a", "e", "f", "g h"])
        #expect(config.aliases.map(\.line) == [1, 1, 2, 3])
    }

    // MARK: - Every directive

    @Test func everySupportedKeywordIsKeptWithItsLine() {
        let lines = OpenSSHConfig.Keyword.allCases.map { keyword in
            switch keyword {
            case .localForward, .remoteForward: "\(keyword.name) 1 h:2"
            default: "\(keyword.name) value"
            }
        }
        let config = OpenSSHConfig((["Host a"] + lines).joined(separator: "\n"))

        #expect(config.skipped.isEmpty)
        #expect(config.directives.map(\.keyword) == OpenSSHConfig.Keyword.allCases)
        #expect(config.directives.map(\.line) == Array(2...(lines.count + 1)))
    }

    @Test func otherKeywordsAreListedAsWritten() {
        let config = OpenSSHConfig(
            "Host a\nForwardAgent yes\nproxycommand ssh -W %h:%p jump\nCertificateFile x\nHostKeyAlias b")

        #expect(
            config.skipped.map(\.reason) == [
                .unsupported(keyword: "ForwardAgent"), .unsupported(keyword: "proxycommand"),
                .unsupported(keyword: "CertificateFile"), .unsupported(keyword: "HostKeyAlias"),
            ])
        #expect(config.skipped.map(\.line) == [2, 3, 4, 5])
    }

    @Test func matchBlockEndsAtTheNextHostOrMatch() {
        let config = OpenSSHConfig("Match all\nUser m\nMatch user x\nPort 2\nHost a\nUser a-user\nInclude other")

        #expect(
            config.skipped.map(\.reason) == [
                .match, .inMatchBlock(matchLine: 1), .match, .inMatchBlock(matchLine: 3), .include,
            ])
        #expect(config.settings(for: "a").user?.value == "a-user")
        #expect(config.settings(for: "a").port == nil)
    }

    // MARK: - Values

    @Test(arguments: [("22", 22), ("1", 1), ("65535", 65535), ("02222", 2222)] as [(String, UInt16)])
    func portIsADecimalFrom1To65535(_ text: String, _ port: UInt16) {
        #expect(OpenSSHConfig.port(text) == port)
    }

    @Test(arguments: ["0", "65536", "", "ssh", "-1", "+22", "22 ", "123456", "0x16"])
    func otherPortsAreNone(_ text: String) {
        #expect(OpenSSHConfig.port(text) == nil)
    }

    @Test func proxyJumpForms() {
        typealias Hop = OpenSSHConfig.Hop
        #expect(OpenSSHConfig.ProxyJump("none") == OpenSSHConfig.ProxyJump.none)
        #expect(OpenSSHConfig.ProxyJump("NONE") == OpenSSHConfig.ProxyJump.none)
        #expect(
            OpenSSHConfig.ProxyJump("bastion") == .hops([Hop(text: "bastion", user: nil, host: "bastion", port: nil)]))
        #expect(
            OpenSSHConfig.ProxyJump("admin@jump.example.com:2222")
                == .hops([
                    Hop(text: "admin@jump.example.com:2222", user: "admin", host: "jump.example.com", port: 2222)
                ]))
        #expect(
            OpenSSHConfig.ProxyJump("ssh://admin@jump:2222/")
                == .hops([Hop(text: "admin@jump:2222", user: "admin", host: "jump", port: 2222)]))
        #expect(
            OpenSSHConfig.ProxyJump("[fd00::1]:2222")
                == .hops([Hop(text: "[fd00::1]:2222", user: nil, host: "fd00::1", port: 2222)]))
        #expect(
            OpenSSHConfig.ProxyJump("first,me@second,third:2200")
                == .hops([
                    Hop(text: "first", user: nil, host: "first", port: nil),
                    Hop(text: "me@second", user: "me", host: "second", port: nil),
                    Hop(text: "third:2200", user: nil, host: "third", port: 2200),
                ]))
        // The last @ ends the user, as in OpenSSH.
        #expect(
            OpenSSHConfig.ProxyJump("me@corp@jump")
                == .hops([Hop(text: "me@corp@jump", user: "me@corp", host: "jump", port: nil)]))
    }

    @Test(arguments: [
        "", ",", "a,", "@host", "host:", "host:0", "host:65536", "host:ssh", "[fd00::1", "[fd00::1]x", "ssh://a/b",
        "user@", "a:1:2",
    ])
    func malformedProxyJumpIsNone(_ text: String) {
        #expect(OpenSSHConfig.ProxyJump(text) == nil)
    }

    @Test func forwardForms() throws {
        typealias Forward = OpenSSHConfig.Forward
        func forward(_ line: String) -> Result<Forward, Forward.Problem> {
            let directive = OpenSSHConfig("Host a\n" + line).directives[0]
            return Forward.parse(directive)
        }
        let destination = Forward.Destination(host: "localhost", port: 80)
        #expect(
            forward("LocalForward 8080 localhost:80")
                == .success(Forward(kind: .local, bindAddress: nil, port: 8080, destination: destination)))
        #expect(
            forward("LocalForward 127.0.0.1:8080 localhost:80")
                == .success(Forward(kind: .local, bindAddress: "127.0.0.1", port: 8080, destination: destination)))
        #expect(
            forward("LocalForward [::1]:8080 [fd00::5]:80")
                == .success(
                    Forward(
                        kind: .local, bindAddress: "::1", port: 8080,
                        destination: Forward.Destination(host: "fd00::5", port: 80))))
        #expect(
            forward("LocalForward *:8080 localhost:80")
                == .success(Forward(kind: .local, bindAddress: "*", port: 8080, destination: destination)))
        #expect(
            forward("LocalForward :8080 localhost:80")
                == .success(Forward(kind: .local, bindAddress: "", port: 8080, destination: destination)))
        #expect(
            forward("RemoteForward 0.0.0.0:9000 localhost:80")
                == .success(Forward(kind: .remote, bindAddress: "0.0.0.0", port: 9000, destination: destination)))
        #expect(
            forward("DynamicForward 1080")
                == .success(Forward(kind: .dynamic, bindAddress: nil, port: 1080, destination: nil)))
        #expect(
            forward("DynamicForward localhost:1080")
                == .success(Forward(kind: .dynamic, bindAddress: "localhost", port: 1080, destination: nil)))
    }

    @Test(arguments: [
        ("LocalForward /tmp/sock localhost:80", OpenSSHConfig.Forward.Problem.unixSocket),
        ("LocalForward 8080 /var/run/db.sock", .unixSocket),
        ("RemoteForward /tmp/sock localhost:80", .unixSocket),
        ("RemoteForward 0 localhost:80", .serverChosenPort),
        ("RemoteForward 8080", .reverseDynamic),
        ("RemoteForward localhost:8080", .reverseDynamic),
        ("LocalForward 8080 ${HOST}:80", .environmentVariable),
        ("LocalForward 8080", .malformed),
        ("LocalForward 0 localhost:80", .malformed),
        ("LocalForward 70000 localhost:80", .malformed),
        ("LocalForward 8080 localhost:0", .malformed),
        ("LocalForward 8080 localhost:http", .malformed),
        ("LocalForward 8080 :80", .malformed),
        ("LocalForward 8080 fd00::5:80", .malformed),
        ("LocalForward [::1 localhost:80", .malformed),
        ("DynamicForward 0", .malformed),
        ("DynamicForward a:b:1080", .malformed),
    ])
    func forwardsShelloCannotImportSayWhy(_ line: String, _ problem: OpenSSHConfig.Forward.Problem) {
        let directive = OpenSSHConfig("Host a\n" + line).directives[0]
        #expect(OpenSSHConfig.Forward.parse(directive) == .failure(problem))
    }

    @Test func tokensAreExpandedOrRefused() {
        #expect(OpenSSHConfig.expandingTokens(in: "%h.example.com", ["h": "web"]) == "web.example.com")
        #expect(OpenSSHConfig.expandingTokens(in: "100%%", [:]) == "100%")
        #expect(OpenSSHConfig.expandingTokens(in: "plain", [:]) == "plain")
        #expect(OpenSSHConfig.expandingTokens(in: "%d/.ssh/id", ["h": "web"]) == nil)
        #expect(OpenSSHConfig.expandingTokens(in: "ends with %", [:]) == nil)
    }

    // MARK: - Robustness

    /// Random text, and the real-world file with characters changed, cut short or repeated, never
    /// traps, and each line is read once: as a block, a directive or a skipped line, with numbers in
    /// the file. Seeded, so that a failure repeats. The fuzz target Fuzz/OpenSSHConfig checks the
    /// same.
    @Test func randomTextNeverTraps() {
        var random = SeededRandom(seed: 40)
        let alphabet = Array(" \t\n\r=#\"'\\*?!,:[]/@%Hhost Userport0123456789abcxyz".utf8) + [0, 0xFF]
        let valid = Array(Self.realWorld.utf8)
        for round in 0..<2000 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                bytes = (0..<Int.random(in: 0..<400, using: &random)).map { _ in
                    alphabet[Int.random(in: 0..<alphabet.count, using: &random)]
                }
            } else {
                bytes = valid
                for _ in 0..<Int.random(in: 1...6, using: &random) where !bytes.isEmpty {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<3, using: &random) {
                    case 0: bytes[index] = alphabet[Int.random(in: 0..<alphabet.count, using: &random)]
                    case 1:
                        bytes.removeSubrange(index..<min(bytes.count, index + Int.random(in: 1...40, using: &random)))
                    default: bytes.insert(contentsOf: Array(bytes[index...].prefix(30)), at: index)
                    }
                }
            }
            Self.check(
                OpenSSHConfig(bytes: bytes),
                lineCount: bytes.split(separator: 0x0A, omittingEmptySubsequences: false).count)
        }
    }

    /// The checks of Fuzz/OpenSSHConfig on one file of `lineCount` lines.
    static func check(_ config: OpenSSHConfig, lineCount: Int) {
        let lines = config.blocks.compactMap(\.line) + config.directives.map(\.line) + config.skipped.map(\.line)
        #expect(lines.allSatisfy { (1...max(lineCount, 1)).contains($0) })
        #expect(config.directives.map(\.line) == config.directives.map(\.line).sorted())
        #expect(Set(config.directives.map(\.line)).count == config.directives.count)
        #expect(Set(config.skipped.map(\.line)).isDisjoint(with: config.directives.map(\.line)))
        for alias in config.aliases {
            let settings = config.settings(for: alias.name)
            #expect(settings.directives.allSatisfy { !$0.arguments.isEmpty })
            for directive in settings.forwards {
                _ = OpenSSHConfig.Forward.parse(directive)
            }
            _ = settings.proxyJump.flatMap { OpenSSHConfig.ProxyJump($0.value) }
        }
    }
}
