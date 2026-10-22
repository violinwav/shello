#!/bin/sh
# Runs sshd in the foreground with host key A or B, as HOST_KEY says (default a). Switching keys
# makes the server look like one whose host key changed.
#
# POST_QUANTUM_KEX=off (default on) limits the key exchange to classical algorithms: OpenSSH's
# defaults without mlkem768x25519-sha256 and sntrup761x25519-sha512, under either of its names.
# local-sshd.sh limits the Mac's own sshd to the same list.
set -eu

CLASSICAL_KEX=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256

case ${HOST_KEY:-a} in
a | b) ;;
*)
    echo "HOST_KEY must be a or b, not ${HOST_KEY}" >&2
    exit 64
    ;;
esac

case ${POST_QUANTUM_KEX:-on} in
on) set -- ;;
off) set -- -o "KexAlgorithms=$CLASSICAL_KEX" ;;
*)
    echo "POST_QUANTUM_KEX must be on or off, not ${POST_QUANTUM_KEX}" >&2
    exit 64
    ;;
esac

exec /usr/sbin/sshd -D -e -h "/etc/ssh/keys/ssh_host_ed25519_key_${HOST_KEY:-a}" "$@"
