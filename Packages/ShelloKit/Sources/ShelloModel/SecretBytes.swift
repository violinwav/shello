/// The bytes of a secret (GLOSSARY), read in place: how a password goes from the Keychain, which
/// ShelloSecurity reads, to the SSH library in ShelloSSH, without either module depending on the
/// other or a copy of the bytes staying behind (README section 13, STACK section 7.3).
/// ShelloSecurity's `Secret` is one.
public protocol SecretBytes: Sendable {
    /// Calls `body` with the secret's bytes, which stay valid only while it runs. A zero byte follows
    /// them, so that C code can take them as a string.
    func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result
}
