import SwiftTerm
import Testing
import UIKit

@testable import ShelloTerminalUI

/// The bytes each key sends (README section 6), as xterm and SwiftTerm send them for the same key
/// on a hardware keyboard.
@Suite struct KeyEncoderTests {
    private static let escape: UInt8 = 0x1B

    private static func csi(_ body: String) -> [UInt8] {
        [escape, UInt8(ascii: "[")] + Array(body.utf8)
    }

    @Test func charactersAreTheirUTF8() {
        #expect(KeyEncoder.bytes(typing: "a") == [0x61])
        #expect(KeyEncoder.bytes(typing: "Q") == [0x51])
        #expect(KeyEncoder.bytes(typing: "é") == Array("é".utf8))
        #expect(KeyEncoder.bytes(typing: " ") == [0x20])
    }

    /// Control and a letter is the letter's place in the alphabet, whatever its case.
    @Test func controlTurnsLettersIntoTheirControlCodes() {
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            let code = UInt8(index + 1)
            #expect(KeyEncoder.bytes(typing: String(letter), modifiers: .control) == [code])
            #expect(KeyEncoder.bytes(typing: letter.uppercased(), modifiers: .control) == [code])
        }
    }

    /// xterm's table for the symbols, and the digits 2 to 8 that stand for them.
    @Test func controlTurnsSymbolsIntoTheirControlCodes() {
        let codes: [String: UInt8] = [
            "@": 0x00, " ": 0x00, "2": 0x00, "[": 0x1B, "3": 0x1B, "\\": 0x1C, "4": 0x1C, "]": 0x1D, "5": 0x1D,
            "^": 0x1E, "6": 0x1E, "~": 0x1E, "_": 0x1F, "7": 0x1F, "/": 0x1F, "?": 0x7F, "8": 0x7F,
        ]
        for (symbol, code) in codes {
            #expect(KeyEncoder.bytes(typing: symbol, modifiers: .control) == [code], "Control-\(symbol)")
        }
    }

    /// A character without a control code goes as it is: Control changes nothing about it.
    @Test func controlLeavesOtherCharactersAlone() {
        #expect(KeyEncoder.bytes(typing: "1", modifiers: .control) == [UInt8(ascii: "1")])
        #expect(KeyEncoder.bytes(typing: "é", modifiers: .control) == Array("é".utf8))
        #expect(KeyEncoder.bytes(typing: "ls", modifiers: .control) == Array("ls".utf8))
    }

    /// Alt is Meta: Esc, then the key, with Control applied first when both are on.
    @Test func altSendsEscapeFirst() {
        #expect(KeyEncoder.bytes(typing: "b", modifiers: .alt) == [Self.escape, UInt8(ascii: "b")])
        #expect(KeyEncoder.bytes(typing: "B", modifiers: .alt) == [Self.escape, UInt8(ascii: "B")])
        #expect(KeyEncoder.bytes(typing: "c", modifiers: [.control, .alt]) == [Self.escape, 0x03])
        #expect(KeyEncoder.bytes(typing: ".", modifiers: .alt) == [Self.escape, UInt8(ascii: ".")])
    }

    @Test func escapeTabReturnAndDelete() {
        #expect(KeyEncoder.output(for: .escape) == .bytes([Self.escape]))
        #expect(KeyEncoder.output(for: .escape, modifiers: .alt) == .bytes([Self.escape, Self.escape]))
        #expect(KeyEncoder.output(for: .return) == .bytes([0x0D]))
        #expect(KeyEncoder.output(for: .return, modifiers: .alt) == .bytes([Self.escape, 0x0D]))
        #expect(KeyEncoder.output(for: .tab) == .bytes([0x09]))
        #expect(KeyEncoder.output(for: .tab, modifiers: .shift) == .bytes(Self.csi("Z")))
        #expect(KeyEncoder.output(for: .tab, modifiers: .alt) == .bytes([Self.escape, 0x09]))
        #expect(KeyEncoder.output(for: .backspace) == .bytes([0x7F]))
        #expect(KeyEncoder.output(for: .backspace, modifiers: .control) == .bytes([0x08]))
        // Alt-Delete deletes the word before the cursor in a shell.
        #expect(KeyEncoder.output(for: .backspace, modifiers: .alt) == .bytes([Self.escape, 0x7F]))
        #expect(KeyEncoder.output(for: .backspace, backspaceSendsControlH: true) == .bytes([0x08]))
    }

    /// Without modifiers, the arrows, Home and End depend on the program's cursor key mode, which
    /// the terminal view knows; with them, they carry xterm's modifier parameter in either mode.
    @Test func arrowsHomeAndEnd() {
        for key in [TerminalKey.up, .down, .left, .right, .home, .end] {
            #expect(KeyEncoder.output(for: key) == .cursor(key))
        }
        #expect(KeyEncoder.output(for: .up, modifiers: .control) == .bytes(Self.csi("1;5A")))
        #expect(KeyEncoder.output(for: .down, modifiers: [.control, .alt]) == .bytes(Self.csi("1;7B")))
        #expect(KeyEncoder.output(for: .right, modifiers: .shift) == .bytes(Self.csi("1;2C")))
        #expect(KeyEncoder.output(for: .left, modifiers: .alt) == .bytes(Self.csi("1;3D")))
        #expect(KeyEncoder.output(for: .home, modifiers: .control) == .bytes(Self.csi("1;5H")))
        #expect(KeyEncoder.output(for: .end, modifiers: .shift) == .bytes(Self.csi("1;2F")))
    }

    @Test func pageInsertAndDeleteKeys() {
        #expect(KeyEncoder.output(for: .pageUp) == .page(.pageUp))
        #expect(KeyEncoder.output(for: .pageDown) == .page(.pageDown))
        #expect(KeyEncoder.output(for: .pageUp, modifiers: .control) == .bytes(Self.csi("5;5~")))
        #expect(KeyEncoder.output(for: .pageDown, modifiers: .shift) == .bytes(Self.csi("6;2~")))
        #expect(KeyEncoder.output(for: .insert) == .bytes(Self.csi("2~")))
        #expect(KeyEncoder.output(for: .delete) == .bytes(Self.csi("3~")))
        #expect(KeyEncoder.output(for: .delete, modifiers: .control) == .bytes(Self.csi("3;5~")))
    }

    /// F1 to F4 as SS3 P to S, F5 to F12 as numbered tilde sequences; with modifiers, both carry
    /// xterm's parameter.
    @Test func functionKeys() {
        let plain: [Int: [UInt8]] = [
            1: [Self.escape, UInt8(ascii: "O"), UInt8(ascii: "P")],
            2: [Self.escape, UInt8(ascii: "O"), UInt8(ascii: "Q")],
            3: [Self.escape, UInt8(ascii: "O"), UInt8(ascii: "R")],
            4: [Self.escape, UInt8(ascii: "O"), UInt8(ascii: "S")],
            5: Self.csi("15~"), 6: Self.csi("17~"), 7: Self.csi("18~"), 8: Self.csi("19~"), 9: Self.csi("20~"),
            10: Self.csi("21~"), 11: Self.csi("23~"), 12: Self.csi("24~"),
        ]
        for (number, bytes) in plain {
            #expect(KeyEncoder.output(for: .function(number)) == .bytes(bytes), "F\(number)")
            // The same table as SwiftTerm's.
            #expect(bytes == EscapeSequences.cmdF[number - 1], "F\(number)")
        }
        #expect(KeyEncoder.output(for: .function(1), modifiers: .shift) == .bytes(Self.csi("1;2P")))
        #expect(KeyEncoder.output(for: .function(4), modifiers: .control) == .bytes(Self.csi("1;5S")))
        #expect(KeyEncoder.output(for: .function(5), modifiers: .control) == .bytes(Self.csi("15;5~")))
        #expect(KeyEncoder.output(for: .function(12), modifiers: .alt) == .bytes(Self.csi("24;3~")))
        #expect(KeyEncoder.output(for: .function(13)) == .bytes([]))
    }
}

/// The Shello keyboard sends what SwiftTerm sends when the same character comes with its own
/// Control or Meta, so that the two never disagree.
@MainActor
@Suite(.serialized) struct KeyEncoderMatchesSwiftTermTests {
    @Test func controlMatchesSwiftTerm() {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        for character in "abcdefghijklmnopqrstuvwxyzABCZ[\\]^_ 6" {
            let before = stream.sent.count
            fixture.view.controlModifier = true
            fixture.view.insertText(String(character))
            let swiftTerm = Array(stream.sent[before...])
            #expect(
                swiftTerm == KeyEncoder.bytes(typing: String(character), modifiers: .control), "Control-\(character)")
        }
    }

    @Test func metaMatchesSwiftTerm() {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        for character in "abxyzQ./" {
            let before = stream.sent.count
            fixture.view.metaModifier = true
            fixture.view.insertText(String(character))
            let swiftTerm = Array(stream.sent[before...])
            #expect(swiftTerm == KeyEncoder.bytes(typing: String(character), modifiers: .alt), "Meta-\(character)")
        }
    }
}
