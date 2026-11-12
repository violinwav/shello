// libFuzzer target for Shello's SSH agent protocol: Packages/ShelloKit/Sources/ShelloSecurity/
// SSHAgent/SSHAgentProtocol.swift, compiled into one module with this file (Fuzz/README.md).
//
// Each input is read twice: as the contents of one message, and as bytes arriving on the agent's
// socket in pieces, framed into messages that are then read too. Every request read is answered
// as the agent would answer it, without keys. Nothing may trap, and the framing must account for
// every byte it was given.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []

    answer(bytes)

    // The first byte chooses how many bytes arrive at once, from 1 to 16.
    let pieceSize = Int(bytes.first ?? 0) % 16 + 1
    var frames = SSHAgentFrames()
    var framed = 0
    var start = 0
    while start < bytes.count {
        let end = min(bytes.count, start + pieceSize)
        frames.append(bytes[start..<end])
        start = end
        while let message = try? frames.next() {
            framed += 4 + message.count
            answer(message)
        }
    }
    precondition(framed + frames.pendingCount == bytes.count, "The framing lost bytes")
    return 0
}

/// Reads `message` as a request, and writes the reply the agent would give it.
private func answer(_ message: [UInt8]) {
    guard let request = try? SSHAgentRequest(message: message) else {
        _ = SSHAgentReply.failure.message
        return
    }
    let reply: SSHAgentReply =
        switch request {
        case .requestIdentities: .identities([SSHAgentIdentity(keyBlob: message, comment: "fuzz")])
        case .sign(_, let data, _): .signature(data)
        case .extension, .unsupported: .failure
        }
    let written = reply.message
    precondition(!written.isEmpty, "A reply without its type")
}
