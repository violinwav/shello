#!/usr/bin/env bash
# Builds Shello's fuzz targets with the swift.org toolchain on Linux, in Docker, and runs each one
# for a while: Fuzz/README.md. Xcode's toolchain rejects -sanitize=fuzzer (docs/spec/STACK.md
# section 11).
#
# Usage: Fuzz/run.sh [seconds]
#
# Each target runs for the given seconds, 60 by default, as the smoke run of STACK section 11. The
# repository is mounted read-only; the build, the corpus and any crash stay in the container, and a
# crash's input is printed in hex before the script fails.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/.." && pwd)
SECONDS_PER_TARGET=${1:-60}
# Swift 6.3.3 on Ubuntu 24.04, the Swift of Xcode 26.6, pinned by the digest of its multi-platform
# image. To move on, take the digest `docker buildx imagetools inspect swift:6.3` prints.
IMAGE=swift:6.3@sha256:c2f3ac2eb806ce43f68859c3d52bd3bb1cfc88672fb3a948b76e136d98e39278

[[ $SECONDS_PER_TARGET =~ ^[0-9]+$ ]] || {
    printf 'usage: %s [seconds]\n' "$0" >&2
    exit 64
}
command -v docker >/dev/null || {
    printf 'error: docker not found: install Docker Desktop\n' >&2
    exit 1
}

docker run --rm --volume "$REPO:/shello:ro" --workdir /tmp --env "SECONDS_PER_TARGET=$SECONDS_PER_TARGET" \
    "$IMAGE" bash -euo pipefail -c '
    swiftc --version | head -1

    # The SSH agent protocol (STACK section 7.3): the parser and the framing, as they ship, with the
    # target in one module.
    swiftc -sanitize=fuzzer,address -parse-as-library -O -g \
        /shello/Packages/ShelloKit/Sources/ShelloSecurity/SSHAgent/SSHAgentProtocol.swift \
        /shello/Fuzz/SSHAgentProtocol/FuzzTarget.swift \
        -o ssh-agent-protocol

    # Seeds: a request for identities and a sign request, framed, and the same unframed.
    mkdir -p corpus crashes
    printf "\x00\x00\x00\x01\x0b" >corpus/identities
    printf "\x00\x00\x00\x14\x0d\x00\x00\x00\x03key\x00\x00\x00\x04data\x00\x00\x00\x00" >corpus/sign
    printf "\x0b" >corpus/identities-unframed
    printf "\x0d\x00\x00\x00\x03key\x00\x00\x00\x04data\x00\x00\x00\x02" >corpus/sign-unframed

    if ! ./ssh-agent-protocol -max_total_time="$SECONDS_PER_TARGET" -print_final_stats=1 \
        -artifact_prefix=crashes/ corpus; then
        for crash in crashes/*; do
            printf "Crashing input %s:\n" "$crash"
            od -A x -t x1z "$crash"
        done
        exit 1
    fi
'
