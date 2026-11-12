import Accessibility
import Observation
import ShelloModel
import SwiftTerm
import Synchronization
import UIKit
import os

/// One terminal: its view, the byte stream it is attached to, and its state for the screen that
/// shows it. The terminal outlives its streams: a tab attaches it to each new connection, and its
/// scrollback stays.
///
/// Output is parsed off the main actor, a slice of at most `maximumFeedBytes` at a time, and
/// SwiftTerm draws what changed once per display refresh (STACK section 6). Input goes from the
/// main actor straight to the stream, never behind output.
@Observable
public final class TerminalController {
    /// The terminal on screen. The screen that shows the terminal puts it in its hierarchy.
    @ObservationIgnored public let view: TerminalHostView

    /// The user's settings. A change applies at once: a new font size resizes the grid, which is
    /// reported to the stream.
    public var preferences: TerminalPreferences {
        didSet {
            guard preferences != oldValue else { return }
            view.apply(preferences)
            if preferences.fontSize != oldValue.fontSize {
                announceSize()
            }
            updateAnnouncing()
        }
    }

    /// The terminal's grid, as last reported to the stream.
    public private(set) var size: TerminalSize
    public private(set) var streamState = StreamState.detached
    /// Whether the bell rang while the terminal was not on screen: the hook for the badge on a
    /// background tab (README section 5).
    public private(set) var hasUnseenBell = false
    /// Whether the terminal is on screen. Seeing it clears the bell's badge.
    public var isVisible = false {
        didSet {
            if isVisible { hasUnseenBell = false }
        }
    }
    /// The window title the program in the terminal set (OSC 0 or 2), on one line and without
    /// control characters, since it comes from the server; empty while there is none. A tab shows
    /// it as its name.
    public private(set) var title = ""
    /// A paste of more than one line that waits for the user to confirm it.
    public private(set) var pendingPaste: PendingPaste?
    /// Whether the screen shows its search bar. Closing it ends the search, and gives the
    /// keyboard back to the terminal if the terminal had it.
    public var isShowingSearch = false {
        didSet {
            guard isShowingSearch != oldValue else { return }
            if isShowingSearch {
                resumesTypingAfterSearch = view.isFirstResponder
            } else {
                endSearch()
                if resumesTypingAfterSearch {
                    _ = view.becomeFirstResponder()
                }
                // VoiceOver's focus was in the search bar, which goes with this update.
                Task { UIAccessibility.post(notification: .layoutChanged, argument: self.view) }
            }
        }
    }
    /// Counts requests to put the focus in the search field, which Find makes each time.
    public private(set) var searchFocusRequests = 0
    /// Control and Alt as the extra keys row has them, which the screen shows over the terminal:
    /// the row can scroll them out of view (README section 6: the armed state is always visible).
    public private(set) var modifiers = ArmedModifiers()

    @ObservationIgnored private var stream: (any TerminalByteStream)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Counts attachments, so that a stream that ends after another took its place changes
    /// nothing.
    @ObservationIgnored private var attachment = 0
    @ObservationIgnored private let feedback: TerminalFeedback
    @ObservationIgnored private let announcements = Announcements()
    @ObservationIgnored private var announcementTimer: Timer?
    /// The output announcement VoiceOver is reading, and since when.
    @ObservationIgnored private var outputAnnouncement: (text: String, posted: ContinuousClock.Instant)?
    @ObservationIgnored private var voiceOverObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var announcementObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var bellGate = BellGate()
    /// VoiceOver says "Bell" less often than the bell flashes.
    @ObservationIgnored private var bellSpeechGate = BellGate(minimumInterval: .seconds(3))
    @ObservationIgnored private var resumesTypingAfterSearch = false

    /// The most bytes parsed at a time. The parser holds the terminal's lock while it parses, and
    /// the lock is fair, so the main thread waits for at most one slice each time it takes the
    /// lock: to register a key, or to prepare a frame. A small slice keeps those waits short.
    nonisolated public static let maximumFeedBytes = 4 * 1024

