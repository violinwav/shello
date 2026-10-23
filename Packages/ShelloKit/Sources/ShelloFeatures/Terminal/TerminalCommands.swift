import ShelloTerminalUI
import SwiftUI

/// The app's shortcuts for terminals (README section 5, STACK section 7.5), which also fill the
/// iPadOS menu bar: New Tab, Close Tab, the next and previous tab and Show Hosts act on the terminal
/// screen's tabs; Find and the font size on the terminal on screen.
public struct TerminalCommands: Commands {
    @FocusedValue(\.terminal) private var terminal
    @FocusedValue(\.terminalTabs) private var tabs

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { tabs?.newTab() }
                .keyboardShortcut("t")
                .disabled(tabs?.selectedTab == nil)
            // What is in front: the connection sheet or a question first, then the tab.
            Button("Close Tab") { tabs?.closeFrontmost() }
                .keyboardShortcut("w")
                .disabled(tabs?.selectedTab == nil)
            Divider()
            Button("Next Tab") { tabs?.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabs?.hasSeveralTabs != true)
            Button("Previous Tab") { tabs?.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabs?.hasSeveralTabs != true)
            // Back to the host list, as the screen's Hosts button: the terminal takes Esc and Tab.
            Button("Show Hosts") { tabs?.hideTerminals() }
                .keyboardShortcut("[")
                .disabled(tabs == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Find…") { terminal?.showSearch() }
                .keyboardShortcut("f")
                .disabled(terminal == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { terminal?.changeFontSize(by: 1) }
                .keyboardShortcut("+")
                .disabled(terminal == nil)
            Button("Smaller Text") { terminal?.changeFontSize(by: -1) }
                .keyboardShortcut("-")
                .disabled(terminal == nil)
            Button("Actual Size") { terminal?.resetFontSize() }
                .keyboardShortcut("0")
                .disabled(terminal == nil)
        }
    }
}

extension FocusedValues {
    /// The terminal on screen in the focused scene, for the shortcuts.
    @Entry var terminal: TerminalController?
    /// The focused scene's tabs, while its terminal screen shows.
    @Entry var terminalTabs: TerminalTabsModel?
}
