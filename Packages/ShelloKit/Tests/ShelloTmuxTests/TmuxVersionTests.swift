import Testing

@testable import ShelloTmux

/// Reading tmux's version from what `tmux -V` printed (STACK section 7.6): the test servers' tmux,
/// releases with letters and release candidates, development builds, and lines the server's shell
/// printed first.
struct TmuxVersionTests {
    /// What the test servers' tmux printed, and what other builds print.
    @Test(arguments: [
        ("tmux 3.7c\n", "3.7c", 3, 7),  // Alpine 3.24
        ("tmux 3.4\n", "3.4", 3, 4),  // Ubuntu 24.04
        ("tmux 3.2a\n", "3.2a", 3, 2),  // Alpine 3.15
        ("tmux 1.8\n", "1.8", 1, 8),
        ("tmux 1.10\n", "1.10", 1, 10),
        ("tmux 3.2-rc3\n", "3.2-rc3", 3, 2),
        ("tmux next-3.6\n", "next-3.6", 3, 6),
        ("tmux 3.5a+git20251001\n", "3.5a+git20251001", 3, 5),
        ("tmux 3.4", "3.4", 3, 4),
        ("tmux 3.4\r\n", "3.4", 3, 4),
        ("  tmux\t3.4  \n", "3.4", 3, 4),
    ])
    func readsTheVersion(_ output: String, name: String, major: Int, minor: Int) throws {
        let version = try #require(TmuxVersion(versionOutput: Array(output.utf8)))

        #expect(version.name == name)
        #expect(version.description == name)
        #expect(version.release == TmuxVersion.Release(major: major, minor: minor))
    }

    /// A build of tmux's development branch from before it named the next release, and OpenBSD's
    /// own tmux, have no release: both follow tmux's newest code.
    @Test(arguments: ["tmux master\n", "tmux openbsd-7.6\n"])
    func developmentAndOpenBSDBuildsCountAsNew(_ output: String) throws {
        let version = try #require(TmuxVersion(versionOutput: Array(output.utf8)))

        #expect(version.release == nil)
        #expect(version.isAtLeast(Tmux.minimumRelease))
    }

    /// A shell's startup files can print before the command runs; the version is on the last line
    /// that starts with tmux.
    @Test func readsTheLastLineThatStartsWithTmux() throws {
        let output = "Welcome to forge\ntmux sessions live in /tmp\nLast login: today\ntmux 3.4\n"

        let version = try #require(TmuxVersion(versionOutput: Array(output.utf8)))

        #expect(version.name == "3.4")
    }

    @Test(arguments: [
        "", "\n", "tmux\n", "tmux \n", "tmux 3\n", "tmux 3.\n", "tmux .4\n", "tmux x.y\n", "tmux 12345.1\n",
        "tmux 3.12345\n", "3.4\n", "tmux: 3.4\n", "Tmux 3.4\n", "usage: tmux [-2CDlNuVv] [-c shell-command]\n",
        "bash: line 1: tmux: command not found\n", "tmux 3.4\u{1B}[31m\n", "tmux 3.4\u{0}\n", "tmux 3,4\n",
        "tmux \u{FF13}.4\n", "tmux 3.4\ntmux nonsense\n", "tmux " + String(repeating: "1", count: 30) + ".4\n",
    ])
    func refusesWhatIsNoVersion(_ output: String) {
        #expect(TmuxVersion(versionOutput: Array(output.utf8)) == nil)
    }

    @Test func refusesBytesThatAreNotText() {
        #expect(TmuxVersion(versionOutput: [0x74, 0x6D, 0x75, 0x78, 0x20, 0xFF, 0xFE, 0x0A]) == nil)
    }

    @Test func releasesCompareByMajorThenMinor() {
        let releases = [(1, 8), (1, 9), (1, 10), (2, 0), (3, 2), (3, 10)].map {
            TmuxVersion.Release(major: $0.0, minor: $0.1)
        }

        #expect(releases == releases.sorted())
        #expect(TmuxVersion.Release(major: 3, minor: 4).description == "3.4")
    }

    /// tmux 1.8 added `new-session -A`; 3.4a is release 3.4.
    @Test func attachesFromTmux18On() throws {
        #expect(Tmux.minimumRelease == TmuxVersion.Release(major: 1, minor: 8))
        #expect(try #require(TmuxVersion(name: "1.8")).isAtLeast(Tmux.minimumRelease))
        #expect(try #require(TmuxVersion(name: "1.9a")).isAtLeast(Tmux.minimumRelease))
        #expect(try #require(TmuxVersion(name: "next-1.8")).isAtLeast(Tmux.minimumRelease))
        #expect(try !#require(TmuxVersion(name: "1.7")).isAtLeast(Tmux.minimumRelease))
        #expect(try !#require(TmuxVersion(name: "1.6")).isAtLeast(Tmux.minimumRelease))
        #expect(try #require(TmuxVersion(name: "3.4a")).release == TmuxVersion.Release(major: 3, minor: 4))
    }
}
