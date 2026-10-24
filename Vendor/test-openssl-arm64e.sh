#!/usr/bin/env bash
# Runs OpenSSL's own test suite as arm64e on this Mac, built with Shello's patches, options and
# hardening flags, and with assembly enabled. This is how OpenSSL's assembly is tested on arm64e
# (docs/spec/STACK.md section 13, spike item 7).
#
# The iOS Simulator has no arm64e. macOS on Apple silicon runs arm64e processes with pointer
# authentication enforced, and the assembly is the same: OpenSSL generates both from its "ios64"
# perlasm flavour. A physical iPhone remains the final check.
#
# Usage: Vendor/test-openssl-arm64e.sh [TESTS]
#   TESTS is OpenSSL's test selection, for example "test_evp test_internal_poly1305". Default: all.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

WORK="$BUILD_DIR/test-arm64e"

# Proves the premise: a call through an unsigned function pointer must crash, as it would on iOS.
check_pointer_authentication() {
    local probe="$WORK/probe"
    mkdir -p "$probe"
    cat >"$probe/probe.c" <<'EOF'
#include <ptrauth.h>
static void target(void) {}
int main(int argc, char **argv) {
    void (*volatile call)(void) = target;
    (void)argv;
    if (argc > 1) call = ptrauth_strip(call, ptrauth_key_function_pointer);
    call();
    return 0;
}
EOF
    xcrun clang -arch arm64e "$probe/probe.c" -o "$probe/probe"
    "$probe/probe" || die "an arm64e process cannot run here"
    if "$probe/probe" unsigned 2>/dev/null; then
        die "this Mac does not enforce pointer authentication for arm64e, so the test would prove nothing"
    fi
    log "Pointer authentication is enforced for arm64e processes"
}

main() {
    local tests=${1:-} options=() option
    [[ $(uname -m) == arm64 ]] || die "needs an Apple silicon Mac"
    require_tools xcrun gpg gpgv curl shasum perl make

    rm -rf "$WORK"
    check_pointer_authentication

    fetch_verified "$OPENSSL_URL" openssl.asc "$OPENSSL_SIGNER"
    unpack "openssl-$OPENSSL_VERSION.tar.gz" "$WORK/src" openssl

    # The shipped options, except that the tests need the tests and the openssl command.
    for option in "${OPENSSL_OPTIONS[@]}"; do
        [[ $option == no-tests || $option == no-apps ]] || options+=("$option")
    done

    log "Building OpenSSL $OPENSSL_VERSION for macOS arm64e with tests"
    mkdir -p "$WORK/build"
    (
        cd "$WORK/build"
        perl "$WORK/src/Configure" --config="$VENDOR_DIR/openssl/50-shello.conf" \
            shello-darwin-arm64e "${options[@]}" "${HARDENING[@]}"
    ) >"$WORK/build.log" 2>&1 || die "Configure failed, see $WORK/build.log"
    make -C "$WORK/build" -j"$JOBS" >>"$WORK/build.log" 2>&1 || die "build failed, see $WORK/build.log"
    lipo "$WORK/build/apps/openssl" -verify_arch arm64e || die "the openssl command is not arm64e"

    log "Running OpenSSL's tests${tests:+: $tests}"
    make -C "$WORK/build" test HARNESS_JOBS="$JOBS" ${tests:+TESTS="$tests"}
}

main "$@"
