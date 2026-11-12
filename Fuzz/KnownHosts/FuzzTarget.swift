// libFuzzer target for the known_hosts file that Shello imports trusted host keys from: Packages/
// ShelloKit/Sources/ShelloSSH/OpenSSHFiles/KnownHosts.swift, compiled into one module with this file
// (Fuzz/README.md).
//
// Each input is read as a known_hosts file. Nothing may trap; every line number is one of the
// file's; no line is both an entry and a skipped line, unless what is skipped is one of its names;
// every entry has names, a key type Shello trusts and a key of that type in SSH's wire format, whose
// base64 is a field of its line; a plain name is lowercase with a port from 1 to 65535; and a hashed
// name has a salt and a hash as long as SHA-1's. Hashed names are matched with a stand-in for the
// HMAC: the parser takes it from its caller, and this target has no libssh.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []
    let file = KnownHosts(bytes: bytes)
    let lines = String(decoding: bytes, as: UTF8.self).utf8.split(separator: 0x0A, omittingEmptySubsequences: false)

    var entryLines: Set<Int> = []
    for entry in file.entries {
        precondition((1...lines.count).contains(entry.line), "An entry outside the file")
        precondition(entryLines.insert(entry.line).inserted, "Two entries on one line")
        precondition(!entry.names.isEmpty, "An entry without names")
        precondition(KnownHosts.supportedKeyTypes.contains(entry.keyType), "A key type Shello does not trust")
        precondition(KnownHosts.isKey(entry.key, ofType: entry.keyType), "A key that is not of its type")
        precondition(
            String(decoding: lines[entry.line - 1], as: UTF8.self).contains(entry.keyBase64),
            "A key that is not on its line")
        for name in entry.names {
            switch name {
            case .plain(let host, let port):
                precondition(!host.isEmpty && host == host.lowercased(), "A plain name not lowercased")
                precondition(port >= 1, "A name on port 0")
                precondition(name.matches(host: host, port: port, hmacSHA1: { _, _ in nil }), "A name not its own")
            case .hashed(let salt, let hash):
                precondition(salt.count == 20 && hash.count == 20, "A hashed name of another length")
                // A stand-in HMAC that returns the hash matches; one that fails does not.
                precondition(name.matches(host: "example.com", port: 22, hmacSHA1: { _, _ in hash }), "A hash not compared")
                precondition(!name.matches(host: "example.com", port: 22, hmacSHA1: { _, _ in nil }), "A failed HMAC matched")
            }
        }
    }
    for skipped in file.skipped {
        precondition((1...lines.count).contains(skipped.line), "A skipped line outside the file")
        switch skipped.reason {
        case .wildcard, .negated, .malformedName:
            continue
        default:
            precondition(!entryLines.contains(skipped.line), "A line both read and skipped")
        }
    }
    return 0
}
