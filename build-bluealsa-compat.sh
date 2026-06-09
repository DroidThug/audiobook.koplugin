#!/usr/bin/env bash
# Build bluez-alsa against Debian Jessie (glibc 2.19) for Kobo armv7l
# This produces a binary compatible with older Kobo devices like Clara 2E.
#
# Usage:
#   nix-shell -p pkgsCross.armv7l-hf-multiplatform.stdenv.cc autoconf automake libtool pkg-config
#   bash build-bluealsa-compat.sh
# Output: .build-bluealsa-compat/out/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build-bluealsa-compat"
SYSROOT="$BUILD_DIR/sysroot"
OUTPUT="$BUILD_DIR/out"
DEB_MIRROR="http://archive.debian.org/debian"

# Debian Jessie packages needed for the sysroot.
# We need both runtime libs and -dev packages (for headers and .so symlinks).
DEBIAN_PACKAGES="
libc6
libc6-dev
linux-libc-dev
libbluetooth-dev
libbluetooth3
libasound2-dev
libasound2
libasound2-data
libdbus-1-dev
libdbus-1-3
libglib2.0-dev
libglib2.0-0
libglib2.0-data
libsbc-dev
libsbc1
libpcre3-dev
libpcre3
libffi-dev
libffi6
zlib1g-dev
zlib1g
libselinux1
libsepol1
libsystemd0
liblzma5
libattr1
libacl1
libgcrypt20
libgpg-error0
"

BLUEALSA_VERSION="4.1.1"
BLUEALSA_URL="https://github.com/arkq/bluez-alsa/archive/v${BLUEALSA_VERSION}.tar.gz"

# ── Setup ─────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$SYSROOT" "$OUTPUT" "$BUILD_DIR/debs"

# ── Find cross-compiler ───────────────────────────────────────────────
for cc_candidate in armv7l-unknown-linux-gnueabihf-gcc arm-linux-gnueabihf-gcc; do
    if command -v "$cc_candidate" >/dev/null 2>&1; then
        export CC="$cc_candidate"
        break
    fi
done

if [ -z "${CC:-}" ]; then
    echo "ERROR: No armv7l cross-compiler found in PATH."
    echo "Install one via Nix:"
    echo "  nix-shell -p pkgsCross.armv7l-hf-multiplatform.stdenv.cc autoconf automake libtool pkg-config"
    exit 1
fi

# Derive related tools from the compiler name
TRIPLET="${CC%-gcc}"
export CXX="${TRIPLET}-g++"
export AR="${TRIPLET}-ar"
export STRIP="${TRIPLET}-strip"
export READELF="${TRIPLET}-readelf"

for tool in "$CXX" "$AR" "$READELF"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Missing cross-compilation tool: $tool"
        exit 1
    fi
done

echo "Cross-compiler: $CC"
echo "Sysroot:        $SYSROOT"
echo "Output:         $OUTPUT"

# ── Download Debian Jessie package index ──────────────────────────────
echo ""
echo "=== Downloading Debian Jessie package index ==="
curl -fsL "$DEB_MIRROR/dists/jessie/main/binary-armhf/Packages.gz" \
    | gunzip > "$BUILD_DIR/Packages"

# ── Download and extract packages ─────────────────────────────────────
echo ""
echo "=== Downloading Debian packages ==="

for pkg in $DEBIAN_PACKAGES; do
    # Extract Filename and SHA256 for this package from the index
    block=$(awk -v p="$pkg" '
        /^Package: / { in_pkg = ($2 == p) }
        in_pkg {
            print
            if (/^$/) { exit }
        }
    ' "$BUILD_DIR/Packages")

    if [ -z "$block" ]; then
        echo "WARNING: Package '$pkg' not found in Jessie index — skipping"
        continue
    fi

    filename=$(echo "$block" | awk '/^Filename: / { print $2; exit }')
    sha256=$(echo "$block" | awk '/^SHA256: / { print $2; exit }')
    debname=$(basename "$filename")

    if [ -z "$filename" ] || [ -z "$sha256" ]; then
        echo "WARNING: Could not parse index entry for '$pkg' — skipping"
        continue
    fi

    echo "  $pkg -> $debname"
    curl -fsL "$DEB_MIRROR/$filename" -o "$BUILD_DIR/debs/$debname"

    # Verify checksum
    echo "$sha256  $BUILD_DIR/debs/$debname" | sha256sum -c - >/dev/null

    # Extract .deb contents (ar archive containing data.tar.*)
    mkdir -p "$BUILD_DIR/extract"
    cd "$BUILD_DIR/extract"
    ${AR:-ar} x "$BUILD_DIR/debs/$debname"

    for tarfile in data.tar.xz data.tar.gz data.tar.bz2; do
        if [ -f "$tarfile" ]; then
            case "$tarfile" in
                *.xz) tar xf "$tarfile" -C "$SYSROOT" ;;
                *.gz) tar xzf "$tarfile" -C "$SYSROOT" ;;
                *.bz2) tar xjf "$tarfile" -C "$SYSROOT" ;;
            esac
            break
        fi
    done

    cd "$BUILD_DIR"
    rm -rf extract
done

# ── Sanity-check sysroot ──────────────────────────────────────────────
if [ ! -f "$SYSROOT/lib/arm-linux-gnueabihf/libc.so.6" ]; then
    echo "ERROR: Sysroot creation failed — libc.so.6 not found"
    echo "Looked in: $SYSROOT/lib/arm-linux-gnueabihf/"
    exit 1
