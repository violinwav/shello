import ShelloSSH
import Testing

@testable import ShelloFeatures

/// A connection's key exchange is marked post-quantum or classical in words and by the shape of its
/// symbol, never by colour alone (README sections 14 and 16).
@Test func postQuantumKeyExchangeSaysSoAndHasAShield() {
    let keyExchange = KeyExchange(name: "mlkem768x25519-sha256", isPostQuantum: true)

    #expect(keyExchange.title == "Post-Quantum Key Exchange")
    #expect(keyExchange.systemImage == "lock.shield")
}

@Test func classicalKeyExchangeSaysSoAndHasAPlainLock() {
    let keyExchange = KeyExchange(name: "curve25519-sha256", isPostQuantum: false)

    #expect(keyExchange.title == "Classical Key Exchange")
    #expect(keyExchange.systemImage == "lock")
}

/// VoiceOver keeps the name as it is written, which braille shows too, and says its punctuation.
@Test func voiceOverReadsTheNameWithItsPunctuation() {
    let keyExchange = KeyExchange(name: "sntrup761x25519-sha512@openssh.com", isPostQuantum: true)

    let spoken = keyExchange.spokenName

    #expect(String(spoken.characters) == "sntrup761x25519-sha512@openssh.com")
    #expect(spoken.runs.allSatisfy { $0.accessibilitySpeechIncludesPunctuation == true })
}
