# A disposable OpenSSH 10 server for Shello's integration and UI tests (TestServers/README.md).
# ssh-server.sh runs it three times: as it is, without post-quantum key exchange, and with the NIST
# curves and Diffie-Hellman groups only (entrypoint.sh).
# Test credentials only: the users, the password, the one-time code's secret and every key in
# TestServers/keys are public.
# Build context: TestServers/.

# Alpine 3.24 ships OpenSSH 10.3 (docs/spec/STACK.md section 11). Pinned by the digest of the
# multi-platform image, so it builds the same on Apple silicon and on Intel. Its packages come from
# the 3.24 branch, which only takes fixes.
FROM alpine:3.24@sha256:71e9b7bae160ba167fa17414401b94cbcdaf3c32feeab9298bd794a2a0614c35

# sshd with PAM, for keyboard-interactive sign-in, and the PAM module that asks for a one-time code.
# tmux for auto-attach (TmuxIntegrationTests), pinned to tmux 3.7c: `~` takes the branch's rebuilds of
# it (-r0, -r1 …), which are fixes, and nothing newer.
RUN apk add --no-cache openssh-server openssh-server-pam google-authenticator tmux~3.7c

COPY keys/client_ed25519.pub keys/ssh_host_ed25519_key_a keys/ssh_host_ed25519_key_b /tmp/keys/
COPY openssh/sshd_config /etc/ssh/sshd_config
COPY openssh/sshd_config.two-factor openssh/google_authenticator /tmp/
COPY openssh/pam-sshd /etc/pam.d/sshd
COPY openssh/entrypoint.sh /entrypoint.sh

# The test users (pam-sshd says how each signs in):
# - shello: its password, or the fixture key;
# - shello-otp: its password and a one-time code;
# - shello-2fa: the fixture key, then a one-time code.
# Two fixed host keys let the tests know the fingerprint and see a changed host key. The shell's
# first line, the message of the day, is what the UI tests look for in the terminal.
RUN for user in shello shello-otp shello-2fa; do \
        adduser -D -s /bin/sh "$user" \
        && echo "$user:shello-test-password" | chpasswd \
        && install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"; \
    done \
    && for user in shello shello-2fa; do \
        install -m 600 -o "$user" -g "$user" /tmp/keys/client_ed25519.pub "/home/$user/.ssh/authorized_keys"; \
    done \
    && for user in shello-otp shello-2fa; do \
        install -m 400 -o "$user" -g "$user" /tmp/google_authenticator "/home/$user/.google_authenticator"; \
    done \
    && cat /tmp/sshd_config.two-factor >> /etc/ssh/sshd_config \
    && install -d -m 755 /etc/ssh/keys \
    && install -m 600 /tmp/keys/ssh_host_ed25519_key_a /tmp/keys/ssh_host_ed25519_key_b /etc/ssh/keys/ \
    && rm -r /tmp/keys /tmp/sshd_config.two-factor /tmp/google_authenticator \
    && chmod 755 /entrypoint.sh \
    && echo 'Shello test server' > /etc/motd

ENV KEYBOARD_INTERACTIVE=on PER_SOURCE_PENALTIES=off
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