    /// A terminal whose Shello keyboard hides while `hardwareKeyboard` says a hardware keyboard is
    /// attached; without one, it never hides.
    public convenience init(
        preferences: TerminalPreferences = TerminalPreferences(), theme: TerminalTheme = .night,
        typeface: TerminalTypeface = .system, renderer: TerminalRenderer = .standard,
        hardwareKeyboard: (any HardwareKeyboardMonitor)? = nil
    ) {
        self.init(
            preferences: preferences, theme: theme, typeface: typeface, renderer: renderer,
            hardwareKeyboard: hardwareKeyboard, feedback: .system)
    }

    init(
        preferences: TerminalPreferences, theme: TerminalTheme, typeface: TerminalTypeface,
        renderer: TerminalRenderer, hardwareKeyboard: (any HardwareKeyboardMonitor)?, feedback: TerminalFeedback
    ) {
        self.preferences = preferences
        self.feedback = feedback
        view = TerminalHostView(
            preferences: preferences, theme: theme, typeface: typeface, renderer: renderer,
            hardwareKeyboard: hardwareKeyboard)
        size = view.currentSize
        view.terminalDelegate = self
        view.events = self
        updateAnnouncing()
        voiceOverObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnnouncing() }
        }
        announcementObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let value = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
            let text = (value as? String) ?? (value as? NSAttributedString)?.string
            MainActor.assumeIsolated {
                // Another announcement that finished leaves the output's waiting; one VoiceOver
                // does not name is taken for the output's.
                if let self, text == nil || text == self.outputAnnouncement?.text {
                    self.outputAnnouncement = nil
                }
            }
        }
    }

    isolated deinit {
        pump?.cancel()
        announcementTimer?.invalidate()
        for observer in [voiceOverObserver, announcementObserver].compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
        Self.close(view)
    }

    /// Releases the view's display link and renderer, once the GPU is done with it.
    private static func close(_ view: TerminalHostView) {
        guard !view.updateUiClosed() else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            close(view)
        }
    }

    // MARK: - Streams

    nonisolated public enum StreamState: Equatable, Sendable {
        /// Not attached to a stream.
        case detached
        case attached
        /// The remote end closed the stream.
        case ended
        /// The stream failed, for the reason given.
        case failed(String)
    }

    /// Attaches the terminal to `stream`, after detaching it from the one before. The stream gets
    /// the terminal's size at once.
    public func attach<Stream: TerminalByteStream>(_ stream: Stream) {
        detach()
        let attachment = attachment
        self.stream = stream
        streamState = .attached
        stream.resize(to: size)
        let output = stream.output
        let feed = view.feedSender
        let announcements = announcements
        pump = Task { [weak self] in
            let end = await Self.pump(output, into: feed, announcements: announcements)
            guard let self, self.attachment == attachment else { return }
            self.stream = nil
            self.streamState = end
        }
    }

    /// Detaches the terminal from its stream. The terminal keeps what it shows.
    public func detach() {
        attachment += 1
        pump?.cancel()
        pump = nil
        stream = nil
        streamState = .detached
    }

    /// Readies the terminal for the next connection's shell, after the last connection dropped
    /// (`TabTerminal`): it leaves the alternate screen a program may have been in, back to the
    /// scrollback, turns off mouse reporting, bracketed paste and focus reports, resets the other
    /// modes and the attributes (DECSTR), and starts a new line. The scrollback stays.
    public func prepareForNextConnection() {
        var reset = view.isShowingAlternateScreen ? Self.leaveAlternateScreen : []
        reset += Self.resetModes
        view.feedSender.feed(byteArray: reset[...])
        title = ""
    }

    /// Shows Shello's `note` on a line of its own, after `Shello:` in bold, which marks it as no
    /// output of the server's (`TabTerminal`). It is cleaned as a window title is, since it can carry
    /// what the server said. VoiceOver can read it in the terminal; it is not announced here, since
    /// the announcement of the connection that follows would cut it off, and says it instead.
    public func showNote(_ note: String) {
        let text = Self.displayableLine(note, maximumLength: Self.maximumNoteLength)
        let newLine = view.terminalStateSnapshot().cursor.col == 0 ? "" : "\r\n"
        view.feedSender.feed(byteArray: Array((newLine + Self.noteMarker + text + "\r\n").utf8)[...])
    }

    /// What comes before a note: `Shello:` in bold, then normal text.
    nonisolated static let noteMarker = "\u{1B}[1mShello:\u{1B}[22m "

    /// The most characters of a note the terminal shows.
    nonisolated static let maximumNoteLength = 300

    /// Back to the normal screen, with the cursor where it was before the program entered the
    /// alternate one. Only sent while the alternate screen shows: elsewhere it would move the cursor
    /// to a position saved long before.
    nonisolated static let leaveAlternateScreen = Array("\u{1B}[?1049l".utf8)

    /// Soft reset, then mouse reporting (X10, button, any-event, SGR and urxvt encodings), bracketed
    /// paste and focus reports off, and a new line.
    nonisolated static let resetModes = Array(
        ("\u{1B}[!p" + "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1015l"
            + "\u{1B}[?2004l\u{1B}[?1004l\r\n").utf8)

    /// Feeds the stream's output to the terminal until the stream ends or the task is cancelled.
    @concurrent
    private nonisolated static func pump<Output: AsyncSequence & Sendable>(
        _ output: Output, into feed: TerminalFeedSender, announcements: Announcements
    ) async -> StreamState where Output.Element == [UInt8] {
        do {
            for try await chunk in output {
                announcements.output(chunk)
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    let end = min(start + maximumFeedBytes, chunk.endIndex)
                    let interval = TerminalSignposts.signposter.beginInterval("Feed", "\(end - start) bytes")
                    feed.feed(byteArray: chunk[start..<end])
                    TerminalSignposts.signposter.endInterval("Feed", interval)
                    start = end
                }
            }
            return .ended
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Search

    /// Where a search's match is among all matches: `index` counts from 1. Counting stops at
    /// `countLimit` matches, so a match after them has an index of 0, as has no match.
    nonisolated public struct SearchResult: Equatable, Sendable {
        public static let countLimit = 1000

        public var index: Int
        public var total: Int

        public static let none = SearchResult(index: 0, total: 0)

        /// Whether there may be more matches than `total`.
        public var isCapped: Bool { total >= Self.countLimit }

        /// The result as VoiceOver says it, such as "Match 2 of 5".
        var spokenDescription: String {
            let total = isCapped ? "\(total.formatted()) or more" : "\(total)"
            switch (index, self.total) {
            case (_, 0): return "No matches"
            case (0, _): return "\(total) matches"
            default: return "Match \(index) of \(total)"
            }
        }
    }

    /// Where the last search's match is, which a new grid size keeps.
    public private(set) var searchResult = SearchResult.none
    @ObservationIgnored private var searchTerm = ""

    /// Shows the search bar and puts the focus in its field, as Find does.
    public func showSearch() {
        isShowingSearch = true
        searchFocusRequests += 1
    }

    /// Finds `term` in the scrollback and on screen, ignoring case, and selects the match. The
    /// first search goes up from the bottom, to the most recent output; `backwards: false` goes
    /// down again.
    @discardableResult
    public func search(for term: String, backwards: Bool = true) -> SearchResult {
        searchTerm = term
        guard !term.isEmpty else {
            view.clearSearch()
            searchResult = .none
            return .none
        }
        var found = backwards ? view.findPrevious(term) : view.findNext(term)
        if !found, backwards {
            // Going on up past the first match, round from the bottom, SwiftTerm skips a match on
            // the continuation of a wrapped line, such as a command after a prompt wider than the
            // terminal. A search that starts at the bottom finds it.
            view.clearSearch()
            found = view.findPrevious(term)
        }
        searchResult = found ? matchSummary() : .none
        return searchResult
    }

    public func endSearch() {
        view.clearSearch()
        searchTerm = ""
        searchResult = .none
    }

    private func matchSummary() -> SearchResult {
        let summary = view.searchMatchSummary(searchTerm, limit: SearchResult.countLimit)
        return SearchResult(index: summary.index, total: summary.total)
    }

    /// Selects the last search's match again. SwiftTerm drops the selection that marks it each
    /// time the grid changes, as it does when the keyboard comes or goes. The search steps to it
    /// from the nearer end; a match without an index gives way to the most recent match.
    private func reselectMatch() {
        let result = searchResult
        guard result.total > 0, !view.hasActiveSelection else { return }
        let stepsUp = result.total - result.index
        let goesUp = result.index == 0 || (!result.isCapped && stepsUp < result.index - 1)
        let steps = result.index == 0 ? 0 : goesUp ? stepsUp : result.index - 1
        view.clearSearch()
        var found = false
        for step in 0...steps {
            found =
                goesUp
                ? view.findPrevious(searchTerm, scrollToResult: step == steps)
                : view.findNext(searchTerm, scrollToResult: step == steps)
            if !found { break }
        }
        searchResult = found ? matchSummary() : .none
    }

    /// Tells VoiceOver where the last search went: which match, and the line it is on.
    public func announceSearchResult() {
        guard feedback.isVoiceOverRunning(), !searchTerm.isEmpty else { return }
        var message = searchResult.spokenDescription
        if searchResult.index > 0, !searchResult.isCapped {
            let text = String(decoding: view.getBufferAsData(), as: UTF8.self)
            if let line = Self.line(ofMatch: searchResult.index, of: searchTerm, in: text, total: searchResult.total) {
                message += ": \(line)"
            }
        }
        feedback.announce(message, .default)
    }

    /// The row of `text` with match number `index` of `term`, counted from 1 as the search counts:
    /// ignoring case, without overlaps. The search joins the rows of a line too long for the
    /// screen, so it finds a match that runs over the end of a row, which this count misses, and
    /// every later match would be off by one. So there is a row only when this count is the
    /// search's `total`.
    nonisolated static func line(ofMatch index: Int, of term: String, in text: String, total: Int) -> String? {
        var count = 0
        var found: Substring?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = line.startIndex..<line.endIndex
            while let match = line.range(of: term, options: .caseInsensitive, range: rest) {
                count += 1
                if count == index {
                    found = line
                }
                rest = match.upperBound..<line.endIndex
            }
        }
        guard count == total, let found else { return nil }
        return OutputAnnouncer.spoken(found)
    }

    // MARK: - Paste

    /// Text of more than one line, pasted while bracketed paste is off.
    nonisolated public struct PendingPaste: Identifiable, Sendable {
        public let id = UUID()
        public let lineCount: Int
        fileprivate let text: String
    }

    public func confirmPaste() {
        guard let pendingPaste else { return }
        self.pendingPaste = nil
        view.pasteText(pendingPaste.text)
    }

    public func cancelPaste() {
        pendingPaste = nil
    }

    // MARK: - Font size

    /// Makes the text larger or smaller by `points`.
    public func changeFontSize(by points: CGFloat) {
        preferences.fontSize += points
    }

    public func resetFontSize() {
        preferences.fontSize = TerminalPreferences.defaultFontSize
    }

    // MARK: - VoiceOver

    /// Reads the line the cursor is on aloud (README section 16).
    public func readCurrentLine() {
        let line = OutputAnnouncer.spoken(view.currentLine)
        feedback.announce(line.isEmpty ? "Empty line" : line, .default)
    }

    /// Tells VoiceOver the new size after the font size changed.
    private func announceSize() {
        guard isVisible, feedback.isVoiceOverRunning() else { return }
        feedback.announce(
            "\(Int(preferences.fontSize)) point text, \(size.columns) columns, \(size.rows) rows", .default)
    }

    /// How long new output waits, at most, for VoiceOver to finish reading the output before.
    static let outputAnnouncementTimeout: Duration = .seconds(20)

    /// Reads new output aloud, if there is any to read: the announcement timer calls it once per
    /// interval while VoiceOver runs and the user wants output read. Output is read only while the
    /// terminal is on screen, after VoiceOver has finished reading the output before, and without
    /// cutting off what VoiceOver is saying. Lines that arrive meanwhile are summed up.
    func announceNewOutput(at now: ContinuousClock.Instant = .now) {
        guard isVisible else { return }
        if let outputAnnouncement, now - outputAnnouncement.posted < Self.outputAnnouncementTimeout {
            return
        }
        guard let text = announcements.announcement(at: now) else { return }
        outputAnnouncement = (text, now)
        feedback.announce(text, .low)
    }

    private func updateAnnouncing() {
        let isOn = preferences.announcesOutput && feedback.isVoiceOverRunning()
        announcements.setOn(isOn)
        outputAnnouncement = nil
        if isOn, announcementTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.announceNewOutput() }
            }
            RunLoop.main.add(timer, forMode: .common)
            announcementTimer = timer
        } else if !isOn {
            announcementTimer?.invalidate()
            announcementTimer = nil
        }
    }
}

