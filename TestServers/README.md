# Test servers

A disposable OpenSSH 10 server for Shello's integration and UI tests, so that nobody's own server is needed (docs/spec/STACK.md section 11). It runs on this Mac's loopback only, on `localhost` port 2222.

Everything here is a test fixture and public: the user, the password and every key in `keys/`. Never use them anywhere else.

## Start it

With Docker Desktop running:

```sh
TestServers/ssh-server.sh
```

The script builds the image, starts the server and waits until it greets:

```
Test server on 127.0.0.1:2222, host key a: SSH-2.0-OpenSSH_10.3
```

| Command | What it does |
| --- | --- |
| `TestServers/ssh-server.sh` | Builds the image and starts the server with host key a, replacing one that runs already |
| `TestServers/ssh-server.sh --host-key b` | The same with host key b: to a client that trusted key a, the server's host key changed |
| `TestServers/ssh-server.sh status` | Says whether it runs, and with which host key |
| `TestServers/ssh-server.sh stop` | Stops and removes the container |

The image is Alpine 3.24, pinned by the digest of its multi-platform image, with Alpine's `openssh-server` package (OpenSSH 10.3). Its packages come from the 3.24 branch, which only takes fixes.

## Sign in

| | |
| --- | --- |
| Server | `localhost`, port 2222 |
| User | `shello` |
| Password | `shello-test-password` |
| SSH key | `keys/client_ed25519` (Ed25519); `keys/client_ed25519_encrypted` is the same key with the passphrase `shello-test-passphrase` |
| Host key a | `SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY` (ED25519) |
| Host key b | `SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI` (ED25519) |

The shell's first line, the message of the day, is `Shello test server`, and the prompt is `shello-test:~$`. The UI tests look for both.

From the Mac's terminal: `ssh -p 2222 shello@localhost`. Git does not keep a key's file mode, so make a copy readable only by you before `ssh -i` takes it.

In Shello: add a host with the address `localhost`, port 2222, user `shello` and the method Password, with the password above. Connect asks to trust host key a; its fingerprint is in the table. To see a changed host key blocked, restart the server with `--host-key b` and connect again.

## Without Docker

`TestServers/local-sshd.sh` runs this Mac's own `/usr/sbin/sshd` as you, unprivileged, on the same port with host key a. It lets only you in, with `keys/client_ed25519`: an unprivileged sshd cannot check passwords. `TestServers/local-sshd.sh stop` stops it. CI runs it, because GitHub's macOS runners have no Docker.

The tests need to know the user then. Pass it on through xcodebuild, which hands `TEST_RUNNER_`-prefixed variables to the tests without the prefix:

```sh
TestServers/local-sshd.sh
TEST_RUNNER_SHELLO_TEST_SERVER_USER=$(id -un) xcodebuild test -project Shello.xcodeproj -scheme Shello \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -skipPackagePluginValidation
```

With `SHELLO_TEST_SERVER_USER` set, the tests that sign in with a password skip.

## The tests that use it

- `ShelloSSHTests` (`ConnectionTests`): the socketpair bridge, both ways to sign in, commands, a shell, and two connections at once.
- `ShelloCoreTests` (`HostConnectorTests`): the first connection's trust question, a trusted key, and a changed one.
- `ShelloUITests/ConnectionTests`: the trust sheet, the changed host key sheet and a password sign-in to the shell.

They check that a server greets on `127.0.0.1:2222`, and skip with a message that points here when none does. Each needs a fresh connection, and the server's default `MaxStartups` would drop some of many at once, so the test server raises it.

## Files

| File | What it is |
| --- | --- |
| `ssh-server.sh` | Starts, stops and checks the Docker server |
| `openssh/Dockerfile` | The image; build context is `TestServers/` |
| `openssh/sshd_config` | sshd's settings |
| `openssh/entrypoint.sh` | Starts sshd with host key a or b, as `HOST_KEY` says |
| `local-sshd.sh` | This Mac's own sshd as a test server |
| `keys/` | The host keys a and b, and the client key, made with `ssh-keygen -t ed25519` for these tests only |

To move to a newer Alpine, take the digest that `docker buildx imagetools inspect alpine:3.24` prints for the image index and put it in the Dockerfile's `FROM` line.
