# Test servers

Disposable OpenSSH servers for Shello's integration and UI tests, so that nobody's own server is needed (docs/spec/STACK.md section 11). They run on this Mac's loopback only, on `localhost`:

| Port | Server | Key exchange Shello negotiates with it | tmux |
| --- | --- | --- | --- |
| 2222 | OpenSSH 10.3 (Alpine 3.24) | `mlkem768x25519-sha256` | 3.7c |
| 2223 | OpenSSH 9.6 (Ubuntu 24.04) | `sntrup761x25519-sha512@openssh.com` | 3.4 |
| 2224 | OpenSSH 10.3 with post-quantum key exchange off | `curve25519-sha256` | 3.7c |
| 2225 | OpenSSH 8.8 (Alpine 3.15), the oldest OpenSSH Shello supports (README section 4) | `curve25519-sha256` | none |
| 2226 | OpenSSH 10.3 with the NIST curves and Diffie-Hellman groups only, as a server in FIPS mode | `ecdh-sha2-nistp256` | 3.7c |

Everything here is a test fixture and public: the users, the password, the one-time code's secret and every key in `keys/`. Never use them anywhere else.

## Start them

With Docker Desktop running:

```sh
TestServers/ssh-server.sh
```

The script builds the images, starts the five servers and waits until each greets:

```
Test server on 127.0.0.1:2222, host key a: SSH-2.0-OpenSSH_10.3
Test server on 127.0.0.1:2223, host key a: SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
Test server on 127.0.0.1:2224, host key a, post-quantum key exchange off: SSH-2.0-OpenSSH_10.3
Test server on 127.0.0.1:2225, host key a: SSH-2.0-OpenSSH_8.8
Test server on 127.0.0.1:2226, host key a, NIST curves and Diffie-Hellman groups only: SSH-2.0-OpenSSH_10.3
```

| Command | What it does |
| --- | --- |
| `TestServers/ssh-server.sh` | Builds the images and starts the servers with host key a, replacing those that run already |
| `TestServers/ssh-server.sh --host-key b` | The same with host key b: to a client that trusted key a, each server's host key changed |
| `TestServers/ssh-server.sh status` | Says which servers run, and with which host key |
| `TestServers/ssh-server.sh stop` | Stops and removes the containers |

Each image is pinned by the digest of its multi-platform image, and takes its packages from a branch that only takes fixes, or no longer changes:

- OpenSSH 10: Alpine 3.24 with Alpine's `openssh-server` package (OpenSSH 10.3). Port 2224 runs the same image with `KexAlgorithms` limited to OpenSSH's classical defaults, port 2226 with those without curve25519 (`entrypoint.sh`, `KEX=classical` and `KEX=nist`).
- OpenSSH 9: Ubuntu 24.04 with Ubuntu's `openssh-server` package (OpenSSH 9.6).
- OpenSSH 8.8: Alpine 3.15, past its end of support, with Alpine's `openssh-server` package (OpenSSH 8.8p1). OpenSSH 8.8 has `sntrup761x25519-sha512@openssh.com` but offers it only when configured to, which 9.0 changed, so Shello negotiates `curve25519-sha256` with it.

tmux, for auto-attach (README section 8), is pinned in the images that have it: Alpine 3.24's `tmux~3.7c`, which takes the branch's rebuilds of 3.7c and nothing newer, and Ubuntu 24.04's `tmux=3.4-1build1`, the version it released with, which stays in its archive. The OpenSSH 8.8 server has no tmux on purpose: it is the server without tmux, where auto-attach falls back to a plain shell.

OpenSSH 9.8 and later refuse an address for a while once its connections fail to sign in, or close before they try (`PerSourcePenalties`). Every test connects from the same address, many of them failing on purpose, so the OpenSSH 10 servers turn that off (`PER_SOURCE_PENALTIES=off`). OpenSSH 9.6 and 8.8 have no such penalties.

## Key exchange names