fi

GLIBC_VERSION=$($READELF -V "$SYSROOT/lib/arm-linux-gnueabihf/libc.so.6" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -V | tail -1 || echo "unknown")
echo ""
echo "Sysroot glibc max version: $GLIBC_VERSION"

# ── Download bluez-alsa source ────────────────────────────────────────
echo ""
echo "=== Downloading bluez-alsa v$BLUEALSA_VERSION ==="
curl -fsL "$BLUEALSA_URL" -o "$BUILD_DIR/bluez-alsa.tar.gz"
tar xzf "$BUILD_DIR/bluez-alsa.tar.gz" -C "$BUILD_DIR"

# ── Build bluez-alsa ──────────────────────────────────────────────────
echo ""
echo "=== Building bluez-alsa ==="
cd "$BUILD_DIR/bluez-alsa-$BLUEALSA_VERSION"

# Generate configure script if needed (GitHub auto-tarballs lack it)
if [ ! -f configure ]; then
    echo "Running autoreconf..."
    autoreconf -fi
fi

# Set up build environment
export CFLAGS="--sysroot=$SYSROOT -I$SYSROOT/usr/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib/arm-linux-gnueabihf -L$SYSROOT/lib/arm-linux-gnueabihf"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/arm-linux-gnueabihf/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

# Disable features that pull in extra deps or aren't needed on Kobo
./configure \
    --host=arm-linux-gnueabihf \
    --prefix="$OUTPUT" \
    --disable-systemd \
    --disable-hcitop \
    --disable-rfcomm \
    --enable-aac=no \
    --enable-debug=no \
    --enable-static=no \
    --enable-shared=yes

make -j"$(nproc 2>/dev/null || echo 2)"
make install

# ── Copy non-glibc runtime libraries ──────────────────────────────────
echo ""
echo "=== Collecting runtime libraries ==="

# Helper: copy a library and its deps from the sysroot
copy_lib_tree() {
    local src="$1"
    local dst_dir="$2"
    local basename_src
    basename_src=$(basename "$src")

    # Skip if already copied
    [ -f "$dst_dir/$basename_src" ] && return 0

    # Skip glibc and other core system libs (device already has these)
    case "$basename_src" in
        ld-*.so*|ld-linux*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|libnsl.so*|libutil.so*|libanl.so*|libcrypt.so*)
            return 0
            ;;
    esac

    cp -L "$src" "$dst_dir/$basename_src"

    # Recursively copy dependencies
    local needed
    needed=$($READELF -d "$src" 2>/dev/null | awk '/NEEDED/ { print $5 }' | tr -d '[]' || true)
    for soname in $needed; do
        local libpath
        libpath=$(find "$SYSROOT" -name "$soname" -o -name "$soname.*" 2>/dev/null | head -1)
        if [ -n "$libpath" ]; then
            copy_lib_tree "$libpath" "$dst_dir"
        fi
    done
}

# Collect deps for bluealsa binary and ALSA plugins
mkdir -p "$OUTPUT/lib"
for binary in "$OUTPUT/bin/bluealsa" "$OUTPUT/lib/alsa-lib/libasound_module_pcm_bluealsa.so" "$OUTPUT/lib/alsa-lib/libasound_module_ctl_bluealsa.so"; do
    if [ -f "$binary" ]; then
        needed=$($READELF -d "$binary" 2>/dev/null | awk '/NEEDED/ { print $5 }' | tr -d '[]' || true)
        for soname in $needed; do
            libpath=$(find "$SYSROOT" -name "$soname" -o -name "$soname.*" 2>/dev/null | head -1)
            if [ -n "$libpath" ]; then
                copy_lib_tree "$libpath" "$OUTPUT/lib"
            fi
        done
    fi
done

# ── Verify output ─────────────────────────────────────────────────────
echo ""
echo "=== Verifying output ==="

if [ ! -f "$OUTPUT/bin/bluealsa" ]; then
    echo "ERROR: bluealsa binary not found in $OUTPUT/bin/"
    exit 1
fi

# Check ELF interpreter
INTERP=$($READELF -l "$OUTPUT/bin/bluealsa" 2>/dev/null | awk -F'[][]' '/interpreter/ { print $2 }')
echo "ELF interpreter: $INTERP"

if echo "$INTERP" | grep -q '/nix/store/'; then
    echo "WARNING: Binary still has Nix store interpreter — something went wrong"
fi

# Check max glibc symbol version
MAX_GLIBC=$($READELF -sW "$OUTPUT/bin/bluealsa" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -V | tail -1 || echo "unknown")
echo "Max GLIBC symbol version: $MAX_GLIBC"

if [ "$MAX_GLIBC" != "unknown" ]; then
    major=$(echo "$MAX_GLIBC" | cut -d. -f1)
    minor=$(echo "$MAX_GLIBC" | cut -d. -f2)
    if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -gt 19 ]; }; then
        echo "WARNING: Binary references glibc symbols newer than 2.19 — may fail on Clara 2E"
    else
        echo "OK: Binary is compatible with glibc 2.19"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "=== Build complete ==="
echo "Output directory: $OUTPUT"
echo ""
echo "Binaries:"
ls -la "$OUTPUT/bin/"
echo ""
echo "Libraries:"
ls -la "$OUTPUT/lib/"
echo ""
echo "ALSA plugins:"
ls -la "$OUTPUT/lib/alsa-lib/" 2>/dev/null || echo "  (none)"
