import Testing
import UIKit

@testable import ShelloTerminalUI

/// The Shello keyboard's layers and layouts as data (README section 6, the UI design's
/// docs/ui/ui_v1/canvas/Terminal.dc.html).
@Suite struct KeyboardLayoutTests {
    /// The text a row's character keys type, in order.
    private func characters(of row: KeyboardRow) -> String {
        row.keys.compactMap { key -> String? in
            guard key.style == .character, case .text(let text) = key.action else { return nil }
            return text
        }.joined()
    }

    private func flicks(of row: KeyboardRow) -> String {
        row.keys.compactMap(\.flick).joined()
    }

    @Test func qwertyFollowsTheDesign() {
        let layer = KeyboardLayer.letters(.qwerty)
        #expect(layer.rows.count == 4)
        #expect(characters(of: layer.rows[0]) == "qwertyuiop")
        #expect(characters(of: layer.rows[1]) == "asdfghjkl")
        #expect(characters(of: layer.rows[2]) == "zxcvbnm")
        #expect(flicks(of: layer.rows[0]) == "1234567890")
        #expect(flicks(of: layer.rows[1]) == "@#$_&-+()")
        #expect(flicks(of: layer.rows[2]) == "*\"':;!?")
        // The second row is shorter, so it moves in by half a key on each side.
        #expect(layer.rows[1].inset == 0.5)
        #expect(layer.rows[2].keys.first?.action == .modifier(.shift))
        #expect(layer.rows[2].keys.last?.action == .key(.backspace))
        #expect(
            layer.rows[3].keys.map(\.action) == [
                .layer(.symbols), .layer(.function), .text(" "), .text("."), .key(.return),
            ])
        #expect(layer.rows[3].keys[3].flick == ",")
    }

    @Test func qwertzSwapsYAndZAndPutsTheUmlautsFirst() {
        let layer = KeyboardLayer.letters(.qwertz)
        #expect(characters(of: layer.rows[0]) == "qwertzuiop")
        #expect(characters(of: layer.rows[1]) == "asdfghjkl")
        #expect(characters(of: layer.rows[2]) == "yxcvbnm")
        let keys = Dictionary(uniqueKeysWithValues: layer.keys.map { ($0.label, $0) })
        #expect(keys["a"]?.alternates.first == "ä")
        #expect(keys["o"]?.alternates.first == "ö")
        #expect(keys["u"]?.alternates.first == "ü")
        #expect(keys["s"]?.alternates.first == "ß")
    }

    /// README section 6: digits plus ! @ # $ % ^ & * ( ) ~ ` | \ { } [ ].
    @Test func symbolsLayerHasTheSpecsSymbols() {
        let typed = Set(
            KeyboardLayer.symbols.keys.compactMap { key -> String? in
                guard case .text(let text) = key.action else { return nil }
                return text
            })
        for symbol in "0123456789!@#$%^&*()~`|\\{}[]" {
            #expect(typed.contains(String(symbol)), "\(symbol) is missing")
        }
        // The design has none of these anywhere else.
        let flicks = Set(KeyboardLayer.symbols.keys.compactMap(\.flick))
        #expect(flicks.isSuperset(of: ["<", "=", ">", "_"]))
    }

    /// README section 6: F1 to F12, Home, End, PgUp, PgDn, Ins, Del and common Control shortcuts.
    @Test func functionLayerHasTheSpecsKeys() {
        let actions = KeyboardLayer.function.keys.map(\.action)
        for number in 1...12 {
            #expect(actions.contains(.key(.function(number))), "F\(number) is missing")
        }
        for key in [TerminalKey.home, .end, .pageUp, .pageDown, .insert, .delete] {
            #expect(actions.contains(.key(key)), "\(key) is missing")
        }
        for letter in "cdzlraew" {
            #expect(actions.contains(.control(letter)), "^\(letter) is missing")
        }
        let shortcuts = KeyboardLayer.function.keys.filter { $0.style == .shortcut }
        #expect(shortcuts.map(\.label) == ["^C", "^D", "^Z", "^L", "^R", "^A", "^E", "^W"])
        #expect(shortcuts.first?.spokenLabel == "Control-C")
        // Arrows that repeat while held, for those who cannot drag the swipe key.
        let arrowKeys: [KeyAction] = [.key(.left), .key(.up), .key(.down), .key(.right)]
        let arrows = KeyboardLayer.function.keys.filter { arrowKeys.contains($0.action) }
        #expect(arrows.map(\.label) == ["←", "↑", "↓", "→"])
        #expect(arrows.map(\.spokenLabel) == ["Left Arrow", "Up Arrow", "Down Arrow", "Right Arrow"])
        #expect(arrows.map(\.repeats) == [true, true, true, true])
    }

    /// Esc, Tab, Control, Alt, the swipe key and the design's symbols.
    @Test func extraKeysRowFollowsTheDesign() {
        let actions = ExtraKeys.standard.map(\.action)
        #expect(Array(actions.prefix(5)) == [.key(.escape), .key(.tab), .modifier(.control), .modifier(.alt), .arrows])
        #expect(ExtraKeys.standard.dropFirst(5).map(\.label).joined() == "|~/-$>*")
    }

    /// Every key says what it is to VoiceOver, and a long-press offers single characters.
    @Test func everyKeyHasASpokenLabel() {
        let layers = LettersLayout.ID.allCases.map { KeyboardLayer.letters($0.layout) } + [.symbols, .function]
        let keys = layers.flatMap(\.keys) + ExtraKeys.standard
        for key in keys {
            #expect(!key.spokenLabel.isEmpty, "\(key.action) has no spoken label")
            for alternate in key.alternates {
                #expect(alternate.count == 1, "\(alternate) is not one character")
            }
        }
        #expect(KeyboardKey.spokenName(of: "|") == "Vertical Bar")
        #expect(KeyboardKey.spokenName(of: "q") == "q")
    }

    /// The first keyboard in the Settings app decides; the emoji keyboard is not a language.
    @Test func automaticLayoutFollowsTheFirstSystemKeyboard() {
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["de-CH"]) == .qwertz)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["de-DE", "en-US"]) == .qwertz)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["fr-CH"]) == .qwertz)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["cs-CZ"]) == .qwertz)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["en-US", "de-DE"]) == .qwerty)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["fr-FR"]) == .qwerty)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["emoji", "de-AT"]) == .qwertz)
        #expect(LettersLayout.automatic(forKeyboardLanguages: ["emoji"]) == .qwerty)
        #expect(LettersLayout.automatic(forKeyboardLanguages: []) == .qwerty)
    }

    /// Every point of the keyboard is on a key, no two keys overlap, and the keys of a row share
    /// its width by their widths.
    @Test func keyboardHasNoDeadZones() {
        let metrics = KeyboardMetrics(
            keyHeight: 44, keySpacing: 5, rowSpacing: 10, insets: UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6),
            cornerRadius: 7, labelScale: 1)
        for layer in [KeyboardLayer.letters(.qwerty), .letters(.qwertz), .symbols, .function] {
            let geometry = KeyboardGeometry(rows: layer.rows, width: 390, metrics: metrics)
            // The design's margins of 8 points, 4 rows of 44 and 3 gaps of 10.
            let height: CGFloat = 222
            #expect(geometry.size.height == height)
            for x in stride(from: CGFloat(0.5), to: 390, by: 7) {
                for y in stride(from: CGFloat(0.5), to: geometry.size.height, by: 5) {
                    let hits = geometry.caps.filter { $0.touchFrame.contains(CGPoint(x: x, y: y)) }
                    #expect(hits.count == 1, "\(hits.count) keys at \(x), \(y) in \(layer.kind)")
                }
            }
        }
        // The design's letter keys: about 33 points wide on a 390-point phone.
        let letters = KeyboardGeometry(rows: KeyboardLayer.letters(.qwerty).rows, width: 390, metrics: metrics)
        let q = letters.caps[0].frame
        #expect(abs(q.width - 33.3) < 0.5)
        #expect(q.height == 44)
    }
}
