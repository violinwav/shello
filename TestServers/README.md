# Test servers

Disposable OpenSSH servers for Shello's integration and UI tests, so that nobody's own server is needed (docs/spec/STACK.md section 11). They run on this Mac's loopback only, on `localhost`:

| Port | Server | Key exchange Shello negotiates with it |
| --- | --- | --- |
| 2222 | OpenSSH 10.3 (Alpine 3.24) | `mlkem768x25519-sha256` |
| 2223 | OpenSSH 9.6 (Ubuntu 24.04) | `sntrup761x25519-sha512@openssh.com` |
| 2224 | OpenSSH 10.3 with post-quantum key exchange off | `curve25519-sha256` |

Everything here is a test fixture and public: the user, the password and every key in `keys/`. Never use them anywhere else.

## Start them

With Docker Desktop running:

```sh
TestServers/ssh-server.sh
```

The script builds the images, starts the three servers and waits until each greets:

```
Test server on 127.0.0.1:2222, host key a: SSH-2.0-OpenSSH_10.3
Test server on 127.0.0.1:2223, host key a: SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
Test server on 127.0.0.1:2224, host key a, post-quantum key exchange off: SSH-2.0-OpenSSH_10.3
```

| Command | What it does |
| --- | --- |
| `TestServers/ssh-server.sh` | Builds the images and starts the servers with host key a, replacing those that run already |
| `TestServers/ssh-server.sh --host-key b` | The same with host key b: to a client that trusted key a, each server's host key changed |
| `TestServers/ssh-server.sh status` | Says which servers run, and with which host key |
| `TestServers/ssh-server.sh stop` | Stops and removes the containers |

Each image is pinned by the digest of its multi-platform image, and takes its packages from a branch that only takes fixes:

- OpenSSH 10: Alpine 3.24 with Alpine's `openssh-server` package (OpenSSH 10.3). The server on port 2224 is the same image with `KexAlgorithms` limited to OpenSSH's classical defaults (`entrypoint.sh`, `POST_QUANTUM_KEX=off`).
- OpenSSH 9: Ubuntu 24.04 with Ubuntu's `openssh-server` package (OpenSSH 9.6).

## Key exchange names

OpenSSH before 9.9 knows `sntrup761x25519-sha512` only as `sntrup761x25519-sha512@openssh.com`, the vendor name it had before IANA assigned it one; 9.0 made it the default. OpenSSH 9.9 added the IANA name and `mlkem768x25519-sha256`, and 10.0 made `mlkem768x25519-sha256` the default ([release notes](https://www.openssh.org/releasenotes.html)). libssh 0.12.2 knows both names of sntrup and reports the one it negotiated, so Shello's algorithm policy (`Packages/ShelloKit/Sources/ShelloSSH/Resources/AlgorithmPolicy.json`) offers both: offered only the standard name, the OpenSSH 9.6 server falls back to `curve25519-sha256`. Debian 12's OpenSSH 9.2 would not show this, because Debian added the standard name to it.

## Sign in

| | |
| --- | --- |
| Server | `localhost`, port 2222, 2223 or 2224 |
| User | `shello` |
| Password | `shello-test-password` |
| SSH key | `keys/client_ed25519` (Ed25519); `keys/client_ed25519_encrypted` is the same key with the passphrase `shello-test-passphrase` |
| Host key a | `SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY` (ED25519) |
| Host key b | `SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI` (ED25519) |

The shell's first line, the message of the day, is `Shello test server`, and on ports 2222 and 2224 the prompt is `shello-test:~$`. The UI tests look for both.

From the Mac's terminal: `ssh -p 2222 shello@localhost`. Git does not keep a key's file mode, so make a copy readable only by you before `ssh -i` takes it.

In Shello: add a host with the address `localhost`, port 2222, user `shello` and the method Password, with the password above. Connect asks to trust host key a; its fingerprint is in the table. The terminal's Connection button then shows the key exchange, post-quantum or classical; ports 2223 and 2224 show the others. To see a changed host key blocked, restart the servers with `--host-key b` and connect again.

## Without Docker

`TestServers/local-sshd.sh` runs this Mac's own `/usr/sbin/sshd` as you, unprivileged, with host key a: on port 2222 with OpenSSH's defaults, and on port 2224 with post-quantum key exchange off. It lets only you in, with `keys/client_ed25519`: an unprivileged sshd cannot check passwords. There is no OpenSSH 9 without Docker. `TestServers/local-sshd.sh stop` stops both. CI runs it, because GitHub's macOS runners have no Docker.

The tests need to know the user then. Pass it on through xcodebuild, which hands `TEST_RUNNER_`-prefixed variables to the tests without the prefix:

```sh
TestServers/local-sshd.sh
TEST_RUNNER_SHELLO_TEST_SERVER_USER=$(id -un) xcodebuild test -project Shello.xcodeproj -scheme Shello \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -skipPackagePluginValidation
```

With `SHELLO_TEST_SERVER_USER` set, the tests that sign in with a password skip.

## The tests that use them

- `ShelloSSHTests` (`ConnectionTests`): the socketpair bridge, both ways to sign in, commands, a shell, and two connections at once, on port 2222.
- `ShelloSSHTests` (`KeyExchangeTests`): the key exchange libssh negotiates with each server, and the server's banner.
- `ShelloCoreTests` (`HostConnectorTests`): the first connection's trust question, a trusted key, and a changed one.
- `ShelloUITests/ConnectionTests`: the trust sheet, the changed host key sheet, a password sign-in to the shell, and the Connection sheet, post-quantum on port 2222 and classical on port 2224.

They check that a server greets on its port, and skip with a message that points here when none does. Each needs a fresh connection, and the server's default `MaxStartups` would drop some of many at once, so the test servers raise it.

## Files

| File | What it is |
| --- | --- |
| `ssh-server.sh` | Starts, stops and checks the Docker servers |
| `openssh/Dockerfile` | The OpenSSH 10 image; build context is `TestServers/` |
| `openssh9/Dockerfile` | The OpenSSH 9 image, with `openssh/sshd_config` and `openssh/entrypoint.sh` |
| `openssh/sshd_config` | sshd's settings |
| `openssh/entrypoint.sh` | Starts sshd with host key a or b, as `HOST_KEY` says, and post-quantum key exchange on or off, as `POST_QUANTUM_KEX` says |
| `local-sshd.sh` | This Mac's own sshd as the test servers on ports 2222 and 2224 |
| `keys/` | The host keys a and b, and the client key, made with `ssh-keygen -t ed25519` for these tests only |

To move to a newer image, take the digest that `docker buildx imagetools inspect alpine:3.24` (or `ubuntu:24.04`) prints for the image index and put it in the Dockerfile's `FROM` line.
