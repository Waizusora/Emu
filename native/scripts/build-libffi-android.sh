#!/usr/bin/env bash
# Cross-build a pinned static libffi release for one Android host ABI.
# GLib uses libffi for its closure and foreign-function interfaces.

set -euo pipefail

# Resolve repository paths and configurable dependency locations.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
BUILD_ROOT="${NATIVE_DEPS_BUILD_ROOT:-$ROOT/.work/deps/build}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
VERSION="3.4.6"
ARCHIVE="libffi-$VERSION.tar.gz"
URL="https://github.com/libffi/libffi/releases/download/v$VERSION/$ARCHIVE"

# Translate Android ABI names into NDK compiler target triples.
case "$ABI" in
  arm64-v8a) TRIPLE="aarch64-linux-android" ;;
  x86_64) TRIPLE="x86_64-linux-android" ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Validate build tools and the selected NDK before downloading sources.
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to a Linux Android NDK installation" >&2
  exit 2
}
for tool in curl tar make; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required on the build host" >&2
    exit 2
  }
done

# Select the API-specific compiler and matching LLVM binutils.
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN/$TRIPLE$API-clang"
AR="$TOOLCHAIN/llvm-ar"
RANLIB="$TOOLCHAIN/llvm-ranlib"
STRIP="$TOOLCHAIN/llvm-strip"
for tool in "$CC" "$AR" "$RANLIB" "$STRIP"; do
  [[ -x "$tool" ]] || {
    echo "ERROR: missing NDK tool: $tool" >&2
    exit 2
  }
done

mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"
ARCHIVE_PATH="$SOURCE_ROOT/$ARCHIVE"
SOURCE_DIR="$SOURCE_ROOT/libffi-$VERSION"
BUILD_DIR="$BUILD_ROOT/libffi-$ABI"

# Download the immutable release archive only when it is not already cached.
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 "$URL" --output "$ARCHIVE_PATH"
fi

# Re-extract the pinned release to avoid carrying stale generated files.
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C "$SOURCE_DIR"
[[ -x "$SOURCE_DIR/configure" ]] || {
  echo "ERROR: libffi release archive does not contain its configure script" >&2
  exit 1
}

# Configure libffi as a position-independent static Android library.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
CFLAGS="-O2 -fPIC" \
"$SOURCE_DIR/configure" \
  --host="$TRIPLE" \
  --prefix=/usr \
  --disable-shared \
  --enable-static \
  --with-pic

# Build and install the static archive and headers into the ABI prefix.
make -j"${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
make DESTDIR="$PREFIX" install

[[ -f "$PREFIX/usr/lib/libffi.a" ]] || {
  echo "ERROR: libffi static archive missing from $PREFIX/usr/lib" >&2
  exit 1
}
[[ -f "$PREFIX/usr/lib/pkgconfig/libffi.pc" ]] || {
  echo "ERROR: libffi pkg-config metadata missing from $PREFIX/usr/lib/pkgconfig" >&2
  exit 1
}

echo "libffi $VERSION built for $ABI (Android API $API)."
echo "Install prefix: $PREFIX/usr"
