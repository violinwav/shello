#!/bin/sh
# Runs sshd in the foreground with host key A or B, as HOST_KEY says (default a). Switching keys
# makes the server look like one whose host key changed.
#
# KEX chooses the key exchanges the server offers:
# - default: OpenSSH's own;
# - classical: OpenSSH's defaults without mlkem768x25519-sha256 and sntrup761x25519-sha512, under
#   either of its names;
# - nist: the classical ones without curve25519, as on a server in FIPS mode, which has only the
#   NIST curves and the Diffie-Hellman groups.
# local-sshd.sh limits the Mac's own sshd to the same lists.
#
# KEYBOARD_INTERACTIVE=on (default off), which the Alpine images set, runs sshd with PAM, which asks
# the keyboard-interactive questions of /etc/pam.d/sshd (pam-sshd).
#
# PER_SOURCE_PENALTIES=off (default on), which the OpenSSH 10 image sets, turns off what OpenSSH 9.8
# and later do to an address whose connections fail to sign in, or close before they try: refuse
# all its connections for a while. Every test connects from the same address, and many of them fail
# on purpose.
set -eu

CLASSICAL_KEX=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256
NIST_KEX=ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256

case ${HOST_KEY:-a} in
a | b) ;;
*)
    echo "HOST_KEY must be a or b, not ${HOST_KEY}" >&2
    exit 64
    ;;
esac

case ${KEX:-default} in
default) set -- ;;
classical) set -- -o "KexAlgorithms=$CLASSICAL_KEX" ;;
nist) set -- -o "KexAlgorithms=$NIST_KEX" ;;
*)
    echo "KEX must be default, classical or nist, not ${KEX}" >&2
    exit 64
    ;;
esac

case ${KEYBOARD_INTERACTIVE:-off} in
on)
    sshd=/usr/sbin/sshd.pam
    set -- "$@" -o UsePAM=yes -o KbdInteractiveAuthentication=yes
    ;;
off) sshd=/usr/sbin/sshd ;;
*)
    echo "KEYBOARD_INTERACTIVE must be on or off, not ${KEYBOARD_INTERACTIVE}" >&2
    exit 64
    ;;
esac

case ${PER_SOURCE_PENALTIES:-on} in
on) ;;
off) set -- "$@" -o PerSourcePenalties=no ;;
*)
    echo "PER_SOURCE_PENALTIES must be on or off, not ${PER_SOURCE_PENALTIES}" >&2
    exit 64
    ;;
esac

exec "$sshd" -D -e -h "/etc/ssh/keys/ssh_host_ed25519_key_${HOST_KEY:-a}" "$@"
