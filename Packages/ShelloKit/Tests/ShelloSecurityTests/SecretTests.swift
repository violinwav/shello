import Foundation
import Testing

@testable import ShelloSecurity

/// Secrets in memory are bytes, never `String`, and overwritten after use (STACK section 7.3).
struct SecretTests {
    @Test func holdsACopyOfTheBytes() {
        var bytes: [UInt8] = [0x68, 0x75, 0x6E, 0x74, 0x65, 0x72, 0x32]

        let secret = Secret(copying: bytes)
        bytes[0] = 0

        #expect(secret.bytes == [0x68, 0x75, 0x6E, 0x74, 0x65, 0x72, 0x32])
    }

    @Test func holdsTheUTF8OfTypedText() {
        let secret = Secret(utf8: "Grüezi 🔑")

        #expect(secret.bytes == Array("Grüezi 🔑".utf8))
    }

    /// libssh takes a password as a C string.
    @Test func bytesAreFollowedByAZeroByte() {
        let secret = Secret(copying: Array("hunter2".utf8))

        let terminator = unsafe secret.withUnsafeBytes { bytes in
            unsafe bytes.baseAddress!.load(fromByteOffset: bytes.count, as: UInt8.self)
        }
        #expect(terminator == 0)
    }

    @Test func emptySecretHasNoBytes() {
        #expect(Secret(copying: []).bytes.isEmpty)
        #expect(Secret(utf8: "").bytes.isEmpty)
    }

    /// What `deinit` does once the last reference goes.
    @Test func wipingOverwritesEveryByteWithZero() {
        let secret = Secret(copying: Array("correct horse battery staple".utf8))

        secret.wipe()

        #expect(secret.bytes.allSatisfy { $0 == 0 })
        #expect(secret.bytes.count == 28)
    }

    /// A secret interpolated into a log message, or dumped in the debugger, shows none of its bytes.
    @Test func descriptionAndReflectionRevealNothing() {
        let secret = Secret(utf8: "hunter2")

        #expect(String(describing: secret) == "Secret")
        #expect(String(reflecting: secret) == "Secret")
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }
}

extension Secret {
    /// A copy of the bytes, for comparing in tests.
    var bytes: [UInt8] {
        unsafe withUnsafeBytes { unsafe Array($0) }
    }
}
