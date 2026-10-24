// libFuzzer target for Shello's tmux output parsers: Packages/ShelloKit/Sources/ShelloTmux/
// TmuxVersion.swift and TmuxSession.swift, compiled into one module with this file (Fuzz/README.md).
//
// Each input is read as what `tmux -V` printed, and as what `tmux list-sessions -F` printed in
// Shello's format. Nothing may trap, and what the parsers accept must follow their rules: a version
// whose name is printable ASCII, at most 32 bytes, and reads back as the same version; sessions with
// an identifier, a name and numbers that are not negative, no more of them than lines.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []

    if let version = TmuxVersion(versionOutput: bytes) {
        precondition(
            !version.name.isEmpty && version.name.utf8.count <= TmuxVersion.maximumNameLength,
            "A version name that is empty or too long")
        precondition(
            version.name.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F },
            "A version name that is not printable ASCII")
        if let release = version.release {
            precondition(release.major >= 0 && release.minor >= 0, "A negative release")
        }
        precondition(TmuxVersion(name: version.name) == version, "A version that does not read back")
    }

    let sessions = TmuxSession.sessions(inListOutput: bytes)
    precondition(
        sessions.count <= bytes.count(where: { $0 == UInt8(ascii: "\n") }) + 1, "More sessions than lines")
    for session in sessions {
        precondition(session.id.first == "$" && session.id.count > 1, "A session without an identifier")
        precondition(!session.name.isEmpty, "A session without a name")
        precondition(
            session.created >= 0 && session.attachedClients >= 0 && session.windows >= 0, "A negative number")
    }
    return 0
}
