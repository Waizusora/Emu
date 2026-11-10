#!/usr/bin/env bash
# Cross-build PCRE2 10.44 as a static Android library for GLib.
# Only the 8-bit library is required by the GLib configuration used here.

set -euo pipefail

# Resolve paths relative to the repository root.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
BUILD_ROOT="${NATIVE_DEPS_BUILD_ROOT:-$ROOT/.work/deps/build}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
VERSION="10.44"
TAG="pcre2-$VERSION"
REPOSITORY="https://github.com/PCRE2Project/pcre2.git"

# Restrict builds to the Android host ABIs shipped by the app.
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Validate NDK, API, and native build tools.
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to a Linux Android NDK installation" >&2
  exit 2
}
for tool in git cmake ninja; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required on the build host" >&2
    exit 2
  }
done

SOURCE_DIR="$SOURCE_ROOT/pcre2-$VERSION"
BUILD_DIR="$BUILD_ROOT/pcre2-$ABI"
mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"

# Fetch the exact upstream release tag and reject any unexpected checkout.
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --depth 1 --branch "$TAG" "$REPOSITORY" "$SOURCE_DIR"
fi
ACTUAL_TAG="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
[[ "$ACTUAL_TAG" == "$TAG" ]] || {
  echo "ERROR: expected PCRE2 tag $TAG, found '${ACTUAL_TAG:-no exact tag}'" >&2
  exit 2
}

# Use the NDK CMake toolchain and disable host-side utilities and JIT.
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=OFF \
  -DPCRE2_BUILD_PCRE2_32=OFF \
  -DPCRE2_SUPPORT_JIT=OFF \
  -DPCRE2_STATIC_PIC=ON \
  -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DBUILD_TESTING=OFF

# Install the target library and development metadata into the ABI prefix.
cmake --build "$BUILD_DIR" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
DESTDIR="$PREFIX" cmake --install "$BUILD_DIR"

[[ -f "$PREFIX/usr/lib/libpcre2-8.a" ]] || {
  echo "ERROR: PCRE2 8-bit static archive missing from $PREFIX/usr/lib" >&2
  exit 1
}

echo "PCRE2 $VERSION built for $ABI (Android API $API)."
echo "Install prefix: $PREFIX/usr"
