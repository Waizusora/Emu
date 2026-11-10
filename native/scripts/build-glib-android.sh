#!/usr/bin/env bash
# Cross-build GLib 2.82.4 for Android using the ABI-specific Meson cross file.
# zlib, libffi, and PCRE2 must already be installed into the same sysroot.

set -euo pipefail

# Resolve paths and preserve the same per-ABI dependency prefix as earlier stages.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
BUILD_ROOT="${NATIVE_DEPS_BUILD_ROOT:-$ROOT/.work/deps/build}"
CROSS_FILE="${ANDROID_MESON_CROSS_FILE:-$ROOT/.work/meson/android-$ABI.ini}"
VERSION="2.82.4"
ARCHIVE="glib-$VERSION.tar.xz"
URL="https://download.gnome.org/sources/glib/2.82/$ARCHIVE"

# Validate the selected Android ABI and the dependency metadata it needs.
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
[[ -d "$PREFIX/usr/include" ]] || {
  echo "ERROR: dependency headers are missing; run build-android-deps.sh first" >&2
  exit 2
}
[[ -f "$CROSS_FILE" ]] || {
  echo "ERROR: Meson cross file missing; run create-android-meson-cross-file.sh first" >&2
  exit 2
}
for module in zlib libffi libpcre2-8; do
  if ! PKG_CONFIG_SYSROOT_DIR="$PREFIX" \
       PKG_CONFIG_LIBDIR="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig" \
       pkg-config --exists "$module"; then
    echo "ERROR: required target pkg-config module '$module' is missing" >&2
    exit 2
  fi
done
for tool in curl tar meson ninja pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required on the build host" >&2
    exit 2
  }
done

mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$PREFIX"
ARCHIVE_PATH="$SOURCE_ROOT/$ARCHIVE"
SOURCE_DIR="$SOURCE_ROOT/glib-$VERSION"
BUILD_DIR="$BUILD_ROOT/glib-$ABI"

# Download and unpack the exact GNOME release archive.
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  curl --fail --location --retry 3 "$URL" --output "$ARCHIVE_PATH"
fi
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
tar -xJf "$ARCHIVE_PATH" --strip-components=1 -C "$SOURCE_DIR"
[[ -f "$SOURCE_DIR/meson.build" ]] || {
  echo "ERROR: GLib release archive is missing meson.build" >&2
  exit 1
}

# Restrict dependency lookup to the target sysroot.
# GLib requires gettext support even when NLS catalogs are disabled.
# Its bundled proxy-libintl Meson fallback supplies that API for Android,
# where the NDK libc does not provide libintl.h or libintl.
export PKG_CONFIG_SYSROOT_DIR="$PREFIX"
export PKG_CONFIG_LIBDIR="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig"
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$SOURCE_DIR" \
  --cross-file "$CROSS_FILE" \
  --prefix /usr \
  --libdir lib \
  --buildtype release \
  --wrap-mode default \
  -Ddefault_library=static \
  -Dtests=false \
  -Dinstalled_tests=false \
  -Dintrospection=disabled \
  -Dman-pages=disabled \
  -Ddocumentation=false \
  -Dgtk_doc=false \
  -Dlibmount=disabled \
  -Dselinux=disabled \
  -Dxattr=false \
  -Dsysprof=disabled \
  -Dnls=disabled \
  -Dlibelf=disabled

# Compile GLib and install its libraries, headers, and pkg-config files.
ninja -C "$BUILD_DIR" -j "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
DESTDIR="$PREFIX" ninja -C "$BUILD_DIR" install

for module in glib-2.0 gobject-2.0 gio-2.0; do
  PKG_CONFIG_SYSROOT_DIR="$PREFIX" \
  PKG_CONFIG_LIBDIR="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig" \
    pkg-config --exists "$module" || {
      echo "ERROR: GLib module '$module' was not installed" >&2
      exit 1
    }
done

echo "GLib $VERSION built for $ABI (Android API $API)."
echo "Install prefix: $PREFIX/usr"
