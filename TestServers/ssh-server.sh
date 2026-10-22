#!/usr/bin/env bash
# Shello's disposable OpenSSH 10 test server, in Docker: TestServers/README.md.
#
# Usage: TestServers/ssh-server.sh [start] [--host-key a|b]
#        TestServers/ssh-server.sh stop | status
#
# start (the default) builds the image and runs the server on 127.0.0.1:2222, replacing a server
# that runs already. --host-key b starts it with the other host key, so that a client that trusted
# key a sees a changed host key. The server listens on this Mac's loopback only: its password and
# keys are public.
set -euo pipefail

NAME=shello-test-openssh
IMAGE=shello-test-openssh
PORT=2222
DIR=$(cd "$(dirname "$0")" && pwd)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Waits until the server greets with its SSH banner, and prints it.
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
    docker logs "$NAME" >&2 || true
    die "the server did not answer on 127.0.0.1:$PORT"
}

start() {
    local host_key=a
    while [[ $# -gt 0 ]]; do
        case $1 in
        --host-key)
            host_key=${2:-}
            shift 2 || die "--host-key needs a or b"
            ;;
        *) die "unknown option $1" ;;
        esac
    done
    [[ $host_key == a || $host_key == b ]] || die "--host-key must be a or b"
    command -v docker >/dev/null || die "docker not found: install Docker Desktop, or use TestServers/local-sshd.sh"

    docker build --quiet --tag "$IMAGE" --file "$DIR/openssh/Dockerfile" "$DIR" >/dev/null
    docker rm --force "$NAME" >/dev/null 2>&1 || true
    docker run --detach --name "$NAME" --hostname shello-test --env "HOST_KEY=$host_key" \
        --publish "127.0.0.1:$PORT:22" "$IMAGE" >/dev/null
    printf 'Test server on 127.0.0.1:%s, host key %s: %s\n' "$PORT" "$host_key" "$(wait_for_banner)"
    printf 'Sign in as shello, password shello-test-password, or with TestServers/keys/client_ed25519.\n'
}

stop() {
    docker rm --force "$NAME" >/dev/null 2>&1 || true
    printf 'Test server stopped.\n'
}

status() {
    if [[ $(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null) == true ]]; then
        printf 'Running on 127.0.0.1:%s, host key %s: %s\n' "$PORT" \
            "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" | sed -n 's/^HOST_KEY=//p')" \
            "$(wait_for_banner)"
    else
        printf 'Not running. Start it with %s.\n' "$0"
        exit 1
    fi
}

command=${1:-start}
case $command in
start)
    shift || true
    start "$@"
    ;;
--host-key) start "$@" ;;
stop) stop ;;
status) status ;;
*) die "usage: $0 [start] [--host-key a|b] | stop | status" ;;
esac
