// libFuzzer target for Shello's SOCKS5 server side, which dynamic forwards serve: Packages/ShelloKit/
// Sources/ShelloSSH/Forwards/SOCKS5.swift, compiled into one module with this file (Fuzz/README.md).
//
// Each input is read twice as what a client sends: all at once, and in pieces as they arrive on the
// forward's connection. Nothing may trap; both readings must end the same way and send the client
// the same bytes; what the handshake sends is a method selection, a reply or both; and a destination
// must be what the bytes said: a domain name of printable ASCII, a port in network order, and the
// client's bytes after its request, every one of them, for the destination.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []

    var whole = SOCKS5Handshake()
    let all = whole.receive(bytes)
    check(all, of: bytes, fed: bytes.count)

    // The first byte chooses how many bytes arrive at once, from 1 to 16.
    let pieceSize = Int(bytes.first ?? 0) % 16 + 1
    var pieces = SOCKS5Handshake()
    var sent: [UInt8] = []
    var outcome = SOCKS5Handshake.Outcome.pending
    var fed = 0
    while fed < bytes.count, outcome == .pending {
        let end = min(bytes.count, fed + pieceSize)
        let step = pieces.receive(Array(bytes[fed..<end]))
        fed = end
        sent += step.send
        outcome = step.outcome
    }
    check(SOCKS5Handshake.Step(send: sent, outcome: outcome), of: bytes, fed: fed)

    precondition(sent == all.send, "The pieces sent the client other bytes")
    switch (all.outcome, outcome) {
    case (.connect(let wholeDestination, let wholeRest), .connect(let destination, let rest)):
        precondition(destination == wholeDestination, "The pieces read another destination")
        precondition(wholeRest.starts(with: rest), "The pieces kept other bytes for the destination")
    default:
        precondition(all.outcome == outcome, "The pieces ended another way")
    }
    precondition(whole.isDone == (all.outcome != .pending), "A handshake done without an outcome")
    return 0
}

/// Checks a handshake's `step` after it was given the first `fed` of `bytes`.
private func check(_ step: SOCKS5Handshake.Step, of bytes: [UInt8], fed: Int) {
    let selections: [[UInt8]] = [[5, 0x00], [5, 0xFF]]
    let replies = SOCKS5.Reply.allCases.map(\.bytes)
    let isSelection = selections.contains(step.send)
    let isReply = replies.contains(step.send)
    let isBoth = step.send.count == 12 && selections.contains(Array(step.send.prefix(2)))
        && replies.contains(Array(step.send.dropFirst(2)))
    precondition(step.send.isEmpty || isSelection || isReply || isBoth, "The handshake sent something else")
    guard case .connect(let destination, let rest) = step.outcome else { return }
    precondition(step.send == [5, 0x00], "A destination without the method selection")
    precondition(rest.count <= fed && Array(bytes[(fed - rest.count)..<fed]) == rest, "Bytes for the destination lost")
    let request = Array(bytes[..<(fed - rest.count)])
    let port = Int(request[request.count - 2]) << 8 | Int(request[request.count - 1])
    precondition(Int(destination.port) == port, "Another port than the request's")
    switch destination.host {
    case .ipv4(let address):
        precondition(address.count == 4, "An IPv4 address of another length")
    case .ipv6(let address):
        precondition(address.count == 16, "An IPv6 address of another length")
        precondition(destination.address.contains(":"), "An IPv6 address written without colons")
    case .domainName(let name):
        precondition(!name.isEmpty, "An empty domain name")
        precondition(name.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }, "A domain name that is not printable ASCII")
        precondition(destination.address == name, "A domain name that was changed")
    }
}
