import ShelloTerminalUI
import SwiftUI

/// A terminal on screen (README section 5), whatever it is attached to: the terminal demo here,
/// an SSH connection behind a tab once tabs come (#28). Search is a bar under the terminal, above
/// the keyboard, where the system's find bar goes; a paste of more lines asks first; a new font
/// size shows the grid's new size for a moment.
struct TerminalScreen: View {
    let controller: TerminalController
    @State private var searchTerm = ""
    /// VoiceOver's announcement of where the search went, which waits while the user types.
    @State private var searchAnnouncement: Task<Void, Never>?
    /// The text size and grid after a font size change, shown for a moment.
    @State private var zoomFeedback: ZoomFeedback?
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    var body: some View {
        TerminalViewHost(controller: controller)
            // The UI design's margins around the terminal's text.
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if controller.isShowingSearch {
                    FindBar(
                        term: $searchTerm, result: controller.searchResult,
                        focusRequests: controller.searchFocusRequests
                    ) {
                        search(backwards: true)
                    } next: {
                        search(backwards: false)
                    } done: {
                        endSearch()
                    }
                }
            }
            .overlay {
                if let zoomFeedback {
                    // VoiceOver hears the new size from the terminal.
                    zoomFeedback
                        .accessibilityHidden(isVoiceOverEnabled)
                }
            }
            // Not under the navigation bar, whose title follows the app's appearance and would be
            // dark on the terminal's dark in light mode.
            .background(Color(uiColor: controller.view.theme.background.uiColor), ignoresSafeAreaEdges: .bottom)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Search", systemImage: "magnifyingglass") {
                        if controller.isShowingSearch {
                            endSearch()
                        } else {
                            controller.showSearch()
                        }
                    }
                    .accessibilityAddTraits(controller.isShowingSearch ? .isSelected : [])
                }
            }
            .alert(
                "Paste \(controller.pendingPaste?.lineCount ?? 0) Lines?",
                isPresented: Binding(
                    get: { controller.pendingPaste != nil },
                    set: { if !$0 { controller.cancelPaste() } }),
                presenting: controller.pendingPaste
            ) { _ in
                Button("Paste") { controller.confirmPaste() }
                Button("Cancel", role: .cancel) { controller.cancelPaste() }
            } message: { _ in
                Text(
                    "The program in this terminal hasn’t turned on bracketed paste, so each line runs as a "
                        + "command as soon as it arrives.")
            }
            .onChange(of: searchTerm) { _, term in
                controller.search(for: term)
                announceSearchResult(after: .milliseconds(500))
            }
            .onChange(of: controller.preferences.fontSize) { _, fontSize in
                showZoomFeedback(fontSize: fontSize)
            }
            .onAppear { controller.isVisible = true }
            .onDisappear { controller.isVisible = false }
            .focusedSceneValue(\.terminal, controller)
    }

    private func search(backwards: Bool) {
        controller.search(for: searchTerm, backwards: backwards)
        announceSearchResult()
    }

    /// Tells VoiceOver where the search went, after `delay`: while the user types, once the typing
    /// pauses. A newer search cancels the announcement of the one before.
    private func announceSearchResult(after delay: Duration = .zero) {
        searchAnnouncement?.cancel()
        guard !searchTerm.isEmpty else { return }
        searchAnnouncement = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                controller.announceSearchResult()
            }
        }
    }

    private func endSearch() {
        searchAnnouncement?.cancel()
        controller.isShowingSearch = false
        searchTerm = ""
    }

    private func showZoomFeedback(fontSize: CGFloat) {
        let feedback = ZoomFeedback(
            fontSize: Int(fontSize), columns: controller.size.columns, rows: controller.size.rows,
            theme: controller.view.theme)
        zoomFeedback = feedback
        Task {
            try? await Task.sleep(for: .seconds(2))
            if zoomFeedback == feedback {
                zoomFeedback = nil
            }
        }
    }
}

