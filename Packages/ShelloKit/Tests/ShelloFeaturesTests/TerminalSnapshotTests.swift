import ShelloTerminalUI
import SnapshotTesting
import Testing
import UIKit

@testable import ShelloFeatures

/// The terminal demo's colour, attribute and Unicode screens, as the terminal draws them with the
/// app's font and theme (README section 5), run through the demo source as the Demo menu runs them.
///
/// The reference images in __Snapshots__ were recorded on the iPhone 17 simulator with iOS 26.5,
/// the one CI uses: other simulators and devices draw text slightly differently. To record them
/// again, delete them and run the tests twice on that simulator.
@MainActor
@Suite(.serialized) struct TerminalSnapshotTests {
    @Test func colorScreen() async {
        await assertScreen(of: .colors, endingWith: "24-bit color")
    }

    @Test func attributeScreen() async {
        await assertScreen(of: .attributes, endingWith: "24-bit text on a 24-bit background")
    }

    /// Each line closes with a bar, and every bar is in the same column.
    @Test func unicodeScreen() async {
        await assertScreen(of: .unicode, endingWith: "Blocks")
    }

    private func assertScreen(
        of command: DemoCommand, endingWith lastLine: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let terminal = DemoTerminal(size: CGSize(width: 390, height: 400))
        #expect(await terminal.wait { terminal.screen.contains { $0.hasPrefix("demo$") } })
        terminal.demo.run(.clear)
        terminal.demo.run(command)
        let isDone = await terminal.wait {
            let screen = terminal.screen
            guard let last = screen.lastIndex(where: { $0.contains(lastLine) }) else { return false }
            return screen[(last + 1)...].contains { $0.hasPrefix("demo$") }
        }
        #expect(isDone, "The \(command) screen did not show", sourceLocation: sourceLocation)
        let image = await terminal.image()
        // Saved as __Snapshots__/TerminalSnapshotTests/terminal.<command>.png.
        assertSnapshot(
            of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: command.rawValue,
            testName: "terminal")
    }
}
