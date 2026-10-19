#!/usr/bin/env bash
# Builds OpenSSL (libcrypto only) and libssh from verified source into static XCFrameworks in
# Vendor/build/xcframeworks, which Packages/ShelloKit links as binary targets.
# Slices: iOS arm64 and arm64e (one fat library), and the iOS Simulator on arm64.
#
# Usage: Vendor/build.sh [--force]
# Skips the build when the XCFrameworks were built from the same Vendor/ files and Xcode version.
# Needs Xcode, cmake and gpgv (brew install cmake gnupg). Why each choice: Vendor/README.md.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

IOS_DEPLOYMENT_TARGET=26.0 # IPHONEOS_DEPLOYMENT_TARGET in Configurations/Project.xcconfig
SLICES=(ios-arm64 ios-arm64e iossimulator-arm64)

# Client only, no command execution (iOS cannot run ProxyCommand or Match exec anyway), no debug
# output paths. zlib is the one in the iOS SDK.
LIBSSH_OPTIONS=(
    -DBUILD_SHARED_LIBS=OFF
    -DWITH_SERVER=OFF
    -DWITH_EXEC=OFF
    -DWITH_GSSAPI=OFF
    -DWITH_PCAP=OFF
    -DWITH_DEBUG_CALLTRACE=OFF
    -DWITH_NACL=OFF
    -DWITH_SYMBOL_VERSIONING=OFF
    -DWITH_EXAMPLES=OFF
    -DUNIT_TESTING=OFF
    -DWITH_SFTP=ON
    -DWITH_ZLIB=ON
)

OUT="$BUILD_DIR/xcframeworks"
WORK="$BUILD_DIR/work"
LOGS="$WORK/logs"

# Everything that changes the output: the Vendor/ inputs below and the Xcode version.
# .github/workflows/ci.yml keys its cache on the same files.
INPUTS=(build.sh lib.sh sources.sha256 keys openssl libssh patches)
inputs_hash() {
    (
        cd "$VENDOR_DIR"
        find "${INPUTS[@]}" -type f ! -name .DS_Store | LC_ALL=C sort |
            while read -r file; do shasum -a 256 "$file"; done
        xcodebuild -version
    ) | shasum -a 256 | awk '{ print $1 }'
}

run_logged() {
    local logfile=$1
    shift
    if ! "$@" >>"$logfile" 2>&1; then
        tail -n 40 "$logfile" >&2
        die "command failed, full log in $logfile: $*"
    fi
}

slice_settings() {
    case $1 in
    ios-arm64 | ios-arm64e)
        sdk=iphoneos
        arch=${1#ios-}
        min_version=-mios-version-min=$IOS_DEPLOYMENT_TARGET
        platform=IOS
        ;;
    iossimulator-arm64)
        sdk=iphonesimulator
        arch=arm64
        min_version=-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET
        platform=IOSSIMULATOR
        ;;
    *) die "unknown slice $1" ;;
    esac
}

# Fails unless every object in a static library is built for the slice's architecture and platform.
check_library() {
    local library=$1 platforms
    lipo "$library" -verify_arch "$arch" || die "$library has no $arch slice"
    platforms=$(otool -l "$library" | awk '$1 == "platform" { print $2 }' | sort -u)
    [[ $platforms == "$(platform_number "$platform")" ]] ||
        die "$library is built for platform '$platforms', expected $platform"
}

platform_number() {
    case $1 in
    IOS) echo 2 ;;
    IOSSIMULATOR) echo 7 ;;
    esac
}