extension TerminalController: TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        announcements.input(bytes)
        TerminalSignposts.signposter.emitEvent("Input", "\(bytes.count) bytes")
        stream?.send(bytes)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        reselectMatch()
        let newSize = view.currentSize
        guard newSize != size else { return }
        size = newSize
        stream?.resize(to: newSize)
    }

    /// The bell: a haptic tap and a flash, at most twice a second (README section 5). VoiceOver
    /// says it too, since neither reaches every user, but less often. In the background, it only
    /// marks the tab.
    public func bell(source: TerminalView) {
        guard isVisible else {
            hasUnseenBell = true
            return
        }
        let now = ContinuousClock.now
        guard bellGate.allows(at: now) else { return }
        feedback.tap()
        view.flashForBell()
        if feedback.isVoiceOverRunning(), bellSpeechGate.allows(at: now) {
            feedback.announce("Bell", .default)
        }
    }

    /// The program set the window title, which the tab shows.
    public func setTerminalTitle(source: TerminalView, title: String) {
        self.title = Self.displayableTitle(title)
    }

    /// The most characters of a window title a tab shows.
    nonisolated static let maximumTitleLength = 64

    /// `title` as a tab can show it: the server's text, without the control characters and
    /// bidirectional overrides that could make it read as something else, on one line, at most
    /// `maximumTitleLength` characters long.
    nonisolated static func displayableTitle(_ title: String) -> String {
        displayableLine(title, maximumLength: maximumTitleLength)
    }

    /// `text` without the control characters and bidirectional overrides that could make it read as
    /// something else, its words on one line, at most `maximumLength` characters long.
    nonisolated static func displayableLine(_ text: String, maximumLength: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: " "
            case .format where (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value):
                " "
            default: scalar
            }
        }
        let words = String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(maximumLength))
    }

    // SwiftTerm's other events: the working directory and links come with shell integration (v1).
    // OSC 52 stays off, so clipboardCopy keeps its default, which does nothing, and clipboardRead its
    // default, which refuses (README section 5).
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A tab attaches each new connection's shell to its terminal, which keeps its scrollback.
extension TerminalController: TabTerminal {}

