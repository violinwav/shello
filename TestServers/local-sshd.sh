#!/usr/bin/env bash
# This Mac's own sshd as a test server, for machines without Docker such as GitHub's macOS runners
# (docs/spec/STACK.md section 11, "app end to end"): TestServers/README.md.
#
# Usage: TestServers/local-sshd.sh [start] | stop
#
# It runs as the current user, unprivileged, on 127.0.0.1:2222 with host key a, and lets that user in
# with the fixture key TestServers/keys/client_ed25519 only: an unprivileged sshd cannot check
# passwords. Its files live in a directory of their own under $TMPDIR.
set -euo pipefail

PORT=2222
DIR=$(cd "$(dirname "$0")" && pwd)
STATE="${TMPDIR:-/tmp}/shello-test-sshd"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

wait_for_banner() {
    local banner attempt
    for attempt in $(seq 1 50); do
        if banner=$(exec 3<>"/dev/tcp/127.0.0.1/$PORT" && read -r -t 2 line <&3 && printf '%s' "$line") &&
            [[ $banner == SSH-2.0-* ]]; then
            printf '%s\n' "${banner%$'\r'}"
            return
        fi
        sleep 0.2
    done
    cat "$STATE/sshd.log" >&2 || true
    die "sshd did not answer on 127.0.0.1:$PORT"
}

start() {
    stop >/dev/null
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    # sshd refuses a host key that others can read; git does not keep the mode.
    install -m 600 "$DIR/keys/ssh_host_ed25519_key_a" "$STATE/ssh_host_ed25519_key"
    install -m 600 "$DIR/keys/client_ed25519.pub" "$STATE/authorized_keys"
    cat >"$STATE/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $PORT
HostKey $STATE/ssh_host_ed25519_key
PidFile $STATE/sshd.pid
AuthorizedKeysFile $STATE/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
MaxStartups 100
EOF
    /usr/sbin/sshd -f "$STATE/sshd_config" -E "$STATE/sshd.log"
    printf 'Test server on 127.0.0.1:%s, host key a: %s\n' "$PORT" "$(wait_for_banner)"
    printf 'Sign in as %s with TestServers/keys/client_ed25519.\n' "$(id -un)"
}

stop() {
    if [[ -f $STATE/sshd.pid ]]; then
        kill "$(cat "$STATE/sshd.pid")" 2>/dev/null || true
        rm -f "$STATE/sshd.pid"
    fi
    printf 'Test server stopped.\n'
}

case ${1:-start} in
start) start ;;
stop) stop ;;
*) die "usage: $0 [start] | stop" ;;
esac