/// The terminal's UIKit view in SwiftUI. The controller keeps the view, so a terminal keeps what
/// it shows when SwiftUI puts it back on screen.
private struct TerminalViewHost: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalHostView {
        controller.view
    }

    func updateUIView(_ view: TerminalHostView, context: Context) {}
}

/// Search in the scrollback and on screen: the term, which match of how many, previous (up, to
/// older output) and next (down). At accessibility text sizes the count and the controls each
/// get a line under the field. Esc on a hardware keyboard closes the bar while the field has the
/// focus, as Done does.
private struct FindBar: View {
    @Binding var term: String
    let result: TerminalController.SearchResult
    /// Find puts the focus back in the field each time.
    let focusRequests: Int
    let previous: () -> Void
    let next: () -> Void
    let done: () -> Void
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isVoiceOverFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout =
            isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            TextField("Search", text: $term)
                .accessibilityLabel("Search Terminal")
                .font(Typography.data)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(previous)
                .focused($isFocused)
                .accessibilityFocused($isVoiceOverFocused)
            if isLarge {
                counter
                controls
            } else {
                HStack(spacing: 4) {
                    counter
                    controls
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        // Down to the bottom edge of the screen when the keyboard is down.
        .background(Palette.cell)
        .overlay(alignment: .top) {
            Palette.hairline.frame(height: 1)
        }
        .onAppear(perform: focus)
        .onChange(of: focusRequests, focus)
    }

    /// Puts the keyboard's focus and VoiceOver's in the field.
    private func focus() {
        isFocused = true
        isVoiceOverFocused = true
    }

    @ViewBuilder
    private var counter: some View {
        if !term.isEmpty {
            Text(Self.counterText(result))
                .font(Typography.footnote)
                .foregroundStyle(Palette.textSecondary)
                // Beside the controls on one line; on a line of its own, it wraps.
                .fixedSize(horizontal: !isLarge, vertical: true)
                .padding(.trailing, 8)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button("Previous Match", systemImage: "chevron.up", action: previous)
                .disabled(result.total == 0)
            Button("Next Match", systemImage: "chevron.down", action: next)
                .disabled(result.total == 0)
            Button("Done", action: done)
                .font(Typography.body)
                // Esc, while the field has the focus: in the terminal, Esc is the program's.
                .keyboardShortcut(isFocused ? .cancelAction : nil)
        }
        .labelStyle(.iconOnly)
        // Touch targets of at least 44 points, past the symbols and the word.
        .buttonStyle(MinimumTargetButtonStyle())
    }

    /// Which match of how many, such as "2 of 5", or "3 of 1,000+" when there are too many to
    /// count.
    static func counterText(_ result: TerminalController.SearchResult) -> String {
        let total = result.isCapped ? "\(result.total.formatted())+" : "\(result.total)"
        switch (result.index, result.total) {
        case (_, 0): return "No Matches"
        case (0, _): return "\(total) Matches"
        default: return "\(result.index) of \(total)"
        }
    }
}

/// A plain button whose touch target is at least 44 by 44 points.
private struct MinimumTargetButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }
}

/// The text size and the grid after a font size change, in the middle of the terminal.
private struct ZoomFeedback: View, Equatable {
    /// Tells each change apart, so that only the last one's timer hides it.
    let id = UUID()
    let fontSize: Int
    let columns: Int
    let rows: Int
    let theme: TerminalTheme

    var body: some View {
        Text("\(fontSize) pt · \(columns) × \(rows)")
            .font(Typography.data)
            .foregroundStyle(Color(uiColor: theme.foreground.uiColor))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // The theme's black: a step up from its background, so the box stands out from it.
            .background(Color(uiColor: theme.ansi[0].uiColor), in: .rect(cornerRadius: 12))
            .accessibilityLabel("\(fontSize) point text, \(columns) columns, \(rows) rows")
            .allowsHitTesting(false)
    }
}
