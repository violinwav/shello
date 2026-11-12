# Shared by Vendor/build.sh and Vendor/test-openssl-arm64e.sh: the pinned versions, verified
# downloads and patching. Source it, do not run it. Why: docs/spec/STACK.md section 12.

OPENSSL_VERSION=3.5.9
LIBSSH_VERSION=0.12.2
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
LIBSSH_URL="https://www.libssh.org/files/${LIBSSH_VERSION%.*}/libssh-$LIBSSH_VERSION.tar.xz"

# Primary key fingerprints allowed to sign each release. The public keys are in Vendor/keys.
# OpenSSL: the "OpenSSL" key in doc/fingerprints.txt and on https://openssl-library.org/source/.
# libssh: the release key for 0.11.0 and later on https://www.libssh.org/get-it/.
OPENSSL_SIGNER=B146647E45A7B33947AB226B2A2C87D161692D40
LIBSSH_SIGNER=88A228D89B07C2C77D0C780903D5DF8CFDD3E8E7

# docs/spec/STACK.md section 5. -ftyped-memory-operations is what Xcode passes for
# CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT, the typed allocators Enhanced Security turns on.
HARDENING=(-fstack-protector-strong -D_FORTIFY_SOURCE=2 -ftrivial-auto-var-init=zero -ftyped-memory-operations)

# libcrypto only: libssh is its only user for now, and libssl is never built.
# no-autoload-config: an app has no openssl.cnf, so never look for one.
OPENSSL_OPTIONS=(no-shared no-engine no-comp no-legacy no-apps no-docs no-tests no-autoload-config)

VENDOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="$VENDOR_DIR/build"
DOWNLOADS="$BUILD_DIR/downloads"
JOBS=$(sysctl -n hw.ncpu)

log() { printf '==> %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || die "$tool not found (Homebrew: brew install cmake gnupg)"
    done
}

# Downloads a release tarball and its signature from the official URL, once. Every call checks the
# tarball against Vendor/sources.sha256 and the signature against the pinned signer.
fetch_verified() {
    local url=$1 keyfile=$2 signer=$3
    local name=${url##*/} suffix
    mkdir -p "$DOWNLOADS"
    for suffix in "" .asc; do
        [[ -f "$DOWNLOADS/$name$suffix" ]] && continue
        log "Downloading $url$suffix"
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --output "$DOWNLOADS/$name$suffix.part" "$url$suffix"
        mv "$DOWNLOADS/$name$suffix.part" "$DOWNLOADS/$name$suffix"
    done
    verify_checksum "$name"
    verify_signature "$DOWNLOADS/$name" "$VENDOR_DIR/keys/$keyfile" "$signer"
}

verify_checksum() {
    local name=$1 expected actual
    expected=$(awk -v name="$name" '$2 == name { print $1 }' "$VENDOR_DIR/sources.sha256")
    [[ -n $expected ]] || die "$name is not listed in Vendor/sources.sha256"
    actual=$(shasum -a 256 "$DOWNLOADS/$name" | awk '{ print $1 }')
    [[ $actual == "$expected" ]] ||
        die "SHA-256 mismatch for $name: expected $expected, got $actual. Delete $DOWNLOADS/$name to download it again."
    log "SHA-256 matches Vendor/sources.sha256: $name"
}

# gpgv with a throwaway keyring: no gpg-agent, and the user's own keyring is never read or changed.
verify_signature() {
    local file=$1 keyfile=$2 signer=$3 home status
    home=$(mktemp -d)
    gpg --batch --quiet --homedir "$home" --dearmor --output "$home/keyring.gpg" "$keyfile"
    status=$(gpgv --keyring "$home/keyring.gpg" --status-fd 1 "$file.asc" "$file" 2>/dev/null) || true
    rm -rf "$home"
    # VALIDSIG's last field is the primary key fingerprint, also when a subkey made the signature.
    awk '$2 == "VALIDSIG" { print $NF }' <<<"$status" | grep -qx "$signer" ||
        die "${file##*/} is not validly signed by $signer"
    log "Signature valid, signed by $signer: ${file##*/}"
}

# Unpacks a verified tarball into a fresh directory and applies Vendor/patches/<name>/*.patch.
unpack() {
    local tarball=$1 dest=$2 patches=$3 patch
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xf "$DOWNLOADS/$tarball" -C "$dest" --strip-components 1
    for patch in "$VENDOR_DIR/patches/$patches"/*.patch; do
        [[ -e $patch ]] || continue
        log "Applying ${patch#"$VENDOR_DIR/"}"
        patch --quiet --forward --batch -p1 -d "$dest" <"$patch"
    done
}