build_openssl() {
    local slice=$1 src="$WORK/src/openssl"
    local build="$WORK/$slice/openssl-build" prefix="$WORK/$slice/openssl" logfile="$LOGS/$slice-openssl.log"
    slice_settings "$slice"
    log "Building OpenSSL $OPENSSL_VERSION for $slice"
    rm -rf "$build" "$prefix"
    mkdir -p "$build" "$prefix/lib" "$prefix/include/openssl"
    (
        cd "$build"
        run_logged "$logfile" perl "$src/Configure" --config="$VENDOR_DIR/openssl/50-shello.conf" \
            "shello-$slice" "${OPENSSL_OPTIONS[@]}" "$min_version" "${HARDENING[@]}"
    )
    run_logged "$logfile" make -C "$build" -j"$JOBS" build_generated
    run_logged "$logfile" make -C "$build" -j"$JOBS" libcrypto.a
    cp "$build/libcrypto.a" "$prefix/lib/"
    # Public headers: the ones in the source tree plus the ones Configure generates.
    cp "$src"/include/openssl/*.h "$build"/include/openssl/*.h "$prefix/include/openssl/"
    check_library "$prefix/lib/libcrypto.a"
}

build_libssh() {
    local slice=$1 src="$WORK/src/libssh"
    local build="$WORK/$slice/libssh-build" prefix="$WORK/$slice/libssh" openssl="$WORK/$slice/openssl"
    local logfile="$LOGS/$slice-libssh.log" sdk_path
    slice_settings "$slice"
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    log "Building libssh $LIBSSH_VERSION for $slice"
    rm -rf "$build" "$prefix"
    # The OpenSSL and zlib paths are given explicitly so that CMake can never pick up a
    # Homebrew or system copy instead.
    run_logged "$logfile" cmake -S "$src" -B "$build" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
        -DCMAKE_C_FLAGS="$min_version ${HARDENING[*]}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DOPENSSL_ROOT_DIR="$openssl" \
        -DOPENSSL_INCLUDE_DIR="$openssl/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl/lib/libcrypto.a" \
        -DZLIB_INCLUDE_DIR="$sdk_path/usr/include" \
        -DZLIB_LIBRARY="$sdk_path/usr/lib/libz.tbd" \
        "${LIBSSH_OPTIONS[@]}"
    # ML-KEM comes from OpenSSL 3.5 (docs/spec/STACK.md section 7.2), not libssh's bundled copy.
    grep -q '^#define HAVE_OPENSSL_MLKEM 1' "$build/config.h" ||
        die "libssh did not detect OpenSSL's ML-KEM, see $logfile"
    run_logged "$logfile" cmake --build "$build" --parallel "$JOBS"
    run_logged "$logfile" cmake --install "$build"
    check_library "$prefix/lib/libssh.a"
}

# One library per platform: the two device slices are merged into one fat library.
create_xcframework() {
    local dir=$1 lib=$2 output=$3 device_lib="$WORK/ios/$1/$2"
    mkdir -p "${device_lib%/*}"
    # Both device slices must have been configured alike, or one set of headers would be wrong.
    diff -r "$WORK/ios-arm64/$dir/include" "$WORK/ios-arm64e/$dir/include" >/dev/null ||
        die "$dir headers differ between arm64 and arm64e"
    lipo -create "$WORK/ios-arm64/$dir/lib/$lib" "$WORK/ios-arm64e/$dir/lib/$lib" -output "$device_lib"
    run_logged "$LOGS/xcframeworks.log" xcodebuild -create-xcframework \
        -library "$device_lib" -headers "$WORK/ios-arm64/$dir/include" \
        -library "$WORK/iossimulator-arm64/$dir/lib/$lib" -headers "$WORK/iossimulator-arm64/$dir/include" \
        -output "$OUT.new/$output.xcframework"
}

main() {
    local force=false hash slice
    [[ ${1:-} == --force ]] && force=true
    require_tools xcodebuild xcrun cmake gpg gpgv curl shasum perl

    hash=$(inputs_hash)
    if ! $force && [[ -f $OUT/inputs.sha256 && $(<"$OUT/inputs.sha256") == "$hash" ]]; then
        log "XCFrameworks are up to date: $OUT (Vendor/build.sh --force rebuilds)"
        return
    fi

    fetch_verified "$OPENSSL_URL" openssl.asc "$OPENSSL_SIGNER"
    fetch_verified "$LIBSSH_URL" libssh.asc "$LIBSSH_SIGNER"

    rm -rf "$WORK"
    mkdir -p "$LOGS"
    unpack "openssl-$OPENSSL_VERSION.tar.gz" "$WORK/src/openssl" openssl
    unpack "libssh-$LIBSSH_VERSION.tar.xz" "$WORK/src/libssh" libssh

    for slice in "${SLICES[@]}"; do
        build_openssl "$slice"
        build_libssh "$slice"
        # The module map makes libssh importable from Swift as CLibSSH.
        cp "$VENDOR_DIR/libssh/module.modulemap" "$WORK/$slice/libssh/include/"
    done

    log "Creating XCFrameworks"
    rm -rf "$OUT.new"
    mkdir -p "$OUT.new"
    create_xcframework openssl libcrypto.a libcrypto
    create_xcframework libssh libssh.a libssh
    echo "$hash" >"$OUT.new/inputs.sha256"
    rm -rf "$OUT"
    mv "$OUT.new" "$OUT"

    log "Done: $OUT"
    du -sh "$OUT"/*.xcframework/*/*.a >&2
}

main "$@"
