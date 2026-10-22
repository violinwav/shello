/// The bytes between a terminal and what it is connected to, in both directions: an SSH channel
/// (#28), or the terminal demo that runs on the device. It is the seam between the terminal view in
/// ShelloTerminalUI and the connections in ShelloCore, so it lives here, where both can reach it
/// without either depending on the other.
///
/// A terminal attaches to one stream at a time. It iterates `output` once and parses each chunk as
/// it arrives, sends the user's input with `send(_:)`, and reports its size with `resize(to:)`: once
/// when it attaches, then on every change. When a connection drops, its tab keeps the terminal and
/// its scrollback and attaches it to the next connection's stream.
public protocol TerminalByteStream: Sendable {
    /// The remote end's output, in the order it was written.
    associatedtype Output: AsyncSequence, Sendable where Output.Element == [UInt8]

    /// What the remote end writes, a chunk at a time, as raw bytes that may split a UTF-8 character
    /// or an escape sequence anywhere. The terminal asks for the next chunk only once it has parsed
    /// the last one, so a stream that reads on demand stops reading while the terminal is behind:
    /// nothing is dropped and memory stays bounded (STACK section 6). The sequence finishes when the
    /// remote end closes the stream and throws when it fails. It is iterated once, off the main
    /// actor.
    var output: Output { get }

    /// Sends the user's input to the remote end: keys, pastes and mouse reports, already encoded.
    /// The terminal calls it on the main actor for each key, so it returns at once and keeps the
    /// order of its calls: it queues the bytes and never waits for the network or for output, which
    /// is how input is never queued behind output.
    func send(_ bytes: [UInt8])

    /// Reports the terminal's new size, such as SSH's window-change request. Like `send(_:)`, it
    /// returns at once.
    func resize(to size: TerminalSize)
}

/// A terminal's size: its grid of character cells, and the pixels those cells cover, which SSH
/// passes on with the grid (RFC 4254 section 6.7).
public struct TerminalSize: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
