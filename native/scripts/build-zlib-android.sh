#!/usr/bin/env bash
# Build the pinned zlib release as a static Android library for one host ABI.
# The output is installed into the ABI-specific QEMU dependency prefix.

set -euo pipefail

# Resolve repository paths so this script can be invoked from any directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
BUILD_ROOT="${NATIVE_DEPS_BUILD_ROOT:-$ROOT/.work/deps/build}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
ZLIB_VERSION="1.3.1"
ZLIB_TAG="v$ZLIB_VERSION"
ZLIB_REPOSITORY="https://github.com/madler/zlib.git"

# Accept only the ABIs configured by the Android application.
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Require a valid Android API and an installed Linux-host NDK toolchain.
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to a Linux Android NDK installation" >&2
  exit 2
}
command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is required on the build host" >&2
  exit 2
}
command -v cmake >/dev/null 2>&1 || {
  echo "ERROR: CMake is required on the build host" >&2
  exit 2
}
command -v ninja >/dev/null 2>&1 || {
  echo "ERROR: Ninja is required on the build host" >&2
  exit 2
}

# Keep source and build trees separate for each target ABI.
SOURCE_DIR="$SOURCE_ROOT/zlib-$ZLIB_VERSION"
BUILD_DIR="$BUILD_ROOT/zlib-$ABI"
mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"

# Fetch only the exact upstream release tag; never silently update sources.
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --depth 1 --branch "$ZLIB_TAG" "$ZLIB_REPOSITORY" "$SOURCE_DIR"
fi
ACTUAL_TAG="$(git -C "$SOURCE_DIR" describe --tags --exact-match 2>/dev/null || true)"
[[ "$ACTUAL_TAG" == "$ZLIB_TAG" ]] || {
  echo "ERROR: expected zlib tag $ZLIB_TAG, found '${ACTUAL_TAG:-no exact tag}'" >&2
  exit 2
}

# Use CMake's Android toolchain integration to select the NDK compiler,
# Android API level, target ABI, and platform system libraries.
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX/usr" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DZLIB_BUILD_EXAMPLES=OFF

# Install headers, static archive, and pkg-config metadata into this ABI prefix.
cmake --build "$BUILD_DIR" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
cmake --install "$BUILD_DIR"

# Fail if the expected static archive was not installed.
[[ -f "$PREFIX/usr/lib/libz.a" ]] || {
  echo "ERROR: zlib static archive missing from $PREFIX/usr/lib" >&2
  exit 1
}

echo "zlib $ZLIB_VERSION built for $ABI (Android API $API)."
echo "Install prefix: $PREFIX/usr"
echo "This completes only the zlib dependency; GLib and Pixman are still required."
