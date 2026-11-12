# Fuzz targets

libFuzzer targets for the parsers that read untrusted input in Shello's own code (docs/spec/STACK.md sections 2 and 11). libssh and Mosh are fuzzed in OSS-Fuzz, SwiftTerm by its own targets.

Xcode's toolchain rejects `-sanitize=fuzzer`, so the targets build with the swift.org toolchain on Linux. `run.sh` does that in Docker, with the `swift:6.3` image pinned by digest, the Swift of Xcode 26.6. Each target compiles the parser's source files from `Packages/ShelloKit` as they ship, together with the target, into one module: the parsers use the standard library only, so that they build anywhere.

## Run them

With Docker Desktop running:

```sh
Fuzz/run.sh        # each target for 60 seconds, as the smoke run of STACK section 11
Fuzz/run.sh 3600   # each target for an hour
```

The script prints the toolchain's version and libFuzzer's statistics, and fails if a target finds an input that traps, after printing that input in hex. The repository is mounted read-only: the build, the corpus and any crashing input stay in the container, which is removed afterwards.

## Targets

| Target | Code | What it checks |
| --- | --- | --- |
| `SSHAgentProtocol/FuzzTarget.swift` | `ShelloSecurity/SSHAgent/SSHAgentProtocol.swift`: the SSH agent protocol's requests, replies and framing (draft-ietf-sshm-ssh-agent) | Each input is read as one message, and as bytes arriving on the agent's socket in pieces of 1 to 16 bytes. Nothing traps, every request read gets a reply, and the framing accounts for every byte. |
| `TmuxOutput/FuzzTarget.swift` | `ShelloTmux/TmuxVersion.swift` and `ShelloTmux/TmuxSession.swift`: what `tmux -V` prints, and the sessions `tmux list-sessions -F` lists in Shello's format (STACK section 7.6) | Each input is read as both. Nothing traps; a version read has a printable ASCII name of at most 32 bytes that reads back as the same version, and each session read has an identifier, a name and numbers that are not negative, no more of them than lines. |
| `KeyText/FuzzTarget.swift` | `ShelloSSH/KeyImport/KeyText.swift` and `ShelloSSH/KeyImport/PKCS8.swift`: what a pasted or picked private key's text says before libssh reads it, and the private key in the PKCS #8 that libssh hands over (STACK section 7.3) | Each input is read as a key's text, with its PEM armor and OpenSSH header, as base64 and as DER. Nothing traps, whatever is found lies within the input, and base64 decodes to no more bytes than it had characters. The key fixtures of `Packages/ShelloKit/Tests/KeyFixtures` are the seeds. |
| `SOCKS5/FuzzTarget.swift` | `ShelloSSH/Forwards/SOCKS5.swift`: the server side of the SOCKS5 handshake that dynamic forwards serve, the greeting and the request (RFC 1928, README section 4) | Each input is read as what a client sends, all at once and in pieces of 1 to 16 bytes. Nothing traps, both readings end the same way and send the same bytes, what is sent is a method selection, a reply or both, and a destination is what the bytes said: a domain name of printable ASCII, the request's port, and every byte after the request kept for the destination. |

| `OpenSSHConfig/FuzzTarget.swift` | `ShelloSSH/OpenSSHFiles/OpenSSHConfig.swift`: the OpenSSH config file that hosts are imported from, as ssh_config(5) reads it, and the values of `Port`, `ProxyJump` and the forwards (README section 3) | Each input is read as a config file. Nothing traps; every line number is one of the file's, and no line is both a directive and a skipped line; directives keep the file's order and have values; and what the aliases and pattern blocks resolve to reads as OpenSSH's values: ports from 1 to 65535, hops with a host, and forwards with a destination exactly when they are not dynamic. |
| `KnownHosts/FuzzTarget.swift` | `ShelloSSH/OpenSSHFiles/KnownHosts.swift`: the known_hosts file that trusted host keys are imported from (README section 3) | Each input is read as a known_hosts file. Nothing traps; every line number is one of the file's; each entry has names, a key type Shello trusts and a key of that type in SSH's wire format, written on its line; plain names are lowercase with a port from 1 to 65535, and hashed names have a salt and hash as long as SHA-1's, matched only when the HMAC, a stand-in here, gives the hash. |

`SSHAgentProtocolTests.randomBytesNeverTrap` in ShelloSecurityTests, `TmuxOutputRobustnessTests` in ShelloTmuxTests, and `KeyTextTests.randomTextNeverTraps`, `SOCKS5Tests.randomBytesNeverTrap`, `OpenSSHConfigTests.randomTextNeverTraps` and `KnownHostsTests.randomTextNeverTraps` in ShelloSSHTests run short, seeded versions of the same checks with every `xcodebuild test`.

## Results

| Date | Target | Toolchain | Runs | Result |
| --- | --- | --- | --- | --- |
| 2026-10-23 | `SSHAgentProtocol` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 841,768 in 61 seconds, 170 edges covered | No crash |
| 2026-10-23 | `TmuxOutput` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 381,174 in 61 seconds, 281 edges covered | No crash |
| 2026-10-23 | `KeyText` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 103,875 in 61 seconds, 311 edges covered | No crash |
| 2026-11-11 | `SOCKS5` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 3,837,622 in 61 seconds, 277 edges covered | No crash |
| 2026-11-12 | `OpenSSHConfig` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 386,717 in 61 seconds, 1,146 edges covered | No crash |
| 2026-11-12 | `KnownHosts` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 763,494 in 61 seconds, 556 edges covered | No crash |
