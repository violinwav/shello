import Testing

@testable import ShelloTmux

/// Reading the sessions that `tmux -u list-sessions -F` lists in `TmuxSession.listFormat`, as tmux
/// 3.2a, 3.4 and 3.7c printed them for the sessions `main` with three windows, `zürich-1`,
/// `$weird*?`, `dot.colon:x` and, before 3.7, which refuses it, a name with a tab: each version
/// escapes and changes names in its own way, and none puts a tab in one.
struct TmuxSessionTests {
    static let tmux32a =
        "$3\t1792738688\t0\t1\t\\$weird*?\n$4\t1792738688\t0\t1\tdot_colon_x\n$0\t1792738688\t0\t3\tmain\n"
        + "$2\t1792738688\t0\t1\ttab\\there\n$1\t1792738688\t0\t1\tz\u{FC}rich-1\n"
    static let tmux34 =
        "$3\t1792738688\t0\t1\t\\\\$weird*?\n$4\t1792738688\t0\t1\tdot_colon_x\n$0\t1792738688\t0\t3\tmain\n"
        + "$2\t1792738688\t0\t1\ttab\\there\n$1\t1792738688\t0\t1\tz\u{FC}rich-1\n"
    static let tmux37c =
        "$2\t1792738687\t0\t1\t$weird*?\n$3\t1792738687\t0\t1\tdot.colon:x\n$0\t1792738687\t0\t3\tmain\n"
        + "$1\t1792738687\t0\t1\tz\u{FC}rich-1\n"

    @Test(arguments: [
        (tmux32a, [#"\$weird*?"#, "dot_colon_x", "main", #"tab\there"#, "zürich-1"]),
        (tmux34, [#"\\$weird*?"#, "dot_colon_x", "main", #"tab\there"#, "zürich-1"]),
        (tmux37c, ["$weird*?", "dot.colon:x", "main", "zürich-1"]),
    ])
    func readsEachSessionAsTmuxListedIt(_ output: String, names: [String]) throws {
        let sessions = TmuxSession.sessions(inListOutput: Array(output.utf8))

        #expect(sessions.map(\.name) == names)
        let main = try #require(sessions.first { $0.name == "main" })
        #expect(main.id == "$0")
        #expect(main.windows == 3)
        #expect(main.attachedClients == 0)
        #expect([1_792_738_687, 1_792_738_688].contains(main.created))
    }

    @Test func readsAnAttachedSession() {
        let sessions = TmuxSession.sessions(inListOutput: Array("$12\t1792738700\t2\t4\twork\r\n".utf8))

        #expect(
            sessions == [TmuxSession(id: "$12", name: "work", created: 1_792_738_700, attachedClients: 2, windows: 4)])
    }

    /// The name comes last, so a tab in one would not shift the fields.
    @Test func nameKeepsATabThatTmuxWouldNeverList() {
        let sessions = TmuxSession.sessions(inListOutput: Array("$1\t1792738700\t0\t1\tone\ttwo\n".utf8))

        #expect(sessions.map(\.name) == ["one\ttwo"])
    }

    /// What the server's shell prints on starting, and lines in no format of Shello's, are left out.
    @Test(arguments: [
        "", "\n", "Welcome to forge\n", "no server running on /tmp/tmux-1000/default\n", "$1\t1\t0\t1\n",
        "$1\t1\t0\t1\t\n", "1\t1\t0\t1\tmain\n", "$\t1\t0\t1\tmain\n", "$x\t1\t0\t1\tmain\n", "$1\t-1\t0\t1\tmain\n",
        "$1\t1\t0\t\tmain\n", "$1\t1\t0\t1x\tmain\n", "$1\t1\t0\t1 \tmain\n",
        "$1\t1234567890123456789\t0\t1\tmain\n", "$1\t\u{FF11}\t0\t1\tmain\n",
    ])
    func leavesOutWhatIsNoSession(_ output: String) {
        #expect(TmuxSession.sessions(inListOutput: Array(output.utf8)).isEmpty)
    }

    @Test func keepsTheSessionsAmongOtherLines() {
        let output = "Last login: today\n$1\t1792738700\t1\t1\tmain\nbye\n$2\t1792738701\t0\t2\twork\n"

        #expect(TmuxSession.sessions(inListOutput: Array(output.utf8)).map(\.id) == ["$1", "$2"])
    }

    @Test func formatListsTheFieldsByTabsWithTheNameLast() {
        #expect(
            TmuxSession.listFormat
                == "#{session_id}\t#{session_created}\t#{session_attached}\t#{session_windows}\t#{session_name}")
    }
}
