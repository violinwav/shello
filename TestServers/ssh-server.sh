#!/usr/bin/env bash
# Shello's disposable OpenSSH test servers, in Docker: TestServers/README.md.
#
# Usage: TestServers/ssh-server.sh [start] [--host-key a|b]
#        TestServers/ssh-server.sh stop | status
#
# start (the default) builds the images and runs five servers, replacing those that run already:
#   127.0.0.1:2222  OpenSSH 10.3, whose default key exchange is mlkem768x25519-sha256
#   127.0.0.1:2223  OpenSSH 9.6, which has sntrup761x25519-sha512@openssh.com and no ML-KEM
#   127.0.0.1:2224  OpenSSH 10.3 with post-quantum key exchange off
#   127.0.0.1:2225  OpenSSH 8.8, the oldest OpenSSH Shello supports
#   127.0.0.1:2226  OpenSSH 10.3 with the NIST curves and Diffie-Hellman groups only, as in FIPS mode
# --host-key b starts them with the other host key, so that a client that trusted key a sees a
# changed host key. The servers listen on this Mac's loopback only: their password and keys are
# public. They share a Docker network of their own, on which each reaches the others by container
# name on port 22, as a jump host reaches the next hop of a route.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
# Docker's default bridge resolves no container names; a network of the servers' own does.
NETWORK=shello-test

# Each server: its container, its port, its image, and the key exchanges it offers (entrypoint.sh).
SERVERS=(
    "shello-test-openssh 2222 shello-test-openssh default"
    "shello-test-openssh9 2223 shello-test-openssh9 default"
    "shello-test-openssh-classical 2224 shello-test-openssh classical"
    "shello-test-openssh8 2225 shello-test-openssh8 default"
    "shello-test-openssh-nist 2226 shello-test-openssh nist"
)

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Waits until the server on port $1, container $2, greets with its SSH banner, and prints it.
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
    docker logs "$name" >&2 || true
    die "the server did not answer on 127.0.0.1:$port"
}

# What a server is, after its address: its host key $1, and the key exchanges $2 when they are not
# OpenSSH's defaults.
describe() {
    printf 'host key %s' "$1"
    case $2 in
    classical) printf ', post-quantum key exchange off' ;;
    nist) printf ', NIST curves and Diffie-Hellman groups only' ;;
    esac
}

start() {
    local host_key=a server name port image kex
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

    docker build --quiet --tag shello-test-openssh --file "$DIR/openssh/Dockerfile" "$DIR" >/dev/null
    docker build --quiet --tag shello-test-openssh9 --file "$DIR/openssh9/Dockerfile" "$DIR" >/dev/null
    docker build --quiet --tag shello-test-openssh8 --file "$DIR/openssh8/Dockerfile" "$DIR" >/dev/null
    docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
    for server in "${SERVERS[@]}"; do
        read -r name port image kex <<<"$server"
        docker rm --force "$name" >/dev/null 2>&1 || true
        docker run --detach --name "$name" --hostname shello-test --network "$NETWORK" \
            --env "HOST_KEY=$host_key" --env "KEX=$kex" --publish "127.0.0.1:$port:22" "$image" >/dev/null
    done
    for server in "${SERVERS[@]}"; do
        read -r name port image kex <<<"$server"
        printf 'Test server on 127.0.0.1:%s, %s: %s\n' "$port" "$(describe "$host_key" "$kex")" \
            "$(wait_for_banner "$port" "$name")"
    done
    printf 'Sign in as shello, password shello-test-password, or with TestServers/keys/client_ed25519.\n'
}

stop() {
    local server name port image kex
    for server in "${SERVERS[@]}"; do
        read -r name port image kex <<<"$server"
        docker rm --force "$name" >/dev/null 2>&1 || true
    done
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    printf 'Test servers stopped.\n'
}

status() {
    local server name port image kex host_key stopped=0
    for server in "${SERVERS[@]}"; do
        read -r name port image kex <<<"$server"
        if [[ $(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then
            host_key=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" |
                sed -n 's/^HOST_KEY=//p')
            printf 'Running on 127.0.0.1:%s, %s: %s\n' "$port" "$(describe "$host_key" "$kex")" \
                "$(wait_for_banner "$port" "$name")"
        else
            printf 'Not running on 127.0.0.1:%s.\n' "$port"
            stopped=1
        fi
    done
    if [[ $stopped == 1 ]]; then
        printf 'Start the test servers with %s.\n' "$0"
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
