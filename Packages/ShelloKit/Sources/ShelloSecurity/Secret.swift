import Foundation

/// A password or passphrase in memory (README section 13, STACK section 7.3): bytes, never a
/// `String`, in a buffer of its own that is overwritten with zeros once the last reference to the
/// secret goes away. Pass the secret itself around, and read its bytes in place with
/// `withUnsafeBytes(_:)`, so that no copy is left behind.
///
/// The bytes are followed by a zero byte, so that C code can take them as a string, as libssh takes
/// a password. A secret's description and reflection show none of its bytes: one that ends up in a
/// log message or in the debugger reveals nothing.
///
/// The buffer is an unsafe pointer that never leaves the class except into the closure of
/// `withUnsafeBytes(_:)`, so the class is safe to use.
@safe
public final class Secret: @unchecked Sendable {
    /// The bytes, then the zero byte. Only `wipe()` writes to it after `init`, from `deinit`, when
    /// nothing else can read it; that is what makes the class sendable.
    private let buffer: UnsafeMutableRawBufferPointer

    /// A secret that holds a copy of `bytes`.
    public init(copying bytes: some Collection<UInt8>) {
        let count = bytes.count
        unsafe buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count + 1, alignment: 1)
        let bytesCopied = unsafe buffer.initializeMemory(as: UInt8.self, from: bytes).initialized.count
        precondition(bytesCopied == count, "The collection has fewer bytes than it counts")
        unsafe buffer[count] = 0
    }

    /// A secret that holds the UTF-8 of `text`, as a text field hands it over. Unlike the secret,
    /// the string is never overwritten, so drop it as soon as the secret exists.
    public convenience init(utf8 text: String) {
        self.init(copying: text.utf8)
    }

    /// Calls `body` with the secret's bytes, without the zero byte that follows them. The bytes stay
    /// valid only while `body` runs, and the secret must stay alive until it returns.
    public func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try unsafe body(UnsafeRawBufferPointer(rebasing: buffer.dropLast()))
    }

    /// Overwrites every byte with zero. `memset_s` is never optimised away, unlike a plain store to
    /// memory that is about to be freed.
    func wipe() {
        _ = unsafe memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
    }

    deinit {
        wipe()
        unsafe buffer.deallocate()
    }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Secret" }
    public var debugDescription: String { "Secret" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
