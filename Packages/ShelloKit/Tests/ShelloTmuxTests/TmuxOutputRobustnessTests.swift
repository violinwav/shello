import Testing

@testable import ShelloTmux

/// The tmux parsers read what a server Shello does not control printed, so whatever they are given,
/// they never trap, and what they accept follows their rules. Fuzz/TmuxOutput checks the same with
/// libFuzzer on Linux; this is its short, seeded stand-in, which runs with every `xcodebuild test`.
struct TmuxOutputRobustnessTests {
    /// What tmux printed, which the random edits start from, so that they reach deep into the parsers.
    static let seeds = [
        "tmux 3.4\n", "tmux 3.7c\n", "tmux next-3.6\n", "tmux master\n", "tmux 3.2-rc3\r\n",
        "Welcome\ntmux 1.8\n", TmuxSessionTests.tmux32a, TmuxSessionTests.tmux34, TmuxSessionTests.tmux37c,
        "$12\t1792738700\t2\t4\twork\r\n",
    ].map { Array($0.utf8) }

    @Test func randomBytesNeverTrap() {
        var random = SeededRandom(seed: 0x544D_5558)
        for _ in 0..<20_000 {
            let count = Int.random(in: 0...96, using: &random)
            let alphabet: [UInt8] = Array("tmux $0123456789.-abc\t\n\r".utf8) + [0x00, 0x1B, 0xC3, 0xBC, 0xFF]
            // Bytes from all over, or from the characters the parsers look for.
            let bytes =
                Bool.random(using: &random)
                ? (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
                : (0..<count).map { _ in alphabet.randomElement(using: &random)! }
            Self.check(bytes)
        }
    }

    @Test func editedOutputNeverTraps() {
        var random = SeededRandom(seed: 2026)
        var versions = 0
        var sessions = 0
        for _ in 0..<20_000 {
            var bytes = Self.seeds.randomElement(using: &random)!
            for _ in 0..<Int.random(in: 1...4, using: &random) where !bytes.isEmpty {
                let index = Int.random(in: bytes.indices, using: &random)
                switch Int.random(in: 0..<4, using: &random) {
                case 0: bytes[index] = UInt8.random(in: 0...255, using: &random)
                case 1: bytes.remove(at: index)
                case 2: bytes.insert(Array("\t\n$.-9 ".utf8).randomElement(using: &random)!, at: index)
                default: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + 8)], at: index)
                }
            }
            let (version, listed) = Self.check(bytes)
            if version != nil { versions += 1 }
            sessions += listed
        }
        // Some edits leave the output readable, and those must read.
        #expect(versions > 100)
        #expect(sessions > 100)
    }

    /// Reads `bytes` with both parsers, and checks that what they accept follows their rules.
    @discardableResult
    private static func check(_ bytes: [UInt8]) -> (TmuxVersion?, Int) {
        let version = TmuxVersion(versionOutput: bytes)
        if let version {
            #expect(!version.name.isEmpty && version.name.utf8.count <= TmuxVersion.maximumNameLength)
            #expect(version.name.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.generalCategory != .control })
            if let release = version.release {
                #expect(release.major >= 0 && release.minor >= 0)
            }
        }
        let sessions = TmuxSession.sessions(inListOutput: bytes)
        for session in sessions {
            #expect(session.id.hasPrefix("$") && session.id.count > 1)
            #expect(!session.name.isEmpty && !session.name.contains("\n"))
            #expect(session.created >= 0 && session.attachedClients >= 0 && session.windows >= 0)
        }
        #expect(sessions.count <= bytes.count(where: { $0 == UInt8(ascii: "\n") }) + 1)
        return (version, sessions.count)
    }
}

/// A random number generator that repeats its numbers for the same seed (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
