# Shello — Technical Stack

Oct 13, 2026 · @violin

This document defines what Shello is built with: languages, toolchain, frameworks, packages and the build, test and release setup. It turns section 2 of `README.md` (the functional specification) into concrete choices and pinned versions. Terms follow `GLOSSARY.md`; phase tags (MVP, v1, Later) follow README section 17.

Versions were checked against primary sources on the date above. "Pin" means the exact version or commit the project starts on; Dependabot and the release checklist move them forward. Where this document disagrees with the README or an ADR, section 15 lists the conflict.

## 1. The stack at a glance

| Layer | Choice | Phase |
| --- | --- | --- |
| Language | Swift 6 (language mode 6, strict concurrency); C and C++ only inside vendored libraries | MVP |
| Toolchain | Xcode 26.6 (Swift 6.3) today, Xcode 27 (Swift 6.4, iOS 27 SDK) before the first App Store upload | MVP |
| Platforms | iOS and iPadOS 26.0 and later, one universal app | MVP |
| App shell | SwiftUI with Observation (`@Observable`) | MVP |
| Terminal, keyboard, VNC view, editor | UIKit, embedded in SwiftUI | MVP / v1 |
| Terminal emulation | SwiftTerm 2.x | MVP |
| SSH, SFTP | libssh 0.12.2 on OpenSSL 3.5 LTS (libcrypto only) | MVP |
| Transport | Network.framework `NWConnection` bridged to libssh through a socketpair (ADR 0002) | MVP |
| Mosh | Upstream Mosh client via Blink Shell's iOS fork (GPLv3), protobuf-lite | v1 |
| VNC | RoyalVNCKit, maintained as a Shello fork (upstream archived) | v1 |
| Storage | SQLite through GRDB.swift 7 | MVP |
| Sync | CloudKit private database through `CKSyncEngine`; iCloud Keychain for opted-in secrets | v1 |
| Keys and secrets | CryptoKit, Secure Enclave, Keychain, LocalAuthentication | MVP |
| Purchases | StoreKit 2, on-device verification | v1 |
| Tests | Swift Testing, XCTest/XCUITest, swift-snapshot-testing, Docker OpenSSH matrix, libFuzzer | MVP |
| CI and release | GitHub Actions for checks, Xcode Cloud for signing and TestFlight | MVP |

## 2. Principles

Every choice below follows from these rules. When a new dependency or tool is proposed, it is checked against them.

1. **Few dependencies, each one earned.** A dependency must be GPLv3-compatible (ADR 0001), maintained, and do something Shello should not write itself. Small, security-sensitive parsers (OpenSSH config, SSH agent protocol, tmux output, SOCKS) are written in-house and fuzzed rather than pulled in.
2. **Memory-unsafe code is contained.** C and C++ exist only in libssh, OpenSSL, Mosh, protobuf and their build. They are built from verified source by Shello's own scripts, with every hardening option the platform offers, and reached only through one Swift module each.
3. **The compiler enforces the threading rules.** Swift 6 language mode makes data races compile errors. Each connection is an actor bound to its own serial queue, which turns libssh's "one thread per session" rule into a type-system guarantee.
4. **Secrets live in the Keychain or the Secure Enclave.** They never reach the database, logs, crash reports, the clipboard or scrollback (README section 13).
5. **Every write is transactional and every schema change is tested.** Host data is never lost on a crash (README section 16).
6. **Performance budgets are tests.** The targets in README section 16 are measured by automated tests, not checked by eye.
7. **No backend, no third-party SDKs.** Only Apple frameworks talk to Apple services; nothing else leaves the device (ADR 0005, README section 15).

## 3. Toolchain and languages

### Xcode and Swift

