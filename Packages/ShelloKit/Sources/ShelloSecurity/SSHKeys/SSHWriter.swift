import Foundation

/// Writes data in the SSH wire format (RFC 4251 section 5), which SSH public keys and signatures
/// are made of, and which an SSH agent speaks.
struct SSHWriter {
    private(set) var data = Data()

    /// A `uint32`: four bytes, the most significant first.
    mutating func write(_ value: UInt32) {
        data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// A `string`: its length as a `uint32`, then its bytes.
    mutating func writeString(_ bytes: some Collection<UInt8>) {
        write(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// A `string` that holds text, such as an algorithm's name, in UTF-8.
    mutating func writeString(_ text: String) {
        writeString(text.utf8)
    }

    /// An `mpint` that holds a non-negative number, given as unsigned big-endian bytes. SSH writes
    /// it in two's complement with as few bytes as possible: leading zero bytes go, and a zero byte
    /// goes first when the top bit is set, so that the number does not read as negative. Zero is an
    /// empty string.
    mutating func writeMPInt(unsignedBigEndian bytes: some Collection<UInt8>) {
        let magnitude = Array(bytes.drop { $0 == 0 })
        if let first = magnitude.first, first & 0x80 != 0 {
            writeString([0] + magnitude)
        } else {
            writeString(magnitude)
        }
    }
}
