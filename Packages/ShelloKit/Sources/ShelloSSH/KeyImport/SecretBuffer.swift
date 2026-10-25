import Foundation
import ShelloModel

/// Secret bytes that ShelloSSH makes itself, such as an imported key's private key once libssh has
/// decrypted it (STACK section 7.3): a buffer of their own, overwritten with zeros once the last
/// reference goes, as ShelloSecurity's `Secret` is. A zero byte follows them, as `SecretBytes`
/// promises.
///
/// The buffer is an unsafe pointer that never leaves the class except into the closure of
/// `withUnsafeBytes(_:)`, and only `init` writes to it, so the class is safe to use.
@safe
final class SecretBuffer: SecretBytes, @unchecked Sendable {
    /// The bytes, then the zero byte; `count` of them are written.
    private let buffer: UnsafeMutableRawBufferPointer
    let count: Int

    /// A buffer of at most `capacity` bytes, which `write` fills from the start and says how many it
    /// wrote.
    init(capacity: Int, write: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity + 1, alignment: 1)
        unsafe buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let written: Int
        do {
            written = try unsafe write(UnsafeMutableRawBufferPointer(rebasing: buffer.dropLast()))
        } catch {
            unsafe Self.wipe(buffer)
            unsafe buffer.deallocate()
            throw error
        }
        precondition((0...capacity).contains(written), "More bytes than the buffer holds")
        unsafe self.buffer = buffer
        count = written
    }

    /// A buffer that holds a copy of `bytes`.
    convenience init(copying bytes: some Collection<UInt8>) {
        unsafe self.init(capacity: bytes.count) { buffer in
            unsafe buffer.initializeMemory(as: UInt8.self, from: bytes).initialized.count
        }
    }

    func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try unsafe body(UnsafeRawBufferPointer(rebasing: buffer.prefix(count)))
    }

    deinit {
        unsafe Self.wipe(buffer)
        unsafe buffer.deallocate()
    }

    /// Overwrites every byte with zero. `memset_s` is never optimised away, unlike a plain store to
    /// memory that is about to be freed.
    static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
        _ = unsafe memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
    }
}

extension SecretBuffer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SecretBuffer" }
    var debugDescription: String { "SecretBuffer" }
    var customMirror: Mirror { Mirror(self, children: []) }
}
