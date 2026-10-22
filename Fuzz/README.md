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

`SSHAgentProtocolTests.randomBytesNeverTrap` in ShelloSecurityTests runs a short, seeded version of the same check with every `xcodebuild test`.

## Results

| Date | Target | Toolchain | Runs | Result |
| --- | --- | --- | --- | --- |
| 2026-10-23 | `SSHAgentProtocol` | Swift 6.3.3, Ubuntu 24.04, arm64, in Docker on Apple silicon | 841,768 in 61 seconds, 170 edges covered | No crash |
