#!/usr/bin/env bash
# Verify the Android dependency sysroot before it is passed to the QEMU build.
# This checks target metadata and static archives, not runtime device behavior.

set -euo pipefail

# Resolve the repository root and the ABI-specific dependency prefix.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"
PREFIX="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
PKG_CONFIG_DIRS="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig"

# Accept only ABIs that are built and packaged by this Android application.
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: supported ABI values: arm64-v8a, x86_64" >&2
    exit 2
    ;;
esac

# Require pkg-config and the selected sysroot before inspecting its contents.
command -v pkg-config >/dev/null 2>&1 || {
  echo "ERROR: pkg-config is required on the build host" >&2
  exit 2
}
[[ -d "$PREFIX/usr/include" && -d "$PREFIX/usr/lib" ]] || {
  echo "ERROR: incomplete Android sysroot: $PREFIX/usr" >&2
  exit 1
}

# Restrict metadata resolution to this ABI; host Linux packages are forbidden.
export PKG_CONFIG_SYSROOT_DIR="$PREFIX"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_DIRS"
export PKG_CONFIG_ALLOW_CROSS=1

# Verify the metadata required by the dependency build and QEMU configure.
for module in zlib libffi libpcre2-8 glib-2.0 gobject-2.0 gio-2.0 pixman-1; do
  pkg-config --exists "$module" || {
    echo "ERROR: missing target pkg-config module: $module" >&2
    exit 1
  }
  # Ensure every module resolves to the selected sysroot, not a host prefix.
  module_prefix="$(pkg-config --variable=prefix "$module")"
  case "$module_prefix" in
    "$PREFIX"/*) ;;
    *)
      echo "ERROR: $module resolves outside target sysroot: $module_prefix" >&2
      exit 1
      ;;
  esac
done

# Check the static archives expected from each pinned dependency build.
for archive in \
  libz.a \
  libffi.a \
  libpcre2-8.a \
  libglib-2.0.a \
  libgobject-2.0.a \
  libgio-2.0.a \
  libpixman-1.a; do
  [[ -s "$PREFIX/usr/lib/$archive" ]] || {
    echo "ERROR: required static archive missing: $PREFIX/usr/lib/$archive" >&2
    exit 1
  }
done

# Ask pkg-config to resolve static link flags for the final QEMU dependencies.
pkg-config --static --libs glib-2.0 pixman-1 >/dev/null

echo "Android dependency sysroot verified for $ABI."
echo "Prefix: $PREFIX/usr"
echo "Verified modules: zlib, libffi, libpcre2-8, glib-2.0, gobject-2.0, gio-2.0, pixman-1"
