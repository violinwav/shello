# Vendor

Shello's C libraries, built from verified source by Shello's own scripts (docs/spec/STACK.md sections 2, 5 and 12). No prebuilt binary enters the app.

| Library | Version | Used for |
| --- | --- | --- |
| OpenSSL (libcrypto only) | 3.5.9, the 3.5 LTS line | libssh's crypto backend, including ML-KEM |
| libssh | 0.12.2 | SSH and SFTP, including `mlkem768x25519-sha256` and `sntrup761x25519-sha512` |

zlib is the one in the iOS SDK.

## Building

```sh
brew install cmake gnupg   # once; Xcode provides everything else
Vendor/build.sh
```

The script writes two static XCFrameworks to `Vendor/build/xcframeworks/`, which `Packages/ShelloKit/Package.swift` links as binary targets. Run it before the first Xcode build and after any change to the files below. It skips the build when nothing changed; `--force` rebuilds anyway. Everything under `Vendor/build/` is git-ignored. CI runs the same script and caches its output by the same files (`.github/workflows/ci.yml`).

Each XCFramework has two libraries: iOS with arm64 and arm64e in one fat library (Enhanced Security needs arm64e), and the iOS Simulator on arm64. Only `ShelloSSH` links them, and Swift sees libssh as the `CLibSSH` module (`libssh/module.modulemap`).

One function `ShelloSSH` calls is not in libssh's public headers: `ssh_global_request`, which sends the keepalive (`keepalive@openssh.com`) and waits for its answer. libssh exports it, and `Packages/ShelloKit/Sources/CLibSSHInternal/libssh_internal.h` declares it as libssh's `channels.h` does.

## Files

| File | What it is |
| --- | --- |
| `build.sh` | Builds the XCFrameworks. The libssh options are here. |
| `lib.sh` | Shared by both scripts: versions, URLs, pinned signers, hardening flags, OpenSSL options, verified download, patching. |
| `sources.sha256` | SHA-256 of each source tarball. |
| `keys/` | The release signing keys, as published by OpenSSL ([pubkeys.asc](https://openssl-library.org/source/pubkeys.asc)) and libssh ([get-it](https://www.libssh.org/get-it/)). |
| `openssl/50-shello.conf` | OpenSSL `Configure` targets for each slice, copied from upstream's iOS targets plus arm64e. |
| `libssh/module.modulemap` | Makes libssh importable from Swift. |
| `patches/<library>/` | Patches applied in order after unpacking. Each says why it exists. |
| `test-openssl-arm64e.sh` | Runs OpenSSL's test suite as arm64e on an Apple silicon Mac. |

## What the build does

1. **Downloads** each tarball and its `.asc` signature from the official URL only: GitHub releases of `openssl/openssl` (where openssl-library.org links) and `libssh.org/files`.
2. **Verifies** the tarball against `sources.sha256` and the signature with `gpgv` against a throwaway keyring made from `keys/`. The signing key must be the pinned primary key in `lib.sh`. Your own GnuPG keyring is never read or changed.
3. **Builds OpenSSL** with `no-shared no-engine no-comp no-legacy no-apps no-docs no-tests no-autoload-config`, and only the `libcrypto.a` target, so libssl is never built. Upstream's iOS targets already disable `async`. Assembly stays on.
4. **Builds libssh** with CMake against that libcrypto: static, client only (`WITH_SERVER=OFF`), `WITH_EXEC=OFF` (no ProxyCommand or `Match exec`), no GSSAPI, no PCAP or call-trace debugging, with SFTP and zlib. The build fails unless libssh uses OpenSSL's ML-KEM.
5. **Hardening:** every C file gets `-fstack-protector-strong -D_FORTIFY_SOURCE=2 -ftrivial-auto-var-init=zero -ftyped-memory-operations`. The last one is Xcode's typed allocator setting (`CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT`). The deployment target is iOS 26.0.
6. **Checks** every library for the right architecture and platform, then creates the XCFrameworks.

## arm64e and OpenSSL's assembly

OpenSSL 3.5.9 has no arm64e support. One piece of its aarch64 assembly breaks under pointer authentication: `poly1305_init` stores raw code addresses that C later calls, so every Poly1305 use crashes, ChaCha20-Poly1305 included. `patches/openssl/0001-…` signs them. No other aarch64 assembly stores code addresses or makes indirect calls.

The iOS Simulator has no arm64e, but macOS on Apple silicon runs arm64e processes with pointer authentication enforced, from the same `ios64` assembly. `test-openssl-arm64e.sh` builds OpenSSL that way, with the shipped options, flags and patches, and runs OpenSSL's own tests. It first checks that a call through an unsigned pointer really crashes. A physical iPhone is still the final check.

## Updating a library

1. Change the version in `lib.sh`.
2. Download the new tarball and `.asc`. Check that the signing key is the project's: OpenSSL's `doc/fingerprints.txt` and source page, or libssh's get-it page. If the key changed, update `keys/` and the signer in `lib.sh`, and say why in the pull request.
3. Replace the line in `sources.sha256` with `shasum -a 256 <tarball>`.
4. Check each patch: does it still apply, and is it still needed?
5. Check that `Packages/ShelloKit/Sources/CLibSSHInternal/libssh_internal.h` still matches the new libssh's declaration of `ssh_global_request` in `include/libssh/channels.h`, and that the library still exports it.
6. Run `Vendor/build.sh` and `Vendor/test-openssl-arm64e.sh`, then the app's tests.
7. Update docs/spec/STACK.md section 8.
