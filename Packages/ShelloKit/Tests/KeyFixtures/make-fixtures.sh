#!/usr/bin/env bash
# Makes the SSH key fixtures in Keys/ for the tests of importing SSH keys (README section 13), and
# the public keys the test servers let in with them (TestServers/keys/import_fixtures.pub). Test
# fixtures only, public in this repository: never anyone's own key, never used anywhere else.
#
# Usage: Packages/ShelloKit/Tests/KeyFixtures/make-fixtures.sh
#
# Each key the tests sign in with comes in every format it can be written in, all of the same key:
# OpenSSH's own, PEM (OpenSSL's traditional format) and PKCS #8, each plain and encrypted with
# KeyFixture.passphrase. Ed25519 has no traditional PEM format. The keys Shello refuses come in the
# formats that show why.
#
# This Mac's ssh-keygen (OpenSSH 10.2 with LibreSSL) makes them, except for two that it cannot:
# - Ed25519 in PKCS #8, which LibreSSL cannot write: the OpenSSH 10.3 test image's ssh-keygen, built
#   with OpenSSL 3, converts the same key.
# - DSA, which OpenSSH 10 removed: the OpenSSH 8.8 test image's ssh-keygen makes it.
# Both images come from TestServers/ssh-server.sh, which builds them. Docker must run.
#
# The keys are new each time: run TestServers/ssh-server.sh and TestServers/local-sshd.sh again
# afterwards, so that the test servers let the new ones in.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../../../.." && pwd)
KEYS="$DIR/Keys"
SERVER_KEYS="$REPO/TestServers/keys/import_fixtures.pub"
# KeyFixture.passphrase.
PASSPHRASE=shello-fixture-passphrase
WORK=$(mktemp -d "${TMPDIR:-/tmp}/shello-key-fixtures.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

docker image inspect shello-test-openssh shello-test-openssh8 >/dev/null ||
    { printf 'error: build the test images first with TestServers/ssh-server.sh\n' >&2; exit 1; }

# Makes the key $1 with ssh-keygen's -t $2 and -b $3 (none for Ed25519), named shello-fixture-$1.
make_key() {
    local name=$1 type=$2 bits=${3:-}
    ssh-keygen -q -t "$type" ${bits:+-b "$bits"} -N "" -C "shello-fixture-$name" -f "$WORK/$name"
}

# Writes the key $1 as Keys/$1-$2 in the format $3 (openssh, PEM or PKCS8), with the passphrase
# $4, or none. ssh-keygen -p rewrites a copy in place.
write() {
    local name=$1 variant=$2 format=$3 passphrase=${4:-}
    cp "$WORK/$name" "$WORK/$name-$variant"
    if [[ $format == openssh ]]; then
        ssh-keygen -q -p -P "" -N "$passphrase" -f "$WORK/$name-$variant" >/dev/null
    else
        ssh-keygen -q -p -P "" -N "$passphrase" -m "$format" -f "$WORK/$name-$variant" >/dev/null
    fi
    cp "$WORK/$name-$variant" "$KEYS/$name-$variant"
}

rm -rf "$KEYS"
mkdir -p "$KEYS"

# The keys the tests import and sign in with, in every format.
make_key ed25519 ed25519
make_key ecdsa-p256 ecdsa 256
make_key ecdsa-p384 ecdsa 384
make_key rsa-3072 rsa 3072
for name in ed25519 ecdsa-p256 ecdsa-p384 rsa-3072; do
    write "$name" openssh openssh
    write "$name" openssh-encrypted openssh "$PASSPHRASE"
    cp "$WORK/$name.pub" "$KEYS/$name.pub"
done
for name in ecdsa-p256 ecdsa-p384 rsa-3072; do
    write "$name" pem PEM
    write "$name" pem-encrypted PEM "$PASSPHRASE"
    write "$name" pkcs8 PKCS8
    write "$name" pkcs8-encrypted PKCS8 "$PASSPHRASE"
done
# Ed25519 in PKCS #8, by the OpenSSH 10.3 image's ssh-keygen. The image's entrypoint starts sshd; this
# runs ssh-keygen in a throwaway container instead, on a copy of the key.
cp "$WORK/ed25519" "$WORK/ed25519-pkcs8"
cp "$WORK/ed25519" "$WORK/ed25519-pkcs8-encrypted"
docker run --rm --entrypoint /usr/bin/ssh-keygen --volume "$WORK:/keys" shello-test-openssh \
    -q -p -P "" -N "" -m PKCS8 -f /keys/ed25519-pkcs8 >/dev/null
docker run --rm --entrypoint /usr/bin/ssh-keygen --volume "$WORK:/keys" shello-test-openssh \
    -q -p -P "" -N "$PASSPHRASE" -m PKCS8 -f /keys/ed25519-pkcs8-encrypted >/dev/null
cp "$WORK/ed25519-pkcs8" "$WORK/ed25519-pkcs8-encrypted" "$KEYS/"

# The smallest RSA key Shello imports.
make_key rsa-2048 rsa 2048
write rsa-2048 openssh openssh
cp "$WORK/rsa-2048.pub" "$KEYS/"

# Keys Shello refuses: RSA under 2048 bits, ECDSA P-521, and DSA, in OpenSSH's format and in PEM
# by OpenSSH 8.8's ssh-keygen, since this Mac's has no DSA.
make_key rsa-1024 rsa 1024
write rsa-1024 openssh openssh
write rsa-1024 pem PEM
make_key ecdsa-p521 ecdsa 521
write ecdsa-p521 openssh openssh
docker run --rm --entrypoint /usr/bin/ssh-keygen --volume "$WORK:/keys" shello-test-openssh8 \
    -q -t dsa -N "" -C shello-fixture-dsa -f /keys/dsa
cp "$WORK/dsa" "$WORK/dsa-pem"
docker run --rm --entrypoint /usr/bin/ssh-keygen --volume "$WORK:/keys" shello-test-openssh8 \
    -q -p -P "" -N "" -m PEM -f /keys/dsa-pem >/dev/null
cp "$WORK/dsa" "$KEYS/dsa-openssh"
cp "$WORK/dsa-pem" "$KEYS/dsa-pem"

# The test servers let the test user in with the keys the tests sign in with.
cat "$KEYS/ed25519.pub" "$KEYS/ecdsa-p256.pub" "$KEYS/ecdsa-p384.pub" "$KEYS/rsa-3072.pub" >"$SERVER_KEYS"
printf 'Wrote the fixtures to %s and their public keys to %s.\n' "$KEYS" "$SERVER_KEYS"
