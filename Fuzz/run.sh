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

    # Runs the target $1 on its corpus, $1-corpus, for SECONDS_PER_TARGET seconds, and fails after
    # printing each input that made it trap.
    fuzz() {
        mkdir -p "$1-crashes"
        if ! "./$1" -max_total_time="$SECONDS_PER_TARGET" -print_final_stats=1 -artifact_prefix="$1-crashes/" \
            "$1-corpus"; then
            for crash in "$1-crashes"/*; do
                printf "Crashing input %s:\n" "$crash"
                od -A x -t x1z "$crash"
            done
            exit 1
        fi
    }

    # The SSH agent protocol (STACK section 7.3): the parser and the framing, as they ship, with the
    # target in one module.
    swiftc -sanitize=fuzzer,address -parse-as-library -O -g \
        /shello/Packages/ShelloKit/Sources/ShelloSecurity/SSHAgent/SSHAgentProtocol.swift \
        /shello/Fuzz/SSHAgentProtocol/FuzzTarget.swift \
        -o ssh-agent-protocol

    # Seeds: a request for identities and a sign request, framed, and the same unframed.
    mkdir -p ssh-agent-protocol-corpus
    printf "\x00\x00\x00\x01\x0b" >ssh-agent-protocol-corpus/identities
    printf "\x00\x00\x00\x14\x0d\x00\x00\x00\x03key\x00\x00\x00\x04data\x00\x00\x00\x00" \
        >ssh-agent-protocol-corpus/sign
    printf "\x0b" >ssh-agent-protocol-corpus/identities-unframed
    printf "\x0d\x00\x00\x00\x03key\x00\x00\x00\x04data\x00\x00\x00\x02" >ssh-agent-protocol-corpus/sign-unframed
    fuzz ssh-agent-protocol

    # tmux output (STACK section 7.6): the parsers of what tmux -V prints and of the sessions that
    # list-sessions lists in the format Shello gives it, as they ship, with the target in one module.
    swiftc -sanitize=fuzzer,address -parse-as-library -O -g \
        /shello/Packages/ShelloKit/Sources/ShelloTmux/TmuxVersion.swift \
        /shello/Packages/ShelloKit/Sources/ShelloTmux/TmuxSession.swift \
        /shello/Fuzz/TmuxOutput/FuzzTarget.swift \
        -o tmux-output

    # Seeds: versions as tmux 3.4, 3.7c and a development build print them, one after a message of
    # the day, and sessions as tmux 3.4 lists them.
    mkdir -p tmux-output-corpus
    printf "tmux 3.4\n" >tmux-output-corpus/version
    printf "tmux 3.7c\n" >tmux-output-corpus/version-with-letter
    printf "tmux next-3.6\n" >tmux-output-corpus/version-of-development-build
    printf "Shello test server\r\ntmux 3.2a\r\n" >tmux-output-corpus/version-after-motd
    printf "\$0\t1792738688\t0\t3\tmain\n\$1\t1792738688\t1\t1\tz\303\274rich-1\n\$4\t1792738688\t0\t1\tdot_x\n" \
        >tmux-output-corpus/sessions
    fuzz tmux-output

    # Private keys as the user pastes them (README section 13): what Shello reads of their text
    # before libssh does, and the PKCS #8 that libssh hands a key over in, as they ship, with the
    # target in one module.
    swiftc -sanitize=fuzzer,address -parse-as-library -O -g \
        /shello/Packages/ShelloKit/Sources/ShelloSSH/KeyImport/KeyText.swift \
        /shello/Packages/ShelloKit/Sources/ShelloSSH/KeyImport/PKCS8.swift \
        /shello/Fuzz/KeyText/FuzzTarget.swift \
        -o key-text

    # Seeds: the key fixtures, test keys of every format and type that ssh-keygen made, public ones
    # and refused ones included.
    mkdir -p key-text-corpus
    cp /shello/Packages/ShelloKit/Tests/KeyFixtures/Keys/* key-text-corpus/
    fuzz key-text
'
