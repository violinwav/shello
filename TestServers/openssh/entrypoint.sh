#!/bin/sh
# Runs sshd in the foreground with host key A or B, as HOST_KEY says (default a). Switching keys
# makes the server look like one whose host key changed.
set -eu

case ${HOST_KEY:-a} in
a | b) ;;
*)
    echo "HOST_KEY must be a or b, not ${HOST_KEY}" >&2
    exit 64
    ;;
esac

exec /usr/sbin/sshd -D -e -h "/etc/ssh/keys/ssh_host_ed25519_key_${HOST_KEY:-a}"