extension TerminalController: TerminalHostViewEvents {
    func terminalView(_ view: TerminalHostView, wantsToPaste text: String) {
        let bracketed = view.terminalStateSnapshot().bracketedPasteMode
        switch PastePolicy.decision(for: text, bracketedPasteMode: bracketed) {
        case .paste: view.pasteText(text)
        case .confirm(let lineCount): pendingPaste = PendingPaste(lineCount: lineCount, text: text)
        }
    }

    func terminalView(_ view: TerminalHostView, zoomedTo fontSize: CGFloat) {
        preferences.fontSize = fontSize
    }

    func terminalView(_ view: TerminalHostView, performs action: TerminalAccessibilityAction) {
        switch action {
        case .readCurrentLine: readCurrentLine()
        case .copyCurrentLine: copyForVoiceOver(view.currentLine)
        case .copyScreen: copyForVoiceOver(view.screenText)
        case .biggerText: changeFontSizeForVoiceOver(by: 1)
        case .smallerText: changeFontSizeForVoiceOver(by: -1)
        }
    }

    func terminalView(_ view: TerminalHostView, modifiersChanged modifiers: ArmedModifiers) {
        self.modifiers = modifiers
    }

    /// A new font size says its grid; at either end of the sizes, VoiceOver says that instead.
    private func changeFontSizeForVoiceOver(by points: CGFloat) {
        let before = preferences.fontSize
        changeFontSize(by: points)
        if preferences.fontSize == before {
            feedback.announce(points > 0 ? "Largest text size" : "Smallest text size", .default)
        }
    }

