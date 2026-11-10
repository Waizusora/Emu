#!/usr/bin/env bash
# Cross-build Pixman 0.44.2 for Android using the generated Meson cross file.
# Pixman is a required graphics dependency of QEMU's system emulator.

set -euo pipefail

# Resolve paths and use the selected ABI's isolated dependency prefix.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
BUILD_ROOT="${NATIVE_DEPS_BUILD_ROOT:-$ROOT/.work/deps/build}"
CROSS_FILE="${ANDROID_MESON_CROSS_FILE:-$ROOT/.work/meson/android-$ABI.ini}"
VERSION="0.44.2"
ARCHIVE="pixman-$VERSION.tar.gz"
URL="https://www.cairographics.org/releases/$ARCHIVE"

# Validate supported Android ABIs and Meson build prerequisites.
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac
[[ "$API" =~ ^[0-9]+$ ]] && (( API >= 28 )) || {
  echo "ERROR: ANDROID_API must be an integer >= 28" >&2
  exit 2
}
[[ -f "$CROSS_FILE" ]] || {
  echo "ERROR: Meson cross file missing; run create-android-meson-cross-file.sh first" >&2
  exit 2
}
for tool in curl tar meson ninja; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required on the build host" >&2
    exit 2
  }
done

mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"
ARCHIVE_PATH="$SOURCE_ROOT/$ARCHIVE"
SOURCE_DIR="$SOURCE_ROOT/pixman-$VERSION"
BUILD_DIR="$BUILD_ROOT/pixman-$ABI"

# Fetch the pinned release archive and unpack it into a clean source directory.
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 "$URL" --output "$ARCHIVE_PATH"
fi
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
tar -xzf "$ARCHIVE_PATH" --strip-components=1 -C "$SOURCE_DIR"
[[ -f "$SOURCE_DIR/meson.build" ]] || {
  echo "ERROR: Pixman release archive is missing meson.build" >&2
  exit 1
}

# Build only the library; demos, tests, optional GTK, and PNG are not needed.
export PKG_CONFIG_SYSROOT_DIR="$PREFIX"
export PKG_CONFIG_LIBDIR="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig"
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$SOURCE_DIR" \
  --cross-file "$CROSS_FILE" \
  --prefix "$PREFIX/usr" \
  --libdir lib \
  --buildtype release \
  --wrap-mode nofallback \
  -Ddefault_library=static \
  -Dtests=disabled \
  -Ddemos=disabled \
  -Dgtk=disabled \
  -Dlibpng=disabled \
  -Dopenmp=disabled

# Install the static Pixman archive and its pixman-1 pkg-config module.
ninja -C "$BUILD_DIR" -j "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
ninja -C "$BUILD_DIR" install

PKG_CONFIG_SYSROOT_DIR="$PREFIX" \
PKG_CONFIG_LIBDIR="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig" \
  pkg-config --exists pixman-1 || {
    echo "ERROR: Pixman pkg-config metadata was not installed" >&2
    exit 1
  }
[[ -f "$PREFIX/usr/lib/libpixman-1.a" ]] || {
  echo "ERROR: Pixman static archive missing from $PREFIX/usr/lib" >&2
  exit 1
}

echo "Pixman $VERSION built for $ABI (Android API $API)."
echo "Install prefix: $PREFIX/usr"
