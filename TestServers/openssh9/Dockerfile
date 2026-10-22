# A disposable OpenSSH 9 server for Shello's key exchange tests (TestServers/README.md). It has no
# ML-KEM, and knows sntrup761x25519-sha512 only as sntrup761x25519-sha512@openssh.com, as OpenSSH
# before 9.9 does. The same user, password, keys and sshd settings as openssh/Dockerfile, whose
# sshd_config and entrypoint.sh it shares. Test credentials only: everything in TestServers/keys is
# public. Build context: TestServers/.

# Ubuntu 24.04 ships OpenSSH 9.6 (docs/spec/STACK.md section 11). Pinned by the digest of the
# multi-platform image, so it builds the same on Apple silicon and on Intel. Its packages come from
# Ubuntu 24.04's updates, which only take fixes. Debian 12's OpenSSH 9.2 would not do: Debian added
# the newer name sntrup761x25519-sha512 to it.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/*

COPY keys/client_ed25519.pub keys/ssh_host_ed25519_key_a keys/ssh_host_ed25519_key_b /tmp/keys/
COPY openssh/sshd_config /etc/ssh/sshd_config
COPY openssh/entrypoint.sh /entrypoint.sh

# As in openssh/Dockerfile. /run/sshd is the directory sshd's unprivileged child runs in, which
# Ubuntu creates only when its service starts.
RUN useradd --create-home --shell /bin/sh shello \
    && echo 'shello:shello-test-password' | chpasswd \
    && install -d -m 700 -o shello -g shello /home/shello/.ssh \
    && install -m 600 -o shello -g shello /tmp/keys/client_ed25519.pub /home/shello/.ssh/authorized_keys \
    && install -d -m 755 /etc/ssh/keys /run/sshd \
    && install -m 600 /tmp/keys/ssh_host_ed25519_key_a /tmp/keys/ssh_host_ed25519_key_b /etc/ssh/keys/ \
    && rm -r /tmp/keys \
    && chmod 755 /entrypoint.sh \
    && echo 'Shello test server' > /etc/motd

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