    private func copyForVoiceOver(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback.announce("Nothing to copy", .default)
            return
        }
        feedback.copy(text)
        feedback.announce("Copied", .default)
    }
}

extension TerminalRenderer {
    /// The renderer Shello uses, chosen by measuring both (see TerminalPerformanceTests).
    public static let standard = TerminalRenderer.coreText
}

/// How urgently VoiceOver speaks an announcement.
typealias AnnouncementPriority = AttributeScopes.AccessibilityAttributes.AnnouncementPriorityAttribute
    .AnnouncementPriority

/// What a terminal tells the user other than on screen, and the pasteboard. Tests replace it.
struct TerminalFeedback {
    var isVoiceOverRunning: () -> Bool
    /// Speaks `message` with VoiceOver. A `.low` message waits until VoiceOver has finished what
    /// it is saying.
    var announce: (_ message: String, _ priority: AnnouncementPriority) -> Void
    /// The bell's haptic tap.
    var tap: () -> Void
    /// Puts `text` on the pasteboard.
    var copy: (_ text: String) -> Void

    static let system = TerminalFeedback(
        isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
        announce: { message, priority in
            var text = AttributedString(message)
            text.accessibilitySpeechAnnouncementPriority = priority
            AccessibilityNotification.Announcement(text).post()
        },
        tap: { UIImpactFeedbackGenerator(style: .light).impactOccurred() },
        copy: { UIPasteboard.general.string = $0 })
}

