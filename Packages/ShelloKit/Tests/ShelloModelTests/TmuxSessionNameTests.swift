import Testing

@testable import ShelloModel

/// The name of a host's tmux session (README section 8): what Shello can type into any shell and
/// hand to tmux without either reading more into it.
struct TmuxSessionNameTests {
    @Test(arguments: ["main", "work", "0", "deploy-1", "ops_2", "_x", "A-Z_09", String(repeating: "a", count: 64)])
    func takesLettersDigitsHyphensAndUnderscores(_ name: String) {
        #expect(TmuxSessionName(name)?.rawValue == name)
        #expect(TmuxSessionName(name)?.description == name)
    }

    /// Empty, too long, a leading hyphen that reads as an option, what a shell reads (quotes, spaces,
    /// expansions, line breaks), and what tmux reads or changes (`$`, `=`, patterns, `.` and `:`).
    @Test(arguments: [
        "", " ", "-main", "my session", "main ", " main", "web.1", "a:b", "$1", "=main", "pro*", "a?", "[ab]", "it's",
        "a\"b", "a\\b", "a\nb", "a\tb", "a\rb", "z\u{FC}rich", "\u{0}", "`id`", "$(id)", "a;b", "a|b", "~", "#{pane}",
        "a\u{200B}b", String(repeating: "a", count: 65),
    ])
    func refusesWhatAShellOrTmuxWouldReadMoreInto(_ name: String) {
        #expect(TmuxSessionName(name) == nil)
    }
}
