#!/usr/bin/env bash
# This Mac's own sshd as a test server, for machines without Docker such as GitHub's macOS runners
# (docs/spec/STACK.md section 11, "app end to end"): TestServers/README.md.
#
# Usage: TestServers/local-sshd.sh [start] | stop
#
# It runs three sshd as the current user, unprivileged, with host key a, on the ports of the Docker
# servers they stand in for: 127.0.0.1:2222 with OpenSSH's default key exchanges, 127.0.0.1:2224
# with post-quantum key exchange off, and 127.0.0.1:2226 with the NIST curves and Diffie-Hellman
# groups only. All let that user in with the fixture key TestServers/keys/client_ed25519 only: an
# unprivileged sshd cannot check passwords, nor ask keyboard-interactive questions. Their files live
# in a directory of their own under $TMPDIR.
#
# tmux: the server on port 2222 puts this Mac's tmux, if it has one, on the PATH a command gets, as a
# Linux server's /usr/bin does, where sshd's default PATH leaves out Homebrew's. The others leave it
# out, as servers without tmux, and give the shell an empty home directory: macOS's bash reads
# ~/.bashrc even for a command sshd runs, and GitHub's runner puts Homebrew on the PATH there. The
# tmux they start runs apart from the user's own, in the servers' directory (TMUX_TMPDIR), and stop
# ends it.
set -euo pipefail

PORT=2222
CLASSICAL_PORT=2224
NIST_PORT=2226
# OpenSSH's default key exchanges without the post-quantum ones, and those without curve25519 too,
# as in openssh/entrypoint.sh.
CLASSICAL_KEX=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256
NIST_KEX=ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256
DIR=$(cd "$(dirname "$0")" && pwd)
STATE="${TMPDIR:-/tmp}/shello-test-sshd"
# The PATH sshd gives a command on macOS.
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
TMUX_COMMAND=$(command -v tmux || true)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Waits until the sshd on port $1, whose files are named after $2, greets, and prints its banner.
wait_for_banner() {
    local port=$1 name=$2 banner attempt
    for attempt in $(seq 1 50); do
        if banner=$(exec 3<>"/dev/tcp/127.0.0.1/$port" && read -r -t 2 line <&3 && printf '%s' "$line") &&
            [[ $banner == SSH-2.0-* ]]; then
            printf '%s\n' "${banner%$'\r'}"
            return
        fi
        sleep 0.2
    done
    cat "$STATE/$name.log" >&2 || true
    die "sshd did not answer on 127.0.0.1:$port"
}

# sshd's settings for port $1, with its files named after $2, then the further lines given.
write_config() {
    local port=$1 name=$2
    shift 2
    cat <<EOF
ListenAddress 127.0.0.1
Port $port
HostKey $STATE/ssh_host_ed25519_key
PidFile $STATE/$name.pid
AuthorizedKeysFile $STATE/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
MaxStartups 100
# Every test connects from 127.0.0.1, and many fail to sign in on purpose: OpenSSH's penalties for
# that would refuse every connection for a while.
PerSourcePenalties no
EOF
    [[ $# -eq 0 ]] || printf '%s\n' "$@"
}

start() {
    stop >/dev/null
    mkdir -p "$STATE" "$STATE/tmux" "$STATE/home"
    chmod 700 "$STATE" "$STATE/tmux" "$STATE/home"
    # sshd refuses a host key that others can read; git does not keep the mode.
    install -m 600 "$DIR/keys/ssh_host_ed25519_key_a" "$STATE/ssh_host_ed25519_key"
    install -m 600 "$DIR/keys/client_ed25519.pub" "$STATE/authorized_keys"
    local with_tmux=$SYSTEM_PATH
    [[ -z $TMUX_COMMAND ]] || with_tmux="$(dirname "$TMUX_COMMAND"):$SYSTEM_PATH"
    # Without tmux: no startup file of the user's can put it back on the PATH.
    local without_tmux="SetEnv \"PATH=$SYSTEM_PATH\" \"HOME=$STATE/home\" \"TMUX_TMPDIR=$STATE/tmux\""
    write_config "$PORT" sshd "SetEnv \"PATH=$with_tmux\" \"TMUX_TMPDIR=$STATE/tmux\"" >"$STATE/sshd_config"
    write_config "$CLASSICAL_PORT" sshd-classical "KexAlgorithms $CLASSICAL_KEX" "$without_tmux" \
        >"$STATE/sshd-classical_config"
    write_config "$NIST_PORT" sshd-nist "KexAlgorithms $NIST_KEX" "$without_tmux" >"$STATE/sshd-nist_config"
    /usr/sbin/sshd -f "$STATE/sshd_config" -E "$STATE/sshd.log"
    /usr/sbin/sshd -f "$STATE/sshd-classical_config" -E "$STATE/sshd-classical.log"
    /usr/sbin/sshd -f "$STATE/sshd-nist_config" -E "$STATE/sshd-nist.log"
    printf 'Test server on 127.0.0.1:%s, host key a: %s\n' "$PORT" "$(wait_for_banner "$PORT" sshd)"
    printf 'Test server on 127.0.0.1:%s, host key a, post-quantum key exchange off: %s\n' "$CLASSICAL_PORT" \
        "$(wait_for_banner "$CLASSICAL_PORT" sshd-classical)"
    printf 'Test server on 127.0.0.1:%s, host key a, NIST curves and Diffie-Hellman groups only: %s\n' \
        "$NIST_PORT" "$(wait_for_banner "$NIST_PORT" sshd-nist)"
    if [[ -n $TMUX_COMMAND ]]; then
        printf 'tmux on 127.0.0.1:%s only: %s, %s\n' "$PORT" "$("$TMUX_COMMAND" -V)" "$TMUX_COMMAND"
    else
        printf 'No tmux on this Mac: the tmux tests will skip.\n'
    fi
    printf 'Sign in as %s with TestServers/keys/client_ed25519.\n' "$(id -un)"
}

stop() {
    local name
    for name in sshd sshd-classical sshd-nist; do
        if [[ -f $STATE/$name.pid ]]; then
            kill "$(cat "$STATE/$name.pid")" 2>/dev/null || true
            rm -f "$STATE/$name.pid"
        fi
    done
    # The tmux the servers started, with what still runs in it. Its socket is named: inside the user's
    # own tmux, $TMUX would point tmux at that one.
    local socket
    socket="$STATE/tmux/tmux-$(id -u)/default"
    if [[ -n $TMUX_COMMAND && -S $socket ]]; then
        "$TMUX_COMMAND" -S "$socket" kill-server 2>/dev/null || true
    fi
    printf 'Test servers stopped.\n'
}

case ${1:-start} in
start) start ;;
stop) stop ;;
*) die "usage: $0 [start] | stop" ;;
esac
