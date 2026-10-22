import ShelloTerminalUI
import SwiftUI

/// The app's shortcuts for terminals (README section 5, STACK section 7.5), which also fill the
/// iPadOS menu bar: Find, and the font size, act on the terminal on screen. New Tab and Next Tab
/// wait for tabs (#28), so they show, disabled.
public struct TerminalCommands: Commands {
    @FocusedValue(\.terminal) private var terminal

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {}
                .keyboardShortcut("t")
                .disabled(true)
            Button("Next Tab") {}
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(true)
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
}
