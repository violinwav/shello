import SnapshotTesting
import Testing
import UIKit

@testable import ShelloFeatures
@testable import ShelloTerminalUI

/// The Shello keyboard as it is drawn (README section 6, the UI design's
/// docs/ui/ui_v1/canvas/Terminal.dc.html): every layer and letters layout, under the extra keys
/// row, on an iPhone and an iPad, with a dark theme and a light one, at the default text size and
/// at the largest accessibility size; then the modifiers' states, Bold Text with Increase Contrast,
/// and a long-press's alternates.
///
/// The keyboard follows the terminal's theme, so dark is the design's Night theme in either
/// appearance, and light a light theme such as Paper (Appearance.dc.html), which v1 brings.
///
/// The reference images in __Snapshots__ were recorded on the iPhone 17 simulator with iOS 26.5,
/// the one CI uses. To record them again, delete them and run the tests twice on that simulator.
@MainActor
@Suite(.serialized) struct KeyboardSnapshotTests {
    nonisolated enum Device: String, CaseIterable, Sendable {
        case iPhone
        case iPad

        /// The width of an iPhone 17 and of an iPad Air 11-inch, in portrait.
        var width: CGFloat { self == .iPhone ? 402 : 820 }
    }

    nonisolated enum Appearance: String, CaseIterable, Sendable {
        case dark
        case light

        var theme: TerminalTheme {
            guard self == .light else { return .night }
            var paper = TerminalTheme.night
            paper.background = TerminalTheme.RGB(0xF7F6F2)
            paper.foreground = TerminalTheme.RGB(0x1E2125)
            return paper
        }
    }

    nonisolated enum TextSize: String, CaseIterable, Sendable {
        case standard
        case accessibility

        var category: UIContentSizeCategory {
            self == .standard ? .large : .accessibilityExtraExtraExtraLarge
        }
    }

    /// A layer, with the letters in a layout for the letters layer.
    nonisolated struct Layer: CustomTestStringConvertible, Sendable {
        let kind: KeyboardLayer.Kind
        let letters: LettersLayout.ID
        let name: String

        static let all = [
            Layer(kind: .letters, letters: .qwerty, name: "qwerty"),
            Layer(kind: .letters, letters: .qwertz, name: "qwertz"),
            Layer(kind: .symbols, letters: .qwerty, name: "symbols"),
            Layer(kind: .function, letters: .qwerty, name: "function"),
        ]

        var testDescription: String { name }
    }

    @Test(arguments: Layer.all, Device.allCases)
    func layer(_ layer: Layer, on device: Device) {
        for appearance in Appearance.allCases {
            for size in TextSize.allCases {
                let image = Self.image(of: layer, on: device, appearance: appearance, size: size)
                // Saved as __Snapshots__/KeyboardSnapshotTests/keyboard.<layer>-<device>-<appearance>-<size>.png.
                assertSnapshot(
                    of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98),
                    named: "\(layer.name)-\(device.rawValue)-\(appearance.rawValue)-\(size.rawValue)",
                    testName: "keyboard")
            }
        }
    }

    /// Shift on, Control armed and Alt locked: each shows by more than its colour. On the light
    /// keyboard they turn dark rather than to the accent.
    @Test(arguments: Appearance.allCases)
    func modifiers(_ appearance: Appearance) {
        let image = Self.image(of: Layer.all[0], on: .iPhone, appearance: appearance, size: .standard) { keyboard in
            keyboard.press(.shift, at: 1)
            keyboard.press(Self.key(.modifier(.control)), at: 1)
            keyboard.press(Self.key(.modifier(.alt)), at: 1)
            keyboard.press(Self.key(.modifier(.alt)), at: 1.1)
        }
        // The dark keyboard's image predates the light one's, and keeps its name.
        assertSnapshot(
            of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: appearance == .dark ? "modifiers" : "modifiers-light", testName: "keyboard")
    }

    /// Bold Text puts every label in the bold face, and Increase Contrast outlines every key.
    @Test(arguments: Appearance.allCases)
    func boldTextAndIncreasedContrast(_ appearance: Appearance) {
        let image = Self.image(
            of: Layer.all[0], on: .iPhone, appearance: appearance, size: .standard, boldText: true, highContrast: true)
        assertSnapshot(
            of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: "bold-high-contrast-\(appearance.rawValue)", testName: "keyboard")
    }

    /// A long-press on E shows its alternates above the top row, over the extra keys row.
    @Test func alternates() {
        let image = Self.image(of: Layer.all[0], on: .iPhone, appearance: .dark, size: .standard) { keyboard in
            let view = keyboard.keyboardView
            let e = view.geometry.caps.first { $0.key.label == "e" }!.frame
            let finger = NSObject()
            view.touches.began(ObjectIdentifier(finger), at: CGPoint(x: e.midX, y: e.midY), time: 1)
            view.touches.tick(at: 1.5)
            view.touches.moved(ObjectIdentifier(finger), to: CGPoint(x: e.midX + e.width, y: e.midY), time: 1.6)
            view.stateChanged()
        }
        assertSnapshot(
            of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: "alternates", testName: "keyboard"
        )
    }

    private static func key(_ action: KeyAction) -> KeyboardKey {
        ExtraKeys.standard.first { $0.action == action }!
    }

    /// The extra keys row above the keyboard, as the system stacks them, drawn at twice the
    /// points' size, with Bold Text and Increase Contrast if asked. `prepare` puts the keyboard
    /// in a state first.
    private static func image(
        of layer: Layer, on device: Device, appearance: Appearance, size: TextSize, boldText: Bool = false,
        highContrast: Bool = false, prepare: (ShelloKeyboard) -> Void = { _ in }
    ) -> UIImage {
        DesignSystem.registerFonts()
        let keyboard = ShelloKeyboard(
            theme: appearance.theme, typeface: DesignSystem.terminalTypeface,
            preferences: KeyboardPreferences(letters: layer.letters))
        keyboard.show(layer.kind)
        let row = keyboard.extraKeysRow
        let keys = keyboard.keyboardView
        let container = UIView()
        for view in [container, row, keys] {
            view.traitOverrides.horizontalSizeClass = device == .iPad ? .regular : .compact
            view.traitOverrides.verticalSizeClass = .regular
            view.traitOverrides.preferredContentSizeCategory = size.category
            view.traitOverrides.displayScale = 2
            view.traitOverrides.legibilityWeight = boldText ? .bold : .regular
            view.traitOverrides.accessibilityContrast = highContrast ? .high : .normal
            view.updateTraitsIfNeeded()
        }
        let rowHeight = row.intrinsicContentSize.height
        let keysHeight = keys.intrinsicContentSize.height
        container.frame = CGRect(x: 0, y: 0, width: device.width, height: rowHeight + keysHeight)
        row.frame = CGRect(x: 0, y: 0, width: device.width, height: rowHeight)
        keys.frame = CGRect(x: 0, y: rowHeight, width: device.width, height: keysHeight)
        container.addSubview(row)
        container.addSubview(keys)
        container.layoutIfNeeded()
        prepare(keyboard)
        displayLayers(container.layer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(bounds: container.bounds, format: format).image { context in
            container.layer.render(in: context.cgContext)
        }
    }

    /// Draws the text layers, which otherwise draw only when Core Animation commits.
    private static func displayLayers(_ layer: CALayer) {
        layer.displayIfNeeded()
        for sublayer in layer.sublayers ?? [] {
            displayLayers(sublayer)
        }
    }
}