/// The bell's limit: at most two a second, under the three flashes a second that WCAG 2.3.1 allows.
nonisolated struct BellGate {
    var minimumInterval: Duration
    private var last: ContinuousClock.Instant?

    init(minimumInterval: Duration = .milliseconds(500)) {
        self.minimumInterval = minimumInterval
    }

    mutating func allows(at now: ContinuousClock.Instant) -> Bool {
        if let last, now - last < minimumInterval {
            return false
        }
        last = now
        return true
    }
}

/// The output announcer, shared between the pump, which feeds it off the main actor, and the
/// announcement timer. It only reads output while VoiceOver is on.
nonisolated final class Announcements: Sendable {
    private struct State {
        var isOn = false
        var announcer = OutputAnnouncer()
    }

    private let state = Mutex(State())

    func setOn(_ isOn: Bool) {
        state.withLock { state in
            guard state.isOn != isOn else { return }
            state.isOn = isOn
            state.announcer = OutputAnnouncer()
        }
    }

    func output(_ bytes: [UInt8]) {
        state.withLock { state in
            guard state.isOn else { return }
            state.announcer.output(bytes, at: .now)
        }
    }

    func input(_ bytes: [UInt8]) {
        state.withLock { state in
            guard state.isOn else { return }
            state.announcer.input(bytes, at: .now)
        }
    }

    func announcement(at now: ContinuousClock.Instant) -> String? {
        state.withLock { state in
            state.isOn ? state.announcer.announcement(at: now) : nil
        }
    }
}

/// The terminal's signposts, for Instruments and the performance tests (STACK section 6).
nonisolated enum TerminalSignposts {
    static let signposter = OSSignposter(subsystem: "ch.shello.Shello", category: "Terminal")
}
