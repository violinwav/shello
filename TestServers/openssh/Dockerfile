# A disposable OpenSSH 10 server for Shello's integration and UI tests (TestServers/README.md).
# Test credentials only: the user, the password and every key in TestServers/keys are public.
# Build context: TestServers/.

# Alpine 3.24 ships OpenSSH 10.3 (docs/spec/STACK.md section 11). Pinned by the digest of the
# multi-platform image, so it builds the same on Apple silicon and on Intel. Its packages come from
# the 3.24 branch, which only takes fixes.
FROM alpine:3.24@sha256:71e9b7bae160ba167fa17414401b94cbcdaf3c32feeab9298bd794a2a0614c35

RUN apk add --no-cache openssh-server

COPY keys/client_ed25519.pub keys/ssh_host_ed25519_key_a keys/ssh_host_ed25519_key_b /tmp/keys/
COPY openssh/sshd_config /etc/ssh/sshd_config
COPY openssh/entrypoint.sh /entrypoint.sh

# The test user signs in with its password or with the fixture key. Two fixed host keys let the
# tests know the fingerprint and see a changed host key. The shell's first line, the message of the
# day, is what the UI tests look for in the terminal.
RUN adduser -D -s /bin/sh shello \
    && echo 'shello:shello-test-password' | chpasswd \
    && install -d -m 700 -o shello -g shello /home/shello/.ssh \
    && install -m 600 -o shello -g shello /tmp/keys/client_ed25519.pub /home/shello/.ssh/authorized_keys \
    && install -d -m 755 /etc/ssh/keys \
    && install -m 600 /tmp/keys/ssh_host_ed25519_key_a /tmp/keys/ssh_host_ed25519_key_b /etc/ssh/keys/ \
    && rm -r /tmp/keys \
    && chmod 755 /entrypoint.sh \
    && echo 'Shello test server' > /etc/motd

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
