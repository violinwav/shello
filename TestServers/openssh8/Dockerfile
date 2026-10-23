# A disposable OpenSSH 8.8 server, the oldest OpenSSH that Shello supports (README section 4), for
# Shello's integration tests (TestServers/README.md). It is openssh/Dockerfile on an older Alpine:
# the same users, passwords, keys, one-time code and sshd settings, whose files it shares. Its
# default key exchanges have no post-quantum one: OpenSSH 8.8 has sntrup761x25519-sha512@openssh.com
# but does not offer it unless configured to, which OpenSSH 9.0 changed.
# Test credentials only: everything here and in TestServers/keys is public.
# Build context: TestServers/.

# Alpine 3.15 ships OpenSSH 8.8p1 (docs/spec/STACK.md section 11). Pinned by the digest of the
# multi-platform image, so it builds the same on Apple silicon and on Intel. Alpine 3.15 is past its
# end of support, so its packages no longer change.
FROM alpine:3.15@sha256:19b4bcc4f60e99dd5ebdca0cbce22c503bbcff197549d7e19dab4f22254dc864

# No tmux, unlike the other images: this is the test server without tmux, where auto-attach falls back
# to a plain shell (TmuxIntegrationTests).
RUN apk add --no-cache openssh-server openssh-server-pam google-authenticator

COPY keys/client_ed25519.pub keys/ssh_host_ed25519_key_a keys/ssh_host_ed25519_key_b /tmp/keys/
COPY openssh/sshd_config /etc/ssh/sshd_config
COPY openssh/sshd_config.two-factor openssh/google_authenticator /tmp/
# Alpine 3.15's sshd.pam asks PAM as the service sshd.pam, after its own name; later ones as sshd.
COPY openssh/pam-sshd /etc/pam.d/sshd.pam
COPY openssh/entrypoint.sh /entrypoint.sh

# As in openssh/Dockerfile.
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

ENV KEYBOARD_INTERACTIVE=on
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