OpenSSH before 9.9 knows `sntrup761x25519-sha512` only as `sntrup761x25519-sha512@openssh.com`, the vendor name it had before IANA assigned it one; 9.0 made it the default. OpenSSH 9.9 added the IANA name and `mlkem768x25519-sha256`, and 10.0 made `mlkem768x25519-sha256` the default ([release notes](https://www.openssh.org/releasenotes.html)). libssh 0.12.2 knows both names of sntrup and reports the one it negotiated, so Shello's algorithm policy (`Packages/ShelloKit/Sources/ShelloSSH/Resources/AlgorithmPolicy.json`) offers both: offered only the standard name, the OpenSSH 9.6 server falls back to `curve25519-sha256`. Debian 12's OpenSSH 9.2 would not show this, because Debian added the standard name to it.

## Sign in

| | |
| --- | --- |
| Server | `localhost`, port 2222, 2223, 2224, 2225 or 2226 |
| User | `shello`; on the Alpine servers (2222, 2224, 2225 and 2226) also `shello-otp` and `shello-2fa` |
| Password | `shello-test-password`, for every user |
| SSH key | `keys/client_ed25519` (Ed25519), for `shello` and `shello-2fa`; `keys/client_ed25519_encrypted` is the same key with the passphrase `shello-test-passphrase` |
| One-time code | TOTP (RFC 6238, six digits every 30 seconds) of the secret `SHELLOTESTSECRET`, for `shello-otp` and `shello-2fa`: `oathtool --totp -b SHELLOTESTSECRET` prints the current one |
| Host key a | `SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY` (ED25519) |
| Host key b | `SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI` (ED25519) |

The Alpine servers ask keyboard-interactive questions through PAM (`openssh/pam-sshd`), one question a round:

| User | Signs in with |
| --- | --- |
| `shello` | Its password or its key; keyboard-interactive asks `Password:`, the answer hidden |
| `shello-otp` | Keyboard-interactive: `Password:`, then `Verification code:`, the code shown as it is typed. Its password alone is refused. |
| `shello-2fa` | Its key, then keyboard-interactive: `Verification code:` (`openssh/sshd_config.two-factor`), as a server with two-factor sign-in |

The shell's first line, the message of the day, is `Shello test server`, and on ports 2222, 2224, 2225 and 2226 the prompt is `shello-test:~$`. The UI tests look for both.

From the Mac's terminal: `ssh -p 2222 shello@localhost`. Git does not keep a key's file mode, so make a copy readable only by you before `ssh -i` takes it.

In Shello: add a host with the address `localhost`, port 2222, user `shello` and the method Password, with the password above. Connect asks to trust host key a; its fingerprint is in the table. The terminal's Connection button then shows the key exchange, post-quantum or classical; ports 2223 and 2224 show the others. To see a changed host key blocked, restart the servers with `--host-key b` and connect again; the block sheet then replaces the trusted key. With the method Keyboard-Interactive and the user `shello-otp`, Shello asks the password, then the one-time code. With Attach tmux session on, the tab attaches the tmux session `main`, or starts it, and comes back to it after a reconnect; on port 2225, which has no tmux, the terminal says so and the tab runs a plain shell.

## Without Docker

`TestServers/local-sshd.sh` runs this Mac's own `/usr/sbin/sshd` as you, unprivileged, with host key a: on port 2222 with OpenSSH's defaults, on port 2224 with post-quantum key exchange off, and on port 2226 with the NIST curves and Diffie-Hellman groups only. It lets only you in, with `keys/client_ed25519`: an unprivileged sshd cannot check passwords, nor ask keyboard-interactive questions. There is no OpenSSH 9 or 8.8 without Docker. `TestServers/local-sshd.sh stop` stops all three. CI runs it, because GitHub's macOS runners have no Docker.

tmux: the server on port 2222 puts this Mac's tmux, if it has one (`brew install tmux`), on the `PATH` a command gets, which sshd's default `/usr/bin:/bin:/usr/sbin:/sbin` leaves out, as a Linux server's `/usr/bin` has it. Ports 2224 and 2226 leave it out, as servers without tmux, and give the shell an empty home directory of the servers' own: macOS's bash reads `~/.bashrc` even for a command that sshd runs, and on GitHub's runner that file puts Homebrew on the `PATH`. The tmux they start keeps its socket in the servers' own directory (`TMUX_TMPDIR`), apart from your own tmux sessions, and `stop` ends it. Without tmux on the Mac, the tmux tests skip. GitHub's macOS runner image has no tmux either, so CI installs it with Homebrew first.

The tests need to know the user then. Pass it on through xcodebuild, which hands `TEST_RUNNER_`-prefixed variables to the tests without the prefix:

```sh
TestServers/local-sshd.sh
TEST_RUNNER_SHELLO_TEST_SERVER_USER=$(id -un) xcodebuild test -project Shello.xcodeproj -scheme Shello \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -skipPackagePluginValidation
```

With `SHELLO_TEST_SERVER_USER` set, the tests that sign in with a password or keyboard-interactive skip.

## The tests that use them

- `ShelloSSHTests` (`ConnectionTests`): the socketpair bridge, signing in with a password and an imported key, commands, a shell, and two connections at once, on port 2222.
- `ShelloSSHTests` (`KeyExchangeTests`): the key exchange libssh negotiates with each server, the classical ones without curve25519 each on its own, the ciphers and MACs, and the server's banner.
- `ShelloSSHTests` (`KeyboardInteractiveTests`, `AgentAuthenticationTests`): keyboard-interactive sign-in, on ports 2222 and 2225, and signing in through an SSH agent, with a stand-in agent.
- `ShelloCoreTests` (`HostConnectorTests`, `SignInTests`): the first connection's trust question, a trusted key, a changed one and its replacement; signing in with the SSH key through Shello's SSH agent, keyboard-interactive with the one-time codes, and two-factor sign-in, on ports 2222 and 2225.
- `ShelloCoreTests` (`TmuxIntegrationTests`): tmux auto-attach, which attaches the same tmux session, with what ran in it, after a dropped connection, on port 2222; the plain shell of a server without tmux, on port 2225 in Docker or 2224 with this Mac's sshd; and the tmux parsers on what tmux 3.7c and 3.4 print, on ports 2222 and 2223. Each test leaves no tmux session behind.
- `ShelloFeaturesTests` (`SignInPromptTests`): the terminal's sign-in sheet, on port 2222.
- `ShelloUITests/ConnectionTests`: the trust sheet, the changed host key sheet and its replacement, sign-in with a password, the SSH key and keyboard-interactive to the shell, and the Connection sheet, post-quantum on port 2222 and classical on port 2224.

They check that a server greets on its port, and skip with a message that points here when none does. Each needs a fresh connection, and the server's default `MaxStartups` would drop some of many at once, so the test servers raise it.

## Files

| File | What it is |
| --- | --- |
| `ssh-server.sh` | Starts, stops and checks the Docker servers |
| `openssh/Dockerfile` | The OpenSSH 10 image; build context is `TestServers/` |
| `openssh9/Dockerfile` | The OpenSSH 9 image, with `openssh/sshd_config` and `openssh/entrypoint.sh` |
| `openssh8/Dockerfile` | The OpenSSH 8.8 image, with the OpenSSH 10 image's files |
| `openssh/sshd_config` | sshd's settings |
| `openssh/sshd_config.two-factor` | The settings the Alpine images add for `shello-2fa`: its key, then keyboard-interactive |
| `openssh/pam-sshd` | PAM on the Alpine images: the password, the one-time code, or both, as each user signs in |
| `openssh/google_authenticator` | The one-time code's secret, for `pam_google_authenticator` |
| `openssh/entrypoint.sh` | Starts sshd with host key a or b, as `HOST_KEY` says, the key exchanges `KEX` names, keyboard-interactive through PAM as `KEYBOARD_INTERACTIVE` says, and without per-source penalties as `PER_SOURCE_PENALTIES` says |
| `local-sshd.sh` | This Mac's own sshd as the test servers on ports 2222, 2224 and 2226 |
| `keys/` | The host keys a and b, and the client key, made with `ssh-keygen -t ed25519` for these tests only |

To move to a newer image, take the digest that `docker buildx imagetools inspect alpine:3.24` (or `ubuntu:24.04`, or `alpine:3.15`) prints for the image index and put it in the Dockerfile's `FROM` line.