- **Today: Xcode 26.6** (build 17F113, Swift 6.3.3, iOS 26.5 SDK), installed and selected on the development Mac.
- **Before the first App Store upload: Xcode 27** (Swift 6.4, iOS 27 SDK). From April 2027, App Store uploads [must be built with the iOS 27 SDK](https://developer.apple.com/app-store/submitting/). Xcode 27 [requires macOS 26.6 or later](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes); the development Mac runs 26.5.2. Move to Xcode 27 at kickoff if macOS can be updated; nothing in this stack depends on it.
- **Swift language mode 6.** New Xcode 26.6 projects still default to `SWIFT_VERSION = 5.0`, so set it explicitly (section 5).

### Languages

| Language | Where | Why |
| --- | --- | --- |
| Swift 6 | All app code, all Shello modules, extensions, tests | The default. |
| C | libssh, OpenSSL (vendored); small C shims if a callback needs one | libssh and OpenSSL are C. Shims are compiled with `-fbounds-safety` (section 5). |
| C++17 | Mosh client, protobuf, Abseil (vendored) | Mosh is C++. No Shello code is written in C++. |
| Shell (POSIX sh, bash, zsh, fish) | Vendor build scripts; shell integration scripts installed on servers by the user (v1) | Shell integration runs on the server, not in the app. |
| Dockerfile, YAML | Test servers, CI workflows | Tooling only. |

There is no Objective-C, no Metal shader code and no web technology in the app. SwiftTerm ships its own optional Metal renderer, so Shello does not write shaders.

## 4. Project structure and modules

A thin Xcode project holds only the app and extension targets. All logic lives in one local Swift package, `ShelloKit`, split into targets whose dependency rules the compiler enforces. This follows README section 2: a UI-independent connection core that can later back a File Provider extension, a Mac app or a shared library.

```
shello/
├── Shello.xcodeproj           app + extension targets only, buildable folders
├── App/                       @main, scenes, composition root, assets, entitlements, privacy manifest
├── UITests/                   XCUITest target, including the accessibility audits
├── Configurations/            xcconfig files holding the build settings in section 5
├── Extensions/
│   └── Share/                 "Upload to host" share extension (v1)
├── Packages/ShelloKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── ShelloModel/       domain types: host, group, tag, snippet, preset … (Foundation only)
│   │   ├── ShelloStorage/     GRDB database, migrations, JSON export/import
│   │   ├── ShelloSync/        CKSyncEngine, field-level merge (v1)
│   │   ├── ShelloSecurity/    Keychain, Secure Enclave, unlock window, SSH agent, security log
│   │   ├── ShelloSSH/         libssh wrapper: connection actor, channels, SFTP, forwards, algorithm policy
│   │   ├── ShelloTmux/        tmux queries and parsers over hidden channels
│   │   ├── ShelloMosh/        Mosh client wrapper (v1)
│   │   ├── ShelloCore/        tabs and connections lifecycle, reconnect/reattach, detection, multi-host run
│   │   ├── ShelloTerminalUI/  UIKit: SwiftTerm host view, Shello keyboard, extra keys row, pads
│   │   ├── ShelloVNCUI/       UIKit VNC view (v1)
│   │   ├── ShelloPurchases/   StoreKit 2 entitlements (v1)
│   │   └── ShelloFeatures/    SwiftUI screens
│   └── Tests/
├── Vendor/                    build scripts, pinned checksums, patches for C/C++ deps; outputs git-ignored
├── ShellIntegration/          bash, zsh, fish scripts (v1)
├── TestServers/               Dockerfiles and compose files for the OpenSSH/tmux/mosh-server matrix
├── Fuzz/                      libFuzzer targets for Shello's parsers
└── docs/
```

Dependency rules:

- `ShelloModel`, `ShelloSSH`, `ShelloTmux` and `ShelloStorage` import Foundation and their C libraries only: no UIKit, no SwiftUI, no CryptoKit. This keeps them buildable on Linux for the integration matrix (section 11) and reusable by a future Mac app.
- `ShelloSecurity`, `ShelloSync` and `ShelloPurchases` use Apple frameworks and stay UI-free.
- Only `ShelloTerminalUI`, `ShelloVNCUI`, `ShelloFeatures` and the app target import UIKit or SwiftUI.
- The C libraries are `binaryTarget`s pointing at XCFrameworks that `Vendor/` scripts build locally and in CI. They are static libraries, so nothing is loaded at runtime from outside the app binary.
- The Xcode project uses buildable (folder-synchronised) groups ([Xcode 16](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)) so adding files does not touch `project.pbxproj`.

Architecture inside the app: plain SwiftUI with `@Observable` models on the main actor and a small composition root that passes services through the SwiftUI environment. No third-party architecture framework.

## 5. Build settings and platform hardening

Shello parses data from servers it does not control, much of it in C. The platform's compile-time and runtime protections are therefore switched on from the first commit, while they are cheap to adopt.

### Swift settings (every target)

| Setting | Value | Why |
| --- | --- | --- |
| `SWIFT_VERSION` | `6` | Strict concurrency: data races are errors. The template default is still 5.0. |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` for UI targets and the app; `nonisolated` for core targets | [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md). In `Package.swift`: `.defaultIsolation(MainActor.self)` on UI targets only. |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` | Swift 6.2 concurrency defaults (SE-0461). |
| `SWIFT_STRICT_MEMORY_SAFETY` | `YES` on core targets | [SE-0458](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md): every unsafe pointer use around libssh, Mosh and VNC framebuffers must be marked `unsafe`, so it can be found and reviewed. |
| Warnings as errors | `YES` in CI | Keeps the strict modes strict. |
| `ENABLE_USER_SCRIPT_SANDBOXING` | `YES` | Build-phase scripts cannot touch files they do not declare. |

### Enhanced Security (every target, including vendored C/C++)

Xcode 26's [Enhanced Security capability](https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app) is supported for App Store apps on iOS and iPadOS. Shello enables it for all targets ("Enable Enhanced Security for All Targets"):

| Protection | Setting or entitlement |
| --- | --- |
| Umbrella | `ENABLE_ENHANCED_SECURITY = YES` |
| Pointer authentication (adds an arm64e slice) | `ENABLE_POINTER_AUTHENTICATION = YES` |
| Typed allocators | `CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT`, `CLANG_ENABLE_CPLUSPLUS_TYPED_ALLOCATOR_SUPPORT` |
| Zero-initialised stack | `CLANG_ENABLE_STACK_ZERO_INIT` |
| Security warnings | `ENABLE_SECURITY_COMPILER_WARNINGS` |
| Hardware memory tagging (Memory Integrity Enforcement, A19 and later) | `com.apple.security.hardened-process.checked-allocations` |
| Read-only dyld memory, platform restrictions | `com.apple.security.hardened-process.dyld-ro`, `…platform-restrictions-string` |

Consequences:

- The arm64e slice is only added when `ARCHS` is left at `ARCHS_STANDARD`, so the `Vendor/` scripts build libssh, OpenSSL and Mosh for **arm64e as well as arm64**. OpenSSL's assembly works on arm64e with one patch (spike item 7, section 13). Poly1305's assembly hands C unsigned code pointers, which pointer authentication rejects, so ChaCha20-Poly1305 crashed. `Vendor/patches/openssl/` signs them. `Vendor/test-openssl-arm64e.sh` runs OpenSSL's test suite as arm64e on macOS, where pointer authentication is enforced too. Disabling OpenSSL assembly would have been the last resort, because it costs a lot of throughput.
- Swift package targets do not inherit the project's build settings, so `ShelloKit` would build without arm64e and the device build fails. The workspace setting `iOSPackagesShouldBuildARM64e`, in `Shello.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`, makes Xcode build packages for arm64e too ([BrowserEngineKit: build for pointer authentication](https://developer.apple.com/documentation/browserenginekit/creating-browser-extensions-in-xcode#Build-for-pointer-authentication)). CI checks both slices.
- Memory tagging only works on A19 and later and is not available in the Simulator. Address Sanitizer [cannot be combined with it](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_1-release-notes), so sanitizer runs use a separate build configuration.

### C and C++ hardening for vendored code

- C: `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-ftrivial-auto-var-init=zero`, plus the typed allocators above. Shello's own C shims also get `ENABLE_C_BOUNDS_SAFETY = YES` (`-fbounds-safety`); upstream libraries are not annotated for it.
- C++ (Mosh, protobuf, Abseil): `CLANG_CXX_STANDARD_LIBRARY_HARDENING = fast` in Release and `extensive` in Debug and tests (`_LIBCPP_HARDENING_MODE`, [Xcode 16](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)).
- OpenSSL is configured with only what libssh, Mosh and the backup need: libcrypto, no libssl, and `no-shared no-engine no-comp no-legacy no-apps no-docs no-tests no-autoload-config`. The spike added `no-autoload-config`, because an app has no `openssl.cnf` to load. `Vendor/README.md` lists the libssh options.

## 6. Concurrency and performance model

**Connections.** Each connection is an `actor` whose executor is its own `DispatchSerialQueue` ([SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md)). The same queue runs the `NWConnection` callbacks, the socketpair pump and every libssh call. libssh is therefore never touched from two threads (ADR 0002), and the compiler rejects code that tries; every libssh operation also checks that it runs on the queue (`dispatchPrecondition`). The executor (`QueueExecutor`) puts each of the actor's jobs on the queue as a block, as Network.framework puts its callbacks, and each block keeps the executor alive until its job has run: a connection's isolated deinit is a job on its own executor, and the jump host's connection it releases deinits right then, while the runtime looks at the executor it runs on. `DispatchSerialQueue`'s own executor (`queue.asUnownedSerialExecutor()`) hands jobs to libdispatch past the functions Thread Sanitizer watches: with it, Thread Sanitizer reported every variable the jobs and the callbacks share as a race (39 reports in the ShelloSSH and ShelloCore tests, none with `QueueExecutor`).

**Input path** (budget: keystroke to network send under 10 ms). Key event on the main actor, one hop to the connection actor, `ssh_channel_write`, then the socketpair and `NWConnection.send`. No allocation-heavy work and no main-thread round trip on the way. A key of the Shello keyboard reaches the terminal's stream before the keyboard draws or gives feedback: in the simulator, with no output, its keys took 0.1 ms (median) and 7.4 ms (95th percentile) from the moment the touch was queued on the main thread (`TerminalPerformanceTests`). The keyboard's own part, from the touch reaching it to the stream, is the signpost interval "Key".

**Output path** (budget: a 10 MB log never freezes input).

- libssh output is read in chunks and handed to the terminal in batches, coalesced to the display refresh.
- When the terminal falls behind, Shello stops reading the channel. The SSH window then fills and the server slows down. Nothing is dropped and memory stays bounded.
- Input is never queued behind output.
- The terminal is attached to a connection through a byte stream (`TerminalByteStream` in `ShelloModel`). It parses the stream's output off the main actor, 4 KiB at a time: SwiftTerm's terminal lock is fair, so the main thread waits for at most one slice when it registers a key or prepares a frame.

**Rendering.** SwiftTerm draws with CoreText by default and has an optional Metal renderer (`setUseMetal(true)`). Shello uses CoreText (`TerminalRenderer.standard`). In the 10 MB test (`TerminalPerformanceTests`, iPhone 17 simulator, debug build) both printed the 10 MB equally fast, but typing stayed responsive only with CoreText: keystroke latency median 9 ms and p95 30 ms, against 113 ms and 502 ms with Metal. The measurement on devices (below) confirms or reverses the choice; switching is one line.

**Memory** (budget: 10 tabs with full scrollback under 200 MB). Ten tabs of 10,000 lines at 80 or more columns is 8 million cells or more. At SwiftTerm's per-cell size this is close to the budget, so it is measured in the spike. If it is over, older scrollback is compacted.

**Measurement.** Measured with `os_signpost` intervals and XCTest metrics: `XCTOSSignpostMetric`, `XCTMemoryMetric`, and `XCTHitchMetric` (new in iOS 26). Measurements run on the oldest iOS 26 iPhone class (A13: iPhone 11, iPhone SE 2nd generation) and on a current A19 device.

## 7. Feature stack

### 7.1 Networking (README sections 3 and 4)

- **Connections:** Network.framework [`NWConnection`](https://developer.apple.com/documentation/network/nwconnection), connecting by name, which gives Happy Eyeballs and VPN On Demand ([TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)).
  - The iOS 26 `NetworkConnection` API is the structured-concurrency successor. `NWConnection` stays because it is mature and exposes viability and better-path updates, which the reconnect logic and the network-switch spike need. The choice is reviewed after the spike.
- **libssh bridge:** `socketpair(AF_UNIX, SOCK_STREAM)` with `SO_NOSIGPIPE`. One end goes to libssh through `SSH_OPTIONS_FD`; Shello pumps bytes between the other end and `NWConnection` on the connection's queue.
- **Network changes:** `NWPathMonitor` plus the connection's viability and better-path handlers drive the "reconnecting" state and backoff.
- **Reachability probes (v1):** a TCP connect with a short timeout through `NWConnection`, at most once per minute per host, and only while the host list is visible.
- **Local Network privacy:**
  - `NSLocalNetworkUsageDescription` is set, and Shello explains the prompt before the first local connect ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)). Whether a server is local is a guess from its address (`Server.isOnLocalNetwork`): private and link-local addresses, `.local` and the suffixes home networks use, and names of one label. Through jump hosts, only the route's first host is reached from the device, so only it counts: a host behind a jump host never brings the explanation, whatever its address.
  - Denial shows up as `.waiting` with `unsatisfiedReason == .localNetworkDenied`, and so does the time while the prompt is up. The connection keeps waiting then, since iOS retries it once access is granted; at the connect timeout it fails with `SSHError.localNetworkDenied`, which says where to allow access. A `.waiting` for any other reason fails a first connection at once.
  - The Simulator does not enforce this, so it is tested on a device.
