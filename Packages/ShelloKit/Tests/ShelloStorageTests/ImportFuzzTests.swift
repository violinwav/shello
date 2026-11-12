import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

/// The importer reads files from anywhere, so STACK section 11 lists JSON import as a fuzz target.
/// Fed malformed input of every kind, it refuses it with an `ImportError` and never crashes, and
/// whatever it accepts imports cleanly: the checks leave nothing for the database to refuse. The
/// inputs come from seeded generators, so a failure repeats. A libFuzzer target can follow later.
struct ImportFuzzTests {
    let test: TestDatabase

    init() throws {
        test = try TestDatabase()
    }

    /// Reads `data`, then summarizes and imports it if it is accepted, as the app does. Returns
    /// whether it was accepted.
    @discardableResult
    private func feed(_ data: Data) async throws -> Bool {
        let file: ExportFile
        do {
            file = try ExportFile(data: data)
        } catch {
            return false
        }
        _ = try await test.exports.importSummary(of: file)
        try await test.exports.importFile(file)
        return true
    }

    @Test func randomBytesAreRefused() async throws {
        var generator = SeededGenerator(seed: 22)
        let jsonStart = Data(#"{"format":"ch.shello.export","schemaVersion":1,"#.utf8)
        for round in 0..<2_000 {
            let bytes = (0..<Int.random(in: 0...600, using: &generator)).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            }
            // Half of them start like an export, so that they get past the first checks.
            let data = round.isMultiple(of: 2) ? Data(bytes) : jsonStart + bytes
            #expect(try await feed(data) == false)
        }
    }

