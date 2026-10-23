import ShelloCore
import ShelloTerminalUI
import SwiftUI

/// The tab bar under the terminal screen's title (docs/ui/ui_v1 Terminal): a tab for each of the
/// window's tabs, scrolling sideways when they are many, and New Tab, for another tab on the selected
/// tab's host. A tap selects a tab; the selected tab has its Close button. Each tab shows how its
/// connection is, by a mark and to VoiceOver in words, and a bell that rang while it was not on
/// screen (README section 5).
///
/// The tabs' names stand on the bar itself. The selected tab is in semibold, underlined in the
/// accent below its touch target, and has Close. When a tab closes from the bar, VoiceOver's focus
/// goes to the tab selected after it.
struct TabBar: View {
    let model: TerminalTabsModel
    @AccessibilityFocusState private var focus: TabBarFocus?

    /// The space above the tabs. The navigation bar's glass buttons cast a shadow some 30 points
    /// down over the bar, too faint to see but enough for the accessibility audit to report a tab's
    /// name in it as low contrast.
    static let shadowClearance: CGFloat = 20

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 2) {
                    let tabs = model.tabs.tabs
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButton(
                            tab: tab, name: model.name(of: tab), position: "tab \(index + 1) of \(tabs.count)",
                            isSelected: tab.id == model.tabs.selectedTabID, focus: $focus
                        ) {
                            model.select(tab)
                        } close: {
                            close(tab)
                        }
                        .id(tab.id)
                    }
                    BarButton("New Tab", systemImage: "plus") { model.newTab() }
                        .disabled(model.selectedTab == nil)
                }
                .padding(.horizontal, 6)
                .padding(.top, Self.shadowClearance)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.tabs.selectedTabID, initial: true) { _, id in
                guard let id else { return }
                withAnimation { scroller.scrollTo(id) }
            }
        }
        .background(Palette.cell)
        .overlay(alignment: .bottom) {
            Palette.hairline.frame(height: 1)
        }
    }

    /// Closes `tab`. VoiceOver's focus, if it was on the tab or its Close button, goes to the tab
    /// selected now.
    private func close(_ tab: TerminalTab<TerminalController>) {
        let hadFocus = focus != nil
        model.close(tab)
        if hadFocus, let id = model.tabs.selectedTabID {
            focus = .tab(id)
        }
    }
}

/// Where VoiceOver's focus is in the tab bar: on a tab, or on its Close button.
private enum TabBarFocus: Hashable {
    case tab(UUID)
    case close(UUID)
}

/// One tab in the tab bar: its connection's mark, its name, a bell that rang unseen, and Close on
/// the selected tab, which an accent line underlines. VoiceOver reads the name, then the host, the
/// connection, the bell and the tab's place among the tabs.
private struct TabButton: View {
    let tab: TerminalTab<TerminalController>
    let name: String
    /// "tab 2 of 3".
    let position: String
    let isSelected: Bool
    let focus: AccessibilityFocusState<TabBarFocus?>.Binding
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: select) {
                    HStack(spacing: 7) {
                        TabStatusSymbol(state: tab.state)
                        Text(name)
                            .font(isSelected ? Typography.selectedTab : Typography.tab)
                            .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
                            .lineLimit(1)
                        if tab.terminal.hasUnseenBell {
                            // In the tab's value, so that the bell leaves the name as it is.
                            Image(systemName: "bell.fill")
                                .font(Typography.tab)
                                .foregroundStyle(Palette.accentInk)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, isSelected ? 0 : 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue("\(TabStatusSymbol.spokenStatus(of: tab, name: name)), \(position)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: "Close Tab", close)
                // A window title from the server can be hard to say: Voice Control also takes the
                // host's name.
                .accessibilityInputLabels(name == tab.host.name ? [name] : [name, tab.host.name])
                .accessibilityFocused(focus, equals: .tab(tab.id))
                // For the UI tests, which cannot see a reconnect otherwise: VoiceOver does not read it.
                .accessibilityIdentifier("tab, connection \(tab.connectionCount)")
                .contextMenu {
                    Button("Close Tab", systemImage: "xmark", action: close)
                }
                if isSelected {
                    BarButton("Close Tab", systemImage: "xmark", action: close)
                        .accessibilityFocused(focus, equals: .close(tab.id))
                }
            }
            // The selected tab's underline, below its touch target, where it is no part of the
            // name's surface.
            Capsule()
                .fill(isSelected ? Palette.accentInk : Color.clear)
                .frame(height: 3)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
        }
    }
}

/// A symbol button of the tab bar, whose touch target is at least 44 by 44 points.
private struct BarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(Typography.tab)
                .foregroundStyle(Palette.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// How a tab's connection is, by its shape as much as by its colour: a filled dot while it works, a
/// half-filled one while it connects, a hollow ring without a connection, and a diamond when
/// connecting failed. They grow with the text. The words are VoiceOver's.
struct TabStatusSymbol: View {
    let state: TabState
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 8

    var body: some View {
        shape
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { size * 0.1875 }

    @ViewBuilder private var shape: some View {
        switch state {
        case .active:
            Circle().fill(Palette.statusOnline)
        case .connecting, .reconnecting:
            Circle()
                .strokeBorder(Palette.textSecondary, lineWidth: lineWidth)
                .background(alignment: .leading) {
                    Circle().fill(Palette.textSecondary)
                        .frame(width: size, height: size)
                        .mask(alignment: .leading) { Rectangle().frame(width: size / 2) }
                }
        case .suspended, .ended, .closed:
            Circle().strokeBorder(Palette.statusOffline, lineWidth: lineWidth)
        case .disconnected:
            Rectangle().fill(Palette.statusError)
                .rotationEffect(.degrees(45))
                .scaleEffect(0.8)
        }
    }

    /// The connection in words: "Connected, 24 milliseconds", "Reconnecting", and so on, after the
    /// host's name when the tab goes by another, and with the bell.
    static func spokenStatus(of tab: TerminalTab<TerminalController>, name: String) -> String {
        var parts: [String] = []
        if name != tab.host.name {
            parts.append(tab.host.name)
        }
        if tab.state == .active, let latency = tab.latency {
            parts.append("\(spokenState(tab.state)), \(latency.spokenLatency)")
        } else {
            parts.append(spokenState(tab.state))
        }
        if tab.terminal.hasUnseenBell {
            parts.append("Bell")
        }
        return parts.joined(separator: ", ")
    }

    /// The state of a tab's connection in a word or two: "Connected", "Reconnecting".
    static func spokenState(_ state: TabState) -> String {
        switch state {
        case .active: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .suspended: "Disconnected in the background"
        case .ended: "Connection closed"
        case .disconnected: "Disconnected"
        case .closed: "Closed"
        }
    }
}