- **Port forwarding (v1):**
  - Local and dynamic forwards listen through `NWListener` bound to `127.0.0.1` only, never to all interfaces.
  - SOCKS5 is parsed in-house and fuzzed.
  - Remote forwards use libssh.
  - Loopback listeners can be reached by other apps running on the device, so they exist only while the user has a forward running.
- **Mosh (v1):** Mosh's UDP traffic uses BSD sockets inside the Mosh client. This is acceptable: the SSH bootstrap runs over `NWConnection` first, so VPN On Demand is already up when Mosh starts.

### 7.2 SSH, SFTP and post-quantum cryptography (README sections 4, 10 and 14)

**libssh 0.12.2** (released 2026-07-28, a security release; [libssh.org](https://www.libssh.org/), [changelog](https://gitlab.com/libssh/libssh-mirror/-/raw/stable-0.12/CHANGELOG)).

- **Key exchange:** `mlkem768x25519-sha256` and `sntrup761x25519-sha512` arrived in 0.12.0 ([announcement](https://archive.libssh.org/libssh/2026-02/0000001.html)). With OpenSSL 3.5 or later, libssh uses OpenSSL's own ML-KEM.
- **SSH agent:** `SSH_OPTIONS_FD`, `ssh_userauth_agent`, `ssh_set_agent_channel`, `ssh_set_agent_socket`, and `ssh_channel_request_auth_agent` for agent forwarding.
- **Authentication:** keyboard-interactive (`ssh_userauth_kbdint*`); OpenSSH certificates (`ssh_pki_import_cert_*`, `ssh_pki_copy_cert_to_privkey`).
- **ProxyJump:** `SSH_OPTIONS_PROXYJUMP` exists, but Shello builds jump chains itself. Each hop is a `direct-tcpip` channel, so every hop gets Shello's own host-key check and credentials.
  - A route (`Route` in `ShelloModel`) is the route to the first jump host, through its own jump hosts as OpenSSH applies them, then the other jump hosts, then the host. Shello refuses one that reaches a host twice, has a jump host that is missing or not an SSH host, or has more than 8 jump hosts (`Route.maximumJumpHosts`; OpenSSH sets no limit).
  - The channel is a byte stream, `SSHTunnel` (`SSHConnection.openTunnel(to:port:)`), which local forwards and VNC's tunnel use too. What the far end sends is read only as fast as the reader asks; what Shello sends goes into the channel as the far end's window allows, and `drain()` waits for it. Either side's end of input (EOF) and close pass through.
  - The next hop's connection is an `SSHConnection` of its own, on its own queue, whose libssh talks on its own socketpair, as a direct one's does. Its bridge sends what libssh writes into the jump host's tunnel instead of an `NWConnection`, and holds no more than 1 MiB that the tunnel has not taken; the jump host's connection writes it into the channel on its own queue. A jump host's connection that ends ends the connections after it, as lost.
  - `HostConnector.connect(along:…)` connects hop by hop, each host key checked under the hop's own server, the address and port as the hop before reaches them, and each hop signing in with its own host's method. A tab's connection is the whole route (`RouteConnection`): the shell, hidden channels and keepalive use the last connection, and the network events come from the first.
- **SFTP:** the async API (`sftp_aio_begin_read/write`, `sftp_aio_wait_*`, since 0.11.0) pipelines requests, which is what makes transfers fast on high-latency links.
- **Fuzzing:** libssh is fuzzed in [OSS-Fuzz](https://github.com/google/oss-fuzz/tree/master/projects/libssh).
- **Licence:** LGPL-2.1-or-later, with an OpenSSL linking exception. Some newer files are LGPL-2.1-only, which is still GPLv3-compatible because LGPL 2.1 section 3 allows relicensing to the GPL.

**OpenSSL 3.5.9, the 3.5 LTS line** ([release strategy](https://openssl-library.org/policies/releasestrat/index.html): supported until 2030-04-08).

- **Why 3.5:** it is the oldest line with native ML-KEM, which libssh uses, and the only LTS. 4.0 is supported only until 2027-05-14, and no libssh CI job builds against it yet. 3.6 ends on 2026-11-01. 3.0 is already end-of-life.
- **What Shello uses from it:** only libcrypto, as libssh's backend. It also provides Argon2id for the encrypted backup (`EVP_KDF-ARGON2`, [since 3.2](https://docs.openssl.org/3.5/man7/EVP_KDF-ARGON2/)), so the backup needs no extra library.
- **iOS support:** iOS is a [community-tier](https://openssl-library.org/policies/general-supplemental/platforms/index.html) OpenSSL platform. Shello builds with the upstream `ios64-xcrun` and `iossimulator-arm64-xcrun` targets and adds arm64e.
- **mbedTLS** is not a real fallback anymore. libssh 0.12 does not support mbedTLS 4.x, and mbedTLS 3.6 LTS ends in March 2027 (section 15).

**Algorithm policy as data** (README section 14). The preferred lists for key exchange, ciphers, MACs, host keys and the SSH keys' signatures ship as a bundled, versioned resource, `Packages/ShelloKit/Sources/ShelloSSH/Resources/AlgorithmPolicy.json` (version 2), with the names of the post-quantum key exchanges that mark a connection post-quantum or classical. They are applied through `ssh_options_set` (`SSH_OPTIONS_KEY_EXCHANGE`, `SSH_OPTIONS_CIPHERS_C_S` and `_S_C`, `SSH_OPTIONS_HMAC_C_S` and `_S_C`, `SSH_OPTIONS_HOSTKEYS`, `SSH_OPTIONS_PUBLICKEY_ACCEPTED_TYPES`). A host's own lists (`AlgorithmOverrides`) replace the policy's; their screen and their storage come with v1. The host key algorithms of the server's trusted host key go first, as OpenSSH orders them for a server in `known_hosts`, so that a server with several host keys presents the trusted one. Settings, Diagnostics shows what the policy offers. MVP default order:

- Key exchange: `mlkem768x25519-sha256`, `sntrup761x25519-sha512`, `curve25519-sha256`, then the classical ones without SHA-1 that a server without curve25519, such as one in FIPS mode, may have: `ecdh-sha2-nistp256`, `ecdh-sha2-nistp384`, `ecdh-sha2-nistp521`, `diffie-hellman-group16-sha512`, `diffie-hellman-group18-sha512`, `diffie-hellman-group14-sha256`. sntrup is offered under its vendor name `sntrup761x25519-sha512@openssh.com` too, the only one OpenSSH before 9.9 knows.
- Ciphers: `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`, `aes256-ctr`, `aes192-ctr`, `aes128-ctr`.
- MACs: `hmac-sha2-256-etm@openssh.com`, `hmac-sha2-512-etm@openssh.com`. Only AES-CTR uses them; the other ciphers authenticate themselves.
- Host keys and SSH keys: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`, `rsa-sha2-512`, `rsa-sha2-256`.
- Off: SHA-1, CBC and DSA. libssh 0.12 has no DSA at all.

**Host keys.**

- Shello keeps its own trust store in the database, keyed by server (address and port), not libssh's `known_hosts` file.
- The fingerprint shown is SHA-256, computed with `ssh_get_publickey_hash(SSH_PUBLICKEY_HASH_SHA256)`.
- Replacing a stored host key requires a LocalAuthentication check: a fresh `LAContext` and `deviceOwnerAuthentication` each time, whether or not the unlock window is open, after the user confirmed the replacement. On a device without a passcode, which cannot ask anyone, the confirmation is enough, as with app lock.

**Keyboard-interactive** (`ssh_userauth_kbdint`): each round of the server's questions goes to the user in one sign-in sheet, which shows or hides each answer as the server asks. The questions are the server's text, so control characters and bidirectional overrides are removed before they are shown. The answers go to libssh as secrets, which libssh overwrites once sent. After a partial success, as on a server with two-factor sign-in, Shello continues with keyboard-interactive, or the host's password or SSH key, whichever the server takes.

### 7.3 SSH keys, secrets and the SSH agent (README section 13)

| Need | Technology |
| --- | --- |
| Generated key, default | CryptoKit `SecureEnclave.P256.Signing.PrivateKey` with a `SecAccessControl` (`.privateKeyUsage` plus user presence). The encrypted key blob is stored as a Keychain item, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable. |
| Generated Ed25519 key | CryptoKit `Curve25519.Signing.PrivateKey`, raw representation in the Keychain, `…WhenUnlockedThisDeviceOnly` with access control. |
| Imported key | Parsed by libssh (`ssh_pki_import_privkey_base64`: OpenSSH and PEM, with passphrase). The private key is stored in the Keychain; the passphrase is not kept. Synced only on opt-in (`kSecAttrSynchronizable`, v1). |
| Unlock window | One `LAContext` evaluated at app lock and passed to every Keychain read (`kSecUseAuthenticationContext`) and Secure Enclave signature (`authenticationContext:`). Invalidated when app lock re-engages. "Every use" keys get a fresh context per signature. |
| Signing for libssh | All SSH keys sign through Shello's SSH agent (`SSHAgent`), connected to libssh with `ssh_set_agent_socket` and used through `ssh_userauth_agent` (spike item 3). The agent serves one end of a pair of Unix sockets on a queue of its own, because libssh waits for each answer on the connection's queue. For a sign-in it offers the host's key only, and signs through `SSHKeyStore`. Secure Enclave keys can never be handed to libssh as private keys, and one signing path gives one place for confirmations and the security log. |
| SSH agent protocol | Written in-house in Swift ([draft-ietf-sshm-ssh-agent](https://datatracker.ietf.org/doc/draft-ietf-sshm-ssh-agent/)), using [Secretive's `SSHProtocolKit`](https://github.com/maxgoedjen/Secretive) (MIT) as a reference, with the standard library only. Fuzzed by `Fuzz/SSHAgentProtocol`, built with the swift.org toolchain in Docker (`Fuzz/README.md`). |
| Public key formats, QR | OpenSSH public-key encoding written in-house; QR codes via Core Image `CIQRCodeGenerator` (v1). |
| Passwords, passphrases, sudo passwords | Keychain generic passwords, `…WhenUnlockedThisDeviceOnly` unless the user opts into sync. Sudo passwords also carry a biometric access control (README section 9). |
| Secrets in memory | Kept as byte buffers, never `String`, and overwritten after use. Passed to libssh as C buffers. |
| Post-quantum signatures (Later) | CryptoKit `MLDSA65` / `MLDSA87`, including Secure Enclave variants, available since [iOS 26](https://developer.apple.com/documentation/cryptokit/enhancing-your-app-s-privacy-and-security-with-quantum-secure-workflows). Waits for OpenSSH. |
| FIDO2 keys (Later) | libssh 0.12 supports FIDO/U2F through libfido2. The iOS transport is a later decision. |

**Generated keys in the Keychain.**

- Each generated key is one generic password item of the service `ch.shello.ssh-key`, found by the key's identifier.
- The item's generic attribute holds the key's record: name, kind, signing policy, public key and creation time. Attributes read without authentication, so keys are listed without a prompt.
- The item's data is the key itself: the Secure Enclave's blob, or the Ed25519 private key behind the access control. The record never holds it.
- `SSHKeyStore` in `ShelloSecurity` is the only code that reads the data, and it hands out public keys and signatures only.

**Imported keys** (README section 13):

- libssh reads the pasted or picked text (`ssh_pki_import_privkey_base64`): OpenSSH's format and PEM, PKCS #8 included, plain or encrypted. Before that, Shello reads only what the text says without its passphrase (`ShelloSSH/KeyImport/KeyText.swift`, fuzzed by `Fuzz/KeyText`): the format, whether it is encrypted, and an OpenSSH key's public key. So it asks for the passphrase only when the key needs one, and refuses DSA, RSA under 2048 bits, ECDSA P-521 and security keys first, each with its own sentence.
- The text and the passphrase stay in byte buffers that are overwritten once let go, never in a `String` or a text field: the sheet has the system's Paste button and the Files app's picker. Once a pasted key is imported, Shello empties the clipboard, which would hold the key, or its passphrase if the user copied that meanwhile. An app cannot tell whether the clipboard changed since its paste: its own count of the clipboard's changes moves whenever one of its text fields takes the keyboard. libssh's own copies are freed by libssh.
- libssh hands the decrypted key over as PKCS #8 (`ssh_pki_export_privkey_base64_format`), whose private key Shello finds in place (`PKCS8.swift`): Ed25519's seed and an ECDSA scalar for CryptoKit, an RSA key's PKCS #1 `RSAPrivateKey` for Security (`SecKeyCreateWithData`), as CryptoKit has no RSA. Shello imports a key only if the public key it computes from the private key is the one libssh read.
- The private key is a Keychain item like a generated Ed25519 key's: the service `ch.shello.ssh-key`, `WhenUnlockedThisDeviceOnly`, never synchronizable (sync on opt-in is v1), readable only with the user's presence. The record's kind is `imported`, with the algorithm beside it; a Shello from before skips such records. The passphrase is not kept.
- Imported keys sign through the same SSH agent and `SSHKeyStore.sign`, under their signing policy. ECDSA P-384 signs with SHA-384; RSA signs with SHA-256 or SHA-512 as the sign request's flags say (RFC 8332), and refuses a request for SHA-1's `ssh-rsa`. libssh asks for SHA-512 when the server's `server-sig-algs` has it.

**Install on host** (README section 13) runs one command on a hidden channel of a tab's open connection, as `ssh-copy-id` does: `exec sh -c '…'`, which every login shell, fish and csh included, passes on to POSIX sh as it is. The script makes `~/.ssh` (700) and `authorized_keys` (600) if they are missing, adds the key's line unless a line that is not a comment has the key already, ends a file without a final line break first, and runs `restorecon` where SELinux is. The key's line reaches the file through `printf` with every byte that a shell or `printf` would read anything into written as an octal escape, so no part of the key's name is ever read as shell syntax (`ShelloCore/AuthorizedKeys.swift`).

**The iOS Simulator** reports a Secure Enclave (`SecureEnclave.isAvailable`) but refuses to make a key that needs the user's presence ("This call is not supported on iOS Simulator"). Its Keychain also gives out items that need the user's presence without asking. Shello therefore offers Ed25519 keys only in the simulator. Secure Enclave keys and the Keychain's access control are checked on a device (section 11).

**App lock and privacy.**

- LocalAuthentication handles app lock.
- The app-switcher snapshot is covered when `scenePhase` leaves `.active`.
- Logging uses `os.Logger` only. Dynamic strings are [redacted by default](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code). Secrets are never interpolated, and no value is logged `.public` without review.
- The security log (v1) is a table in the local database.

### 7.4 Terminal (README section 5)

**SwiftTerm**, [MIT](https://github.com/migueldeicaza/SwiftTerm).

- **Version:** start on the 2.0 API. v1.99.0 (2026-10-08) is the "preview before 2.0", and 2.0 changes the IO model ([migration guide](https://migueldeicaza.github.io/SwiftTerm/documentation/swiftterm/migratingfrom1to2/)). Pin v1.99.0 exactly and move to 2.0.0 on release, rather than building on 1.x and migrating later.
- **iOS view:** `TerminalView` is a `UIScrollView` implementing `UITextInput`, with marked text, dictation and hardware keys through `pressesBegan`. `inputView` and `inputAccessoryView` are settable, which is where the Shello keyboard plugs in.
- **What it already covers:**
  - 24-bit colour and the alternate screen.
  - SGR mouse reporting and bracketed paste.
  - Search API (`findNext`, `findPrevious`).
  - OSC 8 and implicit links.
  - OSC 52, through a delegate.
  - Sixel, iTerm2 and Kitty images (Later items, already supported).
  - The Kitty keyboard protocol.
- **What Shello builds on top:**
  - The search UI.
  - The selection menu. SwiftTerm still uses `UIMenuController`, which is deprecated, so Shello switches to `UIEditMenuInteraction`.
  - The OSC 52 policy: writes only per host, and the clipboard-read hook always declines.
  - The paste confirmation, the bell (haptic plus flash), pinch-to-zoom font size, and resize reporting.
- **Fuzzing:** SwiftTerm ships libFuzzer targets ported from Ghostty's corpus. Shello runs them in its own fuzz CI (section 11).

**Shell integration (v1).** Scripts for bash, zsh and fish in `ShellIntegration/`. They emit OSC 133 for prompt and command marks and OSC 7 for the working directory.

### 7.5 Shello keyboard, extra keys row and pads (README sections 6 and 7)

- **Keyboard:** a UIKit `UIInputView` subclass set as the terminal's `inputView`. SwiftUI has no API to replace the system keyboard.
- **Extra keys row:** a `UIScrollView` set as `inputAccessoryView`, shown above the system keyboard too. The key that switches between the Shello keyboard and the system keyboard stays at its end, outside the scrolling part: it is the only key that can bring the Shello keyboard back.
- **Keys and layouts:** keys are drawn with Core Animation layers. One gesture recognizer per keyboard handles tap, flick, long-press alternates, key repeat and the swipe key, which keeps per-key overhead and latency low. Layouts (QWERTY, QWERTZ, AZERTY, symbols, function, the Vim pad) are data, not code.
- **What keys send:** what SwiftTerm sends for the same key on a hardware keyboard: its `EscapeSequences`, its `sendKey…` and `pageUp`/`pageDown` for the keys that depend on the program's cursor key mode, and xterm's modifier parameters. The Shello keyboard writes to the terminal directly rather than through `UITextInput`, whose rules for the system keyboard, such as a period after two spaces, have no place in a terminal. Control and Alt armed on the extra keys row reach the system keyboard's next key through the terminal's `insertText`.
- **Colours:** the keyboard follows the terminal's theme rather than the app's appearance, so the Night theme's keyboard is dark in light mode too, as the system keyboard over the terminal is.
- **Haptics:** `UIImpactFeedbackGenerator`, prepared ahead of the touch. Input clicks via `UIInputViewAudioFeedback`.
- **Hardware keyboards:**
  - SwiftTerm's `pressesBegan` handles Ctrl and Option as Meta.
  - The Esc remap is a Shello setting.
  - App shortcuts (new tab, next tab, font size, Cmd-K) use SwiftUI `.commands` / `.keyboardShortcut`, which also fill the iPadOS menu bar. `UIKeyCommand.wantsPriorityOverSystemBehavior` handles shortcuts that compete with text input.
- **Accessibility:**
  - Every key has the `.keyboardKey` trait and a localised label, and is an accessibility element of its own whose activation presses it, so VoiceOver's typing modes work as with the system keyboard. A key's corner symbol and alternates are its actions, and a modifier's Lock and Unlock, since VoiceOver's and Switch Control's activations are too far apart for a double tap; holding a modifier on its own locks it too. Voice Control also knows a key by the label it shows, such as "123".
  - The elements outlive layer changes, rotation and text size changes, so VoiceOver keeps its place. After a layer change it moves to the key where the layer key was and says the new layer's name; after a keyboard switch it moves to the switch key.
  - The swipe key, which takes drags, uses `.allowsDirectInteraction`, and offers each arrow as an action too. A tap on one of its arrows sends that arrow, except with VoiceOver, whose touches the trait passes straight through. The function layer has arrow keys, for those who can neither drag nor aim at the swipe key's arrows, and for Voice Control. The whole keyboard container does not use the trait: a direct-interaction element hides the elements inside it from VoiceOver, which would leave no keys to type with.
  - Keys follow Bold Text, Increase Contrast (an outline around every key) and Dynamic Type, up to the size a letter key holds.
- **Custom keys and presets (v1):** stored in the database. A custom key references its snippet by identifier.

### 7.6 tmux (README section 8)

- **Hidden channels:** queries run on hidden channels, which are libssh exec channels on the tab's connection, or on the side connection for Mosh tabs.
- **Commands and parsing:** commands use explicit `-F` format strings with a field separator that cannot appear in tmux names. The parsers are fuzzed.
  - `ShelloTmux` lists sessions with fields separated by a tab, the name last, and `-u`. tmux before 3.7 lists a tab in a name as `\t`, and 3.7 refuses one; with `-u` it passes the format's tabs on, while without it a client whose locale is not UTF-8 turns them into `_`. The unit separator would not do: tmux 3.4 writes it as `\037` even with `-u`. Checked with tmux 3.2a, 3.4 and 3.7c.
  - The parsers of `tmux -V` and of the session list use the standard library only. `Fuzz/TmuxOutput` fuzzes them, and a seeded test runs them with every build.
- **Auto-attach (MVP):**
  - Before a connection's shell opens, a hidden channel runs `tmux -V`, within the host's connect timeout. Before the shell, not beside it: a server that allows one session per connection (`MaxSessions 1`) would refuse the second channel.
  - With tmux 1.8 or later, the tab types the startup command, then ` tmux -u new-session -A -s '<name>'`, both once the shell shows its prompt. The startup command runs in the login shell, outside tmux: what it sets reaches a tmux session that starts now, and nothing is typed into a program left running in a session that is reattached. The space before the command keeps it out of the shell's history where `HISTCONTROL=ignorespace` or `HIST_IGNORE_SPACE` is set; `-u` because Shello's terminal always takes UTF-8 and libssh sends no locale.
  - A tmux that is missing, too old or prints no version Shello reads gets a plain shell, and the terminal says why in a line of Shello's own. VoiceOver hears why with the announcement that the tab is connected, which would cut off an announcement of its own.
  - The check runs with the `PATH` sshd gives a command, as `ssh host tmux -V` does. A tmux that only the login shell's profile puts on the `PATH`, such as Homebrew's on a Mac or Nix's, counts as missing.
- **Version gate:** auto-attach needs tmux 1.8, which added `new-session -A`. The distributions with OpenSSH 8.8 or later ship tmux 3.2a or later, as Alpine 3.15 and Ubuntu 22.04 do, so the gate turns away little more than servers older than Shello supports. The test servers run 3.4 and 3.7c; 1.8 to 3.1 are not tested. The tmux browser (v1) sets its own minimum, between itself and plain attach.
- **Control mode (`tmux -CC`):** Later.

### 7.7 Mosh (README section 4, ADR 0004) — v1

- **Source:**
  - [Blink Shell's Mosh fork](https://github.com/blinksh/mosh) (GPL-3.0), which turns upstream Mosh into an iOS library with a C entry point (`mosh_main` in `moshiosbridge.h`) and removes curses and termios use on iOS.
  - Upstream's last release is 1.4.0 (2022). Master is active and now needs C++17.
  - Shello pins a fork commit, rebased onto upstream master, and builds it with its own `Vendor/` script. Blink's [mosh-apple](https://github.com/blinksh/mosh-apple) shows the build steps but has no licence file, so it is used as a reference, not as code.
- **Licence:** GPLv3-or-later with an OpenSSL exception. Upstream's [`COPYING.iOS`](https://raw.githubusercontent.com/mobile-shell/mosh/master/COPYING.iOS) commits the authors not to enforce the GPL/App Store conflict (ADR 0001).
- **Crypto:** Mosh's internal AES-128-OCB on Apple CommonCrypto AES, which is the default `--with-crypto-library` on Apple platforms. Mosh therefore adds no second crypto library.
- **Wire format:** Mosh's `.proto` files use `LITE_RUNTIME`, so Shello links protobuf-lite.
  - **Recommended:** current protobuf (v36.x, C++ runtime 7.x, BSD-3-Clause) with Abseil (Apache-2.0), C++17, built with the hardening above. Protobuf has [required Abseil since v22](https://github.com/protocolbuffers/protobuf/releases/tag/v22.0).
  - **Fallback:** protobuf 3.21.x, the last version without Abseil and what Blink ships, but no longer maintained. The exposure would be limited, because Mosh authenticates every datagram with AES-OCB before parsing it. The spike decides.
- **Output:** Mosh's output goes into SwiftTerm like SSH output, so it adds no new UI technology.
- **Fuzzing:** Mosh is fuzzed in [OSS-Fuzz](https://github.com/google/oss-fuzz/tree/master/projects/mosh).

### 7.8 SFTP, files and iOS integration (README section 10) — v1

| Need | Technology |
| --- | --- |
| Transfers | libssh SFTP with the aio API; resume from an offset; queue persisted in the database |
| Running in the background | `UIApplication.beginBackgroundTask` for a clean finish. For user-started transfers, [`BGContinuedProcessingTask`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) (iOS 26): it must be started by a user action, shows progress in a Live Activity, can use the network and is cancellable by the user. Not used for reconnects (README section 4). |
| Image and PDF preview | QuickLook (SwiftUI `.quickLookPreview`) |
| Text editor with highlighting | [STTextView](https://github.com/krzyzanowskim/STTextView) 2.4.1 (TextKit 2, UIKit target, GPL-3.0 or commercial, active) with STTextView-Plugin-TreeSitter (MIT), [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) (BSD-3-Clause) and tree-sitter grammars (MIT). Saving compares the remote size, mtime and content hash before overwriting. |
| Files app import/export | SwiftUI `.fileImporter` / `.fileExporter` |
| Drag and drop | SwiftUI `.draggable` / `.dropDestination` in lists; UIKit `UIDropInteraction` on the terminal view |
| Share sheet "Upload to host" | Share extension target using `ShelloSSH`, with the database and Keychain shared through an App Group and a Keychain access group. Its memory budget is checked when v1 starts. |
| File Provider (Later) | `NSFileProviderReplicatedExtension` on top of `ShelloCore` |

### 7.9 Remote desktop (README section 12) — v1

**RoyalVNCKit was archived on 2026-10-05** ([repo](https://github.com/royalapplications/royalvnc)). Its last release is 1.1.0 (2026-02-09).

- **What it offers:**
  - MIT licence.
  - Authentication: None, VNC password and Apple Remote Desktop.
  - Encodings: Tight, ZRLE, Zlib, Hextile and others.
  - An IOSurface-backed framebuffer with callbacks for updated regions.
- **Plan:** Shello maintains a fork, vendored as a local package or as a fork repository pinned by commit, and makes three changes:
  1. **Inject the transport.** VNC traffic then runs straight over a libssh `direct-tcpip` channel. Upstream dials its own `NWConnection` and keeps the transport protocol internal, which would force a loopback listener that other apps on the device can reach.
  2. **Drop the CryptoSwift fork,** which upstream pins by branch, so SwiftPM cannot pin it by version. Apple Remote Desktop authentication needs AES-128-ECB and Diffie-Hellman, which CommonCrypto and RoyalVNCKit's own BigNum cover.
  3. **Move to Swift 6 language mode.**
- **View:** written by Shello in UIKit.
  - The framebuffer's IOSurface is used directly as `CALayer` contents, so frames are not copied.
  - Zoom and pan come from a custom scroll container, and the overview map is a scaled layer.
  - Trackpad mode uses UIKit gesture recognizers. On iPad, pointer lock (`prefersPointerLocked`, full-screen scenes only) plus `GCMouse` gives relative mouse movement.
- **Fallback:** [LibVNCClient](https://github.com/LibVNC/libvncserver) (GPL-2.0-or-later), only if the fork proves unworkable, because it is another C parser of untrusted data.

### 7.10 Storage (README sections 3, 13 and 16)

**SQLite through [GRDB.swift](https://github.com/groue/GRDB.swift) 7.11.1** (MIT), using the system SQLite.

Why not SwiftData:

- With CloudKit, SwiftData [cannot enforce unique constraints and requires optional relationships](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices).
- It has no hook for README section 15's per-field "later change wins" merge or the "restored by a change on \<device\>" rule.
- It hides the transaction and migration boundaries that README section 16's no-data-loss rule depends on.

How the database works:

- **Location and protection:**
  - The database lives in its own directory inside the App Group container, so the share extension can open it.
  - That directory has a Data Protection class, which covers the `-wal` and `-shm` files too ([GRDB guidance](https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/databaseconnections)).
  - The target class is `NSFileProtectionComplete`. Spike item 6 confirms it against background transfer-queue writes while the device locks; the fallback is `CompleteUnlessOpen`.
- **WAL mode:** `observesSuspensionNotifications` avoids the `0xDEAD10CC` termination when the app is suspended while holding the shared database.
- **Migrations:** `DatabaseMigrator`, one migration per schema change. Each migration has a test that upgrades a fixture database from every earlier release.
- **Sync-ready schema from the MVP:**
  - UUID identifiers.
  - A modification timestamp per syncable field.
  - Tombstones for deletions, with an undo window.
  - This avoids a data migration when sync arrives in v1.
- **JSON export and import:** `Codable` with an explicit `schemaVersion`. Imports are validated before they touch the database. The format: `docs/spec/EXPORT.md`.
- **No secrets in the database,** so no SQLCipher. Data Protection plus the Keychain cover the threat model.

### 7.11 Sync and backup (README section 15) — v1

- **Sync engine:** [`CKSyncEngine`](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) (iOS 17) on the private database, in one custom zone.
  - It handles push, pull and retries.
  - Shello persists its state and applies its own per-field merge.
  - It needs the CloudKit and Remote notifications capabilities.
- **Sensitive fields** (address, username, notes, startup command) use [`CKRecord.encryptedValues`](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues). They cannot be queried or indexed, which `CKSyncEngine`'s zone-change fetches do not need.
- **Secrets** sync only through iCloud Keychain, opted into per item. [Synchronizable items cannot use `ThisDeviceOnly` classes](https://developer.apple.com/documentation/security/ksecattrsynchronizable). Whether biometric access control survives sync is spike item 5.
- **Generated keys** never sync (ADR 0003). Public keys sync as ordinary records.
- **Encrypted backup:**
  - The key is derived with Argon2id (OpenSSL `EVP_KDF-ARGON2`). Starting parameters are RFC 9106's second recommended set (64 MiB memory, 3 passes, 4 lanes), recorded in the file header so they can change.
  - Encryption is AES-256-GCM (CryptoKit `AES.GCM`), with the header as authenticated data.
  - The format is versioned. Generated keys are never included.

### 7.12 Purchases (README section 17) — v1

- **StoreKit 2.**
  - Products: two non-consumables, "14-day Trial" at price tier 0 ([Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)) and "Pro".
  - Entitlements come from `Transaction.currentEntitlements`, which StoreKit verifies on device (`VerificationResult`). The trial's end is derived from the verified purchase date of the trial transaction.
- **UI:** SwiftUI `ProductView` / `StoreView`, with the trial terms shown before it starts, as the guideline requires.
- **Testing:** a StoreKit configuration file in the project for local and UI tests.
- **No anti-piracy work.** Shello is GPLv3; anyone may build it, and the registered name is the protection (ADR 0001).

### 7.13 App shell, design system and assets

- **SwiftUI:**
  - Navigation: `NavigationSplitView` on iPad and `NavigationStack` on iPhone.
  - Sheets for host editing and connection prompts.
  - Multiple windows on iPad via `WindowGroup`.
  - iOS 26 system styling comes for free.
- **Restore (v1, README section 4):** each window's remembered tabs (`RememberedTabs`: the host of each tab, in order, and the selected tab) are in a JSON file of their own in the app's Application Support directory (`RememberedTabsStore`), not in the database, since open tabs are neither synced nor exported.
  - They are kept under the window's scene session (`UISceneSession.persistentIdentifier`) and written at each change. On the iOS 26.5 simulator, iOS kept the window's scene session when XCTest terminated Shello on an iPhone, and when the user closed Shello from the app switcher, on an iPhone and on an iPad with one window: the window finds its tabs again.
  - `@SceneStorage` is not used: SwiftUI saves it only as the window goes to the background, so a kill while Shello is in front, or a crash, loses what changed since; and it goes with the session when iOS discards one.
  - A session that iOS discards takes its tabs with it, as a window the user closes on iPad. iOS discarded every session when it installed a new build: the first window of the next launch, which iOS made anew, takes over the tabs of the discarded window that changed last.
  - The window's Live section offers them, and nothing connects until the user taps: the restored tabs then connect as after the background, the selected one at once.
- **External display (Later):** needs a UIKit scene for the external-display role.
- **Fonts:** Geist (interface) and JetBrains Mono (titles, keys, terminal) from the UI design (`docs/ui/ui_v1/README.md`), both under the SIL Open Font Licence 1.1.
  - They are bundled as separate font files, which is aggregation under GPLv3.
  - Their licence texts go into the acknowledgements.
- **Icons:** SF Symbols.
- **Colours:** the dark and light surface, text, accent and status tokens from the UI design, as asset-catalog colour sets with light and dark variants.

### 7.14 Accessibility and languages (README section 16) — v1 requirement, built in from the MVP

- **VoiceOver:**
  - SwiftUI accessibility modifiers on every control. UIKit `UIAccessibility` on the terminal, keyboard and VNC view.
  - New terminal output is announced with `UIAccessibility.post(notification: .announcement, …)`, throttled.
  - Custom actions, in VoiceOver's Actions rotor, read the line the cursor is on, copy it or the screen, and change the text size.
- **Dynamic Type, Reduce Motion, colour:**
  - Dynamic Type for every app screen. The terminal font size is separate.
  - A text size change is laid out at once (`DesignSystem.applyTextSizeChangesAtOnce`), not in the next layout pass, which waits while the main thread is busy. The accessibility audit's Dynamic Type check sets one size after another and reads the screen after each; on a slow CI runner it read sizes that had not been drawn yet, and reported text that scales as partially unsupported.
  - Reduce Motion stops the cursor blink.
  - Status is never shown by colour alone; the UI design already pairs the online dot with an offline ring.
- **Automated checks:** XCUITest runs [`performAccessibilityAudit`](https://developer.apple.com/documentation/xctest/xcuiapplication/performaccessibilityaudit(for:_:)) (iOS 17) on every main screen in CI.
- **Languages:** String Catalogs (`.xcstrings`) for English and German, including plurals and the key labels.

## 8. Dependency register

Shipped in the app:

| Dependency | Pin | Licence | Used for | Phase | Notes |
| --- | --- | --- | --- | --- | --- |
| libssh | 0.12.2 | LGPL-2.1-or-later, OpenSSL exception | SSH, SFTP, forwards, agent, post-quantum key exchange | MVP | Tarball and signature verified. OSS-Fuzz. |
| OpenSSL | 3.5.9 (3.5 LTS) | Apache-2.0 | libssh crypto, ML-KEM, Argon2id | MVP | libcrypto only. |
| zlib | system `libz` | zlib | libssh compression, Mosh, VNC | MVP | Part of iOS. |
| SwiftTerm | v1.99.0, then 2.0.0 | MIT | Terminal emulation and iOS view | MVP | Pinned exactly while 2.0 settles. |
| GRDB.swift | 7.11.1 | MIT | SQLite access, migrations, observation | MVP | |
| Geist, JetBrains Mono | Geist 1.8.1, JetBrains Mono 2.304 | OFL-1.1 | Fonts | MVP | Licence texts in the acknowledgements. Sources and checksums: `Packages/ShelloKit/Sources/ShelloFeatures/Resources/Fonts/README.md`. |
| Mosh (blinksh/mosh fork) | pinned commit | GPL-3.0-or-later, OpenSSL exception | Mosh client | v1 | Upstream 1.4.0 plus master. |
| protobuf (lite) | v36.x (fallback 3.21.x) | BSD-3-Clause | Mosh wire format | v1 | Spike decides the version. |
| Abseil | version required by the protobuf pin | Apache-2.0 | protobuf dependency | v1 | Only with protobuf ≥ v22. |
| RoyalVNCKit (Shello fork) | fork of the last upstream commit (2026-09-21) | MIT | VNC protocol | v1 | Upstream archived 2026-10-05. |
| STTextView + TreeSitter plugin | 2.4.1 | GPL-3.0 or commercial; plugin MIT | SFTP text editor | v1 | |
| SwiftTreeSitter | v0.10.0 by commit | BSD-3-Clause | tree-sitter bindings | v1 | A stray `0.25.0` tag outranks v0.10.0 in semver, so pin by commit. |
| tree-sitter + grammars | the version SwiftTreeSitter requires | MIT (check each grammar) | Syntax highlighting | v1 | |

Approved when needed, not added up front: [swift-collections](https://github.com/apple/swift-collections) 1.7.3 and [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) 1.1.7 (Apache-2.0).

Not bundled, documented for servers: [pam\_rssh](https://github.com/z4yx/pam_rssh) 1.2.1 (MIT) for key-based sudo. Upstream publishes .deb and .rpm packages; it is not in official Debian or Fedora repositories.

Development and CI only:

| Tool | Pin | Licence | Used for |
| --- | --- | --- | --- |
| swift-snapshot-testing | 1.19.6 | MIT | Snapshot tests for screens and keyboard layouts |
| swift-format | bundled with Xcode | Apache-2.0 | Formatting and lint (`swift format`) |
| LicensePlist | 3.28.3 | MIT | Acknowledgements in the app; fails CI on a missing licence |
| syft | 1.54.x | Apache-2.0 | SBOM from `Package.resolved`; Swift 6.4's `swift package generate-sbom` once on Xcode 27 |
| CodeQL | latest | GitHub terms | Swift and C/C++ code scanning |
| Toxiproxy | 2.12.0 | MIT | TCP latency, bandwidth and reset faults |
| tc netem (e.g. via Pumba) | — | — | UDP loss and latency for Mosh, which Toxiproxy cannot proxy |
| Docker images for OpenSSH | per Dockerfile | — | Integration matrix |

## 9. Considered and rejected

| Option | Why not |
| --- | --- |
| SwiftNIO SSH ([0.15.0](https://github.com/apple/swift-nio-ssh)) | No post-quantum key exchange, no RSA, no chacha20-poly1305, no keyboard-interactive, no SFTP. Remains ADR 0002's fallback if Secure Enclave keys cannot work with libssh. |
| Citadel | Same gaps, plus a third-party fork of SwiftNIO SSH. |
| libssh2 | No sntrup761; ML-KEM needs OpenSSL 3.5 (ADR 0002). |
| mbedTLS as libssh backend | libssh 0.12 does not support mbedTLS 4.x; mbedTLS 3.6 LTS ends March 2027. |
| SwiftData | See section 7.10. |
| SQLCipher | The database holds no secrets; Data Protection and the Keychain cover it. Its SwiftPM route also means forking GRDB. |
| Prebuilt OpenSSL packages (OpenSSL-Universal and others) | They ship committed or downloaded binaries. Shello builds every C library from verified source. |
| Runestone | Low maintenance; pins tree-sitter 0.20. |
| Neon | Moved to a personal account and depends on branches, not versions. |
| LibVNCClient | Kept only as the VNC fallback: a C parser of untrusted data. |
| Third-party architecture frameworks (e.g. TCA) | Not needed with Observation and Swift concurrency; a large dependency for a solo project. |
| Analytics, crash or attribution SDKs | Ruled out by README section 15 ("Data Not Collected"). |

## 10. Capabilities, entitlements and Info.plist

| Item | Phase | Notes |
| --- | --- | --- |
| Enhanced Security (and its `hardened-process` entitlements) | MVP | Section 5. |
| Data Protection (`com.apple.developer.default-data-protection` = complete) | MVP | Default for every file; the database directory is set explicitly (section 7.10). |
| Keychain Sharing (access group) | MVP | Shared with the share extension in v1. |
| App Groups | MVP | Database container; created in the MVP so v1 needs no file move. |
| In-App Purchase | v1 | |
| iCloud (CloudKit) and Push Notifications | v1 | `CKSyncEngine`. |
| Background Modes: remote notifications | v1 | For CloudKit change pushes only. No audio, location or VoIP modes (README section 4). |
| `BGTaskSchedulerPermittedIdentifiers` | v1 | `BGContinuedProcessingTask` for SFTP transfers. |
| `NSLocalNetworkUsageDescription`, `NSFaceIDUsageDescription` | MVP | Localised. |
| Multicast networking entitlement | Later | Only if Wake-on-LAN needs broadcast. |
| Privacy manifest (`PrivacyInfo.xcprivacy`) | MVP | No data collected. Declare the required-reason APIs Shello uses (for example `UserDefaults`, system uptime for keepalive timing). |
| Export compliance (`ITSAppUsesNonExemptEncryption`) | MVP | Shello implements standard encryption (SSH, Mosh) beyond what iOS provides. Answer App Store Connect's export questions before the first TestFlight build. |

## 11. Testing and quality

| Layer | Tooling | Runs |
| --- | --- | --- |
| Unit tests | Swift Testing, for every `ShelloKit` target | Every pull request |
| Snapshot tests | swift-snapshot-testing: keyboard layers and layouts on iPhone and iPad, light and dark, accessibility text sizes | Every pull request |
| UI tests | XCUITest, including `performAccessibilityAudit` and a StoreKit configuration | Every pull request |
| Integration: protocol | `ShelloSSH` and `ShelloTmux` built for Linux, run against Docker OpenSSH servers | Every pull request |
| Integration: app end to end | iOS Simulator app connecting to the CI Mac's own `sshd`, started unprivileged on a high port | Every pull request |
| Network faults | Toxiproxy for TCP; tc netem for Mosh's UDP | Nightly |
| Fuzzing | libFuzzer: SwiftTerm's targets plus Shello's parsers (OpenSSH config and known\_hosts import, SSH agent protocol, tmux output, private keys' text before libssh reads them, sudo-prompt detection, SOCKS5, JSON import, snippet variables). libssh and Mosh are covered by OSS-Fuzz. | 60-second smoke run per pull request, long runs nightly |
| Sanitizers | Address, Thread and Undefined Behavior Sanitizers in a dedicated configuration. Thread Sanitizer guards the libssh threading rule. | Nightly |
| Performance | XCTest metrics with signposts (section 6) | Simulator per pull request as a regression signal; physical devices before each TestFlight build |
| Device-only checks | Secure Enclave, arm64e and memory tagging, Local Network prompt, Wi-Fi to cellular switches, haptics | Before each TestFlight build |

**OpenSSH matrix.** The MVP floor is OpenSSH 8.8 on Linux. Versions as shipped by distributions in October 2026:

| Phase | Images |
| --- | --- |
| MVP | Alpine 3.15 (8.8), Ubuntu 22.04 (8.9), Debian 12 (9.2), Ubuntu 24.04 (9.6), RHEL 10 (9.9), Debian 13 (10.0), Alpine 3.24 (10.3), Alpine edge (10.6, the latest upstream) |
| v1 additions | RHEL 9 (8.7), Dropbear, several tmux versions, mosh-server |

The post-quantum tests (spike item 4) run against 10.x, where `mlkem768x25519-sha256` is OpenSSH's default, against Ubuntu 24.04's 9.6, which knows only `sntrup761x25519-sha512@openssh.com`, and against 10.x with post-quantum key exchange off (`TestServers/README.md`). Alpine 3.15's 8.8, the floor, and 10.x limited to the NIST curves and Diffie-Hellman groups, as in FIPS mode, run as Docker test servers too, the floor with sign-in by password, key and keyboard-interactive. RHEL 9.0–9.7 ships OpenSSH 8.7, below the MVP floor, which is why it waits for v1.

**Why the core builds on Linux.** GitHub's macOS runners have no Docker. Building `ShelloSSH`, `ShelloTmux` and `ShelloModel` for Linux, with a POSIX socket transport used only in tests, lets every pull request run against the whole OpenSSH matrix. The Network.framework bridge is covered by the end-to-end tests on macOS and by device tests. If the Linux build costs more than it saves, the fallback is running the matrix locally with Docker before each merge.

**Fuzzing toolchain.** Xcode's toolchain [rejects `-sanitize=fuzzer`](https://developer.apple.com/forums/thread/818248). Fuzz targets therefore build with the swift.org toolchain on Linux runners, the same toolchain SwiftTerm's own fuzz targets use.

**Lint and format.** `swift format` with a checked-in configuration, run in CI. Compiler warnings are errors in CI.

## 12. CI, release and supply chain

**GitHub Actions** (the repository is public, so macOS minutes are free):

- **macOS checks:** the `macos-26` runner with Xcode 26.6 builds, runs unit, snapshot and UI tests, lints, and runs CodeQL for Swift and C/C++.
  - CodeQL [supports Swift up to 6.3](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/), so its job stays on Xcode 26.x until Swift 6.4 is supported.
  - A second job on the `xcode-27` runner image builds with Xcode 27.
- **Linux checks:** Linux runners run the OpenSSH integration matrix and the fuzz smoke tests.
- **Workflow hardening,** in the same style as the existing workflows:
  - `permissions: {}` by default.
  - Actions pinned to commit SHAs.
  - `persist-credentials: false`.
  - No signing secrets in GitHub.

**Xcode Cloud** archives, signs and uploads to TestFlight and the App Store. It is included with the Developer Program ([25 compute hours a month](https://developer.apple.com/xcode-cloud/)). Signing certificates and App Store Connect keys stay with Apple, never in a public repository's secrets.

**Supply chain:**

- **Swift packages:** exact versions (or commits where tags are unreliable), with `Package.resolved` committed.
- **Dependabot:** version and security updates for Swift and GitHub Actions. It [supports SwiftPM inside Xcode projects](https://github.blog/changelog/2026-03-31-dependabot-now-supports-xcode-projects-using-swiftpm-with-xcodeproj-manifests).
- **C and C++ sources:**
  - Downloaded only from official URLs.
  - Checked against SHA-256 checksums committed in `Vendor/`, and against the release signatures OpenSSL and libssh publish.
  - Patches are kept as files in `Vendor/`.
  - The XCFrameworks are built by script in CI and cached by checksum. No prebuilt binary enters the app.
- **Each release:**
  - An SBOM: syft over `Package.resolved`, plus the C/C++ libraries listed by hand.
  - Acknowledgements generated by LicensePlist in offline mode, with manual entries for the vendored C/C++ libraries and the fonts.
- **Repository:**
  - Branch protection with required checks.
  - Secret scanning with push protection.
  - Signed release tags.

## 13. Kickoff checklist

1. Update macOS to 26.6 or later and install Xcode 27, or start on Xcode 26.6 and switch before the first App Store upload.
2. Join the Apple Developer Program. Register the bundle identifier, the App Group and the Keychain access group.
3. Create the repository skeleton (section 4), the Xcode project with the settings in section 5, and `ShelloKit` with empty targets and their dependency rules.
4. Write `Vendor/` build scripts for OpenSSL 3.5.9 and libssh 0.12.2: verified source, arm64, arm64e and simulator slices, hardened flags, XCFramework output (spike item 1).
5. Add `TestServers/` with the MVP OpenSSH images. The first integration test connects, verifies the host key and checks that `mlkem768x25519-sha256` is negotiated against OpenSSH 10.x (spike item 4).
6. Build the socketpair bridge and the connection actor; test a Wi-Fi to cellular switch on a device (spike item 2).
7. Generate a Secure Enclave key and authenticate through Shello's SSH agent (spike item 3).
8. Run spike items 5 and 6 (Keychain sync with Face ID; the database's Data Protection class).
9. Add the CI workflows, Dependabot, CodeQL, secret scanning and branch protection.

Spike additions this document proposes for README section 18:

7. OpenSSL, libssh and (for v1) Mosh build and run as arm64e with Enhanced Security and memory tagging, with OpenSSL's assembly enabled.
8. SwiftTerm 2.x against the budgets: a 10 MB log with responsive input, 120 Hz scrolling (CoreText versus Metal renderer), and memory for 10 tabs of 10,000 lines.
9. `ShelloSSH` builds and runs on Linux for the CI integration matrix.

## 14. Risks specific to the stack

- **VNC has no maintained upstream.** Shello carries a fork from v1 on; the effort is in the plan above (section 7.9).
- **Mosh build complexity.** C++17, protobuf and Abseil for iOS and arm64e are the heaviest build in the project. Mosh is v1, so it does not block the MVP.
- **SwiftTerm 2.0 is new.** Starting on its preview avoids a later migration but exposes Shello to API changes until 2.0.0.
- **OpenSSL on iOS is community-supported upstream.** The Shello build scripts and device tests carry that risk.
- **Toolchain lag.** CodeQL does not support Swift 6.4 yet, and Xcode cannot build Swift fuzz targets.
- **Scrollback memory** may exceed the 200 MB budget at the default settings (section 6).

## 15. Conflicts with the README and ADRs

- **README section 2 and section 18 name RoyalVNCKit as the VNC library.** It was archived on 2026-10-05; this document keeps it as a Shello fork (section 7.9). The README should say so.
- **README section 2 and ADR 0002 name mbedTLS as OpenSSL's fallback.** libssh 0.12 does not support mbedTLS 4.x, and mbedTLS 3.6 LTS ends in March 2027, so the fallback is no longer realistic. OpenSSL 3.5 LTS is the plan; ADR 0002's consequences should drop mbedTLS.
- **README section 2 leaves storage open ("SwiftData or SQLite").** This document chooses SQLite through GRDB (section 7.10). The choice is hard to reverse once sync ships, so it deserves an ADR (0006).
- **README section 18, spike item 1, names "OpenSSL 3.x".** This document narrows it to the 3.5 LTS line, the first with native ML-KEM.