    /// Random edits to a valid export: bits flipped, bytes changed, cut out, repeated or swapped,
    /// and JSON punctuation put in. Most edits break the file; some land inside text and leave a
    /// valid one, which must then import.
    @Test func editedExportsAreRefusedOrImport() async throws {
        let sample = try ExportSample.exportData()
        var generator = SeededGenerator(seed: 2026)
        var accepted = 0
        for _ in 0..<5_000 {
            var data = sample
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                Self.edit(&data, using: &generator)
            }
            if try await feed(data) { accepted += 1 }
        }
        #expect(accepted > 0)
    }

    /// Every value in the sample, objects and lists included, replaced in turn by a value of each
    /// JSON type.
    @Test func everyValueOfTheWrongTypeIsRefusedOrImports() async throws {
        let sample = try JSONSerialization.jsonObject(with: ExportSample.exportData())
        let replacements: [Any] = [
            "", "x", "ch.shello.export", 0, 1, -1, 1.5, Int64.max, true, false, NSNull(), [Any](), [String: Any](),
            ["x"], ["x": 1], [NSNull()],
        ]
        let paths = Self.valuePaths(in: sample)
        #expect(paths.count > 50)
        for path in paths {
            for replacement in replacements {
                let changed = Self.replacing(path, in: sample, with: replacement)
                try await feed(try JSONSerialization.data(withJSONObject: changed))
            }
        }
    }

    /// Numbers beyond what Swift's integers and doubles hold, and text that only looks like a number,
    /// at every number in the sample.
    @Test func hugeAndMalformedNumbersAreRefusedOrImport() async throws {
        let sample = String(decoding: try ExportSample.exportData(), as: UTF8.self)
        let numbers = [
            "1e400", "-1e400", "1e308", "-1e308", "4.9e-324", "9223372036854775807", "9223372036854775808",
            "-9223372036854775809", "18446744073709551616", "99999999999999999999999999999999999999", "65535",
            "65536", "2147483648", "-0", "0.5", "22.0", "1e2", "NaN", "Infinity", "-Infinity", "0x16", "+22",
            "022", "22.", ".5", "1e", "--1", "1_000",
        ]
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let numberLines = lines.indices.filter { lines[$0].contains(#/ : -?[0-9]/#) }
        #expect(numberLines.count > 10)
        for index in numberLines {
            for number in numbers {
                var changed = lines
                changed[index] = Substring(lines[index].replacing(#/ : -?[0-9][0-9.e+-]*/#, with: " : \(number)"))
                try await feed(Data(changed.joined(separator: "\n").utf8))
            }
        }
    }

    /// The decoder refuses nesting deeper than 512 levels; nothing here may overflow the stack.
    @Test(arguments: [10, 511, 512, 513, 10_000, 1_000_000])
    func deeplyNestedJSONIsRefused(_ depth: Int) async throws {
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let objects = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let sample = String(decoding: try ExportSample.exportData(), as: UTF8.self)
        let inputs = [
            arrays, objects,
            // As the hosts, and as one host's notes.
            sample.replacing(#""hosts" : ["#, with: #""hosts" : \#(arrays), "x" : ["#),
            sample.replacing(#""notes" : """#, with: #""notes" : \#(objects)"#),
        ]
        for input in inputs {
            #expect(try await feed(Data(input.utf8)) == false)
        }
    }

    /// Long text and text from all over Unicode is valid wherever the rules allow any text.
    @Test func longAndUnusualTextImports() async throws {
        let texts = [
            String(repeating: "a", count: 1_000_000), "\u{202E}gnp.exe", "e\u{301}\u{301}\u{301}",
            "👩‍👩‍👧‍👦", "\u{FEFF}", "\u{FFFF}", "\u{10FFFF}", "\\", "\"", "\u{1}\u{1F}\u{7F}", "Line\r\nbreak",
        ]
        for text in texts {
            let data = try Corruption.sample { format in
                format.hosts[0].notes = text
                format.hosts[0].username = text
                format.hosts[1].name = text
                format.tags[0].name = text
                format.groups[0].name = text
            }
            #expect(try await feed(data), "\(text.prefix(20).debugDescription)")
        }
        let stored = try await test.repository.hosts()
        #expect(stored.contains { $0.notes == texts.last })
    }

    /// Text the decoder cannot turn into Swift strings: lone surrogate halves and invalid escapes.
    @Test(arguments: [#"\ud800"#, #"\udfff"#, #"\ud800\ud800"#, #"\u12"#, #"\x41"#, #"\"#])
    func brokenEscapesAreRefused(_ escape: String) async throws {
        let sample = String(decoding: try ExportSample.exportData(), as: UTF8.self)

        let data = Data(sample.replacing(#""notes" : """#, with: #""notes" : "\#(escape)""#).utf8)

        #expect(try await feed(data) == false)
    }

    // MARK: - Generators

    /// One random edit to `data`.
    private static func edit(_ data: inout Data, using generator: inout SeededGenerator) {
        guard !data.isEmpty else { return }
        let index = Int.random(in: data.indices, using: &generator)
        switch Int.random(in: 0..<6, using: &generator) {
        case 0:
            data[index] ^= 1 << UInt8.random(in: 0..<8, using: &generator)
        case 1:
            data[index] = UInt8.random(in: .min ... .max, using: &generator)
        case 2:
            data.removeSubrange(index..<min(index + Int.random(in: 1...16, using: &generator), data.endIndex))
        case 3:
            let range = index..<min(index + Int.random(in: 1...64, using: &generator), data.endIndex)
            data.insert(contentsOf: data[range], at: index)
        case 4:
            let tokens = ["{", "}", "[", "]", "\"", ",", ":", "null", "0", "-", "\\", "e", "true", "\u{0}"]
            data.insert(contentsOf: Data(tokens.randomElement(using: &generator)!.utf8), at: index)
        default:
            data.swapAt(index, Int.random(in: data.indices, using: &generator))
        }
    }

    /// The path of every value in a JSON object, each a list of keys and indices.
    private static func valuePaths(in value: Any, at path: [AnyHashable] = []) -> [[AnyHashable]] {
        var paths = path.isEmpty ? [] : [path]
        if let object = value as? [String: Any] {
            for (key, child) in object { paths += valuePaths(in: child, at: path + [key]) }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() { paths += valuePaths(in: child, at: path + [index]) }
        }
        return paths
    }

    /// `value` with the value at `path` replaced.
    private static func replacing(_ path: [AnyHashable], in value: Any, with replacement: Any) -> Any {
        guard let first = path.first else { return replacement }
        let rest = Array(path.dropFirst())
        if var object = value as? [String: Any], let key = first as? String, let child = object[key] {
            object[key] = replacing(rest, in: child, with: replacement)
            return object
        }
        if var array = value as? [Any], let index = first as? Int, array.indices.contains(index) {
            array[index] = replacing(rest, in: array[index], with: replacement)
            return array
        }
        return value
    }
}

/// SplitMix64: a fast random number generator that repeats its numbers for a seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
