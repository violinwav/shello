# libssh for SSH, fed through a socketpair from Network.framework

Shello uses libssh 0.12 for SSH and SFTP from the MVP on. libssh never opens sockets itself: Shello connects with Network.framework and hands libssh one end of a socketpair, because Apple's BSD sockets are incompatible with VPN On Demand and need a hand-written Happy Eyeballs (TN3151).

## Considered Options

- **SwiftNIO SSH**: Swift-native, but offers only curve25519 and AES-GCM, no RSA, chacha20-poly1305, keyboard-interactive or post-quantum key exchange, and no public extension point to add a key exchange. Kept as the fallback if Secure Enclave keys cannot work with libssh.
- **Citadel**: adds AES-CTR and RSA on top of SwiftNIO SSH, but through a third-party fork of it, and signs RSA with SHA-1 only, which OpenSSH 8.8 and later rejects by default.
- **libssh2**: BSD-licensed, but its ML-KEM support was unreleased, requires OpenSSL 3.5, and it has no sntrup761.

## Consequences

- Shello wraps C code and bundles a crypto library (OpenSSL 3.x, or mbedTLS).
- A libssh connection must never be used from two threads at once, so each connection runs on its own serial queue.
