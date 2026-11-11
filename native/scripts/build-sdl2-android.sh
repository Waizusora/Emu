#!/usr/bin/env bash
# Build the pinned SDL2 Android port into the ABI-specific QEMU sysroot.
# This stage produces the native library and SDL Android Java bridge sources;
# it does not yet enable QEMU's SDL display in the app process.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
SOURCE_ROOT="${SDL_SOURCE_ROOT:-$ROOT/.work/SDL2-2.30.12}"
BUILD_ROOT="${SDL_BUILD_ROOT:-$ROOT/.work/sdl2-build}"
VERSION="2.30.12"
ARCHIVE="SDL2-$VERSION.tar.gz"
URL="https://www.libsdl.org/release/$ARCHIVE"
SHA256="ac356ea55e8b9dd0b2d1fa27da40ef7e238267ccf9324704850d5d47375b48ea"

case "$ABI" in
  arm64-v8a) ;;
  x86_64) ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -n "$NDK" && -d "$NDK/build/cmake/android.toolchain.cmake" ]] || {
  echo "ERROR: set ANDROID_NDK_HOME to an Android NDK installation" >&2
  exit 2
}
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum is required" >&2; exit 2; }
command -v cmake >/dev/null 2>&1 || { echo "ERROR: CMake is required" >&2; exit 2; }
command -v ninja >/dev/null 2>&1 || { echo "ERROR: Ninja is required" >&2; exit 2; }

DOWNLOAD_DIR="$ROOT/.work/downloads"
mkdir -p "$DOWNLOAD_DIR" "$PREFIX"
ARCHIVE_PATH="$DOWNLOAD_DIR/$ARCHIVE"
if [[ ! -s "$ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 --output "$ARCHIVE_PATH.tmp" "$URL"
  mv "$ARCHIVE_PATH.tmp" "$ARCHIVE_PATH"
fi
echo "$SHA256  $ARCHIVE_PATH" | sha256sum --check --status || {
  rm -f "$ARCHIVE_PATH"
  echo "ERROR: SDL2 $VERSION source archive SHA-256 mismatch" >&2
  exit 1
}

if [[ ! -f "$SOURCE_ROOT/CMakeLists.txt" ]]; then
  rm -rf "$SOURCE_ROOT"
  mkdir -p "$SOURCE_ROOT"
  tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C "$SOURCE_ROOT"
fi
[[ -f "$SOURCE_ROOT/CMakeLists.txt" ]] || {
  echo "ERROR: SDL2 source archive did not contain CMakeLists.txt" >&2
  exit 1
}
JAVA_SOURCE="$SOURCE_ROOT/android-project/app/src/main/java/org/libsdl/app"
[[ -s "$JAVA_SOURCE/SDLActivity.java" ]] || {
  echo "ERROR: pinned SDL2 Android Java bridge sources are missing" >&2
  exit 1
}

BUILD_DIR="$BUILD_ROOT/$ABI"
mkdir -p "$BUILD_DIR"
cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX/usr" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSDL_SHARED=OFF \
  -DSDL_STATIC=ON \
  -DSDL_TEST=OFF \
  -DSDL_TESTS=OFF \
  -DSDL_INSTALL=ON \
  -DSDL_AUDIO=ON \
  -DSDL_VIDEO=ON \
  -DSDL_RENDER=ON \
  -DSDL_JOYSTICK=ON \
  -DSDL_HAPTIC=OFF \
  -DSDL_SENSOR=ON \
  -DSDL_POWER=ON \
  -DSDL_HIDAPI=OFF
cmake --build "$BUILD_DIR" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
cmake --install "$BUILD_DIR"

[[ -s "$PREFIX/usr/lib/libSDL2.a" ]] || {
  echo "ERROR: SDL2 static library was not installed for $ABI" >&2
  exit 1
}
[[ -s "$PREFIX/usr/include/SDL2/SDL.h" ]] || {
  echo "ERROR: SDL2 public headers were not installed for $ABI" >&2
  exit 1
}

# Keep SDL's official Android Activity/JNI bridge sources beside the ABI
# sysroot. The app integration stage will consume these from the arm64 artifact.
JAVA_DEST="$PREFIX/share/SDL2/android-java/org/libsdl/app"
mkdir -p "$JAVA_DEST"
cp -a "$JAVA_SOURCE/." "$JAVA_DEST/"

echo "SDL2 $VERSION built for Android $ABI (API $API)."
echo "Static library: $PREFIX/usr/lib/libSDL2.a"
echo "Headers: $PREFIX/usr/include/SDL2"
echo "Android Java bridge: $JAVA_DEST"
echo "Note: upstream SDL2 Android audio still uses its Android JNI audio path; AAudio is a separate integration stage."
