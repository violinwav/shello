import ShelloTerminalUI
import SwiftUI

/// Settings, Diagnostics, Terminal Demo: the terminal attached to the terminal demo, which runs on
/// the device (GLOSSARY), until connecting to a server comes with tabs (#28). The Demo menu runs
/// the demo's commands: the colour, attribute and Unicode screens, the alternate screen, mouse
/// reporting, the bell and the 10 MB output test.
struct TerminalDemoView: View {
    @Environment(\.terminalSettings) private var settings
    @State private var demo = TerminalDemo()
    /// Made once the screen appears: making a terminal makes its UIKit view.
    @State private var controller: TerminalController?

    var body: some View {
        Group {
            if let controller {
                // A pinch or a shortcut changes the size the next terminal starts with. Settings
                // cannot change while this screen shows: the terminal takes them when it is made.
                // Taking them back here too would undo the steps of a pinch that the settings
                // have not caught up with.
                TerminalScreen(controller: controller)
                    .onChange(of: controller.preferences.fontSize) { _, fontSize in
                        settings?.fontSize = fontSize
                    }
            } else {
                Color(uiColor: TerminalTheme.night.background.uiColor)
            }
        }
        // A pushed screen takes the font of the list it was pushed from.
        .environment(\.font, nil)
        .navigationTitle("Terminal Demo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(DemoCommand.menu, id: \.self) { command in
                        Button(command.menuTitle) { demo.run(command) }
                    }
                } label: {
                    Label("Demo", systemImage: "play.rectangle")
                }
            }
        }
        .onAppear {
            guard controller == nil else { return }
            let controller = TerminalController(
                preferences: settings?.preferences ?? TerminalPreferences(), theme: .night,
                typeface: DesignSystem.terminalTypeface)
            controller.attach(demo)
            self.controller = controller
        }
    }
}

extension DemoCommand {
    /// The commands in the Demo menu, in its order.
    static let menu: [DemoCommand] = [
        .colors, .attributes, .unicode, .alternate, .mouse, .bell, .flood, .paste, .size, .clear, .help,
    ]

    var menuTitle: String {
        switch self {
        case .help: "Help"
        case .colors: "Colors"
        case .attributes: "Text Attributes"
        case .unicode: "Unicode"
        case .alternate: "Alternate Screen"
        case .mouse: "Mouse Reporting"
        case .bell: "Bell"
        case .flood: "10 MB Output"
        case .paste: "Bracketed Paste"
        case .size: "Terminal Size"
        case .clear: "Clear"
        }
    }
}
