// libFuzzer target for what Shello reads of a private key's text before libssh reads the key, and
// of the PKCS #8 that libssh hands the key over in: Packages/ShelloKit/Sources/ShelloSSH/KeyImport/
// KeyText.swift and PKCS8.swift, compiled into one module with this file (Fuzz/README.md).
//
// Each input is read as a key's text, with its PEM armor and its OpenSSH header, as base64, and as
// DER. Nothing may trap, whatever is found must lie within the input, and base64 never decodes to
// more bytes than it was given characters.

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTestOneInput(_ data: UnsafeRawPointer?, _ count: Int) -> CInt {
    let bytes: [UInt8] = data.map { Array(UnsafeRawBufferPointer(start: $0, count: count)) } ?? []

    _ = KeyText(bytes)
    if let armor = PEMArmor(bytes) {
        precondition(armor.body.lowerBound >= 0 && armor.body.upperBound <= bytes.count, "The body is outside the text")
        _ = OpenSSHKeyHeader(base64: bytes[armor.body])
    }

    var decoder = Base64Decoder(bytes.makeIterator())
    var decoded = 0
    while decoder.next() != nil {
        decoded += 1
    }
    precondition(decoded <= bytes.count, "More bytes decoded than characters given")

    if let key = try? PKCS8PrivateKey(der: bytes) {
        precondition(key.privateKey.upperBound <= bytes.count, "The private key is outside the DER")
    }
    return 0
}
